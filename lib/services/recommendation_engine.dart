// =============================================================================
// FILE: lib/services/recommendation_engine.dart
// PROJECT: Aurum Music
// VERSION: 1.0.0 — Production
//
// PURPOSE:
//   Central intelligence layer for Aurum Music. Handles:
//     - User behavior tracking (play, skip, favorite, replay)
//     - Weighted recommendation scoring
//     - Session context detection (mood/genre/language continuity)
//     - Time-of-day awareness (minor signal)
//     - Anti-repetition enforcement
//     - Discovery injection (70/20/10 mix)
//
// ARCHITECTURE:
//   Pure Dart, no Flutter imports. Fully static — usable from any service
//   or provider without a BuildContext. Persisted via SharedPreferences.
//
// DATA STORED (SharedPreferences):
//   aurum_rec_plays      — Map<songId, int> play counts
//   aurum_rec_completes  — Map<songId, int> completion counts (80%+)
//   aurum_rec_skips      — Map<songId, int> early-skip counts (<15s)
//   aurum_rec_replays    — Map<songId, int> replay counts
//   aurum_rec_artist_w   — Map<artist, double> artist affinity weights
//   aurum_rec_genre_w    — Map<genre, double> genre affinity weights
//   aurum_rec_lang_w     — Map<language, double> language affinity weights
//   aurum_rec_session    — Current session JSON
// =============================================================================

import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';

// =============================================================================
// ENUMS & VALUE OBJECTS
// =============================================================================

enum SessionMood { romantic, sad, party, devotional, workout, chill, energetic, neutral }
enum SessionGenre { bollywood, punjabi, hiphop, english, lofi, devotional, bhojpuri, other }
enum SessionLanguage { hindi, punjabi, english, tamil, telugu, bengali, marathi, gujarati, malayalam, other }
enum TimeSlot { morning, afternoon, evening, night, lateNight }

class _SessionState {
  final SessionMood mood;
  final SessionGenre genre;
  final SessionLanguage language;
  final List<String> recentArtists;  // last 5 unique artists
  final List<String> recentIds;       // last 20 song IDs (anti-repeat window)
  // FIX ("Up Next endless session eventually repeats a reupload of a song
  // played much earlier" — YT-Music-style infinite queues run for hundreds
  // of songs, but recentIds only remembers the last 20; once a song's ID
  // ages out of that window, a DIFFERENT-ID reupload of it (different
  // Saavn track ID, same actual song) could pass every dedup check again).
  // recentTitles is a much longer rolling window (200) of normalized
  // titles — cheap to store, and long enough that a genuinely infinite
  // session still remembers "have I played something with this title
  // before" long after the ID-based window has forgotten it.
  final List<String> recentTitles;
  final DateTime startedAt;

  _SessionState({
    required this.mood,
    required this.genre,
    required this.language,
    required this.recentArtists,
    required this.recentIds,
    required this.recentTitles,
    required this.startedAt,
  });

  factory _SessionState.fromJson(Map<String, dynamic> j) => _SessionState(
        mood: SessionMood.values.firstWhere(
            (e) => e.name == j['mood'], orElse: () => SessionMood.neutral),
        genre: SessionGenre.values.firstWhere(
            (e) => e.name == j['genre'], orElse: () => SessionGenre.other),
        language: SessionLanguage.values.firstWhere(
            (e) => e.name == j['language'], orElse: () => SessionLanguage.hindi),
        recentArtists: List<String>.from(j['recentArtists'] ?? []),
        recentIds: List<String>.from(j['recentIds'] ?? []),
        recentTitles: List<String>.from(j['recentTitles'] ?? []),
        startedAt: DateTime.tryParse(j['startedAt'] ?? '') ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'mood': mood.name,
        'genre': genre.name,
        'language': language.name,
        'recentArtists': recentArtists,
        'recentIds': recentIds,
        'recentTitles': recentTitles,
        'startedAt': startedAt.toIso8601String(),
      };

  _SessionState copyWith({
    SessionMood? mood,
    SessionGenre? genre,
    SessionLanguage? language,
    List<String>? recentArtists,
    List<String>? recentIds,
    List<String>? recentTitles,
  }) =>
      _SessionState(
        mood: mood ?? this.mood,
        genre: genre ?? this.genre,
        language: language ?? this.language,
        recentArtists: recentArtists ?? this.recentArtists,
        recentIds: recentIds ?? this.recentIds,
        recentTitles: recentTitles ?? this.recentTitles,
        startedAt: startedAt,
      );
}

// =============================================================================
// MAIN ENGINE
// =============================================================================

class RecommendationEngine {
  RecommendationEngine._();

  // ---------------------------------------------------------------------------
  // SECTION 1: STORAGE KEYS
  // ---------------------------------------------------------------------------
  static const _kPlays     = 'aurum_rec_plays';
  static const _kCompletes = 'aurum_rec_completes';
  static const _kSkips     = 'aurum_rec_skips';
  static const _kReplays   = 'aurum_rec_replays';
  static const _kArtistW   = 'aurum_rec_artist_w';
  static const _kGenreW    = 'aurum_rec_genre_w';
  static const _kLangW     = 'aurum_rec_lang_w';
  static const _kSession   = 'aurum_rec_session';
  static const _kHomeShown = 'aurum_rec_home_shown';
  // ── Recommendation Intelligence System extensions ──
  // Additive only — existing keys/maps above are untouched, so anyone on
  // an older build's saved prefs upgrades cleanly (missing keys just
  // decode to empty maps via the same _loadIntMap/_loadDoubleMap helpers
  // already used for everything else).
  static const _kAlbumPlays  = 'aurum_rec_album_plays';
  static const _kDecadeW     = 'aurum_rec_decade_w';
  static const _kLastPlayed  = 'aurum_rec_last_played_at';

  // ---------------------------------------------------------------------------
  // SECTION 2: IN-MEMORY STATE
  // ---------------------------------------------------------------------------
  static Map<String, int>    _plays     = {};
  static Map<String, int>    _completes = {};
  static Map<String, int>    _skips     = {};
  static Map<String, int>    _replays   = {};
  static Map<String, double> _artistW   = {};
  static Map<String, double> _genreW    = {};
  static Map<String, double> _langW     = {};
  static _SessionState?      _session;
  static bool                _loaded    = false;
  // Rolling window of song IDs already surfaced on the home feed (most
  // recent last). Purely a "don't show again so soon" queue — separate
  // from _plays (actual listens) and sessionRecentIds (played-in-session),
  // since a song can be repeatedly shown as a home *card* without ever
  // being tapped/played.
  static List<String>        _homeShown = [];
  // ── Recommendation Intelligence System extensions ──
  static Map<String, int>    _albumPlays = {};   // album name -> play count
  static Map<String, double> _decadeW    = {};   // "90s"/"2000s"/... -> affinity weight
  // song id -> epoch ms of most recent play. Powers "Continue Listening"
  // (played recently, not finished) and "Rediscover Favorites" (high
  // affinity artist/genre but not played in a long while).
  static Map<String, int>    _lastPlayedAt = {};

  // Decay factor applied to affinity weights over time.
  // Prevents old listening habits from dominating new ones.
  static const double _decayFactor = 0.92;

  // PERF FIX ("app gets slower the longer it's used"): _plays/_completes/
  // _skips/_lastPlayedAt/_albumPlays are keyed by song id and, before this
  // fix, had NO size cap — every unique song ever played added one more
  // permanent entry, for the lifetime of the app install. The doc comment
  // above topPlayedSongIds() (Section: "Recommendation Intelligence
  // System — home-section-facing getters") already documents the
  // intended assumption that these "stay small (a few hundred entries
  // even for a heavy listener)" — that was the design intent, just never
  // actually enforced anywhere. Two compounding costs as these grew past
  // that: (1) _saveAll() JSON-encodes every one of these maps in full on
  // EVERY single play/complete/skip event — a bigger map means a bigger
  // encode, every time; (2) topPlayedSongIds()/rediscoverCandidateIds()
  // sort the entire map on every Home load — a bigger map means a slower
  // sort, every load. Both scale directly with how long/heavily the app
  // has been used, matching that exact symptom.
  //
  // Fix: after every _saveAll(), prune song-keyed maps down to this cap,
  // dropping the least-recently-played entries first (same "oldest falls
  // off first" pattern _homeShown already uses above). _lastPlayedAt is
  // the natural recency signal already tracked for every song, so pruning
  // by it means the songs kept are exactly the ones every existing
  // getter (recentlyPlayedSongIds, rediscoverCandidateIds, etc.) actually
  // cares about — nothing user-visible changes, only truly stale entries
  // (a song not played in a very long time, sitting far past ~500 more
  // recently-active songs) are dropped from tracking.
  static const int _maxTrackedSongs = 500;

  static void _pruneTrackedSongs() {
    if (_plays.length <= _maxTrackedSongs) return;
    // Rank every currently-tracked song id by recency. A song present in
    // _plays but never given a _lastPlayedAt entry (shouldn't normally
    // happen — onSongStarted always sets both together — but defensive
    // against any future call path that doesn't) sorts as oldest so it's
    // pruned before any song with real recency data.
    final ids = _plays.keys.toList()
      ..sort((a, b) =>
          (_lastPlayedAt[a] ?? 0).compareTo(_lastPlayedAt[b] ?? 0));
    final toDrop = ids.length - _maxTrackedSongs;
    if (toDrop <= 0) return;
    final dropIds = ids.take(toDrop).toSet();
    _plays.removeWhere((k, _) => dropIds.contains(k));
    _completes.removeWhere((k, _) => dropIds.contains(k));
    _skips.removeWhere((k, _) => dropIds.contains(k));
    _replays.removeWhere((k, _) => dropIds.contains(k));
    _lastPlayedAt.removeWhere((k, _) => dropIds.contains(k));
    // _albumPlays is keyed by album name, not song id, so it isn't pruned
    // here — it naturally stays small (bounded by unique album count, not
    // by every song ever played) and dropping it by song-id logic would
    // be wrong anyway.
  }

  // FIX ("Up Next: same songs come back, just format/reupload changed"):
  // generateQueries() used to be fully deterministic per song — same
  // artist name, same static mood phrase, and _pickSimilarArtist was
  // DAY-seeded (same similar-artist all day, every single extend call).
  // Auto-queue extends every time ≤8 songs remain — often several times
  // per session — and each extend fired the EXACT SAME 4 query strings at
  // Saavn/YT, which is itself a deterministic search index: same query ->
  // same top results, every time. Dedup blocked the exact songs already
  // queued, but with no new query angle the shrinking pool of "not yet
  // queued" hits from that one static query set ran out fast — the queue
  // kept re-surfacing the same handful of songs under different
  // reuploads, exactly the "format change karke wapas aata hai" symptom.
  // This counter increments once per generateQueries() call and drives
  // rotation (similar-artist pick, mood-phrasing) so consecutive extends
  // genuinely explore different corners of the catalog instead of
  // hammering one query on repeat.
  static int _queryRotation = 0;

  // ---------------------------------------------------------------------------
  // SECTION 3: INITIALIZATION
  // ---------------------------------------------------------------------------

  /// Load all stored data into memory. Call once at app startup.
  static Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();

    _plays     = _loadIntMap(p, _kPlays);
    _completes = _loadIntMap(p, _kCompletes);
    _skips     = _loadIntMap(p, _kSkips);
    _replays   = _loadIntMap(p, _kReplays);
    _artistW   = _loadDoubleMap(p, _kArtistW);
    _genreW    = _loadDoubleMap(p, _kGenreW);
    _langW     = _loadDoubleMap(p, _kLangW);
    _albumPlays   = _loadIntMap(p, _kAlbumPlays);
    _decadeW      = _loadDoubleMap(p, _kDecadeW);
    _lastPlayedAt = _loadIntMap(p, _kLastPlayed);

    final sessionJson = p.getString(_kSession);
    if (sessionJson != null) {
      try {
        final decoded = jsonDecode(sessionJson) as Map<String, dynamic>;
        final candidate = _SessionState.fromJson(decoded);
        // Sessions older than 2 hours are considered stale — start fresh.
        final age = DateTime.now().difference(candidate.startedAt);
        _session = age.inHours < 2 ? candidate : null;
      } catch (_) {
        _session = null;
      }
    }

    try {
      final raw = p.getStringList(_kHomeShown);
      _homeShown = raw ?? [];
    } catch (_) {
      _homeShown = [];
    }

    _loaded = true;
  }

  /// Wipes all learned affinity/recommendation data, both in-memory and in
  /// SharedPreferences. Used by Settings → Privacy → "Reset Recommendations".
  static Future<void> resetAll() async {
    _plays.clear();
    _completes.clear();
    _skips.clear();
    _replays.clear();
    _artistW.clear();
    _genreW.clear();
    _langW.clear();
    _session = null;
    _homeShown.clear();
    _albumPlays.clear();
    _decadeW.clear();
    _lastPlayedAt.clear();

    final p = await SharedPreferences.getInstance();
    await p.remove(_kPlays);
    await p.remove(_kCompletes);
    await p.remove(_kSkips);
    await p.remove(_kReplays);
    await p.remove(_kArtistW);
    await p.remove(_kGenreW);
    await p.remove(_kLangW);
    await p.remove(_kSession);
    await p.remove(_kHomeShown);
    await p.remove(_kAlbumPlays);
    await p.remove(_kDecadeW);
    await p.remove(_kLastPlayed);
  }

  static Map<String, int> _loadIntMap(SharedPreferences p, String key) {
    try {
      final raw = p.getString(key);
      if (raw == null) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  static Map<String, double> _loadDoubleMap(SharedPreferences p, String key) {
    try {
      final raw = p.getString(key);
      if (raw == null) return {};
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) {
      return {};
    }
  }

  // ---------------------------------------------------------------------------
  // SECTION 4: BEHAVIOR TRACKING
  //
  // These are called from AurumAudioHandler as playback events fire.
  // All calls are fire-and-forget — save runs in background.
  // ---------------------------------------------------------------------------

  /// Call when a song starts playing.
  static Future<void> onSongStarted(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;

    // Update play count
    _plays[song.id] = (_plays[song.id] ?? 0) + 1;
    _lastPlayedAt[song.id] = DateTime.now().millisecondsSinceEpoch;

    // Light immediate signal — user chose to play this, so nudge affinity
    // right away instead of waiting for 80% completion. Small delta so a
    // single tap doesn't overpower real signals, but home feed reacts fast.
    _boostArtist(song.artist, delta: 0.06);
    _boostGenre(detectGenre(song), delta: 0.05);
    _boostLanguage(detectLanguage(song), delta: 0.04);

    // Update session context
    _updateSession(song);

    // Persist in background — non-blocking
    _saveAll();
  }

  /// Call when position >= 80% of duration.
  static Future<void> onSongCompleted(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;

    _completes[song.id] = (_completes[song.id] ?? 0) + 1;

    // Strong positive signal: boost artist, genre, language weights
    _boostArtist(song.artist, delta: 0.15);
    _boostGenre(detectGenre(song), delta: 0.10);
    _boostLanguage(detectLanguage(song), delta: 0.08);

    // Album + decade tracking (Recommendation Intelligence extensions).
    // Same "only count real listens, not just taps" reasoning as the rest
    // of this method — completion is the strongest available signal.
    if (song.album.trim().isNotEmpty) {
      // Lighter normalization than _normalizeKey on purpose: that helper
      // strips ALL non-alphanumeric characters (spaces included), which
      // is fine for artist/genre matching but would turn "Aashiqui 2" into
      // "aashiqui2" — unusable both as a search query and as a display
      // label for "Your Top Albums · <name>". Lowercase+trim is enough to
      // dedupe near-identical casing without destroying the readable name.
      final albumKey = song.album.trim().toLowerCase();
      if (albumKey.isNotEmpty) {
        _albumPlays[albumKey] = (_albumPlays[albumKey] ?? 0) + 1;
      }
    }
    final decade = _songDecade(song);
    if (decade != null) _boostDecade(decade, delta: 0.10);

    _saveAll();
  }

  /// Call when user skips before 15 seconds.
  static Future<void> onEarlySkip(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;

    _skips[song.id] = (_skips[song.id] ?? 0) + 1;

    // Negative signal: decay artist/genre/language slightly
    _boostArtist(song.artist, delta: -0.08);
    _boostGenre(detectGenre(song), delta: -0.05);
    _boostLanguage(detectLanguage(song), delta: -0.03);

    _saveAll();
  }

  /// Call when user replays a song.
  static Future<void> onReplay(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;

    _replays[song.id] = (_replays[song.id] ?? 0) + 1;

    // Strong positive signal
    _boostArtist(song.artist, delta: 0.20);
    _boostGenre(detectGenre(song), delta: 0.15);
    _boostLanguage(detectLanguage(song), delta: 0.10);

    _saveAll();
  }

  /// Call when user favorites a song. Very strong positive signal.
  static Future<void> onFavorited(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;

    _boostArtist(song.artist, delta: 0.35);
    _boostGenre(detectGenre(song), delta: 0.25);
    _boostLanguage(detectLanguage(song), delta: 0.15);

    _saveAll();
  }

  /// Call when user un-favorites a song.
  static Future<void> onUnfavorited(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;

    _boostArtist(song.artist, delta: -0.15);
    _boostGenre(detectGenre(song), delta: -0.10);

    _saveAll();
  }

  // ---------------------------------------------------------------------------
  // SECTION 5: AFFINITY WEIGHT HELPERS
  // ---------------------------------------------------------------------------

  static void _boostArtist(String artist, {required double delta}) {
    final key = _normalizeKey(artist);
    if (key.isEmpty) return;
    final current = _artistW[key] ?? 0.5;  // start at 0.5 (neutral)
    _artistW[key] = (current + delta).clamp(0.0, 1.0);
  }

  static void _boostGenre(String genre, {required double delta}) {
    final current = _genreW[genre] ?? 0.5;
    _genreW[genre] = (current + delta).clamp(0.0, 1.0);
  }

  static void _boostLanguage(String lang, {required double delta}) {
    final current = _langW[lang] ?? 0.5;
    _langW[lang] = (current + delta).clamp(0.0, 1.0);
  }

  static void _boostDecade(String decade, {required double delta}) {
    final current = _decadeW[decade] ?? 0.5;
    _decadeW[decade] = (current + delta).clamp(0.0, 1.0);
  }

  // ---------------------------------------------------------------------------
  // SECTION 6: SESSION MANAGEMENT
  // ---------------------------------------------------------------------------

  static void _updateSession(Song song) {
    final mood     = _detectMoodEnum(song);
    final genre    = _detectGenreEnum(song);
    final language = _detectLanguageEnum(song);

    if (_session == null) {
      _session = _SessionState(
        mood: mood,
        genre: genre,
        language: language,
        recentArtists: [song.artist],
        recentIds: [song.id],
        recentTitles: [_titleCore(song.title)],
        startedAt: DateTime.now(),
      );
      return;
    }

    // Weighted session update: new signal blends into existing session.
    // This prevents a single different-mood song from flipping the session.
    final updatedMood = _blendMood(_session!.mood, mood);
    final updatedGenre = _blendGenre(_session!.genre, genre);
    final updatedLang = _blendLanguage(_session!.language, language);

    // Rolling artist window: keep last 5 unique artists
    final artists = [song.artist, ..._session!.recentArtists]
        .toSet()
        .take(5)
        .toList();

    // Rolling song ID window: keep last 20 IDs (anti-repeat window)
    final ids = [song.id, ..._session!.recentIds].take(20).toList();

    // FIX: title window kept separately and much longer (200) than the ID
    // window (20) — see _SessionState.recentTitles doc comment. A
    // reupload with a fresh Saavn ID still carries the same normalized
    // title, so this is what actually stops it resurfacing deep into a
    // long endless session after its ID has aged out of `recentIds`.
    final titles = [_titleCore(song.title), ..._session!.recentTitles]
        .toSet()
        .take(200)
        .toList();

    _session = _session!.copyWith(
      mood: updatedMood,
      genre: updatedGenre,
      language: updatedLang,
      recentArtists: artists,
      recentIds: ids,
      recentTitles: titles,
    );
  }

  // Blend: 70% existing session, 30% new signal. Threshold to flip = 30%.
  static SessionMood _blendMood(SessionMood current, SessionMood incoming) {
    if (current == incoming) return current;
    // Simple threshold: after 3+ consecutive songs of new mood, session flips.
    // Since we blend per-song, incoming needs to match significantly to change.
    // We only change session mood if new mood is "compatible" or user clearly shifted.
    const compatible = {
      SessionMood.romantic: {SessionMood.sad, SessionMood.chill},
      SessionMood.sad: {SessionMood.romantic, SessionMood.chill},
      SessionMood.party: {SessionMood.energetic, SessionMood.workout},
      SessionMood.workout: {SessionMood.party, SessionMood.energetic},
      SessionMood.energetic: {SessionMood.party, SessionMood.workout},
      SessionMood.chill: {SessionMood.romantic, SessionMood.sad},
      SessionMood.devotional: <SessionMood>{},
      SessionMood.neutral: {SessionMood.romantic, SessionMood.sad, SessionMood.party,
                             SessionMood.chill, SessionMood.energetic},
    };
    final compat = compatible[current] ?? {};
    return compat.contains(incoming) ? incoming : current;
  }

  // FIX (session genre permanently frozen after first non-"other" song):
  // this used to be `current == other ? incoming : current`. Once current
  // became any real genre (bollywood, punjabi, etc.), the condition was
  // false for the rest of the session no matter what `incoming` was —
  // `incoming` was only ever used the ONE time current happened to still
  // be `other`. After that it silently ignored every future song's genre.
  // _session!.genre feeds scoreCandidate's Session genre match (0.10
  // weight), so this directly degraded Up Next quality: a session that
  // opened on one Bollywood song would keep scoring Bollywood-genre
  // matches highest even after a long, clear run of Punjabi or English
  // tracks. Same fix shape as _blendLanguage: always take the new signal.
  static SessionGenre _blendGenre(SessionGenre current, SessionGenre incoming) =>
      incoming;

  // FIX (session language permanently frozen after first song): this used
  // to be `current == incoming ? current : current` — both branches return
  // `current`, so `incoming` was never actually used for anything. Once a
  // session started as, say, Hindi, it stayed "hindi" for the rest of that
  // session no matter what the user played afterward — even a long stretch
  // of Punjabi or English songs. Every score/query that reads _session!
  // .language (scoreCandidate's language-affinity bonus, generateQueries'
  // "$lang songs" queries, _moodLockedQuery, etc.) would then keep chasing
  // the WRONG language for the rest of the session, actively working
  // against what the user was actually listening to.
  //
  // Real fix: mirror _blendGenre's already-correct logic — same shape as
  // the working genre blend, just for language. A session's language only
  // needs to actually shift when the user has clearly moved to a different
  // one; blending in the new language immediately (rather than requiring N
  // consecutive songs first) keeps this simple and consistent with how
  // genre already behaves, while still being far better than a value that
  // can never change at all.
  static SessionLanguage _blendLanguage(SessionLanguage current, SessionLanguage incoming) =>
      incoming;

  // ---------------------------------------------------------------------------
  // SECTION 7: RECOMMENDATION SCORING
  //
  // Score a candidate song on a 0.0–1.0 scale.
  // Higher score = more relevant to user right now.
  //
  // SIGNAL WEIGHTS:
  //   Artist affinity     : 0.25  (learned from user history)
  //   Genre affinity      : 0.20  (learned from user history)
  //   Language affinity   : 0.15  (learned from user history)
  //   Session mood match  : 0.15  (current listening session)
  //   Era match            : 0.15  (same decade as currently playing song)
  //   Session genre match : 0.10  (current listening session)
  //   Same-album bonus    : 0.10  (same movie/EP as currently playing song)
  //   Completion rate     : 0.08  (did user finish this before?)
  //   Freshness bonus     : 0.06  (new release temporary boost, no API)
  //   Trending proxy      : 0.05  (YouTube viewCount, log-scaled — no API)
  //   Replay bonus        : 0.05  (did user replay this before?)
  //   Skip penalty        : -0.20 (hard penalty for early-skipped songs)
  //   Time slot fit       : 0.02  (minor: morning/evening/etc.)
  //
  // NOT implemented (would require a backend/ML/paid API this app doesn't
  // have — listed here so it's clear these were considered, not missed):
  //   Collaborative filtering ("users who played X also played Y") needs
  //   a central server aggregating play history across ALL users — this
  //   app's data lives entirely in each user's own SharedPreferences.
  //   Audio embeddings / BPM / energy / danceability / valence need an
  //   audio-analysis pipeline or a paid audio-features API — there's no
  //   such signal available from Saavn/YouTube metadata alone.
  // ---------------------------------------------------------------------------
  static double scoreCandidate(Song candidate, {Song? currentSong}) {
    if (!_loaded) return 0.5;
    if (candidate.isLocal) return 0.3;

    double score = 0.0;

    final artistKey = _normalizeKey(candidate.artist);
    final genre     = detectGenre(candidate);
    final language  = detectLanguage(candidate);

    // Era match (0–0.15) — only applied when we know the reference song's decade.
    // Without it, a 90s song's up-next could rank a 2024 remix cover above an
    // actual 90s track since nothing penalized the mismatch.
    if (currentSong != null) {
      final refEra = _songDecade(currentSong);
      final candEra = _songDecade(candidate);
      if (refEra != null && candEra != null) {
        if (candEra == refEra) {
          score += 0.15;
        } else {
          score -= 0.10;
        }
      } else if (refEra != null && candEra == null) {
        // Candidate has no parseable release year of its own — common for
        // freshly-uploaded cover/recreated versions that inherit the
        // original movie's metadata inconsistently. Rather than silently
        // skipping the era check (which let recent recreations of old
        // songs through with zero penalty), apply a smaller uncertainty
        // penalty so an unknown-era candidate never outranks a
        // confirmed-same-era one.
        score -= 0.05;
      }
    }

    // Artist affinity (0–0.25)
    score += (_artistW[artistKey] ?? 0.5) * 0.25;

    // Genre affinity (0–0.20)
    score += (_genreW[genre] ?? 0.5) * 0.20;

    // Language affinity (0–0.15)
    score += (_langW[language] ?? 0.5) * 0.15;

    // Session mood match (0–0.15)
    if (_session != null) {
      final songMood = _detectMoodEnum(candidate);
      if (songMood == _session!.mood) {
        score += 0.15;
      } else if (_moodCompatible(_session!.mood, songMood)) {
        score += 0.08;
      }
    } else {
      score += 0.075; // neutral when no session
    }

    // Session genre match (0–0.10)
    if (_session != null) {
      final songGenreEnum = _detectGenreEnum(candidate);
      if (songGenreEnum == _session!.genre) score += 0.10;
      else if (_session!.genre == SessionGenre.other) score += 0.05;
    } else {
      score += 0.05;
    }

    // Same-album bonus (0–0.10) — strongest "this actually belongs together"
    // signal available (same movie/EP/session recording).
    if (currentSong != null &&
        currentSong.album.isNotEmpty &&
        candidate.album.isNotEmpty &&
        _normalizeKey(candidate.album) == _normalizeKey(currentSong.album)) {
      score += 0.10;
    }

    // Completion rate bonus (0–0.08)
    final plays = _plays[candidate.id] ?? 0;
    if (plays > 0) {
      final completes = _completes[candidate.id] ?? 0;
      final rate = completes / plays;
      score += rate * 0.08;
    }

    // Replay bonus (0–0.05)
    final replays = _replays[candidate.id] ?? 0;
    if (replays > 0) score += math.min(replays * 0.02, 0.05);

    // Skip penalty (hard)
    final skips = _skips[candidate.id] ?? 0;
    if (skips > 0) score -= math.min(skips * 0.07, 0.20);

    // Time slot fit (0–0.02)
    score += _timeSlotBonus(candidate) * 0.02;

    // Freshness boost (0–0.06) — new releases get a temporary lift, same
    // idea as Spotify/YT Music surfacing "new music" more eagerly right
    // after release. Decays smoothly to 0 over ~18 months so it's a
    // genuine "just dropped" signal, not a permanent bias toward recent
    // years (that's already handled separately by the era-match score
    // above, which cares about matching the CURRENT song's era, not
    // absolute recency).
    score += _freshnessBonus(candidate) * 0.06;

    // Trending proxy (0–0.05) — YouTube's viewCount is the only real
    // "how popular is this RIGHT NOW" signal actually available without a
    // charts API. Log-scaled so a 50M-view song doesn't totally dominate
    // over a 5M-view one — both are clearly popular, the curve just needs
    // to distinguish "viral hit" from "unproven upload", not rank-order
    // every view count linearly. Saavn songs have no viewCount (catalog
    // data, not engagement data) so they neither gain nor lose from this —
    // same neutral treatment isPremiumQuality() already uses for them.
    score += _trendingBonus(candidate) * 0.05;

    return score.clamp(0.0, 1.0);
  }

  // Below this age, a song is "fresh" and gets the full freshness bonus.
  // Linearly decays to 0 by _freshnessFullDecayDays.
  static const int _freshnessFullBonusDays = 30;
  static const int _freshnessFullDecayDays = 540; // ~18 months

  static double _freshnessBonus(Song song) {
    final year = int.tryParse(song.year ?? '') ?? 0;
    if (year <= 0) return 0.0;
    // Only the release YEAR is available (not month/day), so treat a
    // song as released on Jan 1 of its year for age purposes. This
    // slightly understates freshness for songs released later in their
    // year, but there's no finer-grained date to work with from this
    // metadata — a coarse "how many years old" signal is still far
    // better than no freshness signal at all.
    final releaseDate = DateTime(year, 1, 1);
    final ageDays = DateTime.now().difference(releaseDate).inDays;
    if (ageDays < 0) return 0.0; // future-dated/bad metadata, ignore
    if (ageDays <= _freshnessFullBonusDays) return 1.0;
    if (ageDays >= _freshnessFullDecayDays) return 0.0;
    final span = _freshnessFullDecayDays - _freshnessFullBonusDays;
    final progress = (ageDays - _freshnessFullBonusDays) / span;
    return (1.0 - progress).clamp(0.0, 1.0);
  }

  // View counts below this are treated as "no signal" (0 bonus) — an
  // unproven upload shouldn't get credit just for having *some* views.
  static const int _trendingFloorViews = 500000;
  // View counts at/above this are treated as "clearly viral" (full
  // bonus) — chosen so a genuine mainstream Bollywood hit (which
  // routinely reaches crores of views within months) saturates the
  // bonus rather than needing an ever-larger count to matter.
  static const int _trendingCeilingViews = 50000000;

  static double _trendingBonus(Song song) {
    if (song.source != SongSource.youtube) return 0.0; // no engagement data
    final views = song.viewCount;
    if (views == null || views < _trendingFloorViews) return 0.0;
    if (views >= _trendingCeilingViews) return 1.0;
    // Log scale: the difference between 1M and 5M views should matter
    // more than the difference between 40M and 44M — both of the latter
    // are already unambiguously "huge", so a linear scale would waste
    // most of its range distinguishing degrees of "very popular" instead
    // of the more useful "popular vs not yet proven" distinction.
    final logFloor = math.log(_trendingFloorViews);
    final logCeil  = math.log(_trendingCeilingViews);
    final logViews = math.log(views);
    return ((logViews - logFloor) / (logCeil - logFloor)).clamp(0.0, 1.0);
  }

  static bool _moodCompatible(SessionMood session, SessionMood song) {
    const compat = {
      SessionMood.romantic: [SessionMood.sad, SessionMood.chill],
      SessionMood.sad: [SessionMood.romantic, SessionMood.chill],
      SessionMood.party: [SessionMood.energetic, SessionMood.workout],
      SessionMood.workout: [SessionMood.party, SessionMood.energetic],
      SessionMood.energetic: [SessionMood.party, SessionMood.workout],
      SessionMood.chill: [SessionMood.romantic, SessionMood.sad],
    };
    return (compat[session] ?? []).contains(song);
  }

  static double _timeSlotBonus(Song song) {
    final slot = currentTimeSlot();
    final genre = detectGenre(song);
    final mood  = _detectMoodEnum(song);

    switch (slot) {
      case TimeSlot.morning:
        // Light, upbeat
        if (mood == SessionMood.chill || mood == SessionMood.romantic) return 1.0;
        if (genre == 'lofi') return 0.8;
        return 0.3;
      case TimeSlot.afternoon:
        // Balanced — all good
        return 0.5;
      case TimeSlot.evening:
        // Popular, mainstream
        if (mood == SessionMood.party || mood == SessionMood.energetic) return 0.9;
        return 0.5;
      case TimeSlot.night:
        // Chill, romantic
        if (mood == SessionMood.romantic || mood == SessionMood.chill) return 1.0;
        if (mood == SessionMood.sad) return 0.7;
        return 0.3;
      case TimeSlot.lateNight:
        // Relax, lofi
        if (genre == 'lofi' || mood == SessionMood.chill) return 1.0;
        if (mood == SessionMood.sad) return 0.8;
        return 0.2;
    }
  }

  // ---------------------------------------------------------------------------
  // SECTION 8: ANTI-REPETITION
  // ---------------------------------------------------------------------------

  /// Returns true if this song should be blocked from the auto-queue.
  /// Checks: session recent IDs, artist repetition limit, variant detection.
  static bool shouldBlock(Song song, {String? currentTitle}) {
    if (!_loaded) return false;

    // Block if in recent session window (last 20 songs)
    if (_session != null && _session!.recentIds.contains(song.id)) return true;

    // Block artist only if appeared in last 2 CONSECUTIVE songs
    // (not last 3 unique — that's too aggressive for small genre pools like bhojpuri)
    if (_session != null && _session!.recentArtists.length >= 2) {
      final lastTwo   = _session!.recentArtists.take(2).toList();
      final artistNorm = _normalizeKey(song.artist);
      // Only block if BOTH of the last 2 were this same artist
      if (lastTwo.every((a) => _normalizeKey(a) == artistNorm)) return true;
    }

    // Block if this is a variant of the current/recently played song
    if (currentTitle != null) {
      if (_isVariant(song.title, currentTitle)) return true;
    }

    // Block the song itself if it's inherently a low-quality variant
    if (isInherentVariant(song.title)) return true;

    return false;
  }

  /// Is `candidate` a variant (remix/cover/lofi/etc.) of `original`?
  static bool _isVariant(String candidate, String original) {
    final candCore = _titleCore(candidate);
    final origCore = _titleCore(original);
    if (candCore.isEmpty || origCore.isEmpty) return false;
    // Block if cores are identical (same song different label)
    if (candCore == origCore) return true;
    // Block if candidate core contains the full original core (e.g. "tum hi ho female")
    if (candCore.contains(origCore) && origCore.length >= 5) return true;
    // Block if original core contains the candidate core (reverse)
    if (origCore.contains(candCore) && candCore.length >= 5) return true;
    // Prefix match — first 15 chars
    final prefixLen = origCore.length.clamp(0, 15);
    final prefix = origCore.substring(0, prefixLen);
    if (prefix.isNotEmpty && candCore.startsWith(prefix) && candCore != origCore) return true;
    // FIX ("same song 5-8x in Up Next from different re-uploads"): none of
    // the checks above catch real-world title pollution like "- SONG |
    // Salman Khan", "8K - Saajan | Madhuri...", "4k HD ((Jhankar))",
    // "With LYRICS", "-Duet | Alka...", "(feat. Armaan Malik)". These
    // aren't remix/cover keywords (isInherentVariant's blocklist can't
    // catch them, and never fully will — uploaders invent new junk
    // suffixes constantly) — they're uploader/quality/credit noise
    // appended AFTER the real title. Comparing on the RAW titles (not the
    // already-stripped cores) lets isSameSongSmart use the separators
    // uploaders themselves put around that noise.
    if (isSameSongSmart(candidate, original)) return true;
    return false;
  }

  // Matches a leading run of separator characters uploaders use to fence
  // off the real title from everything else in a listing: pipe, colon,
  // en/em-dash, a spaced hyphen, or an opening bracket. Whatever comes
  // before the FIRST one of these is, in the overwhelming majority of
  // real JioSaavn/YouTube titles, the actual song name — movie name,
  // uploader credit, featured artists, and quality/format tags always
  // come after one of these markers, never before.
  static final RegExp _titleSeparator =
      RegExp(r'\s*[|:\u2013\u2014(\[]\s*|\s-\s');

  // Extra noise words that show up glued directly onto the title itself
  // (no separator before them) often enough to need stripping even from
  // the "head": quality tags, "with lyrics", "duet", credit joiners.
  // Deliberately separate from _variantPattern — these aren't musical
  // variants (remix/cover/slowed), just upload-listing clutter, so they
  // don't belong in the "block this song as an inferior variant" list,
  // only in the "does this look like the same song" comparison.
  //
  // EXPANDED: original list only caught "8k"/"4k"/"hd". Real uploads glue
  // on a much wider set of resolution/bitrate/encode tags directly onto
  // the head with no separator — "1080p", "720p", "320kbps", "hq", "official
  // video/audio", "full song/video" — every one of which used to survive
  // into the cleaned head and could break an otherwise-matching comparison
  // (e.g. "Dekha Hai Pehli Baar 1080p" vs "Dekha Hai Pehli Baar HQ" — two
  // reuploads of the same song, previously left with two different
  // trailing tokens instead of both collapsing to the same clean head).
  static final RegExp _headNoisePattern = RegExp(
    r'\b(8k|4k|2k|hd|hq|fhd|uhd|\d{3,4}p|\d{2,4}\s*kbps|'
    r'with\s*lyrics|lyrics video|lyrics|duet|feat|ft|'
    r'official\s*(video|audio|music\s*video)?|full\s*(song|video|audio)|'
    r'audio|video|song)\b',
    caseSensitive: false,
  );

  /// The real song-title portion of a raw (unstripped) title string — text
  /// up to the first separator, with quality/credit noise words removed.
  /// Public so ApiService/PlayerProvider (different files) can build the
  /// same head for their own dedup passes without duplicating this regex.
  ///
  /// NOTE: this assumes the title is the FIRST segment before any
  /// separator. That holds for the common "Title | Movie | Uploader"
  /// shape, but not for uploads formatted "Artist: Title" or
  /// "Artist - Title" (credit-first). Use [titleSegments] +
  /// [isSameSongSmart] for the general case — this is kept only for
  /// existing call sites that specifically want "just the first chunk".
  static String titleHead(String rawTitle) {
    final firstPart = rawTitle.split(_titleSeparator).first;
    return _cleanSegment(firstPart);
  }

  static String _cleanSegment(String segment) {
    // FIX (Devanagari/non-Latin segments producing false matches): stripping
    // every non-ASCII character from a segment like "साजन की आँखों में
    // प्यार 4K Salman" used to leave only the stray Latin leftover ("4k
    // salman" -> "salman") behind, which could then coincidentally token-
    // match an unrelated title's short segment. A segment that's mostly
    // non-Latin script has no reliable ASCII "head" to extract at all —
    // safer to treat it as junk (empty) than to silently compare on
    // whatever Latin fragment happens to survive.
    //
    // Counts letters only (not punctuation/digits/whitespace) using
    // simple explicit character classes rather than a `\p{...}` Unicode
    // property regex — those need `unicode: true` support that's newer
    // and less universally exercised across Dart/Flutter versions, and a
    // rough letter count is all this ratio check actually needs.
    final nonLatinLetters = RegExp(r'[^\x00-\x7F]').allMatches(segment).length;
    final letterish =
        RegExp(r'[a-zA-Z\u00C0-\uFFFF]').allMatches(segment).length;
    if (letterish > 0 && nonLatinLetters / letterish > 0.3) return '';

    return segment
        .toLowerCase()
        .replaceAll(_headNoisePattern, '')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // Segments not worth treating as "the title" even after cleaning — pure
  // uploader/channel-name/credit noise that would otherwise falsely match
  // another short credit-only segment from an unrelated title. Keeps
  // titleSegments() from picking e.g. a bare "duet" or "lyrics" leftover
  // as if it were a real song name.
  static bool _isJunkSegment(String cleaned) =>
      cleaned.isEmpty || cleaned.length < 3;

  // ---------------------------------------------------------------------------
  // STRUCTURAL suffix-noise detection (keyword-independent).
  //
  // WHY THIS EXISTS: _variantPattern/_headNoisePattern are keyword blocklists.
  // They catch "jhankar beats"/"afro mix"/"duet version" only because those
  // exact words were added by hand — a new uploader tag invented tomorrow
  // ("Dolby Atmos Mix", "8D Surround Edit", "Rewind 2027") slips through
  // both silently, and the list needs a manual patch every time. That is
  // fine as a *fast path* (cheap, catches the common cases immediately) but
  // is not something a paid app should rely on as the ONLY defense.
  //
  // The structural fix: a trailing segment (the part of a title AFTER a
  // separator like "|", "-", ":", "(") is treated as decorative noise —
  // regardless of what word it contains — whenever ALL of the following
  // hold:
  //   1. It is short (<= 3 real words) — genuine alternate song titles are
  //      almost never this short on their own.
  //   2. It does NOT itself look like a plausible independent song title —
  //      approximated here as "shares no word with the head segment AND
  //      isn't long enough to plausibly stand alone" is too aggressive, so
  //      instead we only use this signal to WEAKEN the requirement for
  //      treating two titles as the same song, never to strengthen it. See
  //      _looksLikeDecorativeSuffix below for the precise rule.
  //
  // This is deliberately layered ON TOP of the keyword lists, not a
  // replacement — keyword hits are still checked first because they're
  // unambiguous. This structural check is the fallback that keeps working
  // when a keyword hit doesn't happen.
  // ---------------------------------------------------------------------------

  /// True if `segment` (already-cleaned, lowercase) looks like decorative
  /// uploader noise glued onto a title rather than a real second song name.
  /// Used only as a fallback signal inside [isSameSongSmart] — never used to
  /// block a song outright on its own, only to make the "is this the same
  /// song" comparison more lenient about an unrecognized trailing tag.
  static bool _looksLikeDecorativeSuffix(String segment) {
    if (segment.isEmpty) return false;
    final words = segment.split(' ').where((w) => w.isNotEmpty).toList();
    // Real song titles are very rarely 1-3 words of purely generic-sounding
    // filler. Genuine short titles ("Kesariya", "Raataan Lambiyan") do
    // exist, which is exactly why this signal is only ever used to WEAKEN
    // a match requirement, never to unilaterally decide two songs are the
    // same — see call site.
    if (words.length > 3) return false;
    // A segment made up of very common English filler/production words
    // ("with", "beats", "mix", "version", "edit", "vol", numerals, etc.)
    // structurally resembles a production/quality tag even without being
    // on the hardcoded keyword list — this is a SHAPE check (short +
    // generic-looking tokens), not a specific-word check.
    final genericTokenPattern = RegExp(
      r'^(with|beats?|mix(?:ed)?|version|edit(?:ed)?|vol\.?|part|pt\.?|'
      r'v\d+|no\s?\d+|\d+|super|new|old|special|exclusive|ultra|super hd|'
      r'studio|live|original|classic|hits?|collection)$',
    );
    final genericCount = words.where((w) => genericTokenPattern.hasMatch(w)).length;
    // If at least half the words in this short segment are generic/
    // production-sounding tokens, treat it as decorative.
    return genericCount * 2 >= words.length;
  }

  /// All plausible "this could be the real title" segments of a raw
  /// (unstripped) title string, cleaned the same way as [titleHead].
  /// Real-world uploads put the song name in different positions —
  /// "Title | Movie | Uploader" (title first) vs. "Uploader: Title" or
  /// "Artist - Title" (credit first, title second) — and there's no
  /// reliable way to know which shape a given upload used just from its
  /// punctuation. Returning every segment (instead of only the first)
  /// lets [isSameSongSmart] try each one, so a credit-first title like
  /// "Alka Yagnik: Dekha Hai Pehli Baar..." still matches "Dekha Hai
  /// Pehli Baar" via its SECOND segment even though its first segment
  /// ("alka yagnik") does not.
  static List<String> titleSegments(String rawTitle) {
    final parts = rawTitle.split(_titleSeparator);
    final segments = <String>[];
    for (final part in parts) {
      final cleaned = _cleanSegment(part);
      if (!_isJunkSegment(cleaned)) segments.add(cleaned);
    }
    // Always include the raw first-segment head too (even if short),
    // so behavior never regresses for titles where every segment is
    // legitimately short (e.g. a 2-word song name with no clutter).
    final head = _cleanSegment(parts.first);
    if (head.isNotEmpty && !segments.contains(head)) {
      segments.insert(0, head);
    }
    return segments;
  }


  /// Is this the same underlying song, judging by its real title rather
  /// than the uploader/quality/credit noise wrapped around it? This is
  /// the durable, generalizing check — Spotify/YouTube Music lean on
  /// engagement + catalog matching for the same reason a keyword
  /// blocklist alone never survives contact with real-world uploaders:
  /// there's no finite list of every way a title can be dressed up.
  /// Approach: extract each title's "head" (the real name, before any
  /// uploader/credit/quality suffix) using [titleHead], then require the
  /// shorter head's words to appear, in order, in the longer head — so
  /// "Dekha Hai Pehli Baar" (from a bare listing) matches "Dekha Hai
  /// Pehli Baar 8K" and "...With LYRICS" (extra tag words glued onto the
  /// head itself, no separator before them) but NOT some unrelated title
  /// that merely shares a couple of common words.
  static bool isSameSongSmart(String rawA, String rawB) {
    // FIX ("Alka Yagnik: Dekha Hai Pehli Baar..." not matching "Dekha Hai
    // Pehli Baar"): comparing only titleHead() (the first segment) misses
    // every credit-first upload — "Uploader: Title" or "Artist - Title"
    // puts the real song name in the SECOND segment, not the first, so the
    // old head-vs-head compare silently matched "alka yagnik" against
    // "dekha hai pehli baar" (no match) and gave up, instead of ever
    // trying the segment that actually would have matched. Trying every
    // segment of each title against every segment of the other catches
    // both title-first AND credit-first upload shapes without needing to
    // guess which shape a given upload used.
    final segmentsA = titleSegments(rawA);
    final segmentsB = titleSegments(rawB);
    if (segmentsA.isEmpty || segmentsB.isEmpty) return false;

    for (final headA in segmentsA) {
      for (final headB in segmentsB) {
        if (_segmentsMatch(headA, headB)) return true;
      }
    }

    // STRUCTURAL fallback (keyword-independent): if the two titles' FIRST
    // segments already match closely, and every segment of the LONGER
    // title beyond that point looks like decorative noise (short,
    // generic-shaped — see _looksLikeDecorativeSuffix), treat them as the
    // same song even though no keyword list recognized the trailing tag.
    // This is what lets an uploader-invented tag nobody has hardcoded yet
    // ("Dolby Atmos Mix", "Rewind 2027 Edit", ...) still get caught, as
    // long as it structurally looks like a short production tag rather
    // than a genuine second song title.
    final firstA = segmentsA.first;
    final firstB = segmentsB.first;
    if (_segmentsMatch(firstA, firstB)) {
      final extraSegments = segmentsA.length >= segmentsB.length
          ? segmentsA.skip(1)
          : segmentsB.skip(1);
      if (extraSegments.isEmpty ||
          extraSegments.every(_looksLikeDecorativeSuffix)) {
        return true;
      }
    }

    return false;
  }

  /// True if two tokens are the same word, allowing for a common
  /// reupload/transliteration typo — one character inserted, deleted, or
  /// substituted (Levenshtein distance 1). Deliberately restrictive:
  /// - Only applies to tokens of length >= 5. Shorter words ("hai", "toh",
  ///   "yeh", "aur") are 1 edit away from too many genuinely different
  ///   short words to risk fuzzy-matching safely.
  /// - Distance must be exactly <= 1, never more — this is for catching
  ///   "Dekhha"/"Dekha" and "Rajkummar"/"Rajkumar" style double-letter
  ///   typos in phonetic Hindi->English transliteration, not for loosely
  ///   matching different words that happen to look similar.
  static bool _fuzzyTokenMatch(String a, String b) {
    if (a == b) return true;
    if (a.length < 5 || b.length < 5) return false;
    if ((a.length - b.length).abs() > 1) return false;
    return _levenshteinAtMost1(a, b);
  }

  /// Returns true iff edit distance between [a] and [b] is 0 or 1.
  /// Early-exits as soon as more than 1 edit is proven necessary, so this
  /// stays cheap even though it's called inside a nested loop — no full
  /// O(n*m) DP table, just a linear scan with at most one skip allowed.
  static bool _levenshteinAtMost1(String a, String b) {
    if (a == b) return true;
    final lenDiff = a.length - b.length;
    if (lenDiff.abs() > 1) return false;

    if (lenDiff == 0) {
      // Same length: must be exactly one substitution.
      var mismatches = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) {
          mismatches++;
          if (mismatches > 1) return false;
        }
      }
      return true;
    }

    // Different length by 1: one insertion/deletion. Walk both strings,
    // allow exactly one index-skip on the longer string when a mismatch
    // is hit, then require the rest to line up exactly.
    final shorter = a.length < b.length ? a : b;
    final longer   = a.length < b.length ? b : a;
    var i = 0, j = 0;
    var skipped = false;
    while (i < shorter.length && j < longer.length) {
      if (shorter[i] == longer[j]) {
        i++;
        j++;
      } else {
        if (skipped) return false;
        skipped = true;
        j++; // skip one char in the longer string
      }
    }
    return true;
  }

  /// Core token-overlap + order check between two already-cleaned segments.
  /// Extracted from the old isSameSongSmart body so [isSameSongSmart] can
  /// call it once per segment pair.
  static bool _segmentsMatch(String headA, String headB) {
    if (headA.isEmpty || headB.isEmpty) return false;
    if (headA == headB) return true;

    final tokensA = headA.split(' ').where((t) => t.length >= 2).toList();
    final tokensB = headB.split(' ').where((t) => t.length >= 2).toList();
    if (tokensA.isEmpty || tokensB.isEmpty) return false;

    final List<String> shortTokens;
    final List<String> longTokens;
    if (tokensA.length <= tokensB.length) {
      shortTokens = tokensA;
      longTokens = tokensB;
    } else {
      shortTokens = tokensB;
      longTokens = tokensA;
    }

    final longSet = longTokens.toSet();
    // FIX (spelling-variant reuploads: "Dekhha" vs "Dekha", "Rajkummar" vs
    // "Rajkumar"): exact set-containment alone misses this extremely
    // common class of reupload noise — uploaders retyping a Hindi/Urdu
    // name phonetically produces a token that's 1 character off from the
    // "real" spelling, which used to count as a total non-match for that
    // token (0 overlap credit) even though a human reads them as the same
    // word instantly. `_fuzzyTokenMatch` allows a tight 1-edit tolerance,
    // but ONLY for tokens of length >= 5 — short 3-4 letter words (like
    // "hai", "toh", "yeh") are exactly 1 edit apart from lots of genuinely
    // different short words, so fuzzy-matching those would create false
    // positives instead of catching real typos.
    bool tokenOverlaps(String t) =>
        longSet.contains(t) || longTokens.any((lt) => _fuzzyTokenMatch(t, lt));
    final overlap = shortTokens.where(tokenOverlaps).length;
    final overlapRatio = overlap / shortTokens.length;

    // Very short heads (<=2 real words) need a perfect match — a single
    // coincidental shared word means little. Longer heads tolerate one
    // stray non-matching word (a typo, an extra tag word the noise regex
    // missed) without being rejected outright.
    final minRatio = shortTokens.length <= 2 ? 1.0 : 0.8;
    if (overlapRatio < minRatio) return false;

    // Order check: matched words must appear in the same relative
    // sequence in both heads, not just the same bag of words — guards
    // against two unrelated titles that happen to share a couple of
    // common Hindi/English words in scrambled order.
    final matchedInShort = shortTokens.where(tokenOverlaps).toList();
    final longIndex = <String, int>{};
    for (var i = 0; i < longTokens.length; i++) {
      longIndex.putIfAbsent(longTokens[i], () => i);
    }
    var lastPos = -1;
    for (final t in matchedInShort) {
      final pos = longIndex[t];
      if (pos == null) continue;
      if (pos < lastPos) return false;
      lastPos = pos;
    }
    return true;
  }

  /// Back-compat name kept for call sites that already dedup on
  /// pre-stripped `_titleCore`/`_normTitle` strings rather than raw
  /// titles — falls through to the same smart comparison since
  /// [isSameSongSmart] degrades gracefully on already-cleaned input
  /// (no separators left to split on just means the whole string is
  /// treated as the head, which is exactly the old token-overlap
  /// behavior for that case).
  static bool isSameSongByTokens(String coreA, String coreB) =>
      isSameSongSmart(coreA, coreB);

  /// Is this song itself a low-quality variant by title alone?
  /// Public — called from ApiService._scoreSearchResult().
  static bool isInherentVariant(String title) {
    return _variantPattern.hasMatch(title);
  }

  static final RegExp _variantPattern = RegExp(
    r'\b(remix|lofi|lo[- ]?fi|slowed|reverb|nightcore|cover|karaoke|'
    r'instrumental|bass[ -]?boost(?:ed)?|8d|sped[ -]?up|speed(?:ed)?[ -]?up|'
    r'reprise|mashup|tribute|remaster(?:ed)?|unplugged|acoustic version|'
    r'orchestra|choir|chillout|drill remix|female version|male version|'
    r'recreated|recreation|refix|redux|rework(?:ed)?|revamp(?:ed)?|'
    r'lounge mix|jukebox|jhankar(?:\s*beats)?|super\s*jhankar|'
    r'recreate|extended|flip|bootleg|'
    r'chill mix|punjabi mix|hindi mix|afro mix|tapori|dj |club mix|'
    r'the return|revisited|throwback mix|new version|duet(?:\s*version)?|'
    r'ringtone|bgm|background music|type beat|'
    r'\d\.\d)\b',
    caseSensitive: false,
  );

  static bool looksLikeChannelName(String artist) {
    return _channelNamePattern.hasMatch(artist);
  }

  static final RegExp _channelNamePattern = RegExp(
    r'\b(t-?series|vevo|records|music company|music official|'
    r'entertainment|studios?|productions?|films?|cinema|label|'
    r'official channel|music india|music bhojpuri|music hub|'
    r'sony music|zee music|saregama|tips (?:official|music)|'
    r'speed records|white hill|desi music|indie music|'
    r'top\s?(?:10|20)|now (?:playing|streaming)|jukebox)\b',
    caseSensitive: false,
  );

  /// Catches low-quality ORIGINAL uploads that aren't remixes/covers but
  /// still don't belong in a premium "Top Hits" feed — random local
  /// uploaders' New Year jingles, generic "naya dhamaka" spam, wedding/
  /// folk-event tracks, freestyle filler. These pass isInherentVariant()
  /// (no remix/cover keyword) but are still junk. Used only for the
  /// curated home-feed playlist cards (_kCuratedPlaylists), which use
  /// broad queries like "top hindi songs 2025 2026" that Saavn's search
  /// matches loosely against any title containing those words/years.
  static bool isLowQualityUpload(String title) {
    return _junkUploadPattern.hasMatch(title);
  }

  static final RegExp _junkUploadPattern = RegExp(
    r'\b(naya dhamaka|dhamaka 20\d\d|happy new year|nav varsh|'
    r'naye saal|det badhai|badhai ho|beet phone|bhaiya ji|'
    r'freestyle|panwadi|wedding dance|vivah geet|shaadi geet|'
    r'jukebox 20\d\d|mp3 song|whatsapp status|status video|'
    r'trending status|viral video song|dance video|'
    r'gana 20\d\d|new gana|superhit gana|bhojpuri gana)\b',
    caseSensitive: false,
  );

  // ---------------------------------------------------------------------------
  // PREMIUM QUALITY GATE — the real Spotify/YouTube-Music-style signal.
  //
  // Keyword blocklists (isInherentVariant / isLowQualityUpload) only catch
  // junk that happens to use predictable words. New junk uploaders constantly
  // invent new phrasing that slips past any word list. A real premium feed
  // instead trusts ENGAGEMENT — genuine hit songs accumulate massive view
  // counts; random local/wedding/status uploads almost never do. This is the
  // same signal Spotify/YouTube Music algorithms lean on (popularity/plays),
  // and it can't be defeated by a junk uploader just picking different words.
  //
  // Applies to YouTube results only (Song.viewCount is null for Saavn/local —
  // Saavn's catalog is already pre-curated licensed content, so it doesn't
  // carry this same junk-upload risk the same way raw YouTube search does).
  // ---------------------------------------------------------------------------

  // Below this view count, a YouTube result is treated as an unproven/
  // low-quality upload and excluded from home-feed sections. Chosen so a
  // genuine mainstream Bollywood/Hindi song (which routinely sits in the
  // lakhs-to-crores range within weeks) clears it easily, while one-off
  // wedding/status/local uploads (typically hundreds to low thousands of
  // views) do not.
  static const int _minViewsForPremiumFeed = 100000;

  // Real songs are rarely under 90s (that's a ringtone/status clip length).
  // Upper bound is generous — qawwali/ghazal tracks legitimately run long —
  // and only exists to catch actual jukebox/full-album compilations mislabeled
  // as a single track.
  static const int _minDurationSeconds = 90;
  static const int _maxDurationSeconds = 1200;

  /// True if `song` meets the bar for a premium home-feed section.
  /// For YouTube: requires a minimum view count AND a sane song-length
  /// duration. For Saavn/local: only the existing duration sanity check
  /// applies (no view-count data available from that source).
  static bool isPremiumQuality(Song song) {
    if (song.duration != null) {
      if (song.duration! < _minDurationSeconds) return false;
      if (song.duration! > _maxDurationSeconds) return false;
    }
    if (song.source == SongSource.youtube) {
      // No view count at all (fetch failed/hidden) — don't trust it blind.
      if (song.viewCount == null) return false;
      if (song.viewCount! < _minViewsForPremiumFeed) return false;
    }
    return true;
  }

  // FIX ("T-Series/Saregama copyright-holder uploads and non-music videos
  // (news, vlogs) showing up in the queue"): YouTube's own related-videos
  // graph (NativeRelatedVideos.getRelated, used as one of getAutoQueue's
  // signal sources) has no concept of "music vs. everything else" — it
  // surfaces whatever YouTube's algorithm associates with a video, which
  // for a Bollywood song is very often the SAME song re-uploaded on the
  // label's own channel (T-Series/Saregama/Sony Music/Zee Music etc. —
  // legitimate uploaders, but a bare label-channel reupload with no real
  // song title, since the label channel IS the primary/official upload
  // rather than a distinct discovery), or entirely unrelated content the
  // algorithm associates only by co-watch pattern (news, commentary,
  // vlogs — e.g. a Dhruv Rathee political video, which is exactly what
  // was reported: it played AS a queue entry, not just appeared in a
  // list). Two independent signals catch this without needing a real
  // genre/category API (YouTube doesn't expose one via NewPipeExtractor):
  //   1. Title pattern: real song uploads consistently use "Song Name -
  //      Movie | Artist" or "Song Name (Lyrics)" style titles. Generic
  //      news/vlog-style titles ("Why is X DROWNING?", "X EXPLAINED",
  //      question-style or all-caps-hook titles) don't follow that
  //      pattern and are excluded on title shape alone, independent of
  //      channel name — this also catches non-label channels doing the
  //      same kind of content.
  //   2. Channel-only labels: a handful of major label/network channels
  //      (T-Series, Saregama, Sony Music [India], Zee Music, Aditya
  //      Music, Tips, Venus) are legitimate music sources in general, so
  //      they're not blocked outright — but a bare label-channel entry
  //      with no distinguishing song-style title marker is exactly the
  //      "generic reupload, not a real discovery" case, so those are
  //      filtered while a clearly-titled song from the same label (which
  //      does happen, e.g. an actual new release) still passes through.
  static final RegExp _nonMusicTitlePattern = RegExp(
    r'\b(vs\.?\b|explained|exposed|breaking|debate|interview|podcast|'
    r'documentary|analysis|review|reaction|vlog|news|update|crisis|'
    r'scandal|controversy|drowning|flood|election|protest|war\b|'
    r'government|politics|political)\b',
    caseSensitive: false,
  );

  // Titles ending in a bare "?" hook or written in a shouty all-caps
  // clause are a strong commentary/news-video signal — real song titles
  // essentially never end a sentence-style question this way.
  static final RegExp _questionHookPattern = RegExp(r'\?\s*\|?\s*$');

  static const Set<String> _labelOnlyChannels = {
    't-series', 'saregama', 'saregama music', 'sony music india',
    'zee music company', 'aditya music', 'tips official', 'venus',
    'speed records', 'white hill music',
  };

  // A title carries real song-style markers if it has a separator
  // structure typical of music uploads: "Song - Movie", "Song | Artist",
  // "Song (Lyrics)/(Official Video)/(Audio)". Absence of all of these
  // combined with a label-only channel is what marks a bare reupload.
  static final RegExp _songStyleMarkerPattern = RegExp(
    r'[\-\|]|\((lyrics?|official( video| audio)?|full song|audio)\)',
    caseSensitive: false,
  );

  /// True if `song` looks like non-music content (news/commentary/vlog) or
  /// a bare label-channel reupload with no real song-title structure, and
  /// should never be auto-queued regardless of how strongly YouTube's own
  /// related-videos graph associated it with the current song.
  static bool isNonMusicContent(Song song) {
    if (song.source != SongSource.youtube) return false;
    final title = song.title;
    if (_nonMusicTitlePattern.hasMatch(title)) return true;
    if (_questionHookPattern.hasMatch(title)) return true;

    final channel = song.artist.trim().toLowerCase();
    if (_labelOnlyChannels.contains(channel) &&
        !_songStyleMarkerPattern.hasMatch(title)) {
      return true;
    }
    return false;
  }

  // Strip variant tags from title to get the "core" for comparison
  static String _titleCore(String title) {
    return title
        .toLowerCase()
        .replaceAll(_variantPattern, '')
        .replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), '') // remove bracketed extras
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ---------------------------------------------------------------------------
  // SECTION 9: POOL FILTERING & RANKING
  //
  // Given a pool of candidate songs, apply scoring, filtering, and the
  // 70/20/10 discovery mix. Returns ranked list ready for queue insertion.
  // ---------------------------------------------------------------------------

  /// Rank and filter a pool of candidate songs for auto-queue use.
  ///
  /// [pool]            — all candidates from signal queries
  /// [currentSong]     — song currently playing (for variant detection)
  /// [existingIds]     — IDs already in queue (dedup)
  /// [allowVariants]   — if true, skip the _isInherentVariant filter
  ///   (used when user explicitly tapped a lofi/remix song)
  static List<Song> rankAndFilter({
    required List<Song> pool,
    required Song currentSong,
    required Set<String> existingIds,
    bool allowVariants = false,
    int limit = 10,
  }) {
    final seenIds    = <String>{currentSong.id, ...existingIds};
    final currentCore = _titleCore(currentSong.title);
    final seenTitles = <String>{currentCore};
    // FIX ("infinite Up Next eventually replays a reupload from much
    // earlier in the session"): seenTitles above only ever knew about
    // titles accepted within THIS SINGLE rankAndFilter call. On a long
    // endless session, _maybeExtendQueue calls getAutoQueue→rankAndFilter
    // fresh every time the queue runs low, so nothing here previously
    // remembered a title that was accepted three or four batches ago.
    // Seeding seenTitles with the session's long title window (up to 200,
    // see RecommendationEngine.sessionRecentTitles) closes that gap —
    // batches now share dedup memory across the whole session, not just
    // within themselves.
    seenTitles.addAll(sessionRecentTitles);
    // Raw (unstripped) titles of everything accepted so far, kept
    // alongside `seenTitles` so isSameSongSmart still has the original
    // separators (|, :, -, brackets) to split on — _titleCore already
    // destroys those, which is fine for the exact/prefix checks above but
    // would blind the smart head-comparison below.
    final seenRawTitles = <String>[currentSong.title];

    final scored = <_ScoredSong>[];

    for (final song in pool) {
      // ID dedup
      if (seenIds.contains(song.id)) continue;

      // FIX (isNonMusicContent was defined but never actually called —
      // dead code from an earlier pass): this is the actual wire-in. Every
      // candidate, from every signal, now gets checked here before any
      // other filter — non-music/news/vlog content and bare label-channel
      // reuploads never reach scoring at all, regardless of which signal
      // (Saavn-similar, YT-related, mood/genre fallback, etc.) surfaced
      // them or how strongly that signal's own logic favored them.
      if (isNonMusicContent(song)) continue;

      // Variant filter
      if (!allowVariants) {
        if (isInherentVariant(song.title)) continue;
        if (_isVariant(song.title, currentSong.title)) continue;
        // Check against recently played in session
        final core = _titleCore(song.title);
        if (seenTitles.contains(core)) continue;
        // Prefix match: block "Tum Hi Ho (Female)" etc.
        final prefix = currentCore.substring(0, currentCore.length.clamp(0, 10));
        if (prefix.isNotEmpty && core.startsWith(prefix) && core != currentCore) continue;
        // FIX ("same song 5-8x back to back in Up Next"): the checks above
        // only compare `core` against the CURRENT song and against exact
        // string matches already in `seenTitles`. Two different re-uploads
        // of the SAME other song (e.g. "...8K - Saajan | Madhuri..." and
        // "...With LYRICS | Saajan...") produce two different `core`
        // strings from each other too, so neither exact-match nor prefix
        // catches the pair — they'd both individually clear every check
        // above and both land in the accepted pool side by side. Smart
        // title-head comparison against every RAW title already accepted
        // into THIS pool (not just the current song) is what actually
        // stops that.
        var isDupOfAccepted = false;
        for (final seenRaw in seenRawTitles) {
          if (isSameSongSmart(song.title, seenRaw)) {
            isDupOfAccepted = true;
            break;
          }
        }
        if (isDupOfAccepted) continue;
      }

      // Artist repetition check from session
      if (_session != null) {
        final recentTwo = _session!.recentArtists.take(2).toSet();
        if (recentTwo.contains(song.artist) && scored.length > 3) continue;
      }

      final score = scoreCandidate(song, currentSong: currentSong);
      if (score < 0.1) continue; // hard floor — skip heavily penalized songs

      seenIds.add(song.id);
      seenTitles.add(_titleCore(song.title));
      seenRawTitles.add(song.title);
      scored.add(_ScoredSong(song, score));
    }

    // Sort by score descending
    scored.sort((a, b) => b.score.compareTo(a.score));

    // Apply 70/20/10 discovery mix
    return _applyDiscoveryMix(scored, limit: limit);
  }

  static List<Song> _applyDiscoveryMix(List<_ScoredSong> sorted, {required int limit}) {
    if (sorted.isEmpty) return [];

    final core      = <Song>[];  // top 70% — highly relevant
    final related   = <Song>[];  // next 20% — related
    final discovery = <Song>[];  // bottom 10% — varied/new

    final total = sorted.length;
    for (int i = 0; i < total; i++) {
      final ratio = i / total;
      if (ratio < 0.70)      core.add(sorted[i].song);
      else if (ratio < 0.90) related.add(sorted[i].song);
      else                   discovery.add(sorted[i].song);
    }

    // Build final list: 70% core, 20% related, 10% discovery
    final result = <Song>[];
    final coreCount      = (limit * 0.70).ceil();
    final relatedCount   = (limit * 0.20).ceil();
    final discoveryCount = (limit * 0.10).ceil();

    // Per-artist cap: no single artist should flood a batch even if their
    // songs scored highest. Real YT/Spotify mixes always look "shuffled by
    // artist" — max 3 songs from one artist in a single auto-queue batch.
    const maxPerArtist = 3;
    final artistCounts = <String, int>{};

    // Per-album cap: same idea, but for the movie/OST/album a song comes
    // from. Without this, a movie soundtrack with several genuinely
    // DIFFERENT songs (not duplicates — e.g. "Sagar Se Gehra Hai Pyar
    // Humara", "Mera Dil Bhi Kitna Pagal Hai", "Kya Beqarari Hai", all from
    // "Saajan") can legitimately out-score everything else via the
    // same-artist/same-era signals and flood 4-5 consecutive Up Next slots
    // with tracks from one soundtrack — technically not duplicates (they
    // pass isSameSongSmart fine) but it still reads as "stuck on one
    // album" rather than a fresh, diverse mix. Capped tighter than the
    // artist cap (2 vs 3) since an album is a narrower, more repetitive
    // context than an artist's whole catalog. Blank/unknown album names
    // are never capped (compilations/singles legitimately share "Unknown"
    // or "" and shouldn't be penalized for it).
    const maxPerAlbum = 2;
    final albumCounts = <String, int>{};

    bool underCap(Song s) {
      final artistKey = _normalizeKey(s.artist);
      final albumKey  = _normalizeKey(s.album);
      final artistN = artistCounts[artistKey] ?? 0;
      final albumN  = albumKey.isEmpty ? 0 : (albumCounts[albumKey] ?? 0);
      // Check both caps BEFORE mutating either counter — a song rejected
      // by one cap must not still consume a slot against the other.
      if (artistN >= maxPerArtist) return false;
      if (albumKey.isNotEmpty && albumN >= maxPerAlbum) return false;
      artistCounts[artistKey] = artistN + 1;
      if (albumKey.isNotEmpty) albumCounts[albumKey] = albumN + 1;
      return true;
    }

    result.addAll(core.where(underCap).take(coreCount));
    result.addAll(related.where(underCap).take(relatedCount));
    result.addAll(discovery.where(underCap).take(discoveryCount));

    // If the cap left us short of `limit` (small pool, few artists),
    // backfill from whatever's left over.
    // FIX: this loop used to skip `underCap` entirely ("ignoring the cap"),
    // which meant a short pool could let one high-scoring artist flood
    // straight back in during backfill — silently undoing the maxPerArtist
    // enforcement literally just applied above. Backfill now respects the
    // same cap first; only once *every* remaining candidate has been
    // considered under the cap and the queue is STILL short does it fall
    // back to ignoring the cap (better than returning a short queue).
    if (result.length < limit) {
      final used = result.map((s) => s.id).toSet();
      final leftover = [...core, ...related, ...discovery]
          .where((s) => !used.contains(s.id))
          .toList();
      for (final s in leftover) {
        if (result.length >= limit) break;
        if (!underCap(s)) continue;
        result.add(s);
        used.add(s.id);
      }
      // Still short after respecting the cap (genuinely thin pool) — only
      // now ignore the cap, so a small catalog still returns a full queue.
      if (result.length < limit) {
        for (final s in leftover) {
          if (result.length >= limit) break;
          if (used.contains(s.id)) continue;
          result.add(s);
          used.add(s.id);
        }
      }
    }

    // Shuffle slightly within each tier to avoid same-order repetition
    _shuffleTier(result, 0, math.min(coreCount, result.length));

    // FIX ("premium feel" — real Spotify/YT Music never play 2-3 songs by
    // the same artist back-to-back even when that artist legitimately
    // scores highest for several songs in a row). The per-artist CAP above
    // only limits how many total songs from one artist appear in the whole
    // batch — it says nothing about WHERE they land, so 3 allowed copies
    // of the same artist could still all end up consecutive at positions
    // 4, 5, 6. This pass re-orders the already-capped, already-shuffled
    // list so the same artist is pushed at least [_minArtistGap] slots
    // apart, without dropping or duplicating anything — it only swaps
    // positions among songs already selected.
    return _interleaveByArtist(result);
  }

  // Minimum number of other songs that must separate two plays of the
  // same artist. 2 mirrors what Spotify/YT Music mixes typically feel
  // like — an artist can return, just not immediately or one song later.
  static const int _minArtistGap = 2;

  /// Reorders `songs` so the same artist never appears within
  /// [_minArtistGap] positions of itself, using a greedy "place the
  /// highest-priority still-eligible song next" pass. Falls back to
  /// placing the least-recently-used artist's song if every remaining
  /// song is currently blocked by the gap rule (small pools / heavy
  /// single-artist bias), so the queue never comes up short.
  static List<Song> _interleaveByArtist(List<Song> songs) {
    if (songs.length < 3) return songs;

    final remaining = List<Song>.from(songs);
    final result = <Song>[];
    final lastSeenAt = <String, int>{}; // artist key -> position last placed

    while (remaining.isNotEmpty) {
      final pos = result.length;
      int pickIndex = -1;

      // First pass: earliest remaining song (preserves the existing
      // relevance ordering) whose artist last appeared far enough back.
      for (var i = 0; i < remaining.length; i++) {
        final key = _normalizeKey(remaining[i].artist);
        final last = lastSeenAt[key];
        if (last == null || pos - last > _minArtistGap) {
          pickIndex = i;
          break;
        }
      }

      // Every remaining song is still within its artist's gap window
      // (only happens with a very artist-heavy small pool) — just take
      // the next one anyway rather than stalling or dropping songs.
      if (pickIndex == -1) pickIndex = 0;

      final chosen = remaining.removeAt(pickIndex);
      lastSeenAt[_normalizeKey(chosen.artist)] = pos;
      result.add(chosen);
    }

    return result;
  }

  static void _shuffleTier(List<Song> list, int start, int end) {
    if (end - start < 2) return;
    final rng = math.Random();
    for (int i = end - 1; i > start; i--) {
      final j = start + rng.nextInt(i - start + 1);
      final temp = list[i];
      list[i] = list[j];
      list[j] = temp;
    }
  }

  // ---------------------------------------------------------------------------
  // SECTION 10: QUERY GENERATION
  //
  // Generates smart search queries for auto-queue signals based on current
  // song + session context. Returns 4 queries in priority order.
  // ---------------------------------------------------------------------------

  static List<AutoQueueQuery> generateQueries(Song currentSong) {
    final genre   = detectGenre(currentSong);
    final lang    = detectLanguage(currentSong);
    final mood    = _detectMoodEnum(currentSong);
    final era     = _eraLanguageQuery(currentSong);
    // Use session mood if available — session mood is the locked context
    final activeMood = _session?.mood ?? mood;

    // Era lock: once we know the current song's decade, queries get
    // era-scoped. This is what makes 90s -> 90s and blocks 2020s songs
    // from sneaking into a 90s session (the YT/Spotify "up next" behavior).
    // decadeTok is the bare token ("90s"), NOT the full `era` phrase —
    // `era` already has language/"songs" baked in and can't be used as a prefix.
    final decadeTok = _songDecade(currentSong);

    // Bump the rotation counter once per call — this is what makes
    // consecutive auto-queue extends explore different similar-artists/
    // mood-phrasings instead of hammering the exact same query (see the
    // fix note on _queryRotation's declaration above).
    final rotation = _queryRotation++;

    if (!_loaded) {
      return [
        AutoQueueQuery('${currentSong.artist} songs', weight: 2),
        AutoQueueQuery(_moodLockedQuery(activeMood, lang, genre, era: decadeTok, rotation: rotation), weight: 2),
        AutoQueueQuery(_sessionMoodQuery(activeMood, lang, era: decadeTok, rotation: rotation), weight: 1),
        AutoQueueQuery(era, weight: 2),
      ];
    }

    final topArtistKeys = _artistW.entries
        .where((e) => e.value > 0.55)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topArtists = topArtistKeys.take(5).map((e) => e.key).toList();

    // Signal 1: Same artist, NO title — gets that artist's other songs
    // Weight 2 but NOT 3 — we don't want only one artist
    final q1 = AutoQueueQuery(
      '${currentSong.artist} songs',
      weight: 2,
    );

    // Signal 2: Mood-locked + genre + ERA — THIS is the YouTube magic
    // Sad 90s song -> "sad 90s bollywood hindi songs", not just "sad bollywood hindi songs"
    // Different artists, same vibe, same decade. Mood phrasing now rotates
    // through a few synonym variants per call (see _moodLockedQuery) so
    // this doesn't become the exact same static string every extend.
    final q2 = AutoQueueQuery(
      _moodLockedQuery(activeMood, lang, genre, era: decadeTok, rotation: rotation),
      weight: 2,
    );

    // Signal 3: Similar artist from genre pool (artist diversity). Now
    // rotation-driven instead of day-seeded — a fresh extend call walks
    // to the NEXT artist in the pool rather than repeating the same one
    // for the whole day, which was the single biggest cause of "Up Next
    // keeps circling back to the same songs".
    final similarArtist = _pickSimilarArtist(currentSong, topArtists, rotation);
    final q3 = AutoQueueQuery(
      '$similarArtist songs',
      weight: 1,
    );

    // Signal 4: Pure era+mood query — broadest net, catches era-matching songs
    // across artists the user hasn't explicitly listened to
    final q4 = AutoQueueQuery(
      decadeTok != null ? era : _sessionMoodQuery(activeMood, lang, rotation: rotation),
      weight: 2,
    );

    // Signal 5 (NEW): a second, DIFFERENT similar-artist pick from the
    // same genre pool — pure catalog-exploration query with no mood/era
    // scoping at all, so it surfaces a genuinely different artist's
    // popular songs every rotation instead of only ever mining the same
    // 1-2 signal shapes for fresh candidates. This is what keeps a long,
    // many-extend session from exhausting one narrow slice of the
    // catalog — same idea real music apps use ("explore" alongside
    // "more like this").
    final exploreArtist = _pickSimilarArtist(currentSong, topArtists, rotation + 3);
    final q5 = AutoQueueQuery(
      '$exploreArtist hit songs',
      weight: 1,
    );

    return [q1, q2, q3, q4, q5];
  }

  /// Builds a mood-locked query combining mood + language + genre + era.
  /// This is what makes the queue feel like YouTube's mood-aware mix.
  /// [rotation] picks between a few equivalent phrasings of the same mood
  /// (see _moodSearchWord) so consecutive auto-queue extends for the same
  /// song don't fire the literal same query string at Saavn/YT every time
  /// — same intent, different words, so the search index returns a
  /// genuinely different slice of matching songs instead of the same
  /// top-N results minus whatever's already been queued.
  static String _moodLockedQuery(SessionMood mood, String lang, String genre, {String? era, int rotation = 0}) {
    final moodWord = _moodSearchWord(mood, rotation);
    final erapfx = (era != null && era.isNotEmpty) ? '$era ' : '';
    // For regional genres, use genre name directly — more precise Saavn results
    if (genre == 'bhojpuri') return '$erapfx$moodWord bhojpuri songs';
    if (genre == 'punjabi')  return '$erapfx$moodWord punjabi songs';
    if (genre == 'english')  return '$erapfx$moodWord english songs';
    if (genre == 'hiphop')   return '$erapfx$moodWord hindi rap songs';
    if (genre == 'devotional') return 'bhakti devotional songs';
    if (genre == 'lofi')     return 'lofi chill songs hindi';
    if (genre == 'tamil')    return '$erapfx$moodWord tamil songs';
    if (genre == 'telugu')   return '$erapfx$moodWord telugu songs';
    // Default bollywood
    return '$erapfx$moodWord bollywood hindi songs';
  }

  // Each mood maps to a small list of near-equivalent search phrasings —
  // real synonyms a human would also type, not random words — so rotating
  // through them still returns genuinely mood-matching songs, just from a
  // different angle of Saavn/YT's own search ranking each time.
  static String _moodSearchWord(SessionMood mood, [int rotation = 0]) {
    const variants = <SessionMood, List<String>>{
      SessionMood.romantic:   ['romantic love', 'love', 'romantic'],
      SessionMood.sad:        ['sad heartbreak dard', 'sad', 'emotional heartbreak'],
      SessionMood.party:      ['party dance', 'dance party', 'party'],
      SessionMood.workout:    ['energetic motivation', 'workout gym', 'motivation'],
      SessionMood.chill:      ['chill relax', 'relaxing', 'chill'],
      SessionMood.energetic:  ['energetic upbeat', 'upbeat', 'high energy'],
      SessionMood.devotional: ['bhakti devotional', 'devotional bhajan', 'bhakti'],
      SessionMood.neutral:    ['top hits', 'best songs', 'popular hits'],
    };
    final options = variants[mood] ?? const ['top hits'];
    return options[rotation.abs() % options.length];
  }

  static String _pickSimilarArtist(Song song, List<String> userTopArtists, [int rotation = 0]) {
    final genre = detectGenre(song);
    final pool  = _genreSimilarArtists[genre] ?? _genreSimilarArtists['bollywood']!;

    // Remove current artist
    final currentNorm = _normalizeKey(song.artist);
    final candidates = pool.where((a) => !_normalizeKey(a).contains(currentNorm) &&
                                         !currentNorm.contains(_normalizeKey(a))).toList();
    if (candidates.isEmpty) return pool.first;

    // Prefer artists the user has affinities for — but still rotate
    // THROUGH the matching preferred artists instead of always returning
    // the very first one, so a user with several high-affinity artists in
    // the same genre gets all of them explored across extends, not just
    // their single top pick every single time.
    final preferredMatches = <String>[];
    for (final preferred in userTopArtists) {
      final match = candidates.firstWhere(
        (a) => _normalizeKey(a) == _normalizeKey(preferred),
        orElse: () => '',
      );
      if (match.isNotEmpty) preferredMatches.add(match);
    }
    if (preferredMatches.isNotEmpty) {
      return preferredMatches[rotation.abs() % preferredMatches.length];
    }

    // FIX ("Up Next keeps circling back to the same songs"): this used to
    // be day-seeded (DateTime.now() based), which meant EVERY auto-queue
    // extend call for the entire day picked the exact same similar-artist
    // — so every single extend fired the same '$artist songs' query and
    // ran into the same shrinking, already-queued result set. Rotation is
    // now driven by the per-call counter passed in from generateQueries,
    // so each successive extend walks to the next artist in the pool —
    // still a stable, sensible sequence (not random noise), just no
    // longer frozen for 24 hours at a time.
    return candidates[rotation.abs() % candidates.length];
  }

  static String _moodQuery(Song song) {
    final mood = _detectMoodEnum(song);
    final lang = detectLanguage(song);
    return _sessionMoodQuery(mood, lang);
  }

  static String _sessionMoodQuery(SessionMood mood, String lang, {String? era, int rotation = 0}) {
    // Same fix as _moodSearchWord — a few real-phrasing variants per mood
    // instead of one static string, so this signal's query also rotates
    // across successive auto-queue extends rather than repeating verbatim.
    const variants = <SessionMood, List<String>>{
      SessionMood.romantic:   ['romantic love songs', 'love songs', 'romantic hits'],
      SessionMood.sad:        ['heartbreak sad songs', 'sad songs', 'emotional songs'],
      SessionMood.party:      ['party dance hits', 'dance hits', 'party songs'],
      SessionMood.devotional: ['bhakti devotional songs', 'devotional bhajan songs'],
      SessionMood.workout:    ['workout motivation energy songs', 'gym workout songs'],
      SessionMood.chill:      ['chill relax lofi songs', 'relaxing songs', 'chill songs'],
      SessionMood.energetic:  ['energetic upbeat hits', 'upbeat songs', 'high energy hits'],
      SessionMood.neutral:    ['top hits songs', 'best songs', 'popular songs'],
    };
    final options = variants[mood] ?? const ['top hits songs'];
    var base = options[rotation.abs() % options.length];
    if (era != null && era.isNotEmpty && mood != SessionMood.devotional) {
      base = '$era $base';
    }
    if (lang == 'hindi' || lang == 'punjabi') return '$base hindi';
    if (lang == 'english') return '$base english';
    return base;
  }

  /// Returns the decade bucket string used in queries, e.g. "90s", "2000s".
  /// Null if the song has no usable year metadata — in that case we must
  /// NOT era-scope, since we'd have nothing correct to scope to.
  static String? _songDecade(Song song) {
    final year = int.tryParse(song.year ?? '') ?? 0;
    if (year <= 0) return null;
    if (year < 2000) return '90s';
    if (year < 2010) return '2000s';
    if (year < 2020) return '2010s';
    // FIX: this was hardcoded to 'new 2024 2025' — two specific years that
    // silently go stale every single year (right now, mid-2026, it's
    // already excluding the current year's own new releases from its own
    // "new" query). A song released in 2026, 2027, etc. would keep getting
    // scoped to a search phrase for 2024/2025 releases specifically,
    // actively working against the freshness bonus scoreCandidate already
    // computes correctly from the real current date. Computing the actual
    // current year (and the year before, to keep some breadth) instead of
    // a frozen literal means this stays correct without needing a manual
    // yearly edit.
    final thisYear = DateTime.now().year;
    return 'new $thisYear ${thisYear - 1}';
  }

  static String _eraLanguageQuery(Song song) {
    final lang = detectLanguage(song);
    final era = _songDecade(song);
    if (era != null) return '$era $lang songs';
    return '$lang top hits';
  }

  // ---------------------------------------------------------------------------
  // SECTION 11: SIGNAL DETECTION (PUBLIC — used by ApiService)
  // ---------------------------------------------------------------------------

  // Word-boundary-safe "does this text mention this artist" check — plain
  // .contains() on short/common artist names (e.g. "sia", "kk singer",
  // "abba") could false-match inside unrelated words ("asia", "kkumar",
  // "abbas"). Splitting the haystack into whole words and comparing
  // against the artist's own word sequence avoids that, while still
  // matching multi-word artist names ("the weeknd") as a contiguous
  // sequence rather than requiring an exact single-token match.
  static bool _mentionsArtist(String haystackLower, String artistLower) {
    final artistWords = artistLower.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (artistWords.isEmpty) return false;
    final haystackWords = haystackLower.split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();
    if (artistWords.length == 1) return haystackWords.contains(artistWords.first);
    for (var i = 0; i + artistWords.length <= haystackWords.length; i++) {
      var matches = true;
      for (var j = 0; j < artistWords.length; j++) {
        if (haystackWords[i + j] != artistWords[j]) { matches = false; break; }
      }
      if (matches) return true;
    }
    return false;
  }

  static String detectGenre(Song song) {
    final text = '${song.title} ${song.artist} ${song.language ?? ""}'.toLowerCase();
    final langLow = (song.language ?? '').toLowerCase();
    final artistLow = song.artist.toLowerCase();

    // Bhojpuri — detect before bollywood fallback
    if (langLow.contains('bhojpuri') || text.contains('bhojpuri') ||
        text.contains('pawan singh') || text.contains('khesari') ||
        text.contains('neelkamal singh') || text.contains('shilpi raj') ||
        text.contains('pramod premi') || text.contains('arvind akela') ||
        text.contains('nirhua') || text.contains('dinesh lal') ||
        text.contains('samar singh') || text.contains('ritesh pandey') ||
        text.contains('ankush raja') || text.contains('gunjan singh') ||
        text.contains('amrapali dubey') || text.contains('akshara singh')) return 'bhojpuri';

    if (text.contains('punjabi') || text.contains('bhangra') ||
        text.contains('diljit') || text.contains('sidhu') ||
        langLow == 'punjabi') return 'punjabi';
    if (text.contains('rap') || text.contains('hip hop') || text.contains('hiphop') ||
        text.contains('trap') || text.contains('divine') || text.contains('emiway') ||
        text.contains('kr\$na') || text.contains('mc stan') || text.contains('seedhe')) return 'hiphop';
    if (text.contains('lofi') || text.contains('lo-fi') ||
        text.contains('chill') || text.contains('study') || text.contains('sleep')) return 'lofi';

    // FIX ("Hollywood song falls back to Bollywood genre"): the old check
    // only ever fired on an explicit language=='english' tag or the
    // literal phrase "english pop"/"pop hits" appearing in the title —
    // neither of which is true for the vast majority of real English
    // songs (Saavn/YT metadata routinely leaves `language` blank for
    // YouTube-sourced tracks, and a real title never contains the words
    // "english pop"). That silently sent almost every Hollywood song
    // through the bollywood fallback at the bottom, which is exactly why
    // Up Next for an English song could end up mood/genre-matching against
    // Bollywood queries instead. Now cross-checked against the full,
    // authoritative english artist pool (single source of truth shared
    // with the "similar artist" rotation) using word-boundary-safe
    // matching, so any artist in that god-level list is correctly
    // recognized regardless of what the language tag says.
    if (langLow == 'english' || text.contains('english pop') || text.contains('pop hits') ||
        (_genreSimilarArtists['english'] ?? const []).any((a) => _mentionsArtist(artistLow, a))) {
      return 'english';
    }

    if (text.contains('tamil') || langLow == 'tamil') return 'tamil';
    if (text.contains('telugu') || langLow == 'telugu') return 'telugu';
    if (text.contains('bhajan') || text.contains('aarti') || text.contains('mantra') ||
        text.contains('kirtan') || text.contains('chalisa')) return 'devotional';
    return 'bollywood';
  }

  static String detectLanguage(Song song) {
    final lang = (song.language ?? '').toLowerCase();
    if (lang.contains('bhojpuri')) return 'bhojpuri';
    if (lang.contains('punjabi'))  return 'punjabi';
    if (lang.contains('english'))  return 'english';
    if (lang.contains('tamil'))    return 'tamil';
    if (lang.contains('telugu'))   return 'telugu';
    if (lang.contains('bengali'))  return 'bengali';
    if (lang.contains('marathi'))  return 'marathi';
    if (lang.contains('gujarati')) return 'gujarati';
    if (lang.contains('malayalam')) return 'malayalam';
    // Artist-name fallback for bhojpuri (Saavn often tags these as 'hindi')
    final a = song.artist.toLowerCase();
    if (a.contains('pawan singh') || a.contains('khesari') || a.contains('neelkamal') ||
        a.contains('shilpi raj') || a.contains('pramod premi') || a.contains('nirhua') ||
        a.contains('samar singh') || a.contains('ritesh pandey') || a.contains('ankush raja') ||
        a.contains('gunjan singh') || a.contains('amrapali') || a.contains('akshara singh')) return 'bhojpuri';
    // FIX (same root cause as detectGenre): a missing/blank language tag
    // — very common for YouTube-sourced Hollywood tracks — used to fall
    // all the way through to a hardcoded 'hindi' default, meaning
    // Up Next's mood query for an English song could come out as "sad
    // heartbreak dard bollywood hindi songs" instead of an English mood
    // query, actively working against the song the user is actually
    // listening to. Cross-checking the artist against the same
    // authoritative english pool used by detectGenre/_pickSimilarArtist
    // closes that gap without needing a second hardcoded artist list.
    if ((_genreSimilarArtists['english'] ?? const []).any((art) => _mentionsArtist(a, art))) {
      return 'english';
    }
    return 'hindi';
  }

  static SessionMood _detectMoodEnum(Song song) {
    final text = '${song.title} ${song.artist}'.toLowerCase();
    if (text.contains('sad') || text.contains('dard') || text.contains('rona') ||
        text.contains('toot') || text.contains('yaad') || text.contains('judai') ||
        text.contains('bewafa') || text.contains('akela') || text.contains('alvida') ||
        text.contains('broken') || text.contains('heartbreak') || text.contains('bheegi') ||
        text.contains('aansu') || text.contains('tadap')) return SessionMood.sad;
    if (text.contains('pyar') || text.contains('love') || text.contains('ishq') ||
        text.contains('mohabbat') || text.contains('romantic') || text.contains('sajde') ||
        text.contains('teri') || text.contains('tere bina') || text.contains('humsafar') ||
        text.contains('sunn') || text.contains('kesariya') || text.contains('raataan') ||
        text.contains('dil') && !text.contains('dildaar')) return SessionMood.romantic;
    if (text.contains('party') || text.contains('dance') || text.contains('naach') ||
        text.contains('bajao') || text.contains('dj') || text.contains('balle') ||
        text.contains('garmi') || text.contains('hookah bar') || text.contains('lungi') ||
        // Bhojpuri party keywords
        text.contains('kamariya') || text.contains('lachke') || text.contains('hila') ||
        text.contains('nathuniya') || text.contains('saiya') && text.contains('dance') ||
        text.contains('tohar') || text.contains('ghaghra')) return SessionMood.party;
    if (text.contains('workout') || text.contains('gym') || text.contains('motivation') ||
        text.contains('power') || text.contains('beast') || text.contains('fire') ||
        text.contains('thunder')) return SessionMood.workout;
    if (text.contains('lofi') || text.contains('lo-fi') || text.contains('chill') ||
        text.contains('night') || text.contains('rain') || text.contains('coffee') ||
        text.contains('study') || text.contains('sleep')) return SessionMood.chill;
    if (text.contains('bhajan') || text.contains('aarti') || text.contains('mantra') ||
        text.contains('chalisa') || text.contains('kirtan')) return SessionMood.devotional;
    if (text.contains('energy') || text.contains('run') || text.contains('speed') ||
        text.contains('race') || text.contains('fighter')) return SessionMood.energetic;
    return SessionMood.neutral;
  }

  static SessionGenre _detectGenreEnum(Song song) {
    final g = detectGenre(song);
    switch (g) {
      case 'bollywood':  return SessionGenre.bollywood;
      case 'punjabi':    return SessionGenre.punjabi;
      case 'hiphop':     return SessionGenre.hiphop;
      case 'english':    return SessionGenre.english;
      case 'lofi':       return SessionGenre.lofi;
      case 'devotional': return SessionGenre.devotional;
      case 'bhojpuri':   return SessionGenre.bhojpuri;
      default:           return SessionGenre.other;
    }
  }

  static SessionLanguage _detectLanguageEnum(Song song) {
    final l = detectLanguage(song);
    switch (l) {
      case 'hindi':     return SessionLanguage.hindi;
      case 'punjabi':   return SessionLanguage.punjabi;
      case 'english':   return SessionLanguage.english;
      case 'tamil':     return SessionLanguage.tamil;
      case 'telugu':    return SessionLanguage.telugu;
      case 'bengali':   return SessionLanguage.bengali;
      case 'marathi':   return SessionLanguage.marathi;
      case 'gujarati':  return SessionLanguage.gujarati;
      case 'malayalam': return SessionLanguage.malayalam;
      default:          return SessionLanguage.other;
    }
  }

  // ---------------------------------------------------------------------------
  // SECTION 12: PUBLIC GETTERS FOR HOME/FEED INTELLIGENCE
  // ---------------------------------------------------------------------------

  /// Top artists by user affinity weight. Used for home feed personalization.
  static List<String> topAffinityArtists({int count = 5}) {
    if (!_loaded) return [];
    final sorted = _artistW.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.where((e) => e.value > 0.5).take(count).map((e) => e.key).toList();
  }

  /// Same ranking as [topAffinityArtists] but pulls `count` artists from a
  /// wider top-N pool (default 12) and shuffles with the given seed, instead
  /// of always returning the exact same top-`count` in the exact same order.
  ///
  /// WHY THIS EXISTS: pull-to-refresh on Home was feeding [topAffinityArtists]
  /// straight into the "Made for You · <artist>" section queries. Since that
  /// method deterministically returns the SAME top artists by weight every
  /// single call (weights only change from actual new listening activity),
  /// those sections — along with the equivalent genre sections — never
  /// varied between pulls. Only the unrelated filler pool at the bottom of
  /// the feed rotated, so most of the visible feed looked frozen/unchanged
  /// after a refresh even though a real network fetch (with a random seed)
  /// was happening underneath. This keeps personalization (still only real
  /// affinity artists, never a random stranger) while actually rotating
  /// which of the person's top artists get featured each pull.
  static List<String> rotatingAffinityArtists({int count = 4, int? seed}) {
    if (!_loaded) return [];
    final sorted = _artistW.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final pool = sorted.where((e) => e.value > 0.5).take(12).map((e) => e.key).toList();
    if (pool.length <= count) return pool;
    pool.shuffle(math.Random(seed));
    return pool.take(count).toList();
  }

  /// Top genres by user affinity. Used for home feed section ordering.
  static List<String> topAffinityGenres({int count = 3}) {
    if (!_loaded) return [];
    final sorted = _genreW.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.where((e) => e.value > 0.5).take(count).map((e) => e.key).toList();
  }

  /// Rotating counterpart to [topAffinityGenres] — see [rotatingAffinityArtists]
  /// for why this exists (same pull-to-refresh staleness fix).
  static List<String> rotatingAffinityGenres({int count = 3, int? seed}) {
    if (!_loaded) return [];
    final sorted = _genreW.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final pool = sorted.where((e) => e.value > 0.5).take(8).map((e) => e.key).toList();
    if (pool.length <= count) return pool;
    pool.shuffle(math.Random(seed));
    return pool.take(count).toList();
  }

  /// Top languages by user affinity. Used for home feed and query building.
  static List<String> topAffinityLanguages({int count = 2}) {
    if (!_loaded) return [];
    final sorted = _langW.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.where((e) => e.value > 0.5).take(count).map((e) => e.key).toList();
  }

  // ───────────────────────────────────────────────────────────────────────
  // Recommendation Intelligence System — home-section-facing getters.
  // All read-only, all O(n log n) at worst on maps that stay small (a few
  // hundred entries even for a heavy listener), so calling these on every
  // Home build is cheap — the actual network/recompute work they gate
  // still only happens in HomeScreen's existing cache/refresh logic.
  // ───────────────────────────────────────────────────────────────────────

  /// Song IDs ordered by raw play count, most-played first. Backs "Your
  /// Top Songs"-style logic and (combined with a title/artist lookup
  /// elsewhere) the "Most Played" facet of listening history.
  static List<String> topPlayedSongIds({int count = 20}) {
    if (!_loaded) return [];
    final sorted = _plays.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(count).map((e) => e.key).toList();
  }

  /// Album names (normalized keys) ordered by completed-play count,
  /// most-played first. Backs "Your Top Albums".
  static List<String> topAlbumsByPlays({int count = 10}) {
    if (!_loaded) return [];
    final sorted = _albumPlays.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.where((e) => e.value > 0).take(count).map((e) => e.key).toList();
  }

  /// Decades ("90s", "2000s", ...) by user affinity, strongest first.
  /// Backs "Favorite Decades" and decade-locked query generation for
  /// sections like "Because You Listened To 90s Bollywood".
  static List<String> topAffinityDecades({int count = 2}) {
    if (!_loaded) return [];
    final sorted = _decadeW.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.where((e) => e.value > 0.5).take(count).map((e) => e.key).toList();
  }

  /// Song IDs played within the last [within] (default 48h) but not
  /// necessarily completed — i.e. genuinely "in progress" listening,
  /// most-recent first. Backs "Continue Listening".
  static List<String> recentlyPlayedSongIds({
    int count = 15,
    Duration within = const Duration(hours: 48),
  }) {
    if (!_loaded) return [];
    final cutoff = DateTime.now().subtract(within).millisecondsSinceEpoch;
    final sorted = _lastPlayedAt.entries.where((e) => e.value >= cutoff).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(count).map((e) => e.key).toList();
  }

  /// Song IDs with real listening signal (played at least twice, or ever
  /// completed) that HAVEN'T been played in a long while (default 21
  /// days). Backs "Rediscover Favorites" — old favorites resurfaced,
  /// never a song with no real history behind it.
  static List<String> rediscoverCandidateIds({
    int count = 15,
    Duration olderThan = const Duration(days: 21),
  }) {
    if (!_loaded) return [];
    final cutoff = DateTime.now().subtract(olderThan).millisecondsSinceEpoch;
    final candidates = _plays.entries
        .where((e) => e.value >= 2 || (_completes[e.key] ?? 0) >= 1)
        .map((e) => e.key)
        .where((id) {
          final last = _lastPlayedAt[id];
          return last == null || last < cutoff;
        })
        .toList();
    // Rank by how much genuine listening signal each song has (plays +
    // 2x weight for completions), strongest favorites resurfaced first.
    candidates.sort((a, b) {
      final scoreA = (_plays[a] ?? 0) + 2 * (_completes[a] ?? 0);
      final scoreB = (_plays[b] ?? 0) + 2 * (_completes[b] ?? 0);
      return scoreB.compareTo(scoreA);
    });
    return candidates.take(count).toList();
  }

  /// Current session mood (for home feed "mood mix" section labeling).
  static SessionMood? get currentMood => _session?.mood;

  /// Current time slot.
  static TimeSlot currentTimeSlot() {
    final hour = DateTime.now().hour;
    if (hour >= 5  && hour < 11) return TimeSlot.morning;
    if (hour >= 11 && hour < 17) return TimeSlot.afternoon;
    if (hour >= 17 && hour < 21) return TimeSlot.evening;
    if (hour >= 21 && hour < 24) return TimeSlot.night;
    return TimeSlot.lateNight;
  }

  /// Song IDs shown on the home feed in the last [_homeShownWindow] refreshes'
  /// worth of songs. Passed into fetchHome() so a fresh pull-to-refresh
  /// actively avoids re-surfacing songs the user just saw a moment ago —
  /// this is what stops the "same few songs ghoom ghoom kar aate hain"
  /// (same handful of songs looping) complaint: search ranking alone always
  /// returns the same top hits for a given query, so without this a query
  /// like "arijit singh best songs" would show an identical top-60 on every
  /// single refresh forever.
  static Set<String> get recentHomeShownIds => _homeShown.toSet();

  // How many of the most-recently-shown song IDs to actively avoid
  // repeating. Wide enough to cover several refreshes' worth of a typical
  // ~8-section, 60-80-song-per-section home feed without permanently
  // blacklisting a song (it ages back out of the window eventually), but
  // not so wide that a small catalog runs out of "fresh" songs to show.
  static const int _homeShownWindow = 2400;

  /// Records that these song IDs were just shown on the home feed, ready to
  /// be excluded from the next refresh's dedup pass. Call once per
  /// successful fetchHome() with every song id across all sections.
  static Future<void> recordHomeShown(Iterable<String> ids) async {
    if (!_loaded) await load();
    _homeShown.addAll(ids);
    // Keep only the most recent window — oldest entries fall off first,
    // so a song only stays "avoided" for a while, not forever.
    if (_homeShown.length > _homeShownWindow) {
      _homeShown = _homeShown.sublist(_homeShown.length - _homeShownWindow);
    }
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kHomeShown, _homeShown);
  }

  /// Song IDs the user has played often (3+ times). Used by the home feed
  /// to gently deprioritize songs they've already heard a lot in favor of
  /// fresher picks — same idea as [sessionRecentIds] but based on lifetime
  /// play count rather than just the current session, so a song you loved
  /// last month doesn't keep hogging the top slot of every "Made for You"
  /// mix forever.
  static Set<String> get heavilyPlayedIds {
    if (!_loaded) return {};
    return _plays.entries.where((e) => e.value >= 3).map((e) => e.key).toSet();
  }

  /// IDs in the current session recent window. Used for queue dedup.
  static Set<String> get sessionRecentIds =>
      _session?.recentIds.toSet() ?? {};

  /// Normalized titles in the current session's long-window memory (up to
  /// 200) — used alongside [sessionRecentIds] so a reupload with a fresh
  /// ID still gets caught once its title has already been played earlier
  /// in a long/endless session, well after the 20-slot ID window forgot it.
  static Set<String> get sessionRecentTitles =>
      _session?.recentTitles.toSet() ?? {};

  /// Artists in current session (for anti-repeat). Returns up to 5.
  static List<String> get sessionRecentArtists =>
      _session?.recentArtists ?? [];

  // ---------------------------------------------------------------------------
  // SECTION 13: GENRE ARTIST POOLS
  // ---------------------------------------------------------------------------
  static const Map<String, List<String>> _genreSimilarArtists = {
    // BOLLYWOOD — "god level" pool: current playback-singers, legendary
    // playback singers, composers/music-directors, and current chart-
    // topping male/female voices, so _pickSimilarArtist's rotation has a
    // genuinely deep, era-spanning bench to draw from instead of cycling
    // through the same dozen names every few extends.
    'bollywood': [
      // Current-gen leading male voices
      'arijit singh', 'atif aslam', 'armaan malik', 'jubin nautiyal',
      'sonu nigam', 'shaan', 'kk singer', 'mohit chauhan', 'vishal mishra',
      'darshan raval', 'stebin ben', 'yasser desai', 'ankit tiwari',
      'amaal mallik', 'javed ali', 'rahat fateh ali khan',
      // Current-gen leading female voices
      'shreya ghoshal', 'neha kakkar', 'sunidhi chauhan', 'monali thakur',
      'palak muchhal', 'asees kaur', 'dhvani bhanushali', 'neeti mohan',
      'shilpa rao', 'jonita gandhi', 'kanika kapoor', 'akasa singh',
      'shashaa tirupati', 'nikhita gandhi',
      // Legendary playback singers (golden/silver era — still core to any
      // "bollywood similar artist" query for older/classic songs)
      'lata mangeshkar', 'kishore kumar', 'mohd rafi', 'asha bhosle',
      'udit narayan', 'kumar sanu', 'alka yagnik', 'mukesh',
      'manna dey', 'hemant kumar', 'geeta dutt', 'mahendra kapoor',
      // Composers / music directors (their name alone is a strong,
      // distinct "similar songs" search anchor — Pritam's or A.R.
      // Rahman's discography sounds nothing alike, which is exactly the
      // artist-diversity rotation needs)
      'a r rahman', 'pritam', 'vishal shekhar', 'shankar ehsaan loy',
      'anu malik', 'nadeem shravan', 'himesh reshammiya', 'amit trivedi',
      'sachin jigar', 'tanishk bagchi', 'vishal bhardwaj', 'ram sampath',
      'rd burman', 'laxmikant pyarelal',
    ],
    // HOLLYWOOD / ENGLISH — "god level" pool: current pop chart-toppers,
    // legendary/classic acts, and major bands/groups across pop, rock, and
    // R&B, so the rotation has real range instead of only ~15 of the same
    // 2020s pop names.
    'english': [
      // Current pop / chart-topping solo acts
      'the weeknd', 'ed sheeran', 'bruno mars', 'charlie puth',
      'post malone', 'dua lipa', 'taylor swift', 'ariana grande',
      'billie eilish', 'olivia rodrigo', 'shawn mendes', 'harry styles',
      'sam smith', 'adele', 'justin bieber', 'selena gomez',
      'rihanna', 'beyonce', 'lady gaga', 'katy perry', 'miley cyrus',
      'sia', 'khalid', 'zayn', 'niall horan', 'camila cabello',
      'doja cat', 'sza', 'the kid laroi', 'lewis capaldi',
      // Bands / groups
      'coldplay', 'imagine dragons', 'onerepublic', 'maroon 5',
      'the chainsmokers', 'twenty one pilots', 'panic at the disco',
      'fall out boy', 'linkin park', 'the killers',
      // Legends / classic acts (still a strong, distinct search anchor
      // for "similar english songs" regardless of era)
      'michael jackson', 'whitney houston', 'eminem', 'queen',
      'the beatles', 'elton john', 'celine dion', 'mariah carey',
      'george michael', 'phil collins', 'stevie wonder', 'abba',
    ],
    'punjabi': [
      'diljit dosanjh', 'ap dhillon', 'sidhu moosewala', 'guru randhawa',
      'badshah', 'hardy sandhu', 'b praak', 'jasleen royal',
      'parmish verma', 'ammy virk', 'karan aujla', 'shubh',
    ],
    'hiphop': [
      'divine', 'emiway bantai', 'kr\$na', 'mc stan', 'seedhe maut',
      'yo yo honey singh', 'badshah', 'raftar', 'naezy', 'ranveer',
    ],
    'lofi': [
      'lofi hip hop', 'chillhop music', 'lo-fi beats', 'study music',
      'calm music', 'sleep music', 'coffee shop music',
    ],
    'bhojpuri': [
      'pawan singh', 'khesari lal yadav', 'neelkamal singh', 'shilpi raj',
      'pramod premi yadav', 'ritesh pandey', 'samar singh', 'gunjan singh',
      'ankush raja', 'dinesh lal nirhua', 'arvind akela kallu',
      'awadhesh premi yadav', 'manoj tiwari', 'indu sonali',
    ],
    'devotional': [
      'lata mangeshkar bhajan', 'anuradha paudwal', 'narendra chanchal',
      'jagjit singh', 'gulshan kumar bhajan', 'shankar mahadevan bhajan',
    ],
    'tamil': [
      'ar rahman tamil', 'sid sriram', 'anirudh ravichander',
      'yuvan shankar raja', 'harris jayaraj', 'd imman',
    ],
    'telugu': [
      'dsp telugu', 'thaman s', 'ss thaman', 'mickey j meyer', 'anirudh telugu',
    ],
  };

  // ---------------------------------------------------------------------------
  // SECTION 14: PERIODIC DECAY
  //
  // Apply gentle decay to affinity weights so old listening habits
  // don't permanently dominate. Call once per day on app start.
  // ---------------------------------------------------------------------------

  static Future<void> applyDecay() async {
    if (!_loaded) await load();
    _artistW.updateAll((_, v) => (v * _decayFactor).clamp(0.0, 1.0));
    _genreW.updateAll((_, v)  => (v * _decayFactor).clamp(0.0, 1.0));
    _langW.updateAll((_, v)   => (v * _decayFactor).clamp(0.0, 1.0));
    await _saveAll();
  }

  // ---------------------------------------------------------------------------
  // SECTION 15: PERSISTENCE
  // ---------------------------------------------------------------------------

  static Future<void> _saveAll() async {
    // See _pruneTrackedSongs() doc comment above — keeps the song-keyed
    // maps below bounded before every encode+write, rather than letting
    // them grow forever across the life of the app install.
    _pruneTrackedSongs();
    final p = await SharedPreferences.getInstance();
    await Future.wait([
      p.setString(_kPlays,     jsonEncode(_plays)),
      p.setString(_kCompletes, jsonEncode(_completes)),
      p.setString(_kSkips,     jsonEncode(_skips)),
      p.setString(_kReplays,   jsonEncode(_replays)),
      p.setString(_kArtistW,   jsonEncode(_artistW)),
      p.setString(_kGenreW,    jsonEncode(_genreW)),
      p.setString(_kLangW,     jsonEncode(_langW)),
      p.setString(_kAlbumPlays, jsonEncode(_albumPlays)),
      p.setString(_kDecadeW,    jsonEncode(_decadeW)),
      p.setString(_kLastPlayed, jsonEncode(_lastPlayedAt)),
      if (_session != null)
        p.setString(_kSession, jsonEncode(_session!.toJson())),
    ]);
  }

  // ---------------------------------------------------------------------------
  // SECTION 16: UTILITIES
  // ---------------------------------------------------------------------------
  static String _normalizeKey(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').trim();
}

// =============================================================================
// INTERNAL VALUE OBJECTS
// =============================================================================

class _ScoredSong {
  final Song   song;
  final double score;
  _ScoredSong(this.song, this.score);
}

// Public — used by ApiService.getAutoQueue() to iterate queries
class AutoQueueQuery {
  final String query;
  final int    weight;
  AutoQueueQuery(this.query, {this.weight = 1});
}
