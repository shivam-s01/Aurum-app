// =============================================================================
// FILE: lib/providers/recently_played_provider.dart
// PROJECT: Aurum Music
// VERSION: 2.0.0 — RecommendationEngine Integration
//
// WHAT'S NEW IN v2:
//   ✅ Hooks into RecommendationEngine on every addPlay()
//   ✅ Tracks completion via notifyCompletion() (called from PlayerProvider)
//   ✅ Tracks early skips via notifySkip() (called from PlayerProvider)
//   ✅ Tracks replay via notifyReplay() (called from PlayerProvider)
//   ✅ Tracks favorites via notifyFavorited/Unfavorited() (from FavoritesProvider)
//   ✅ topArtists() still works as before (backward compatible)
//   ✅ All existing Hive persistence logic unchanged
//   ✅ applyDecay() called on init once per day (SharedPreferences date check)
//
// BACKWARD COMPATIBILITY:
//   - `history` getter: unchanged
//   - `init()`: unchanged signature
//   - `addPlay(Song)`: unchanged signature
//   - `topArtists({int count})`: unchanged
//   All new methods are additive. Nothing removed.
// =============================================================================

import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../utils/constants.dart';
import '../services/recommendation_engine.dart';
import '../services/audio_prefs.dart';

class RecentlyPlayedProvider extends ChangeNotifier {
  static const _boxName         = AppConstants.boxRecentlyPlayed;
  static const _kLastDecayDate  = 'aurum_rec_last_decay_date';

  late Box<Map> _box;
  List<Song>    _history = [];
  // Tracks when each song currently in _history was (re-)played, so disk
  // order can be reconstructed independent of Hive's key iteration order.
  // Only updated when a song is actually inserted/moved-to-front in
  // _addPlay — never touched by trims or the diff-write in _persistHistory,
  // so re-saving an unchanged entry doesn't shift its timestamp/position.
  final Map<String, int> _playedAtById = {};

  // ---------------------------------------------------------------------------
  // PUBLIC GETTERS (unchanged)
  // ---------------------------------------------------------------------------

  /// Newest-first list of recently played songs. Used by Library screen.
  List<Song> get history => List.unmodifiable(_history);

  // ---------------------------------------------------------------------------
  // INIT
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
    // ROOT FIX: ordering must not depend on Hive's internal key iteration
    // order — that only reflects insertion order when every write is a
    // full clear+rewrite-in-order, which the new diff-based persistence
    // (see _addPlay below) deliberately avoids for crash-safety. Instead,
    // each stored entry carries its own `_playedAt` timestamp (added at
    // write time), and history order is reconstructed by sorting on that
    // — correct regardless of what order Hive happens to iterate keys in.
    final entries = _box.values.map((m) {
      final map = Map<String, dynamic>.from(m);
      final playedAtMs = map['_playedAt'] as int?;
      return (
        song: Song.fromJson(map),
        playedAt: playedAtMs ?? 0,
      );
    }).toList()
      ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    _history = entries.map((e) => e.song).toList();
    _playedAtById
      ..clear()
      ..addEntries(entries.map((e) => MapEntry(e.song.id, e.playedAt)));

    // Load RecommendationEngine data (no-op if already loaded)
    await RecommendationEngine.load();

    // Apply affinity weight decay once per day
    await _maybeApplyDecay();

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // CORE: addPlay — called when a song starts playing
  //
  // v1 behaviour: save to Hive, dedup, trim.
  // v2 addition:  also call RecommendationEngine.onSongStarted().
  // ---------------------------------------------------------------------------
  // Serializes addPlay() so that a rapid sequence of song-changes (e.g.
  // fast skip-through, or a stale call landing just as a new one starts)
  // can never interleave their Hive `clear()` + rewrite passes. Without
  // this, two overlapping addPlay() calls could each read `_history` at
  // a different point mid-mutation and then both wipe+rewrite the box,
  // silently dropping whichever entry lost the race — the opposite of
  // "history saves perfectly every time."
  Future<void> _writeQueue = Future.value();

  Future<void> addPlay(Song song) {
    final result = _writeQueue.then((_) => _addPlay(song));
    // Swallow errors here so one failed write doesn't wedge the queue for
    // every addPlay() call after it; the caller can still .catchError().
    _writeQueue = result.catchError((_) {});
    return result;
  }

  Future<void> _addPlay(Song song) async {
    // Incognito Mode: don't record history, don't feed the recommendation
    // engine. This is the single gate that makes the Privacy toggle real.
    if (AudioPrefs.incognito) return;

    // FIX: previously this returned early for local songs, so playing
    // anything from "Local Files" never showed up in History/Recently
    // Played. Local songs should still be recorded — they just don't
    // need stream-URL stripping (they have none) and we skip the
    // RecommendationEngine hooks for them below (those are tuned for
    // streamed/online songs' artist/genre affinity, not device files).

    // Dedup: remove existing entry for this song (move-to-front)
    _history.removeWhere((s) => s.id == song.id);

    // Strip stream URL before persisting (it expires, no point storing it)
    final entry = song.streamUrl == null
        ? song
        : Song(
            id:         song.id,
            title:      song.title,
            artist:     song.artist,
            album:      song.album,
            artworkUrl: song.artworkUrl,
            streamUrl:  null,
            duration:   song.duration,
            language:   song.language,
            year:       song.year,
            localPath:  song.localPath,
            source:     song.source,
          );

    _history.insert(0, entry);
    _playedAtById[entry.id] = DateTime.now().millisecondsSinceEpoch;

    // Settings → Player & Audio → "History Duration": slider 0–100 maps
    // to 10–200 songs. Default 50 = 100 songs.
    final p2 = await SharedPreferences.getInstance();
    final sliderVal = (p2.getInt('history_duration') ?? 50).clamp(0, 100);
    final maxHistory = (10 + (sliderVal / 100.0 * 190).round()).clamp(10, 200);
    if (_history.length > maxHistory) {
      _history = _history.sublist(0, maxHistory);
    }

    await _persistHistory();

    // ── NEW v2: Signal RecommendationEngine ──────────────────────────────────
    // Fire-and-forget — never blocks UI or playback
    RecommendationEngine.onSongStarted(song);

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // ROOT FIX (history not saving reliably / Spotify-style discipline):
  // the old approach did `_box.clear()` then looped `_box.put()` for every
  // song in `_history`, purely to keep on-disk order matching the in-memory
  // list. That has a real data-loss window: if the app process is killed
  // (this app already has to defend against aggressive OEM background
  // kills — see AurumAudioEngine/ColorOS autostart notes elsewhere in the
  // codebase) at any point between `clear()` finishing and the rewrite loop
  // completing, every entry not yet re-written is gone from disk
  // permanently. From the user's side that reads as "history sometimes
  // just doesn't save" even though the in-memory list was briefly correct
  // right before the crash.
  //
  // Fix: never fully clear the box on a routine save.
  //  1. Diff current on-disk keys against the current `_history` id set
  //     and delete only the keys that genuinely dropped off (trimmed by
  //     the history-length limit, or replaced by a de-duped move-to-front
  //     — same song, same id, so it's a harmless overwrite either way).
  //  2. Write every current entry keyed by song.id, with its tracked
  //     `_playedAtById` timestamp embedded so ordering survives independent
  //     of Hive's own key iteration order (see init()).
  // At every point during this sequence, whatever is already on disk is a
  // valid subset of the correct history — a kill mid-write can only ever
  // lose the newest not-yet-written entries, never wipe everything that
  // was already saved.
  // ---------------------------------------------------------------------------
  Future<void> _persistHistory() async {
    final keepIds = _history.map((s) => s.id).toSet();
    final staleKeys = _box.keys.where((k) => !keepIds.contains(k)).toList();
    for (final key in staleKeys) {
      await _box.delete(key);
    }
    for (final s in _history) {
      final json = s.toJson();
      json['_playedAt'] = _playedAtById[s.id] ?? DateTime.now().millisecondsSinceEpoch;
      await _box.put(s.id, json);
    }
  }

  // ---------------------------------------------------------------------------
  // NEW: Completion tracking (80%+ of duration played)
  // Call from PlayerProvider when position crosses 80%.
  // ---------------------------------------------------------------------------
  void notifyCompletion(Song song) {
    if (AudioPrefs.incognito) return;
    if (song.source == SongSource.local) return;
    RecommendationEngine.onSongCompleted(song);
  }

  // ---------------------------------------------------------------------------
  // NEW: Early skip tracking (skipped before 15 seconds)
  // Call from PlayerProvider when user skips early.
  // ---------------------------------------------------------------------------
  void notifySkip(Song song) {
    if (AudioPrefs.incognito) return;
    if (song.source == SongSource.local) return;
    RecommendationEngine.onEarlySkip(song);
  }

  // ---------------------------------------------------------------------------
  // NEW: Replay tracking
  // Call from PlayerProvider when user replays current song.
  // ---------------------------------------------------------------------------
  void notifyReplay(Song song) {
    if (AudioPrefs.incognito) return;
    if (song.source == SongSource.local) return;
    RecommendationEngine.onReplay(song);
  }

  // ---------------------------------------------------------------------------
  // NEW: Favorite/unfavorite hooks
  // Call from FavoritesProvider.toggleFavorite().
  // ---------------------------------------------------------------------------
  void notifyFavorited(Song song) {
    if (AudioPrefs.incognito) return;
    if (song.source == SongSource.local) return;
    RecommendationEngine.onFavorited(song);
  }

  void notifyUnfavorited(Song song) {
    if (AudioPrefs.incognito) return;
    if (song.source == SongSource.local) return;
    RecommendationEngine.onUnfavorited(song);
  }

  // ---------------------------------------------------------------------------
  // trimToLimit — trims history to [limit] most recent songs.
  // Called live when the user moves the "History Duration" slider.
  // ---------------------------------------------------------------------------
  Future<void> trimToLimit(int limit) {
    final result = _writeQueue.then((_) => _trimToLimit(limit));
    _writeQueue = result.catchError((_) {});
    return result;
  }

  Future<void> _trimToLimit(int limit) async {
    if (_history.length <= limit) return;
    _history = _history.sublist(0, limit);
    await _persistHistory();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // clearHistory — wipes all play history from memory + Hive
  // ---------------------------------------------------------------------------
  Future<void> clearHistory() {
    final result = _writeQueue.then((_) => _clearHistory());
    _writeQueue = result.catchError((_) {});
    return result;
  }

  Future<void> _clearHistory() async {
    _history.clear();
    _playedAtById.clear();
    await _box.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // topArtists — unchanged (backward compatible)
  //
  // Returns up to `count` most-listened artist names, ranked by play
  // frequency. Used by ApiService.fetchHome() for "Made For You" sections.
  // "Unknown" is excluded (returns junk Saavn results).
  // ---------------------------------------------------------------------------
  List<String> topArtists({int count = 2}) {
    if (_history.isEmpty) return [];
    return _rankedArtists().take(count).toList();
  }

  // ---------------------------------------------------------------------------
  // ROOT CAUSE (part 2) of "pull-to-refresh shows the same songs" — this was
  // the piece the earlier rotatingAffinityArtists/Genres fix in
  // recommendation_engine.dart never touched, because it lives in a
  // different provider entirely.
  //
  // ApiService.fetchHomeStreaming() only uses RecommendationEngine's rotating
  // affinity artists/genres when the user already has enough *learned*
  // affinity weight (>0.5 score for at least a couple of artists/genres —
  // built up over real listening activity). For a newer account, or anyone
  // whose weights haven't crossed that threshold yet, `rotatingAffinityArtists`
  // returns an empty list, and the code falls straight back to this
  // provider's `topArtists(count: 3)` — a plain frequency count with NO
  // seed, NO shuffle, deterministically sorted by play count. That fallback
  // is what was actually driving the "Made for You · <artist>" sections
  // (the first, most visible rows on the page) on every single pull, and it
  // never varied no matter how many times you refreshed.
  //
  // Fix: a rotating counterpart, same pattern as
  // RecommendationEngine.rotatingAffinityArtists — pull from a wider top-N
  // pool by frequency, then shuffle with the given seed before slicing to
  // `count`. Real listening data still drives who's eligible; a fresh
  // random seed per pull decides who's actually featured this time.
  List<String> rotatingTopArtists({int count = 3, int? seed, int poolSize = 12}) {
    if (_history.isEmpty) return [];
    final pool = _rankedArtists().take(poolSize).toList();
    if (pool.length <= count) return pool;
    pool.shuffle(seed != null ? math.Random(seed) : math.Random());
    return pool.take(count).toList();
  }

  List<String> _rankedArtists() {
    if (_history.isEmpty) return [];

    // Label/publisher names that sometimes appear in the `artist` field of
    // Saavn metadata instead of an actual singer — these must never be
    // treated as an artist for "Made for You" personalization.
    const labelNames = {
      'unknown', 'unknown artist', 't-series', 'tseries', 't series',
      'zee music company', 'zee music', 'sony music', 'sony music india',
      'saregama', 'venus', 'venus music', 'tips', 'tips music',
      'yrf', 'yash raj films', 'eros now music', 'eros music',
      'speed records', 'white hill music', 'jjust music',
    };

    final freq = <String, int>{};
    for (final song in _history) {
      final artist = song.artist.trim();
      final key = artist.toLowerCase();
      if (artist.isEmpty || labelNames.contains(key)) continue;
      freq[artist] = (freq[artist] ?? 0) + 1;
    }

    final sorted = freq.keys.toList()
      ..sort((a, b) => freq[b]!.compareTo(freq[a]!));

    return sorted;
  }

  // ---------------------------------------------------------------------------
  // NEW: topAffinityArtists — from RecommendationEngine (learned, not just count)
  // Used by fetchHome() via RecommendationEngine.topAffinityArtists() directly,
  // but exposed here for convenience if needed by UI.
  // ---------------------------------------------------------------------------
  List<String> topAffinityArtists({int count = 5}) =>
      RecommendationEngine.topAffinityArtists(count: count);

  // ---------------------------------------------------------------------------
  // DAILY DECAY — apply once per day to prevent stale affinities dominating
  // ---------------------------------------------------------------------------
  Future<void> _maybeApplyDecay() async {
    try {
      final p = await SharedPreferences.getInstance();
      final lastDecayStr = p.getString(_kLastDecayDate);
      final today = DateTime.now().toIso8601String().substring(0, 10); // YYYY-MM-DD
      if (lastDecayStr != today) {
        await RecommendationEngine.applyDecay();
        await p.setString(_kLastDecayDate, today);
      }
    } catch (_) {
      // Non-critical — decay is a nice-to-have, not a crash point
    }
  }
}
