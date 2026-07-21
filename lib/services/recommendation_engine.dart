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
  final DateTime startedAt;

  _SessionState({
    required this.mood,
    required this.genre,
    required this.language,
    required this.recentArtists,
    required this.recentIds,
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
        startedAt: DateTime.tryParse(j['startedAt'] ?? '') ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'mood': mood.name,
        'genre': genre.name,
        'language': language.name,
        'recentArtists': recentArtists,
        'recentIds': recentIds,
        'startedAt': startedAt.toIso8601String(),
      };

  _SessionState copyWith({
    SessionMood? mood,
    SessionGenre? genre,
    SessionLanguage? language,
    List<String>? recentArtists,
    List<String>? recentIds,
  }) =>
      _SessionState(
        mood: mood ?? this.mood,
        genre: genre ?? this.genre,
        language: language ?? this.language,
        recentArtists: recentArtists ?? this.recentArtists,
        recentIds: recentIds ?? this.recentIds,
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

  // Decay factor applied to affinity weights over time.
  // Prevents old listening habits from dominating new ones.
  static const double _decayFactor = 0.92;

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

    _session = _session!.copyWith(
      mood: updatedMood,
      genre: updatedGenre,
      language: updatedLang,
      recentArtists: artists,
      recentIds: ids,
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

  static SessionGenre _blendGenre(SessionGenre current, SessionGenre incoming) =>
      current == SessionGenre.other ? incoming : current;

  static SessionLanguage _blendLanguage(SessionLanguage current, SessionLanguage incoming) =>
      current == incoming ? current : current; // Keep primary language for session

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
  //   Session genre match : 0.10  (current listening session)
  //   Completion rate     : 0.08  (did user finish this before?)
  //   Replay bonus        : 0.05  (did user replay this before?)
  //   Skip penalty        : -0.20 (hard penalty for early-skipped songs)
  //   Time slot fit       : 0.02  (minor: morning/evening/etc.)
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

    return score.clamp(0.0, 1.0);
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
    return false;
  }

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
    r'lounge mix|jukebox|full song|lyric video|lyrics|'
    r'official video|music video|audio|video song|full video|'
    r'version|recreate|extended|edit|flip|bootleg|'
    r'vibe|mood|chill mix|punjabi mix|hindi mix|tapori|dj |club mix|'
    r'old is gold|the return|revisited|throwback mix|new version|'
    r'\d\.\d)\b',
    caseSensitive: false,
  );

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

    final scored = <_ScoredSong>[];

    for (final song in pool) {
      // ID dedup
      if (seenIds.contains(song.id)) continue;

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
    bool underCap(Song s) {
      final key = _normalizeKey(s.artist);
      final n = artistCounts[key] ?? 0;
      if (n >= maxPerArtist) return false;
      artistCounts[key] = n + 1;
      return true;
    }

    result.addAll(core.where(underCap).take(coreCount));
    result.addAll(related.where(underCap).take(relatedCount));
    result.addAll(discovery.where(underCap).take(discoveryCount));

    // If the cap left us short of `limit` (small pool, few artists),
    // backfill from whatever's left over, ignoring the cap, rather than
    // returning a short queue.
    if (result.length < limit) {
      final used = result.map((s) => s.id).toSet();
      for (final s in [...core, ...related, ...discovery]) {
        if (result.length >= limit) break;
        if (used.contains(s.id)) continue;
        result.add(s);
        used.add(s.id);
      }
    }

    // Shuffle slightly within each tier to avoid same-order repetition
    _shuffleTier(result, 0, math.min(coreCount, result.length));

    return result.take(limit).toList();
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

    if (!_loaded) {
      return [
        AutoQueueQuery('${currentSong.artist} songs', weight: 2),
        AutoQueueQuery(_moodLockedQuery(activeMood, lang, genre, era: decadeTok), weight: 2),
        AutoQueueQuery(_sessionMoodQuery(activeMood, lang, era: decadeTok), weight: 1),
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
    // Different artists, same vibe, same decade
    final q2 = AutoQueueQuery(
      _moodLockedQuery(activeMood, lang, genre, era: decadeTok),
      weight: 2,
    );

    // Signal 3: Similar artist from genre pool (artist diversity)
    final similarArtist = _pickSimilarArtist(currentSong, topArtists);
    final q3 = AutoQueueQuery(
      '$similarArtist songs',
      weight: 1,
    );

    // Signal 4: Pure era+mood query — broadest net, catches era-matching songs
    // across artists the user hasn't explicitly listened to
    final q4 = AutoQueueQuery(
      decadeTok != null ? era : _sessionMoodQuery(activeMood, lang),
      weight: 2,
    );

    return [q1, q2, q3, q4];
  }

  /// Builds a mood-locked query combining mood + language + genre + era.
  /// This is what makes the queue feel like YouTube's mood-aware mix.
  static String _moodLockedQuery(SessionMood mood, String lang, String genre, {String? era}) {
    final moodWord = _moodSearchWord(mood);
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

  static String _moodSearchWord(SessionMood mood) {
    switch (mood) {
      case SessionMood.romantic:   return 'romantic love';
      case SessionMood.sad:        return 'sad heartbreak dard';
      case SessionMood.party:      return 'party dance';
      case SessionMood.workout:    return 'energetic motivation';
      case SessionMood.chill:      return 'chill relax';
      case SessionMood.energetic:  return 'energetic upbeat';
      case SessionMood.devotional: return 'bhakti devotional';
      case SessionMood.neutral:    return 'top hits';
    }
  }

  static String _pickSimilarArtist(Song song, List<String> userTopArtists) {
    final genre = detectGenre(song);
    final pool  = _genreSimilarArtists[genre] ?? _genreSimilarArtists['bollywood']!;

    // Remove current artist
    final currentNorm = _normalizeKey(song.artist);
    final candidates = pool.where((a) => !_normalizeKey(a).contains(currentNorm) &&
                                         !currentNorm.contains(_normalizeKey(a))).toList();

    // Prefer artists the user has affinities for
    for (final preferred in userTopArtists) {
      final match = candidates.firstWhere(
        (a) => _normalizeKey(a) == _normalizeKey(preferred),
        orElse: () => '',
      );
      if (match.isNotEmpty) return match;
    }

    // Fall back to day-seeded rotation
    if (candidates.isEmpty) return pool.first;
    final dayIdx = DateTime.now().difference(DateTime(2026, 1, 1)).inDays;
    return candidates[dayIdx % candidates.length];
  }

  static String _moodQuery(Song song) {
    final mood = _detectMoodEnum(song);
    final lang = detectLanguage(song);
    return _sessionMoodQuery(mood, lang);
  }

  static String _sessionMoodQuery(SessionMood mood, String lang, {String? era}) {
    const queries = {
      SessionMood.romantic:   'romantic love songs',
      SessionMood.sad:        'heartbreak sad songs',
      SessionMood.party:      'party dance hits',
      SessionMood.devotional: 'bhakti devotional songs',
      SessionMood.workout:    'workout motivation energy songs',
      SessionMood.chill:      'chill relax lofi songs',
      SessionMood.energetic:  'energetic upbeat hits',
      SessionMood.neutral:    'top hits songs',
    };
    var base = queries[mood] ?? 'top hits songs';
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
    return 'new 2024 2025';
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

  static String detectGenre(Song song) {
    final text = '${song.title} ${song.artist} ${song.language ?? ""}'.toLowerCase();
    final langLow = (song.language ?? '').toLowerCase();

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
        (song.language ?? '').toLowerCase() == 'punjabi') return 'punjabi';
    if (text.contains('rap') || text.contains('hip hop') || text.contains('hiphop') ||
        text.contains('trap') || text.contains('divine') || text.contains('emiway') ||
        text.contains('kr\$na') || text.contains('mc stan') || text.contains('seedhe')) return 'hiphop';
    if (text.contains('lofi') || text.contains('lo-fi') ||
        text.contains('chill') || text.contains('study') || text.contains('sleep')) return 'lofi';
    if ((song.language ?? '').toLowerCase() == 'english' ||
        text.contains('english pop') || text.contains('pop hits')) return 'english';
    if (text.contains('tamil') || (song.language ?? '').toLowerCase() == 'tamil') return 'tamil';
    if (text.contains('telugu') || (song.language ?? '').toLowerCase() == 'telugu') return 'telugu';
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

  /// Artists in current session (for anti-repeat). Returns up to 5.
  static List<String> get sessionRecentArtists =>
      _session?.recentArtists ?? [];

  // ---------------------------------------------------------------------------
  // SECTION 13: GENRE ARTIST POOLS
  // ---------------------------------------------------------------------------
  static const Map<String, List<String>> _genreSimilarArtists = {
    'bollywood': [
      'arijit singh', 'atif aslam', 'armaan malik', 'jubin nautiyal',
      'shreya ghoshal', 'neha kakkar', 'sonu nigam', 'kumar sanu',
      'udit narayan', 'lata mangeshkar', 'kishore kumar', 'mohd rafi',
      'a r rahman', 'pritam', 'vishal shekhar', 'shankar ehsaan loy',
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
    'english': [
      'the weeknd', 'ed sheeran', 'bruno mars', 'charlie puth',
      'post malone', 'dua lipa', 'taylor swift', 'ariana grande',
      'billie eilish', 'olivia rodrigo', 'shawn mendes', 'harry styles',
      'sam smith', 'adele', 'cold play', 'imagine dragons',
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
    final p = await SharedPreferences.getInstance();
    await Future.wait([
      p.setString(_kPlays,     jsonEncode(_plays)),
      p.setString(_kCompletes, jsonEncode(_completes)),
      p.setString(_kSkips,     jsonEncode(_skips)),
      p.setString(_kReplays,   jsonEncode(_replays)),
      p.setString(_kArtistW,   jsonEncode(_artistW)),
      p.setString(_kGenreW,    jsonEncode(_genreW)),
      p.setString(_kLangW,     jsonEncode(_langW)),
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
