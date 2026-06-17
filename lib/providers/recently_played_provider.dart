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

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../utils/constants.dart';
import '../services/recommendation_engine.dart';

class RecentlyPlayedProvider extends ChangeNotifier {
  static const _boxName         = AppConstants.boxRecentlyPlayed;
  static const _kLastDecayDate  = 'aurum_rec_last_decay_date';

  late Box<Map> _box;
  List<Song>    _history = [];

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
    _history = _box.values
        .map((m) => Song.fromJson(Map<String, dynamic>.from(m)))
        .toList()
        .reversed
        .toList();

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
  Future<void> addPlay(Song song) async {
    if (song.source == SongSource.local) return;

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

    // Trim to limit
    if (_history.length > AppConstants.recentlyPlayedLimit) {
      _history = _history.sublist(0, AppConstants.recentlyPlayedLimit);
    }

    // Persist to Hive (clear + rewrite for correct order)
    await _box.clear();
    for (final s in _history.reversed) {
      await _box.put(s.id, s.toJson());
    }

    // ── NEW v2: Signal RecommendationEngine ──────────────────────────────────
    // Fire-and-forget — never blocks UI or playback
    RecommendationEngine.onSongStarted(song);

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // NEW: Completion tracking (80%+ of duration played)
  // Call from PlayerProvider when position crosses 80%.
  // ---------------------------------------------------------------------------
  void notifyCompletion(Song song) {
    if (song.source == SongSource.local) return;
    RecommendationEngine.onSongCompleted(song);
  }

  // ---------------------------------------------------------------------------
  // NEW: Early skip tracking (skipped before 15 seconds)
  // Call from PlayerProvider when user skips early.
  // ---------------------------------------------------------------------------
  void notifySkip(Song song) {
    if (song.source == SongSource.local) return;
    RecommendationEngine.onEarlySkip(song);
  }

  // ---------------------------------------------------------------------------
  // NEW: Replay tracking
  // Call from PlayerProvider when user replays current song.
  // ---------------------------------------------------------------------------
  void notifyReplay(Song song) {
    if (song.source == SongSource.local) return;
    RecommendationEngine.onReplay(song);
  }

  // ---------------------------------------------------------------------------
  // NEW: Favorite/unfavorite hooks
  // Call from FavoritesProvider.toggleFavorite().
  // ---------------------------------------------------------------------------
  void notifyFavorited(Song song) {
    if (song.source == SongSource.local) return;
    RecommendationEngine.onFavorited(song);
  }

  void notifyUnfavorited(Song song) {
    if (song.source == SongSource.local) return;
    RecommendationEngine.onUnfavorited(song);
  }

  // ---------------------------------------------------------------------------
  // clearHistory — wipes all play history from memory + Hive
  // ---------------------------------------------------------------------------
  Future<void> clearHistory() async {
    _history.clear();
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

    final freq = <String, int>{};
    for (final song in _history) {
      final artist = song.artist.trim();
      if (artist.isEmpty || artist.toLowerCase() == 'unknown' ||
          artist.toLowerCase() == 'unknown artist') continue;
      freq[artist] = (freq[artist] ?? 0) + 1;
    }

    final sorted = freq.keys.toList()
      ..sort((a, b) => freq[b]!.compareTo(freq[a]!));

    return sorted.take(count).toList();
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
