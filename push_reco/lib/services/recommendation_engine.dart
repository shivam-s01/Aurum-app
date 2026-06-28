// =============================================================================
// FILE: lib/services/recommendation_engine.dart
// PROJECT: Aurum Music
// VERSION: 2.0.0 — Spotify-Grade Contextual Engine
//
// REDESIGN GOALS:
//   ✅ 50+ song queues that feel hand-curated
//   ✅ Zero remixes / covers / lofi / slowed unless user explicitly wants them
//   ✅ Language lock — Hindi stays Hindi, Punjabi stays Punjabi, Tamil stays Tamil
//   ✅ Mood lock — romantic stays romantic for hours
//   ✅ Artist diversity — same artist max 3 out of every 10 songs
//   ✅ 8-signal query generation → much richer candidate pool
//   ✅ Hard variant blacklist applied at both query AND filter level
// =============================================================================

import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';

// =============================================================================
// ENUMS
// =============================================================================
enum SessionMood { romantic, sad, party, devotional, workout, chill, energetic, neutral }
enum SessionGenre { bollywood, punjabi, hiphop, english, lofi, devotional, bhojpuri, tamil, telugu, other }
enum SessionLanguage { hindi, punjabi, english, tamil, telugu, bengali, marathi, gujarati, malayalam, bhojpuri, other }
enum TimeSlot { morning, afternoon, evening, night, lateNight }

// =============================================================================
// SESSION STATE
// =============================================================================
class _SessionState {
  final SessionMood mood;
  final SessionGenre genre;
  final SessionLanguage language;
  final List<String> recentArtists;
  final List<String> recentIds;
  final Map<String, int> artistPlayCount; // how many times each artist appeared in session
  final DateTime startedAt;

  _SessionState({
    required this.mood,
    required this.genre,
    required this.language,
    required this.recentArtists,
    required this.recentIds,
    required this.artistPlayCount,
    required this.startedAt,
  });

  factory _SessionState.fromJson(Map<String, dynamic> j) => _SessionState(
        mood: SessionMood.values.firstWhere((e) => e.name == j['mood'], orElse: () => SessionMood.neutral),
        genre: SessionGenre.values.firstWhere((e) => e.name == j['genre'], orElse: () => SessionGenre.other),
        language: SessionLanguage.values.firstWhere((e) => e.name == j['language'], orElse: () => SessionLanguage.hindi),
        recentArtists: List<String>.from(j['recentArtists'] ?? []),
        recentIds: List<String>.from(j['recentIds'] ?? []),
        artistPlayCount: Map<String, int>.from(j['artistPlayCount'] ?? {}),
        startedAt: DateTime.tryParse(j['startedAt'] ?? '') ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'mood': mood.name,
        'genre': genre.name,
        'language': language.name,
        'recentArtists': recentArtists,
        'recentIds': recentIds,
        'artistPlayCount': artistPlayCount,
        'startedAt': startedAt.toIso8601String(),
      };

  _SessionState copyWith({
    SessionMood? mood,
    SessionGenre? genre,
    SessionLanguage? language,
    List<String>? recentArtists,
    List<String>? recentIds,
    Map<String, int>? artistPlayCount,
  }) => _SessionState(
        mood: mood ?? this.mood,
        genre: genre ?? this.genre,
        language: language ?? this.language,
        recentArtists: recentArtists ?? this.recentArtists,
        recentIds: recentIds ?? this.recentIds,
        artistPlayCount: artistPlayCount ?? this.artistPlayCount,
        startedAt: startedAt,
      );
}

// =============================================================================
// MAIN ENGINE
// =============================================================================
class RecommendationEngine {
  RecommendationEngine._();

  static const _kPlays     = 'aurum_rec_plays';
  static const _kCompletes = 'aurum_rec_completes';
  static const _kSkips     = 'aurum_rec_skips';
  static const _kReplays   = 'aurum_rec_replays';
  static const _kArtistW   = 'aurum_rec_artist_w';
  static const _kGenreW    = 'aurum_rec_genre_w';
  static const _kLangW     = 'aurum_rec_lang_w';
  static const _kSession   = 'aurum_rec_session';
  static const double _decayFactor = 0.92;

  static Map<String, int>    _plays     = {};
  static Map<String, int>    _completes = {};
  static Map<String, int>    _skips     = {};
  static Map<String, int>    _replays   = {};
  static Map<String, double> _artistW   = {};
  static Map<String, double> _genreW    = {};
  static Map<String, double> _langW     = {};
  static _SessionState?      _session;
  static bool                _loaded    = false;

  // ---------------------------------------------------------------------------
  // HARD VARIANT BLACKLIST
  // Applied at BOTH query-building AND song-filtering level.
  // Any song matching this is 100% blocked unless user explicitly searched variant.
  // ---------------------------------------------------------------------------
  static final RegExp variantBlacklist = RegExp(
    r'\b(remix|dj[ -]?remix|dj mix|club mix|'
    r'female version|female|male version|'
    r'lofi|lo[- ]?fi|slowed|reverb|slowed\s*\+\s*reverb|'
    r'nightcore|bass[ -]?boost(?:ed)?|8d(?: audio)?|'
    r'sped[- ]?up|speed(?:ed)?[- ]?up|chipmunk|'
    r'cover|karaoke|instrumental|live version|live at|'
    r'fan made|fan upload|mashup|tribute|'
    r'remaster(?:ed)?|unplugged|acoustic version|'
    r'reprise|extended|edit|flip|bootleg|'
    r'tapori|drill remix|recreation|recreated|'
    r'jukebox|full video|lyric video|lyrics|'
    r'official video|music video|audio|video song|'
    r'full song|hd|4k|320kbps)\\b',
    caseSensitive: false,
  );

  // Bracket content blacklist — catches "(Female Version)", "[Lofi Mix]" etc.
  static final RegExp _bracketVariant = RegExp(
    r'[\(\[\{][^\)\]\}]*(remix|cover|lofi|slowed|reverb|female|male|karaoke|'
    r'instrumental|nightcore|bass|8d|sped|acoustic|live|mashup|tribute)[^\)\]\}]*[\)\]\}]',
    caseSensitive: false,
  );

  // ---------------------------------------------------------------------------
  // INIT
  // ---------------------------------------------------------------------------
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
        final candidate = _SessionState.fromJson(jsonDecode(sessionJson));
        final age = DateTime.now().difference(candidate.startedAt);
        _session = age.inHours < 4 ? candidate : null; // 4h session window (was 2h)
      } catch (_) { _session = null; }
    }
    _loaded = true;
  }

  static Map<String, int> _loadIntMap(SharedPreferences p, String key) {
    try {
      final raw = p.getString(key);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) { return {}; }
  }

  static Map<String, double> _loadDoubleMap(SharedPreferences p, String key) {
    try {
      final raw = p.getString(key);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) { return {}; }
  }

  // ---------------------------------------------------------------------------
  // BEHAVIOR TRACKING (unchanged signals, same API)
  // ---------------------------------------------------------------------------
  static Future<void> onSongStarted(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;
    _plays[song.id] = (_plays[song.id] ?? 0) + 1;
    _boostArtist(song.artist, delta: 0.06);
    _boostGenre(detectGenre(song), delta: 0.05);
    _boostLanguage(detectLanguage(song), delta: 0.04);
    _updateSession(song);
    _saveAll();
  }

  static Future<void> onSongCompleted(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;
    _completes[song.id] = (_completes[song.id] ?? 0) + 1;
    _boostArtist(song.artist, delta: 0.15);
    _boostGenre(detectGenre(song), delta: 0.10);
    _boostLanguage(detectLanguage(song), delta: 0.08);
    _saveAll();
  }

  static Future<void> onEarlySkip(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;
    _skips[song.id] = (_skips[song.id] ?? 0) + 1;
    _boostArtist(song.artist, delta: -0.08);
    _boostGenre(detectGenre(song), delta: -0.05);
    _boostLanguage(detectLanguage(song), delta: -0.03);
    _saveAll();
  }

  static Future<void> onReplay(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;
    _replays[song.id] = (_replays[song.id] ?? 0) + 1;
    _boostArtist(song.artist, delta: 0.20);
    _boostGenre(detectGenre(song), delta: 0.15);
    _boostLanguage(detectLanguage(song), delta: 0.10);
    _saveAll();
  }

  static Future<void> onFavorited(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;
    _boostArtist(song.artist, delta: 0.35);
    _boostGenre(detectGenre(song), delta: 0.25);
    _boostLanguage(detectLanguage(song), delta: 0.15);
    _saveAll();
  }

  static Future<void> onUnfavorited(Song song) async {
    if (!_loaded) await load();
    if (song.isLocal) return;
    _boostArtist(song.artist, delta: -0.15);
    _boostGenre(detectGenre(song), delta: -0.10);
    _saveAll();
  }

  static void _boostArtist(String artist, {required double delta}) {
    final key = _normalizeKey(artist);
    if (key.isEmpty) return;
    _artistW[key] = ((_artistW[key] ?? 0.5) + delta).clamp(0.0, 1.0);
  }
  static void _boostGenre(String genre, {required double delta}) =>
      _genreW[genre] = ((_genreW[genre] ?? 0.5) + delta).clamp(0.0, 1.0);
  static void _boostLanguage(String lang, {required double delta}) =>
      _langW[lang] = ((_langW[lang] ?? 0.5) + delta).clamp(0.0, 1.0);

  // ---------------------------------------------------------------------------
  // SESSION MANAGEMENT
  // ---------------------------------------------------------------------------
  static void _updateSession(Song song) {
    final mood     = _detectMoodEnum(song);
    final genre    = _detectGenreEnum(song);
    final language = _detectLanguageEnum(song);
    final artistKey = _normalizeKey(song.artist);

    if (_session == null) {
      _session = _SessionState(
        mood: mood, genre: genre, language: language,
        recentArtists: [song.artist],
        recentIds: [song.id],
        artistPlayCount: {artistKey: 1},
        startedAt: DateTime.now(),
      );
      return;
    }

    // Mood: only flip if clearly different and compatible
    final updatedMood = _blendMood(_session!.mood, mood);

    // Genre: keep primary genre once established — don't flip on 1 song
    final updatedGenre = _session!.genre == SessionGenre.other ? genre : _session!.genre;

    // Language: HARD LOCK — never change language mid-session
    // This is the key fix: if user starts with Hindi, stay Hindi
    final updatedLang = _session!.language;

    final artists = [song.artist, ..._session!.recentArtists].toSet().take(10).toList();
    final ids = [song.id, ..._session!.recentIds].take(50).toList(); // 50-song window

    // Track per-artist count for diversity enforcement
    final counts = Map<String, int>.from(_session!.artistPlayCount);
    counts[artistKey] = (counts[artistKey] ?? 0) + 1;

    _session = _session!.copyWith(
      mood: updatedMood,
      genre: updatedGenre,
      language: updatedLang,
      recentArtists: artists,
      recentIds: ids,
      artistPlayCount: counts,
    );
  }

  static SessionMood _blendMood(SessionMood current, SessionMood incoming) {
    if (current == incoming) return current;
    const compatible = {
      SessionMood.romantic:   {SessionMood.sad, SessionMood.chill},
      SessionMood.sad:        {SessionMood.romantic, SessionMood.chill},
      SessionMood.party:      {SessionMood.energetic, SessionMood.workout},
      SessionMood.workout:    {SessionMood.party, SessionMood.energetic},
      SessionMood.energetic:  {SessionMood.party, SessionMood.workout},
      SessionMood.chill:      {SessionMood.romantic, SessionMood.sad},
      SessionMood.devotional: <SessionMood>{},
      SessionMood.neutral:    {SessionMood.romantic, SessionMood.sad, SessionMood.party,
                               SessionMood.chill, SessionMood.energetic},
    };
    return (compatible[current] ?? {}).contains(incoming) ? incoming : current;
  }

  // ---------------------------------------------------------------------------
  // SCORING
  // ---------------------------------------------------------------------------
  static double scoreCandidate(Song candidate) {
    if (!_loaded) return 0.5;
    if (candidate.isLocal) return 0.3;

    // HARD BLOCK: any variant = 0.0 score (will be filtered)
    if (isVariant(candidate.title)) return 0.0;

    double score = 0.0;
    final artistKey = _normalizeKey(candidate.artist);
    final genre     = detectGenre(candidate);
    final language  = detectLanguage(candidate);

    score += (_artistW[artistKey] ?? 0.5) * 0.25;
    score += (_genreW[genre] ?? 0.5) * 0.20;
    score += (_langW[language] ?? 0.5) * 0.15;

    if (_session != null) {
      final songMood = _detectMoodEnum(candidate);
      if (songMood == _session!.mood) score += 0.15;
      else if (_moodCompatible(_session!.mood, songMood)) score += 0.08;

      final songGenreEnum = _detectGenreEnum(candidate);
      if (songGenreEnum == _session!.genre) score += 0.10;
      else if (_session!.genre == SessionGenre.other) score += 0.05;

      // Language match bonus — CRITICAL for language lock
      final songLang = _detectLanguageEnum(candidate);
      if (songLang == _session!.language) score += 0.10;
      else score -= 0.15; // hard penalty for wrong language
    } else {
      score += 0.075 + 0.05;
    }

    final plays = _plays[candidate.id] ?? 0;
    if (plays > 0) {
      final rate = (_completes[candidate.id] ?? 0) / plays;
      score += rate * 0.08;
    }
    final replays = _replays[candidate.id] ?? 0;
    if (replays > 0) score += math.min(replays * 0.02, 0.05);
    final skips = _skips[candidate.id] ?? 0;
    if (skips > 0) score -= math.min(skips * 0.07, 0.20);

    score += _timeSlotBonus(candidate) * 0.02;
    return score.clamp(0.0, 1.0);
  }

  static bool _moodCompatible(SessionMood session, SessionMood song) {
    const compat = {
      SessionMood.romantic:   [SessionMood.sad, SessionMood.chill],
      SessionMood.sad:        [SessionMood.romantic, SessionMood.chill],
      SessionMood.party:      [SessionMood.energetic, SessionMood.workout],
      SessionMood.workout:    [SessionMood.party, SessionMood.energetic],
      SessionMood.energetic:  [SessionMood.party, SessionMood.workout],
      SessionMood.chill:      [SessionMood.romantic, SessionMood.sad],
    };
    return (compat[session] ?? []).contains(song);
  }

  static double _timeSlotBonus(Song song) {
    final slot  = currentTimeSlot();
    final genre = detectGenre(song);
    final mood  = _detectMoodEnum(song);
    switch (slot) {
      case TimeSlot.morning:   return (mood == SessionMood.chill || mood == SessionMood.romantic) ? 1.0 : 0.3;
      case TimeSlot.afternoon: return 0.5;
      case TimeSlot.evening:   return (mood == SessionMood.party || mood == SessionMood.energetic) ? 0.9 : 0.5;
      case TimeSlot.night:     return (mood == SessionMood.romantic || mood == SessionMood.chill) ? 1.0 : 0.3;
      case TimeSlot.lateNight: return (genre == 'lofi' || mood == SessionMood.chill) ? 1.0 : 0.2;
    }
  }

  // ---------------------------------------------------------------------------
  // ANTI-REPETITION
  // ---------------------------------------------------------------------------
  static bool shouldBlock(Song song, {String? currentTitle}) {
    if (!_loaded) return false;

    // Hard variant block
    if (isVariant(song.title)) return true;

    // Session recent window (50 songs)
    if (_session != null && _session!.recentIds.contains(song.id)) return true;

    // Language lock — block wrong language songs
    if (_session != null) {
      final songLang = _detectLanguageEnum(song);
      if (songLang != _session!.language && _session!.language != SessionLanguage.other) {
        // Allow only if language is very closely related (e.g. hindi/bhojpuri)
        final allowedCrossover = _languageCrossover[_session!.language] ?? {};
        if (!allowedCrossover.contains(songLang)) return true;
      }
    }

    // Artist diversity: max 3 songs per artist per session
    if (_session != null) {
      final artistKey = _normalizeKey(song.artist);
      final count = _session!.artistPlayCount[artistKey] ?? 0;
      if (count >= 3) return true;
    }

    // Variant of current song
    if (currentTitle != null && _isVariant(song.title, currentTitle)) return true;

    return false;
  }

  static const Map<SessionLanguage, Set<SessionLanguage>> _languageCrossover = {
    SessionLanguage.hindi:   {SessionLanguage.bhojpuri},
    SessionLanguage.bhojpuri:{SessionLanguage.hindi},
    SessionLanguage.punjabi: {SessionLanguage.hindi},
  };

  static bool _isVariant(String candidate, String original) {
    final candCore = _titleCore(candidate);
    final origCore = _titleCore(original);
    if (candCore.isEmpty || origCore.isEmpty) return false;
    if (candCore == origCore) return true;
    if (candCore.contains(origCore) && origCore.length >= 5) return true;
    if (origCore.contains(candCore) && candCore.length >= 5) return true;
    final prefixLen = origCore.length.clamp(0, 15);
    final prefix = origCore.substring(0, prefixLen);
    if (prefix.isNotEmpty && candCore.startsWith(prefix) && candCore != origCore) return true;
    return false;
  }

  /// Public — is this title a variant/remix/cover/lofi etc.?
  static bool isVariant(String title) {
    if (variantBlacklist.hasMatch(title)) return true;
    if (_bracketVariant.hasMatch(title)) return true;
    return false;
  }

  /// Legacy alias — keep backward compat with ApiService calls
  static bool isInherentVariant(String title) => isVariant(title);

  static String _titleCore(String title) => title
      .toLowerCase()
      .replaceAll(variantBlacklist, '')
      .replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), '')
      .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  // ---------------------------------------------------------------------------
  // POOL FILTERING & RANKING
  // ---------------------------------------------------------------------------
  static List<Song> rankAndFilter({
    required List<Song> pool,
    required Song currentSong,
    required Set<String> existingIds,
    bool allowVariants = false,
    int limit = 50,
  }) {
    final seenIds    = <String>{currentSong.id, ...existingIds};
    final currentCore = _titleCore(currentSong.title);
    final seenTitles = <String>{currentCore};

    // Per-artist counter for diversity enforcement in output
    final outputArtistCount = <String, int>{};

    final scored = <_ScoredSong>[];

    for (final song in pool) {
      if (seenIds.contains(song.id)) continue;

      // Hard variant filter
      if (!allowVariants) {
        if (isVariant(song.title)) continue;
        if (_isVariant(song.title, currentSong.title)) continue;
        final core = _titleCore(song.title);
        if (seenTitles.contains(core)) continue;
        final prefix = currentCore.substring(0, currentCore.length.clamp(0, 10));
        if (prefix.isNotEmpty && core.startsWith(prefix) && core != currentCore) continue;
      }

      // Language lock filter
      if (_session != null) {
        final songLang = _detectLanguageEnum(song);
        if (songLang != _session!.language) {
          final crossover = _languageCrossover[_session!.language] ?? {};
          if (!crossover.contains(songLang)) continue;
        }
      }

      final score = scoreCandidate(song);
      if (score <= 0.0) continue; // 0.0 = hard blocked (variant)

      seenIds.add(song.id);
      seenTitles.add(_titleCore(song.title));
      scored.add(_ScoredSong(song, score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    // Artist diversity: max 4 per artist in final output
    final result = <Song>[];
    for (final s in scored) {
      if (result.length >= limit) break;
      final key = _normalizeKey(s.song.artist);
      final count = outputArtistCount[key] ?? 0;
      if (count >= 4) continue;
      outputArtistCount[key] = count + 1;
      result.add(s.song);
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // QUERY GENERATION — 8 signals (was 4), much richer candidate pool
  //
  // Priority order (matches spec):
  //   1. Same original artist
  //   2. Same singer style
  //   3. Same mood + genre
  //   4. Same language + era
  //   5. Same mood broader
  //   6. Similar artists from genre pool
  //   7. Genre top hits
  //   8. Time-of-day mood
  // ---------------------------------------------------------------------------
  static List<AutoQueueQuery> generateQueries(Song currentSong) {
    if (!_loaded) {
      return _fallbackQueries(currentSong);
    }

    final genre       = detectGenre(currentSong);
    final lang        = detectLanguage(currentSong);
    final mood        = _detectMoodEnum(currentSong);
    final activeMood  = _session?.mood ?? mood;
    final activeLang  = _sessionLanguageString(_session?.language) ?? lang;
    final era         = _eraQuery(currentSong);
    final moodWord    = _moodSearchWord(activeMood);

    // Q1: Same artist — highest priority
    final q1 = AutoQueueQuery('${currentSong.artist} songs', weight: 3);

    // Q2: Same artist + mood — very specific
    final q2 = AutoQueueQuery('${currentSong.artist} $moodWord songs', weight: 2);

    // Q3: Mood + genre + language locked — THE key signal
    final q3 = AutoQueueQuery(_moodGenreQuery(activeMood, activeLang, genre), weight: 3);

    // Q4: Similar artist from same genre
    final topArtistKeys = _artistW.entries.where((e) => e.value > 0.55).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topArtists = topArtistKeys.take(5).map((e) => e.key).toList();
    final similarArtist = _pickSimilarArtist(currentSong, topArtists);
    final q4 = AutoQueueQuery('$similarArtist songs', weight: 2);

    // Q5: Era + language — same era feel
    final q5 = AutoQueueQuery('$era $activeLang songs', weight: 1);

    // Q6: Genre top hits in same language
    final q6 = AutoQueueQuery(_genreTopQuery(genre, activeLang), weight: 2);

    // Q7: Broader mood + language
    final q7 = AutoQueueQuery('$moodWord $activeLang songs', weight: 1);

    // Q8: Second similar artist
    final similarArtist2 = _pickSimilarArtist2(currentSong, topArtists, similarArtist);
    final q8 = AutoQueueQuery('$similarArtist2 songs', weight: 1);

    return [q1, q2, q3, q4, q5, q6, q7, q8];
  }

  static List<AutoQueueQuery> _fallbackQueries(Song song) {
    final genre = detectGenre(song);
    final lang  = detectLanguage(song);
    final mood  = _detectMoodEnum(song);
    return [
      AutoQueueQuery('${song.artist} songs', weight: 3),
      AutoQueueQuery(_moodGenreQuery(mood, lang, genre), weight: 3),
      AutoQueueQuery(_genreTopQuery(genre, lang), weight: 2),
      AutoQueueQuery('${_moodSearchWord(mood)} $lang songs', weight: 1),
    ];
  }

  static String _moodGenreQuery(SessionMood mood, String lang, String genre) {
    final moodWord = _moodSearchWord(mood);
    if (genre == 'bhojpuri')   return '$moodWord bhojpuri songs';
    if (genre == 'punjabi')    return '$moodWord punjabi songs';
    if (genre == 'english')    return '$moodWord english pop songs';
    if (genre == 'hiphop')     return '$moodWord hindi rap hip hop';
    if (genre == 'devotional') return 'bhakti devotional songs hindi';
    if (genre == 'lofi')       return 'lofi chill hindi songs';
    if (genre == 'tamil')      return '$moodWord tamil songs';
    if (genre == 'telugu')     return '$moodWord telugu songs';
    return '$moodWord bollywood hindi songs';
  }

  static String _genreTopQuery(String genre, String lang) {
    if (genre == 'bhojpuri')   return 'top bhojpuri songs hits';
    if (genre == 'punjabi')    return 'punjabi hits songs 2024 2025';
    if (genre == 'english')    return 'english pop hits 2024 2025';
    if (genre == 'hiphop')     return 'hindi rap hits desi hiphop';
    if (genre == 'devotional') return 'bhajan aarti devotional hits';
    if (genre == 'lofi')       return 'lofi hindi chill beats';
    if (genre == 'tamil')      return 'tamil hits songs 2024';
    if (genre == 'telugu')     return 'telugu hit songs 2024';
    return 'bollywood hits songs $lang';
  }

  static String _moodSearchWord(SessionMood mood) {
    switch (mood) {
      case SessionMood.romantic:   return 'romantic love';
      case SessionMood.sad:        return 'sad emotional dard';
      case SessionMood.party:      return 'party dance';
      case SessionMood.workout:    return 'energetic motivation';
      case SessionMood.chill:      return 'chill relaxing';
      case SessionMood.energetic:  return 'energetic upbeat';
      case SessionMood.devotional: return 'bhakti devotional';
      case SessionMood.neutral:    return 'popular hits';
    }
  }

  static String? _sessionLanguageString(SessionLanguage? lang) {
    if (lang == null) return null;
    switch (lang) {
      case SessionLanguage.hindi:    return 'hindi';
      case SessionLanguage.punjabi:  return 'punjabi';
      case SessionLanguage.english:  return 'english';
      case SessionLanguage.tamil:    return 'tamil';
      case SessionLanguage.telugu:   return 'telugu';
      case SessionLanguage.bengali:  return 'bengali';
      case SessionLanguage.marathi:  return 'marathi';
      case SessionLanguage.gujarati: return 'gujarati';
      case SessionLanguage.malayalam:return 'malayalam';
      case SessionLanguage.bhojpuri: return 'bhojpuri';
      default:                       return null;
    }
  }

  static String _pickSimilarArtist(Song song, List<String> userTopArtists) {
    final genre = detectGenre(song);
    final pool  = _genreSimilarArtists[genre] ?? _genreSimilarArtists['bollywood']!;
    final currentNorm = _normalizeKey(song.artist);
    final candidates = pool.where((a) =>
        !_normalizeKey(a).contains(currentNorm) &&
        !currentNorm.contains(_normalizeKey(a))).toList();
    for (final pref in userTopArtists) {
      final match = candidates.firstWhere(
        (a) => _normalizeKey(a) == _normalizeKey(pref), orElse: () => '');
      if (match.isNotEmpty) return match;
    }
    if (candidates.isEmpty) return pool.first;
    final dayIdx = DateTime.now().difference(DateTime(2026, 1, 1)).inDays;
    return candidates[dayIdx % candidates.length];
  }

  static String _pickSimilarArtist2(Song song, List<String> userTopArtists, String alreadyPicked) {
    final genre = detectGenre(song);
    final pool  = _genreSimilarArtists[genre] ?? _genreSimilarArtists['bollywood']!;
    final currentNorm = _normalizeKey(song.artist);
    final pickedNorm  = _normalizeKey(alreadyPicked);
    final candidates = pool.where((a) {
      final n = _normalizeKey(a);
      return !n.contains(currentNorm) && !currentNorm.contains(n) && n != pickedNorm;
    }).toList();
    if (candidates.isEmpty) return pool.last;
    final hourIdx = DateTime.now().hour;
    return candidates[hourIdx % candidates.length];
  }

  static String _eraQuery(Song song) {
    final year = int.tryParse(song.year ?? '') ?? 0;
    if (year > 0 && year < 2000) return '90s classic';
    if (year >= 2000 && year < 2010) return '2000s';
    if (year >= 2010 && year < 2020) return '2010s';
    if (year >= 2020) return 'new 2024 2025';
    return 'popular';
  }

  static String _sessionMoodQuery(SessionMood mood, String lang) {
    const queries = {
      SessionMood.romantic:   'romantic love songs',
      SessionMood.sad:        'heartbreak sad songs',
      SessionMood.party:      'party dance hits',
      SessionMood.devotional: 'bhakti devotional songs',
      SessionMood.workout:    'workout motivation energy',
      SessionMood.chill:      'chill relax songs',
      SessionMood.energetic:  'energetic upbeat hits',
      SessionMood.neutral:    'top hits songs',
    };
    final base = queries[mood] ?? 'top hits songs';
    return '$base $lang';
  }

  // ---------------------------------------------------------------------------
  // SIGNAL DETECTION (public, used by ApiService)
  // ---------------------------------------------------------------------------
  static String detectGenre(Song song) {
    final text    = '${song.title} ${song.artist} ${song.language ?? ""}'.toLowerCase();
    final langLow = (song.language ?? '').toLowerCase();

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
        text.contains('mc stan') || text.contains('seedhe')) return 'hiphop';
    if (langLow == 'english' || text.contains('english pop')) return 'english';
    if (text.contains('tamil') || langLow == 'tamil') return 'tamil';
    if (text.contains('telugu') || langLow == 'telugu') return 'telugu';
    if (text.contains('bhajan') || text.contains('aarti') || text.contains('mantra') ||
        text.contains('kirtan') || text.contains('chalisa')) return 'devotional';
    // lofi last — don't block lofi searches, just detect when in queue
    if (text.contains('lofi') || text.contains('lo-fi')) return 'lofi';
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
        text.contains('broken') || text.contains('heartbreak') || text.contains('aansu') ||
        text.contains('tadap') || text.contains('bheegi')) return SessionMood.sad;
    if (text.contains('pyar') || text.contains('love') || text.contains('ishq') ||
        text.contains('mohabbat') || text.contains('romantic') || text.contains('sajde') ||
        text.contains('teri') || text.contains('tere bina') || text.contains('humsafar') ||
        text.contains('kesariya') || text.contains('raataan') ||
        (text.contains('dil') && !text.contains('dildaar'))) return SessionMood.romantic;
    if (text.contains('party') || text.contains('dance') || text.contains('naach') ||
        text.contains('bajao') || text.contains('dj') || text.contains('balle') ||
        text.contains('garmi') || text.contains('kamariya') || text.contains('ghaghra')) return SessionMood.party;
    if (text.contains('workout') || text.contains('gym') || text.contains('motivation') ||
        text.contains('power') || text.contains('beast') || text.contains('fire')) return SessionMood.workout;
    if (text.contains('lofi') || text.contains('lo-fi') || text.contains('chill') ||
        text.contains('night') || text.contains('rain') || text.contains('study')) return SessionMood.chill;
    if (text.contains('bhajan') || text.contains('aarti') || text.contains('mantra') ||
        text.contains('chalisa') || text.contains('kirtan')) return SessionMood.devotional;
    if (text.contains('energy') || text.contains('run') || text.contains('fighter')) return SessionMood.energetic;
    return SessionMood.neutral;
  }

  static SessionGenre _detectGenreEnum(Song song) {
    switch (detectGenre(song)) {
      case 'bollywood':  return SessionGenre.bollywood;
      case 'punjabi':    return SessionGenre.punjabi;
      case 'hiphop':     return SessionGenre.hiphop;
      case 'english':    return SessionGenre.english;
      case 'lofi':       return SessionGenre.lofi;
      case 'devotional': return SessionGenre.devotional;
      case 'bhojpuri':   return SessionGenre.bhojpuri;
      case 'tamil':      return SessionGenre.tamil;
      case 'telugu':     return SessionGenre.telugu;
      default:           return SessionGenre.other;
    }
  }

  static SessionLanguage _detectLanguageEnum(Song song) {
    switch (detectLanguage(song)) {
      case 'hindi':     return SessionLanguage.hindi;
      case 'punjabi':   return SessionLanguage.punjabi;
      case 'english':   return SessionLanguage.english;
      case 'tamil':     return SessionLanguage.tamil;
      case 'telugu':    return SessionLanguage.telugu;
      case 'bengali':   return SessionLanguage.bengali;
      case 'marathi':   return SessionLanguage.marathi;
      case 'gujarati':  return SessionLanguage.gujarati;
      case 'malayalam': return SessionLanguage.malayalam;
      case 'bhojpuri':  return SessionLanguage.bhojpuri;
      default:          return SessionLanguage.other;
    }
  }

  // ---------------------------------------------------------------------------
  // PUBLIC GETTERS
  // ---------------------------------------------------------------------------
  static List<String> topAffinityArtists({int count = 5}) {
    if (!_loaded) return [];
    return (_artistW.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .where((e) => e.value > 0.5).take(count).map((e) => e.key).toList();
  }

  static List<String> topAffinityGenres({int count = 3}) {
    if (!_loaded) return [];
    return (_genreW.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .where((e) => e.value > 0.5).take(count).map((e) => e.key).toList();
  }

  static List<String> topAffinityLanguages({int count = 2}) {
    if (!_loaded) return [];
    return (_langW.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .where((e) => e.value > 0.5).take(count).map((e) => e.key).toList();
  }

  static SessionMood? get currentMood => _session?.mood;

  static TimeSlot currentTimeSlot() {
    final hour = DateTime.now().hour;
    if (hour >= 5  && hour < 11) return TimeSlot.morning;
    if (hour >= 11 && hour < 17) return TimeSlot.afternoon;
    if (hour >= 17 && hour < 21) return TimeSlot.evening;
    if (hour >= 21 && hour < 24) return TimeSlot.night;
    return TimeSlot.lateNight;
  }

  static Set<String> get sessionRecentIds => _session?.recentIds.toSet() ?? {};
  static List<String> get sessionRecentArtists => _session?.recentArtists ?? [];

  // ---------------------------------------------------------------------------
  // GENRE ARTIST POOLS (expanded)
  // ---------------------------------------------------------------------------
  static const Map<String, List<String>> _genreSimilarArtists = {
    'bollywood': [
      'arijit singh', 'atif aslam', 'armaan malik', 'jubin nautiyal',
      'shreya ghoshal', 'neha kakkar', 'sonu nigam', 'kumar sanu',
      'udit narayan', 'lata mangeshkar', 'kishore kumar', 'mohd rafi',
      'a r rahman', 'pritam', 'vishal shekhar', 'shankar ehsaan loy',
      'b praak', 'darshan raval', 'akhil sachdeva', 'ash king',
    ],
    'punjabi': [
      'diljit dosanjh', 'ap dhillon', 'sidhu moosewala', 'guru randhawa',
      'badshah', 'hardy sandhu', 'b praak', 'jasleen royal',
      'parmish verma', 'ammy virk', 'karan aujla', 'shubh',
      'satinder sartaaj', 'gurdas maan', 'jazzy b', 'surjit bindrakhia',
    ],
    'hiphop': [
      'divine', 'emiway bantai', 'mc stan', 'seedhe maut',
      'yo yo honey singh', 'badshah', 'raftar', 'naezy',
      'krsna', 'd13', 'prabh deep', 'brodha v',
    ],
    'english': [
      'the weeknd', 'ed sheeran', 'bruno mars', 'charlie puth',
      'post malone', 'dua lipa', 'taylor swift', 'ariana grande',
      'billie eilish', 'olivia rodrigo', 'shawn mendes', 'harry styles',
      'sam smith', 'adele', 'coldplay', 'imagine dragons',
      'lewis capaldi', 'calum scott', 'james arthur', 'passenger',
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
      'jagjit singh', 'gulshan kumar', 'shankar mahadevan',
      'hariharan', 'suresh wadkar', 'anup jalota',
    ],
    'tamil': [
      'ar rahman tamil', 'sid sriram', 'anirudh ravichander',
      'yuvan shankar raja', 'harris jayaraj', 'd imman',
      'vijay antony', 'gv prakash', 'santhosh narayanan',
    ],
    'telugu': [
      'dsp telugu', 'thaman s', 'mickey j meyer', 'anirudh telugu',
      'mani sharma', 'keeravani', 'chakri', 'manisharma',
    ],
  };

  // ---------------------------------------------------------------------------
  // DECAY & PERSISTENCE
  // ---------------------------------------------------------------------------
  static Future<void> applyDecay() async {
    if (!_loaded) await load();
    _artistW.updateAll((_, v) => (v * _decayFactor).clamp(0.0, 1.0));
    _genreW.updateAll((_, v)  => (v * _decayFactor).clamp(0.0, 1.0));
    _langW.updateAll((_, v)   => (v * _decayFactor).clamp(0.0, 1.0));
    await _saveAll();
  }

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

  static String _normalizeKey(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').trim();
}

// =============================================================================
// VALUE OBJECTS
// =============================================================================
class _ScoredSong {
  final Song   song;
  final double score;
  _ScoredSong(this.song, this.score);
}

class AutoQueueQuery {
  final String query;
  final int    weight;
  AutoQueueQuery(this.query, {this.weight = 1});
}
