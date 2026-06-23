// =============================================================================
// FILE: lib/services/api_service.dart
// PROJECT: Aurum Music
// VERSION: 4.0.0 — YT Stream Fix + Search Boost
//
// CHANGES vs v3:
//   ✅ YT STREAM FIX  — Multi-endpoint Piped/Invidious fallback chain when
//                       Cloudflare Worker fails. No more youtube_explode_dart
//                       PoToken issues blocking YT playback.
//   ✅ SEARCH BOOST   — Saavn timeout 4s→8s, limit 25→40, YT limit 15→20.
//                       Dedup window narrowed (30 chars) so fewer songs dropped.
//                       Saavn gets clear priority in merged results.
//   ✅ QUICK SEARCH   — Both sources timeout 3s→5s, more results flow through.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:async/async.dart';
import 'package:just_audio/just_audio.dart';
import 'dart:math' as math;

import '../models/song.dart';
import '../models/artist.dart';
import '../utils/constants.dart';
import 'audio_prefs.dart';
import 'recommendation_engine.dart';

// =============================================================================
// Result of a REAL playback attempt, used by debugPlaybackPath's
// [realPlaybackTest] callback. Lives here (not in audio_handler.dart) so
// BOTH api_service.dart and audio_handler.dart can reference it without
// creating a circular import (audio_handler.dart already imports
// api_service.dart for resolveStreamUrl etc).
// =============================================================================
class RealPlaybackResult {
  final bool success;
  final int positionMs;
  final String processingState;
  final String? errorMessage;

  const RealPlaybackResult({
    required this.success,
    required this.positionMs,
    required this.processingState,
    this.errorMessage,
  });
}

// =============================================================================
// PIPED / INVIDIOUS INSTANCES — YT stream fallback chain
// Tried in order until one returns a valid audio URL.
// Public instances — rotated to spread load.
// =============================================================================
const List<String> _kPipedInstances = [
  'https://pipedapi.kavin.rocks',
  'https://piped-api.privacy.com.de',
  'https://api.piped.projectsegfau.lt',
];

const List<String> _kInvidiousInstances = [
  'https://invidious.io.lol',
  'https://inv.nadeko.net',
  'https://invidious.privacydev.net',
];

// =============================================================================
// AURUM API SERVICE v4.0
// =============================================================================
class ApiService {

  static final http.Client    _client = http.Client();
  static final YoutubeExplode _yt     = YoutubeExplode();

  // Saavn: onrender = primary (richer song data), existing CF worker = fallback
  static const String _saavnPrimary  = 'https://jiosaavn-op-gits.onrender.com';
  static const String _saavn         = 'https://aurum-worker.shivamsharma962122.workers.dev';
  static const String _worker        = AppConstants.apiBase;

  // Stream cache
  static final Map<String, _CachedStream> _streamCache = {};
  static const Duration _streamTtl   = Duration(minutes: 50);
  static const int      _maxCacheSize = 150;

  // Search cache
  static final Map<String, _CachedSearch> _searchCache = {};
  static const Duration _searchTtl     = Duration(minutes: 10);
  static const int      _maxSearchCache = 100;

  static final Map<String, Future<String?>> _pendingResolutions = {};
  static CancelableOperation<void>? _activePrefetch;

  static const bool _kDebugLogging =
      bool.fromEnvironment('AURUM_DEBUG', defaultValue: false);

  static void _log(String message) {
    if (kDebugMode || _kDebugLogging) dev.log(message, name: 'ApiService');
  }

  static void dispose() {
    _yt.close();
    _client.close();
    _streamCache.clear();
    _pendingResolutions.clear();
    _searchCache.clear();
    _activePrefetch?.cancel();
    _activePrefetch = null;
  }

  static void wakeSaavn() {
    _client
        .get(Uri.parse('$_saavn/result/?query=hello&limit=1'))
        .timeout(const Duration(seconds: 15))
        .then((_) => _log('[wakeSaavn] Backend is warm'))
        .catchError((e) => _log('[wakeSaavn] Ping failed: $e'));
  }

  // ===========================================================================
  // HOME FEED (unchanged from v3)
  // ===========================================================================
  static final List<_PoolEntry> _pool = [
    _PoolEntry('trending hindi songs 2026',       'Trending Now'),
    _PoolEntry('new bollywood songs 2026',         'New Releases'),
    _PoolEntry('top bollywood hits 2025',          'Best of 2025'),
    _PoolEntry('hindi top charts',                 'Hindi Charts'),
    _PoolEntry('top 50 global hits',               'Global Top 50'),
    _PoolEntry('viral songs 2026',                 'Going Viral'),
    _PoolEntry('bollywood hits',                   'Bollywood Hits'),
    _PoolEntry('90s bollywood hits',               '90s Bollywood'),
    _PoolEntry('2000s bollywood songs',            '2000s Nostalgia'),
    _PoolEntry('2010s bollywood songs',            '2010s Bollywood'),
    _PoolEntry('old is gold hindi songs',          'Old Is Gold'),
    _PoolEntry('classic hindi film songs',         'Classic Cinema'),
    _PoolEntry('romantic hindi songs',             'Romantic Vibes'),
    _PoolEntry('sad emotional hindi songs',        'Heartbreak Hour'),
    _PoolEntry('party songs hindi 2026',           'Party Mode'),
    _PoolEntry('lofi chill hindi',                 'Lofi & Chill'),
    _PoolEntry('workout motivation songs',         'Workout Energy'),
    _PoolEntry('happy feel good songs hindi',      'Feel Good'),
    _PoolEntry('peaceful calm instrumental music', 'Calm & Focus'),
    _PoolEntry('late night chill songs',           'Late Night'),
    _PoolEntry('punjabi hits 2026',                'Punjabi Hits'),
    _PoolEntry('punjabi romantic songs',           'Punjabi Romance'),
    _PoolEntry('new punjabi songs 2025 2026',      'New Punjabi'),
    _PoolEntry('tamil superhit songs',             'Tamil Hits'),
    _PoolEntry('telugu hits songs',                'Telugu Hits'),
    _PoolEntry('haryanvi hits songs',              'Haryanvi Hits'),
    _PoolEntry('arijit singh best songs',          'Arijit Singh'),
    _PoolEntry('jubin nautiyal hits',              'Jubin Nautiyal'),
    _PoolEntry('neha kakkar songs',                'Neha Kakkar'),
    _PoolEntry('ap dhillon songs',                 'AP Dhillon'),
    _PoolEntry('pritam bollywood songs',           'Pritam Hits'),
    _PoolEntry('shreya ghoshal songs',             'Shreya Ghoshal'),
    _PoolEntry('atif aslam hits',                  'Atif Aslam'),
    _PoolEntry('english pop hits 2025 2026',       'English Hits'),
    _PoolEntry('90s english pop songs',            '90s English'),
    _PoolEntry('2010s english hits',               '2010s Hits'),
    _PoolEntry('hip hop hits songs',               'Hip Hop'),
    _PoolEntry('rnb songs playlist',               'R&B Vibes'),
    _PoolEntry('indie pop hits',                   'Indie Picks'),
    _PoolEntry('ed sheeran songs playlist',        'Ed Sheeran'),
    _PoolEntry('sufi songs hindi',                 'Sufi Melodies'),
    _PoolEntry('ghazal songs hindi',               'Ghazals'),
    _PoolEntry('devotional hindi songs',           'Devotional'),
    _PoolEntry('indie hindi songs',                'Hindi Indie'),
    _PoolEntry('acoustic hindi songs',             'Acoustic Vibes'),
  ];

  static Future<List<SongSection>> fetchHome({List<String> topArtists = const []}) async {
    await RecommendationEngine.load();
    final now = DateTime.now();
    final hourSeed = now.difference(DateTime(2026, 1, 1)).inHours;
    final refreshSalt = math.Random().nextInt(1000000);
    final rng = math.Random(hourSeed ^ refreshSalt);
    final shuffledPool = List<_PoolEntry>.from(_pool)..shuffle(rng);

    final affinityArtists = RecommendationEngine.topAffinityArtists(count: 4);
    final personalArtists = affinityArtists.isNotEmpty ? affinityArtists : topArtists;
    final topGenres = RecommendationEngine.topAffinityGenres(count: 3);

    final slot = RecommendationEngine.currentTimeSlot();
    final timeMoodQuery = _timeMoodQuery(slot);
    final timeMoodLabel = _timeMoodLabel(slot);

    final queryList = <_SectionQuery>[];
    queryList.add(_SectionQuery(timeMoodQuery, timeMoodLabel, priority: true));
    for (final artist in personalArtists.take(4)) {
      queryList.add(_SectionQuery('$artist best songs', 'Made for You · $artist', priority: true));
    }
    for (final genre in topGenres) {
      queryList.add(_SectionQuery(_genreMixQuery(genre), _genreMixLabel(genre), priority: true));
    }
    int poolPicks = 0;
    for (final entry in shuffledPool) {
      if (poolPicks >= 8) break;
      if (queryList.any((q) => q.label == entry.label)) continue;
      queryList.add(_SectionQuery(entry.query, entry.label));
      poolPicks++;
    }
    if (personalArtists.isEmpty && topGenres.isEmpty) {
      int extra = 0;
      for (final entry in shuffledPool.reversed) {
        if (extra >= 3) break;
        if (!queryList.any((q) => q.label == entry.label)) {
          queryList.add(_SectionQuery(entry.query, entry.label));
          extra++;
        }
      }
    }

    final results = <SongSection?>[];
    const batchSize = 3;
    for (int i = 0; i < queryList.length; i += batchSize) {
      final batch = queryList.skip(i).take(batchSize).toList();
      final batchResults = await Future.wait(
        batch.map((sq) => _saavnSectionV4(sq.query, sq.label)),
      );
      results.addAll(batchResults);
      if (i + batchSize < queryList.length) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }

    final globalSeenIds = <String>{};
    final seen = <String>{};
    final sections = <SongSection>[];
    for (final s in results.whereType<SongSection>()) {
      if (!seen.add(s.title)) continue;
      final uniqueSongs = s.songs.where((song) => globalSeenIds.add(song.id)).toList();
      if (uniqueSongs.isNotEmpty) {
        sections.add(SongSection(title: s.title, songs: uniqueSongs));
      }
    }
    return sections;
  }

  static Future<SongSection?> _saavnSectionV4(String query, String label) async {
    // Saavn is hard primary now — only call YT if Saavn comes up short.
    final saavnSongs = await _searchSaavn(query, limit: 25);
    List<Song> ytSongs = [];
    if (saavnSongs.length < 12) {
      ytSongs = await _searchYt(query, limit: 10)
          .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[]);
    }
    if (saavnSongs.isEmpty && ytSongs.isEmpty) return null;
    final seenIds = <String>{};
    final merged  = <Song>[];
    // Saavn songs kept in front; only shuffle within the Saavn block for variety,
    // YT songs appended after (never shuffled to the top).
    final seed = query.hashCode ^ DateTime.now().hour ^ math.Random().nextInt(1000000);
    final saavnShuffled = List<Song>.from(saavnSongs)..shuffle(math.Random(seed));
    for (final s in [...saavnShuffled, ...ytSongs]) {
      if (seenIds.add(s.id)) merged.add(s);
    }
    return SongSection(title: label, songs: merged.take(15).toList());
  }

  static String _timeMoodQuery(TimeSlot slot) {
    switch (slot) {
      case TimeSlot.morning:   return 'fresh morning upbeat songs hindi';
      case TimeSlot.afternoon: return 'popular bollywood songs';
      case TimeSlot.evening:   return 'evening vibes hindi songs';
      case TimeSlot.night:     return 'romantic night songs hindi';
      case TimeSlot.lateNight: return 'lofi chill late night songs';
    }
  }
  static String _timeMoodLabel(TimeSlot slot) {
    switch (slot) {
      case TimeSlot.morning:   return 'Morning Vibes';
      case TimeSlot.afternoon: return 'Afternoon Picks';
      case TimeSlot.evening:   return 'Evening Flow';
      case TimeSlot.night:     return 'Night Mode';
      case TimeSlot.lateNight: return 'Late Night Chill';
    }
  }
  static String _genreMixLabel(String genre) {
    const labels = {
      'bollywood':  'Bollywood Mix', 'punjabi': 'Punjabi Blast',
      'hiphop':     'Hip Hop Mix',   'english': 'English Mix',
      'lofi':       'Lofi Mix',      'devotional': 'Devotional',
      'tamil':      'Tamil Hits',    'telugu': 'Telugu Hits',
    };
    return labels[genre] ?? '$genre Mix';
  }
  static String _genreMixQuery(String genre) {
    const queries = {
      'bollywood':  'bollywood hits songs', 'punjabi': 'punjabi hits songs',
      'hiphop':     'hindi rap hip hop hits','english': 'english pop hits songs',
      'lofi':       'lofi chill hindi songs','devotional': 'bhakti devotional songs',
      'tamil':      'tamil hits songs',      'telugu': 'telugu hits songs',
    };
    return queries[genre] ?? '$genre top songs';
  }

  // ===========================================================================
  // AUTO-QUEUE (unchanged from v3)
  // ===========================================================================
  static Future<List<Song>> getAutoQueue(
    Song currentSong, {
    int limit = 20,
    Set<String>? existingQueueIds,
  }) async {
    await RecommendationEngine.load();
    if (currentSong.isLocal) return [];
    final queries = RecommendationEngine.generateQueries(currentSong);
    _log('[autoQueue] "${currentSong.title}" → ${queries.length} signals');
    final searchFutures = queries.map((q) async {
      final perLimit = 20 * q.weight;
      final results = await _searchSaavn(q.query, limit: perLimit)
          .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[]);
      return _SignalResult(results, q.weight);
    }).toList();
    final signalResults = await Future.wait(searchFutures);
    final merged = <Song>[];
    final iters = signalResults.map((r) => r.songs.iterator).toList();
    bool anyLeft = true;
    while (anyLeft && merged.length < limit * 6) {
      anyLeft = false;
      for (int i = 0; i < iters.length; i++) {
        final w = signalResults[i].weight;
        for (int x = 0; x < w; x++) {
          if (iters[i].moveNext()) { merged.add(iters[i].current); anyLeft = true; }
        }
      }
    }
    final allExistingIds = <String>{
      ...?existingQueueIds,
      ...RecommendationEngine.sessionRecentIds,
    };
    return RecommendationEngine.rankAndFilter(
      pool: merged, currentSong: currentSong,
      existingIds: allExistingIds, limit: limit,
    );
  }

  // ===========================================================================
  // SEARCH ENGINE v4 — Saavn-first, more results, smarter dedup
  //
  // CHANGES vs v3:
  //   • Saavn limit: 25 → 40, timeout: 4s → 8s
  //   • YT limit: 15 → 20
  //   • _normTitle dedup window: 20 chars → 30 chars (fewer false drops)
  //   • Saavn songs added without dedup check first (Saavn is always kept)
  //   • YT songs only deduped against Saavn (not each other)
  //   • Saavn source bonus: +5 → +15
  // ===========================================================================
  static Future<List<Song>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final cacheKey = _normalise(q);
    final cached = _searchCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      _log('[search] Cache HIT: "$q"');
      return cached.results;
    }

    final wantsVariant = _wantsVariantQuery(q);

    // Saavn gets 8s, YT gets 6s — Saavn is priority
    final both = await Future.wait([
      _searchSaavn(q, limit: 40)
          .timeout(const Duration(seconds: 8), onTimeout: () => <Song>[]),
      _searchYt(q, limit: 20)
          .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[]),
    ]);

    final saavnResults = both[0];
    final ytResults    = both[1];

    final scored    = <_ScoredSong>[];
    final saavnNorms = <String>{};

    // ALL Saavn results go in — no aggressive dedup on Saavn side
    for (final song in saavnResults) {
      final score = _scoreSearchResult(song, q, wantsVariant);
      final norm  = _normTitle(song.title);
      saavnNorms.add(norm);
      scored.add(_ScoredSong(song, score));
    }

    // YT: only skip if title is near-identical to a Saavn result
    for (final song in ytResults) {
      final norm = _normTitle(song.title);
      if (!saavnNorms.contains(norm)) {
        final score = _scoreSearchResult(song, q, wantsVariant);
        scored.add(_ScoredSong(song, score));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final results = scored.map((s) => s.song).toList();

    _writeSearchCache(cacheKey, results);
    _log('[search] "$q" → ${results.length} results '
         '(saavn:${saavnResults.length} yt:${ytResults.length})');
    return results;
  }

  static double _scoreSearchResult(Song song, String query, bool wantsVariant) {
    double score = 0;
    final qNorm      = _normalise(query);
    final titleNorm  = _normalise(song.title);
    final artistNorm = _normalise(song.artist);

    if (titleNorm == qNorm)                score += 100;
    else if (artistNorm == qNorm)          score += 80;
    else if (titleNorm.startsWith(qNorm))  score += 60;
    else if (artistNorm.startsWith(qNorm)) score += 40;
    else if (titleNorm.contains(qNorm))    score += 20;
    else if (artistNorm.contains(qNorm))   score += 10;

    final queryWords = qNorm.split(' ').where((w) => w.length > 2).toSet();
    if (queryWords.length > 1) {
      int wordMatches = 0;
      for (final word in queryWords) {
        if (titleNorm.contains(word) || artistNorm.contains(word)) wordMatches++;
      }
      score += wordMatches * 8.0;
    }

    if (_isOfficialAudio(song)) score += 30;

    if (!wantsVariant && RecommendationEngine.shouldBlock(song)) {
      score -= 50;
    } else if (wantsVariant && RecommendationEngine.isInherentVariant(song.title)) {
      score += 15;
    }

    // Saavn priority: bigger bonus — pre-fetched URL + better audio quality
    if (song.source == SongSource.saavn) {
      score += song.streamUrl != null ? 20 : 15;
    }

    return score;
  }

  static bool _isOfficialAudio(Song song) {
    final title = song.title.toLowerCase();
    if (title.contains('official audio') ||
        title.contains('official video') ||
        title.contains('official music video') ||
        title.contains('original')) return true;
    return !RecommendationEngine.isInherentVariant(song.title) &&
           !title.contains('cover') &&
           song.artist.isNotEmpty &&
           song.artist.toLowerCase() != 'unknown';
  }

  static bool _wantsVariantQuery(String query) =>
      RecommendationEngine.isInherentVariant(query);

  // Wider dedup window (30 chars) so fewer legitimate songs are dropped
  static String _normTitle(String title) {
    final clean = title
        .toLowerCase()
        .replaceAll(RegExp(r'\b(remix|lofi|lo[- ]?fi|slowed|reverb|nightcore|cover|'
                           r'karaoke|instrumental|bass[ -]?boost(?:ed)?|8d|sped[- ]?up|'
                           r'reprise|mashup|acoustic|unplugged|official|audio|video|'
                           r'lyric(?:s)?|full song|hd|4k)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), '')
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .trim();
    return clean.substring(0, clean.length.clamp(0, 30)); // was 20
  }

  // ===========================================================================
  // QUICK SEARCH — Saavn first (fast), YT only fills remaining slots
  // ===========================================================================
  static Future<List<Song>> quickSearch(String query, {int limit = 15}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    // Saavn first — show results fast without waiting for slow YT
    final saavnResults = await _searchSaavn(q, limit: limit + 15)
        .timeout(const Duration(seconds: 8), onTimeout: () => <Song>[]);

    // Saavn gave most of what's needed — return immediately, skip YT entirely.
    // FIX: threshold lowered from "limit" to "limit * 0.6" so YT is only used
    // as a true last resort gap-filler, not a co-equal source.
    if (saavnResults.length >= (limit * 0.6).ceil()) {
      return saavnResults.take(limit).toList();
    }

    // Saavn short — fill remaining slots with YT quickly
    final remaining = limit - saavnResults.length;
    final ytResults = await _searchYt(q, limit: remaining)
        .timeout(const Duration(seconds: 3), onTimeout: () => <Song>[]);

    final saavnNorms = saavnResults.map((s) => _normTitle(s.title)).toSet();
    final ytUnique = ytResults
        .where((s) => !saavnNorms.contains(_normTitle(s.title)))
        .take(remaining)
        .toList();

    return [...saavnResults, ...ytUnique];
  }

  // ===========================================================================
  // SUGGEST
  // ===========================================================================
  static Future<List<String>> suggest(String query) async {
    final results = await _suggestSaavn(query);
    return results.take(8).toList();
  }

  static Future<List<String>> _suggestSaavn(String query) async {
    // Try onrender primary first
    for (final base in [_saavnPrimary, _saavn]) {
      try {
        final url = Uri.parse(
          '$base/result/?query=${Uri.encodeQueryComponent(query)}&limit=5',
        );
        final res = await _client.get(url).timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final results = data is List ? data : (data['data']?['results'] ?? []);
          if (results is List && results.isNotEmpty) {
            return results
                .whereType<Map<String, dynamic>>()
                .map((j) => _cleanText(
                      (j['song'] ?? j['name'] ?? j['title'] ?? '').toString()))
                .where((s) => s.isNotEmpty)
                .take(5)
                .toList();
          }
        }
      } catch (_) {}
    }
    return [];
  }

  // ===========================================================================
  // SAAVN SEARCH — onrender is now the HARD primary.
  // Route order: confirmed-working /api/search/songs (verified via curl —
  // returns full song objects incl. downloadUrl) tried FIRST, legacy /result/
  // route kept as secondary in case the backend version differs, CF worker
  // is last-resort fallback only.
  // ===========================================================================
  static Future<List<Song>> _searchSaavn(String query, {int limit = 20}) async {
    // 1a. Confirmed-working onrender route
    try {
      final url = Uri.parse(
        '$_saavnPrimary/api/search/songs?query=${Uri.encodeQueryComponent(query)}&limit=$limit',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final results = (data is Map ? (data['data']?['results']) : null) ?? [];
        if (results is List && results.isNotEmpty) {
          final songs = results
              .whereType<Map<String, dynamic>>()
              .take(limit)
              .map(_songFromSaavn)
              .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
              .toList();
          if (songs.isNotEmpty) return songs;
        }
      }
    } catch (e) {
      _log('[_searchSaavn] onrender /api/search/songs error: $e');
    }
    // 1b. Legacy onrender route (kept as secondary)
    try {
      final url = Uri.parse(
        '$_saavnPrimary/result/?query=${Uri.encodeQueryComponent(query)}&limit=$limit',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final results = data is List
            ? data
            : (data['data']?['results'] ?? data['data'] ?? []);
        if (results is List && results.isNotEmpty) {
          final songs = results
              .whereType<Map<String, dynamic>>()
              .take(limit)
              .map(_songFromSaavn)
              .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
              .toList();
          if (songs.isNotEmpty) return songs;
        }
      }
    } catch (e) {
      _log('[_searchSaavn] onrender /result/ error: $e');
    }
    // 2. Fallback to existing CF worker backend
    try {
      final url = Uri.parse(
        '$_saavn/result/?query=${Uri.encodeQueryComponent(query)}&limit=$limit',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final results = data is List
            ? data
            : (data['data']?['results'] ?? data['data'] ?? []);
        if (results is List && results.isNotEmpty) {
          return results
              .whereType<Map<String, dynamic>>()
              .take(limit)
              .map(_songFromSaavn)
              .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
              .toList();
        }
      }
    } catch (e) {
      _log('[_searchSaavn] Error: $e');
    }
    return [];
  }

  // ===========================================================================
  // YOUTUBE SEARCH
  // ===========================================================================
  static Future<List<Song>> _searchYt(String query, {int limit = 15}) async {
    try {
      final results = await Future.any<List<dynamic>>([
        _yt.search.search(query).then((list) => list.toList()),
        Future.delayed(const Duration(seconds: 6), () => <dynamic>[]),
      ]);
      return results
          .whereType<Video>()
          .take(limit)
          .map(_songFromYtVideo)
          .where((s) => s.id.isNotEmpty)
          .toList();
    } catch (e) {
      _log('[_searchYt] Error: $e');
    }
    return [];
  }

  static Song _songFromYtVideo(Video v) => Song(
        id:         v.id.value,
        title:      _cleanText(v.title),
        artist:     _cleanText(v.author),
        album:      '',
        artworkUrl: _bestThumbnail(v.thumbnails),
        streamUrl:  null,
        duration:   v.duration?.inSeconds,
        source:     SongSource.youtube,
      );

  static String _bestThumbnail(dynamic t) {
    for (final url in [t.maxResUrl, t.highResUrl, t.standardResUrl, t.mediumResUrl, t.lowResUrl]) {
      if (url != null && url.toString().isNotEmpty) return url.toString();
    }
    return '';
  }

  // ===========================================================================
  // STREAM URL RESOLUTION — v4 YT fix
  // ===========================================================================
  static Future<String?> resolveStreamUrl(Song song, {bool forceRefresh = false}) async {
    if (song.isLocal) return song.localPath;

    final cacheKey = '${song.source.name}:${song.id}';

    if (!forceRefresh) {
      final cached = _streamCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        _log('[resolve] Cache HIT: "${song.title}"');
        return cached.url;
      }
    }

    if (!forceRefresh && _pendingResolutions.containsKey(cacheKey)) {
      _log('[resolve] Joining in-flight: "$cacheKey"');
      return _pendingResolutions[cacheKey];
    }

    // Saavn pre-fetched URL — only use if already proxied through worker.
    if (!forceRefresh &&
        song.source == SongSource.saavn &&
        song.streamUrl != null &&
        song.streamUrl!.contains('/stream-proxy?url=')) {
      final cached = _streamCache[cacheKey];
      if (cached == null) {
        _log('[resolve] Pre-fetched Saavn URL (proxied): "${song.title}"');
        _writeStreamCache(cacheKey, song.streamUrl!);
        return song.streamUrl;
      }
      if (!cached.isExpired) return cached.url;
      _log('[resolve] Saavn pre-fetched expired — re-resolving');
    }

    _log('[resolve] Resolving "${song.title}" source=${song.source.name}');
    final resolutionFuture = _doResolve(song, cacheKey);
    _pendingResolutions[cacheKey] = resolutionFuture;
    try {
      return await resolutionFuture;
    } finally {
      _pendingResolutions.remove(cacheKey);
    }
  }

  static Future<String?> _doResolve(Song song, String cacheKey) async {
    String? url;
    switch (song.source) {
      case SongSource.saavn:
        if (song.id.isNotEmpty) {
          url = await _retry(() => _saavnStreamById(song.id), attempts: 2);
          _log('[resolve] Saavn by ID "${song.title}": ${url != null ? "OK" : "FAILED"}');
        }
        if (url == null) {
          _log('[resolve] Saavn fallback → YT search for "${song.title} ${song.artist}"');
          url = await _ytStreamFull('${song.title} ${song.artist}');
        }
        break;

      case SongSource.youtube:
        if (song.id.isNotEmpty) {
          url = await _ytStreamById(song.id);
          _log('[resolve] YT "${song.id}": ${url != null ? "OK" : "FAILED"}');
        }
        if (url == null) {
          _log('[resolve] YT by-ID failed → search "${song.title} ${song.artist}"');
          url = await _ytStreamFull('${song.title} ${song.artist}');
        }
        break;

      case SongSource.local:
        return song.localPath;
    }

    if (url != null) {
      _writeStreamCache(cacheKey, url);
      _log('[resolve] SUCCESS "${song.title}"');
    } else {
      _log('[resolve] FAILED all sources "${song.title}"');
    }
    return url;
  }

  // ===========================================================================
  // YT STREAM — v4 multi-endpoint fallback chain
  //
  // ORDER:
  //   1. Cloudflare Worker  (/api/yt-stream?id=)       — fastest, our own CF
  //   2. Piped instances    (3 public, tried in order) — free, reliable
  //   3. Invidious instances(3 public, tried in order) — fallback
  //   4. youtube_explode_dart                          — last resort, may be
  //                                                      blocked by PoToken
  //
  // _ytStreamById races Worker vs Piped[0] first (fastest pair).
  // If both fail, sequentially tries remaining Piped → Invidious → explode.
  // ===========================================================================
  static Future<String?> _ytStreamById(String videoId) async {
    // Stage 1: Race Worker vs first Piped instance
    final stage1 = await _raceFirstValid([
      () => _workerYtStream(videoId),
      () => _pipedStream(videoId, _kPipedInstances[0]),
    ]);
    if (stage1 != null) return stage1;

    // Stage 2: Remaining Piped instances
    for (int i = 1; i < _kPipedInstances.length; i++) {
      final url = await _pipedStream(videoId, _kPipedInstances[i]);
      if (url != null) return _proxiedSaavnUrl(url);
    }

    // Stage 3: Invidious instances
    for (final inst in _kInvidiousInstances) {
      final url = await _invidiousStream(videoId, inst);
      if (url != null) return _proxiedSaavnUrl(url);
    }

    // Stage 4: youtube_explode_dart (last resort)
    return _ytExplodeStream(videoId);
  }

  static Future<String?> _ytStreamFull(String query) async {
    try {
      final results = await Future.any<List<dynamic>>([
        _yt.search.search(query).then((list) => list.toList()),
        Future.delayed(const Duration(seconds: 8), () => <dynamic>[]),
      ]);
      final videos = results.whereType<Video>().toList();
      if (videos.isEmpty) return null;
      return _ytStreamById(videos.first.id.value);
    } catch (e) {
      _log('[ytStreamFull] Error: $e');
    }
    return null;
  }

  // ── Cloudflare Worker ────────────────────────────────────────────────────
  // FIX: the Worker's own resolveYtStreamFast() runs up to 3 internal stages
  // (Innertube+Piped race → 5-way blast → remaining instances with a 5s
  // deadline), which can take ~13-15s end-to-end on a cold Worker isolate
  // (Cloudflare recycles isolates, so the in-memory instanceHealth Map —
  // used to rank/skip bad instances — starts empty and gives no speed
  // advantage on the first request). The old 8s timeout was killing the
  // Worker call before it could finish, forcing every cold-start resolve
  // onto the slower Dart-side Piped/Invidious chain instead. 16s gives the
  // Worker's full internal chain room to actually complete.
  static Future<String?> _workerYtStream(String videoId) async {
    try {
      final uri = Uri.parse('$_worker/api/yt-stream?id=$videoId');
      final res = await _client.get(uri).timeout(const Duration(seconds: 16));
      if (res.statusCode == 200) {
        final ct = res.headers['content-type'] ?? '';
        if (ct.contains('application/json')) {
          final data = jsonDecode(res.body);
          String? url = (data['url'] ?? data['stream_url'] ?? data['audio_url'])?.toString();
          if (url == null && data['data'] is Map) {
            url = (data['data']['url'] ?? data['data']['stream_url'])?.toString();
          }
          if (url == null && data is List && data.isNotEmpty && data[0] is Map) {
            url = (data[0]['url'] ?? data[0]['stream_url'])?.toString();
          }
          if (url != null && url.startsWith('http')) return url;
          return null;
        }
        final body = res.body.trim();
        if (body.startsWith('http')) return body;
      }
    } catch (e) {
      _log('[worker] Exception: $e');
    }
    return null;
  }

  // ── Piped ────────────────────────────────────────────────────────────────
  static Future<String?> _pipedStream(String videoId, String instance) async {
    try {
      final uri = Uri.parse('$instance/streams/$videoId');
      final res = await _client.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0',
      }).timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final streams = data['audioStreams'] as List?;
        if (streams == null || streams.isEmpty) return null;

        // Prefer m4a/mp4 at highest bitrate
        final m4a = streams.where((s) {
          final mime = (s['mimeType'] ?? '').toString().toLowerCase();
          return mime.contains('mp4') || mime.contains('m4a');
        }).toList();

        final pool = m4a.isNotEmpty ? m4a : streams;
        pool.sort((a, b) {
          final bA = (a['bitrate'] as num? ?? 0).toInt();
          final bB = (b['bitrate'] as num? ?? 0).toInt();
          return bB.compareTo(bA);
        });

        final url = pool.first['url']?.toString();
        if (url != null && url.startsWith('http')) {
          _log('[piped] OK $instance for $videoId');
          return url;
        }
      }
    } catch (e) {
      _log('[piped] $instance error: $e');
    }
    return null;
  }

  // ── Invidious ────────────────────────────────────────────────────────────
  static Future<String?> _invidiousStream(String videoId, String instance) async {
    try {
      final uri = Uri.parse('$instance/api/v1/videos/$videoId?fields=adaptiveFormats');
      final res = await _client.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0',
      }).timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final formats = data['adaptiveFormats'] as List?;
        if (formats == null || formats.isEmpty) return null;

        final audio = formats.where((f) {
          final type = (f['type'] ?? '').toString().toLowerCase();
          return type.contains('audio');
        }).toList();
        if (audio.isEmpty) return null;

        audio.sort((a, b) {
          final bA = (a['bitrate'] as num? ?? 0).toInt();
          final bB = (b['bitrate'] as num? ?? 0).toInt();
          return bB.compareTo(bA);
        });

        final url = audio.first['url']?.toString();
        if (url != null && url.startsWith('http')) {
          _log('[invidious] OK $instance for $videoId');
          return url;
        }
      }
    } catch (e) {
      _log('[invidious] $instance error: $e');
    }
    return null;
  }

  // ── youtube_explode_dart (last resort) ───────────────────────────────────
  static Future<String?> _ytExplodeStream(String videoId) async {
    try {
      final manifest = await _yt.videos.streamsClient
          .getManifest(VideoId(videoId))
          .timeout(const Duration(seconds: 10));
      if (manifest.audioOnly.isEmpty) return null;
      final m4aStreams = manifest.audioOnly.where((s) {
        final mime      = s.codec.mimeType.toLowerCase();
        final container = s.container.name.toLowerCase();
        return mime.contains('mp4') || mime.contains('aac') ||
               container == 'mp4'  || container == 'm4a';
      }).toList();
      if (m4aStreams.isNotEmpty) {
        m4aStreams.sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        return m4aStreams.first.url.toString();
      }
      return manifest.audioOnly.withHighestBitrate().url.toString();
    } catch (e) {
      _log('[ytExplode] Error for $videoId: $e');
    }
    return null;
  }

  // ===========================================================================
  // SAAVN STREAM RESOLUTION
  // ===========================================================================
  static Future<String?> _saavnStreamById(String songId) async {
    // 1a. Confirmed-working route: /api/songs?ids= (returns clean downloadUrl
    // array with 48/96/160/320kbps — verified via curl). Try this FIRST since
    // /song/?id= below 404s on some onrender deploys depending on backend version.
    try {
      final res = await _client
          .get(Uri.parse('$_saavnPrimary/api/songs?ids=$songId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final raw = jsonDecode(res.body);
        Map<String, dynamic>? songData;
        final inner = (raw is Map<String, dynamic>) ? raw['data'] : null;
        if (inner is List && inner.isNotEmpty) {
          songData = inner[0] as Map<String, dynamic>?;
        } else if (raw is List && raw.isNotEmpty) {
          songData = raw[0] as Map<String, dynamic>?;
        }
        if (songData != null) {
          // _onrenderStreamUrl and _extractSaavnStreamUrl already call _proxiedSaavnUrl internally
          final url = _onrenderStreamUrl(songData) ?? _extractSaavnStreamUrl(songData);
          if (url != null) return url;
        }
      }
    } catch (e) {
      _log('[saavnById] onrender /api/songs error for $songId: $e');
    }
    // 1b. Try onrender primary (legacy route, kept as fallback)
    try {
      final res = await _client
          .get(Uri.parse('$_saavnPrimary/song/?id=$songId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final raw = jsonDecode(res.body);
        Map<String, dynamic>? songData;
        if (raw is Map<String, dynamic> && raw['success'] == true && raw['url'] != null) {
          final url = raw['url'].toString();
          if (url.startsWith('http')) return url;
        }
        if (raw is List && raw.isNotEmpty) {
          songData = raw[0] as Map<String, dynamic>?;
        } else if (raw is Map<String, dynamic>) {
          final inner = raw['data'];
          if (inner is List && inner.isNotEmpty) {
            songData = inner[0] as Map<String, dynamic>?;
          } else if (inner is Map<String, dynamic>) {
            songData = inner;
          } else {
            songData = raw;
          }
        }
        if (songData != null) {
          // _onrenderStreamUrl and _extractSaavnStreamUrl already proxy internally
          final url = _onrenderStreamUrl(songData) ?? _extractSaavnStreamUrl(songData);
          if (url != null) return url;
        }
      }
    } catch (e) {
      _log('[saavnById] onrender error for $songId: $e');
    }
    // 2. Fallback to existing backend
    try {
      final res = await _client
          .get(Uri.parse('$_saavn/song/?id=$songId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final raw = jsonDecode(res.body);
        Map<String, dynamic>? songData;
        if (raw is Map<String, dynamic> && raw['success'] == true && raw['url'] != null) {
          final url = raw['url'].toString();
          if (url.startsWith('http')) return url;
        }
        if (raw is List && raw.isNotEmpty) {
          songData = raw[0] as Map<String, dynamic>?;
        } else if (raw is Map<String, dynamic>) {
          final inner = raw['data'];
          if (inner is List && inner.isNotEmpty) {
            songData = inner[0] as Map<String, dynamic>?;
          } else if (inner is Map<String, dynamic>) {
            songData = inner;
          } else {
            songData = raw;
          }
        }
        if (songData != null) {
          return _onrenderStreamUrl(songData) ?? _extractSaavnStreamUrl(songData);
        }
      }
    } catch (e) {
      _log('[saavnById] Error for $songId: $e');
    }
    return null;
  }

  static String? _onrenderStreamUrl(Map<String, dynamic> j) {
    final url320   = (j['320kbps'] ?? '').toString();
    if (url320.startsWith('http')) return _proxiedSaavnUrl(url320);
    final urlMedia = (j['media_url'] ?? '').toString();
    if (urlMedia.startsWith('http')) return _proxiedSaavnUrl(urlMedia);
    return null;
  }

  static String? _extractSaavnStreamUrl(Map<String, dynamic> song) {
    final downloads = song['downloadUrl'] as List?;
    if (downloads != null && downloads.isNotEmpty) {
      for (final q in AudioPrefs.qualityOrder()) {
        final match = downloads.firstWhere(
          (d) => d is Map && d['quality'] == q &&
                 (d['url'] as String?)?.startsWith('http') == true,
          orElse: () => null,
        );
        if (match != null) return _proxiedSaavnUrl(match['url'] as String);
      }
      final last = downloads.last;
      if (last is Map && (last['url'] as String?)?.startsWith('http') == true) {
        return _proxiedSaavnUrl(last['url'] as String);
      }
    }
    final su = song['media_url'] ?? song['streamUrl'];
    if (su is String && su.startsWith('http')) return _proxiedSaavnUrl(su);
    return null;
  }

  // ===========================================================================
  // RACE HELPER
  // ===========================================================================
  static Future<String?> _raceFirstValid(List<Future<String?> Function()> fns) async {
    final completer = Completer<String?>();
    var remaining = fns.length;
    void onDone(String? value) {
      remaining--;
      if (completer.isCompleted) return;
      if (value != null && value.isNotEmpty) completer.complete(value);
      else if (remaining == 0) completer.complete(null);
    }
    for (final fn in fns) fn().then(onDone).catchError((_) => onDone(null));
    return completer.future;
  }

  // ===========================================================================
  // RETRY
  // ===========================================================================
  static Future<String?> _retry(
    Future<String?> Function() fn, {
    int attempts = 3,
    Duration baseDelay = const Duration(milliseconds: 300),
  }) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final result = await fn();
        if (result != null && result.isNotEmpty) return result;
      } catch (e) {
        _log('[retry] Attempt ${i + 1}/$attempts failed: $e');
      }
      if (i < attempts - 1) await Future.delayed(baseDelay * (1 << i));
    }
    return null;
  }

  // ===========================================================================
  // CACHE MANAGEMENT
  // ===========================================================================
  static void _writeStreamCache(String key, String url) {
    if (_streamCache.length >= _maxCacheSize) {
      final expiredKeys = _streamCache.entries
          .where((e) => e.value.isExpired).map((e) => e.key).toList();
      for (final k in expiredKeys) _streamCache.remove(k);
      if (_streamCache.length >= _maxCacheSize) {
        final oldest = _streamCache.entries.reduce(
          (a, b) => a.value.resolvedAt.isBefore(b.value.resolvedAt) ? a : b,
        );
        _streamCache.remove(oldest.key);
      }
    }
    _streamCache[key] = _CachedStream(url);
  }

  static void invalidateStream(Song song) {
    _streamCache.remove('${song.source.name}:${song.id}');
  }

  static void clearExpiredCache() {
    _streamCache.removeWhere((_, v) => v.isExpired);
    _searchCache.removeWhere((_, v) => v.isExpired);
  }

  static void _writeSearchCache(String key, List<Song> results) {
    if (_searchCache.length >= _maxSearchCache) {
      final expiredKeys = _searchCache.entries
          .where((e) => e.value.isExpired).map((e) => e.key).toList();
      for (final k in expiredKeys) _searchCache.remove(k);
      if (_searchCache.length >= _maxSearchCache) {
        final oldest = _searchCache.entries.reduce(
          (a, b) => a.value.cachedAt.isBefore(b.value.cachedAt) ? a : b,
        );
        _searchCache.remove(oldest.key);
      }
    }
    _searchCache[key] = _CachedSearch(results);
  }

  // ===========================================================================
  // NETWORK RECOVERY
  // ===========================================================================
  static Future<void> onNetworkRestored({Song? currentSong}) async {
    _streamCache.removeWhere((_, v) => v.isExpired);
    if (currentSong != null && !currentSong.isLocal) {
      try { await resolveStreamUrl(currentSong, forceRefresh: true); } catch (_) {}
    }
  }

  // ===========================================================================
  // PREFETCH
  // ===========================================================================
  static void prefetchNext(Song song) {
    if (song.isLocal) return;
    _activePrefetch?.cancel();
    _activePrefetch = null;
    _activePrefetch = CancelableOperation.fromFuture(
      Future.delayed(const Duration(milliseconds: 800), () async {
        try { await resolveStreamUrl(song); } catch (_) {}
      }),
    );
  }

  static void cancelPrefetch() {
    _activePrefetch?.cancel();
    _activePrefetch = null;
  }

  // ===========================================================================
  // SONG PARSERS
  // ===========================================================================
  static Song _songFromSaavn(Map<String, dynamic> j) {
    final title = _cleanText((j['song'] ?? j['name'] ?? j['title'] ?? 'Unknown').toString());

    String artist = '';
    final artistsField = j['artists'];
    if (artistsField is Map && artistsField['primary'] is List) {
      artist = (artistsField['primary'] as List)
          .map((a) => a is Map ? (a['name'] ?? '').toString() : a.toString())
          .where((s) => s.isNotEmpty)
          .join(', ');
    }
    if (artist.isEmpty) {
      final fallback = j['primary_artists'] ?? j['singers'] ?? j['artist'];
      if (fallback is String) artist = fallback;
    }
    artist = _cleanText(artist);

    String album = '';
    final albumField = j['album'];
    if (albumField is Map) {
      album = (albumField['name'] ?? '').toString();
    } else if (albumField is String) {
      album = albumField;
    }
    album = _cleanText(album);

    final artwork   = _onrenderArtwork(j);
    final streamUrl = _onrenderStreamUrl(j);
    return Song(
      id:         (j['id'] ?? '').toString(),
      title:      title,
      artist:     artist.isEmpty ? 'Unknown Artist' : artist,
      album:      album,
      artworkUrl: artwork,
      streamUrl:  streamUrl,
      duration:   _parseInt(j['duration']),
      language:   j['language']?.toString() ?? 'hindi',
      year:       j['year']?.toString(),
      source:     SongSource.saavn,
    );
  }

  // ===========================================================================
  // HOME ARTISTS STRIP
  // ===========================================================================

  /// 5-6 random popular artists with images for the home artist strip.
  static Future<List<ArtistSimple>> fetchHomeArtists() async {
    // Curated pool — picked from Saavn's most followed artists
    const pool = [
      _ArtistEntry('arijit singh',   'Arijit Singh'),
      _ArtistEntry('jubin nautiyal', 'Jubin Nautiyal'),
      _ArtistEntry('neha kakkar',    'Neha Kakkar'),
      _ArtistEntry('ap dhillon',     'AP Dhillon'),
      _ArtistEntry('atif aslam',     'Atif Aslam'),
      _ArtistEntry('shreya ghoshal', 'Shreya Ghoshal'),
      _ArtistEntry('pritam',         'Pritam'),
      _ArtistEntry('sonu nigam',     'Sonu Nigam'),
      _ArtistEntry('diljit dosanjh', 'Diljit Dosanjh'),
      _ArtistEntry('badshah',        'Badshah'),
      _ArtistEntry('armaan malik',   'Armaan Malik'),
      _ArtistEntry('darshan raval',  'Darshan Raval'),
      _ArtistEntry('b praak',        'B Praak'),
      _ArtistEntry('vishal mishra',  'Vishal Mishra'),
      _ArtistEntry('kumar sanu',     'Kumar Sanu'),
    ];

    final rng = math.Random(DateTime.now().difference(DateTime(2026, 1, 1)).inHours);
    final shuffled = List<_ArtistEntry>.from(pool)..shuffle(rng);
    final picked = shuffled.take(6).toList();

    final results = await Future.wait(picked.map((a) async {
      try {
        final uri = Uri.parse('$_saavnPrimary/api/search/artists')
            .replace(queryParameters: {'query': a.query, 'limit': '1'});
        final res = await _client.get(uri).timeout(const Duration(seconds: 5));
        if (res.statusCode != 200) return null;
        final body = jsonDecode(res.body);
        final results = body['data']?['results'] as List?;
        if (results == null || results.isEmpty) return null;
        final r = results.first as Map<String, dynamic>;
        final imageList = r['image'] as List?;
        String imageUrl = '';
        if (imageList != null && imageList.isNotEmpty) {
          imageUrl = (imageList.last['url'] ?? imageList.last['link'] ?? '').toString();
        }
        if (imageUrl.isEmpty) return null;
        return ArtistSimple(
          id: (r['id'] ?? '').toString(),
          name: a.displayName,
          imageUrl: imageUrl,
        );
      } catch (_) {
        return null;
      }
    }));

    return results.whereType<ArtistSimple>().toList();
  }

  // ===========================================================================
  // ARTIST PAGE
  // ===========================================================================

  /// Resolve an artist's Saavn ID from their display name (used when navigating
  /// from a song tile, where we only have the artist's name string).
  static Future<String?> searchArtistByName(String name) async {
    if (name.trim().isEmpty) return null;
    try {
      final uri = Uri.parse('$_saavnPrimary/api/search/artists')
          .replace(queryParameters: {'query': name});
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      final results = body['data']?['results'] as List?;
      if (results == null || results.isEmpty) return null;
      // Prefer an exact (case-insensitive) name match, else take the first hit.
      final lower = name.trim().toLowerCase();
      final exact = results.firstWhere(
        (r) => (r['name'] ?? '').toString().toLowerCase() == lower,
        orElse: () => results.first,
      );
      return (exact['id'] ?? '').toString();
    } catch (e) {
      _log('[artist] searchArtistByName failed: $e');
      return null;
    }
  }

  /// Fetch full artist page data: profile, top songs, top albums and singles.
  static Future<Artist?> fetchArtist(String artistId,
      {int songCount = 15, int albumCount = 12}) async {
    if (artistId.isEmpty) return null;
    try {
      final uri = Uri.parse('$_saavnPrimary/api/artists/$artistId').replace(
        queryParameters: {
          'songCount': '$songCount',
          'albumCount': '$albumCount',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      if (body['success'] != true) return null;
      final d = body['data'] as Map<String, dynamic>?;
      if (d == null) return null;

      final topSongs = ((d['topSongs'] as List?) ?? [])
          .whereType<Map>()
          .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
          .toList();

      final topAlbums = ((d['topAlbums'] as List?) ?? [])
          .whereType<Map>()
          .map((a) => _artistAlbumFromJson(Map<String, dynamic>.from(a), type: 'album'))
          .toList();

      final singles = ((d['singles'] as List?) ?? [])
          .whereType<Map>()
          .map((a) => _artistAlbumFromJson(Map<String, dynamic>.from(a), type: 'single'))
          .toList();

      String bio = '';
      final bioField = d['bio'];
      if (bioField is List && bioField.isNotEmpty) {
        final first = bioField.first;
        if (first is Map && first['text'] is String) {
          bio = _cleanText(first['text'] as String);
        }
      }

      return Artist(
        id: (d['id'] ?? artistId).toString(),
        name: _cleanText((d['name'] ?? '').toString()),
        imageUrl: _onrenderArtwork(d),
        followerCount: _parseInt(d['followerCount']) ?? 0,
        isVerified: d['isVerified'] == true,
        bio: bio,
        topSongs: topSongs,
        topAlbums: topAlbums,
        singles: singles,
      );
    } catch (e) {
      _log('[artist] fetchArtist failed: $e');
      return null;
    }
  }

  /// Fetch the songs inside an album or single, by its Saavn ID.
  static Future<List<Song>> fetchAlbumSongs(String albumId) async {
    if (albumId.isEmpty) return [];
    try {
      final uri = Uri.parse('$_saavnPrimary/api/albums')
          .replace(queryParameters: {'id': albumId});
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      final body = jsonDecode(res.body);
      if (body['success'] != true) return [];
      final songs = (body['data']?['songs'] as List?) ?? [];
      return songs
          .whereType<Map>()
          .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
          .toList();
    } catch (e) {
      _log('[artist] fetchAlbumSongs failed: $e');
      return [];
    }
  }

  static ArtistAlbum _artistAlbumFromJson(Map<String, dynamic> j, {required String type}) {
    return ArtistAlbum(
      id: (j['id'] ?? '').toString(),
      name: _cleanText((j['name'] ?? j['title'] ?? 'Unknown').toString()),
      artworkUrl: _onrenderArtwork(j),
      year: j['year']?.toString(),
      type: type,
    );
  }

  static SongSource sourceFromString(String? s) {
    switch (s) {
      case 'saavn':   return SongSource.saavn;
      case 'youtube': return SongSource.youtube;
      case 'local':   return SongSource.local;
      default:        return SongSource.saavn;
    }
  }

  // ===========================================================================
  // LYRICS
  // ===========================================================================
  static final Map<String, String> _lyricsCache = {};

  static Future<String?> fetchLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return null;
    final cacheKey = '${song.source.name}:${song.id}';
    if (_lyricsCache.containsKey(cacheKey)) return _lyricsCache[cacheKey];
    String? lyrics;
    if (song.source == SongSource.saavn) {
      lyrics = await _fetchSaavnLyrics(song.id);
    }
    lyrics ??= await _fetchLrcLibLyrics(song.title, song.artist);
    if (lyrics != null && lyrics.isNotEmpty) _lyricsCache[cacheKey] = lyrics;
    return lyrics;
  }

  static Future<String?> _fetchSaavnLyrics(String songId) async {
    try {
      final res = await _client
          .get(Uri.parse('$_saavn/lyrics/?id=$songId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final l = data['data']?['lyrics'] as String?;
        return (l != null && l.isNotEmpty) ? l : null;
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _fetchLrcLibLyrics(String title, String artist) async {
    try {
      final q = Uri.encodeQueryComponent('$title $artist');
      final res = await _client
          .get(Uri.parse('https://lrclib.net/api/search?q=$q'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is List && data.isNotEmpty) {
          final first = data.first as Map<String, dynamic>?;
          final plain = first?['plainLyrics'] as String?;
          if (plain != null && plain.isNotEmpty) return plain;
          final synced = first?['syncedLyrics'] as String?;
          if (synced != null && synced.isNotEmpty) {
            return synced
                .split('\n')
                .map((line) => line.replaceFirst(RegExp(r'^\[\d{2}:\d{2}\.\d{2,3}\] ?'), ''))
                .where((line) => line.isNotEmpty)
                .join('\n');
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================
  static String _onrenderArtwork(Map<String, dynamic> j) {
    final imgField = j['image'];
    if (imgField is List && imgField.isNotEmpty) {
      for (final entry in imgField.reversed) {
        if (entry is Map && entry['url'] is String) {
          final u = entry['url'] as String;
          if (u.startsWith('http')) return u;
        }
      }
    }
    if (imgField is String && imgField.startsWith('http')) {
      return imgField
          .replaceAll('150x150', '500x500')
          .replaceAll('50x50',   '500x500');
    }
    return '';
  }

  static String _cleanText(String s) => s
      .replaceAll('&amp;',  '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&lt;',   '<')
      .replaceAll('&gt;',   '>');

  static int? _parseInt(dynamic d) {
    if (d == null)   return null;
    if (d is int)    return d;
    if (d is double) return d.toInt();
    if (d is String) return int.tryParse(d);
    return null;
  }

  static String _normalise(String s) {
    final clean = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return clean.substring(0, clean.length.clamp(0, 25));
  }

  // ===========================================================================
  // DIAGNOSTICS
  // ===========================================================================

  // Result of a REAL playback attempt through the live AurumAudioHandler —
  // returned by the [realPlaybackTest] callback passed into
  // [debugPlaybackPath] from the UI. Separate from PlayerException so the
  // diagnostic function doesn't need to import audio_handler.dart directly
  // (avoids a circular import: audio_handler.dart already imports
  // api_service.dart).
  static Map<String, dynamic> getDiagnosticsSnapshot() {
    return {
      'timestamp':           DateTime.now().toIso8601String(),
      'stream_cache_size':   _streamCache.length,
      'search_cache_size':   _searchCache.length,
      'pending_resolutions': _pendingResolutions.length,
      'prefetch_active':     _activePrefetch != null,
      'lyrics_cached':       _lyricsCache.length,
      'worker_base':         _worker,
      'saavn_base':          _saavn,
      'piped_instances':     _kPipedInstances,
      'invidious_instances': _kInvidiousInstances,
    };
  }

  /// [realPlaybackTest], if provided, is called with a test [Song] and
  /// should attempt REAL playback through the app's live AurumAudioHandler
  /// (wired in from home_screen.dart via PlayerProvider) and report back
  /// what actually happened. When null, falls back to the old
  /// throwaway-AudioPlayer test so this function still works standalone.
  static Future<String> debugPlaybackPath({
    Future<RealPlaybackResult> Function(Song)? realPlaybackTest,
  }) async {
    final buf = StringBuffer();
    buf.writeln('=== Aurum Playback Diagnostics v4 ===');
    buf.writeln('Time:   ${DateTime.now()}');
    buf.writeln('Worker: $_worker');
    buf.writeln('Saavn:  $_saavn');
    buf.writeln('');

    // Test Worker
    buf.writeln('▶ 1. Cloudflare Worker');
    try {
      final sw = Stopwatch()..start();
      final url = await _workerYtStream('dQw4w9WgXcQ');
      sw.stop();
      buf.writeln(url != null ? '   ✅ OK (${sw.elapsedMilliseconds}ms)' : '   ❌ FAILED');
    } catch (e) { buf.writeln('   ❌ $e'); }

    // Test Piped
    for (int i = 0; i < _kPipedInstances.length; i++) {
      buf.writeln('▶ ${i + 2}. Piped: ${_kPipedInstances[i]}');
      try {
        final sw = Stopwatch()..start();
        final url = await _pipedStream('dQw4w9WgXcQ', _kPipedInstances[i]);
        sw.stop();
        buf.writeln(url != null ? '   ✅ OK (${sw.elapsedMilliseconds}ms)' : '   ❌ FAILED');
      } catch (e) { buf.writeln('   ❌ $e'); }
    }

    // Test Saavn
    buf.writeln('▶ ${_kPipedInstances.length + 2}. Saavn search');
    List<Song> testSongs = [];
    try {
      final sw = Stopwatch()..start();
      testSongs = await _searchSaavn('arijit singh', limit: 3);
      sw.stop();
      buf.writeln(testSongs.isNotEmpty
          ? '   ✅ OK (${sw.elapsedMilliseconds}ms) — ${testSongs.length} results, first: "${testSongs.first.title}"'
          : '   ❌ FAILED — 0 results');
    } catch (e) { buf.writeln('   ❌ $e'); }

    // Test actual Saavn STREAM resolve (the real playback path)
    buf.writeln('▶ ${_kPipedInstances.length + 3}. Saavn STREAM resolve');
    String? resolvedUrl;
    if (testSongs.isNotEmpty) {
      final testSong = testSongs.first;
      buf.writeln('   song: "${testSong.title}" id=${testSong.id}');
      try {
        final sw = Stopwatch()..start();
        resolvedUrl = await resolveStreamUrl(testSong, forceRefresh: true)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        sw.stop();
        buf.writeln(resolvedUrl != null
            ? '   ✅ OK (${sw.elapsedMilliseconds}ms)\n   FULL URL:\n   $resolvedUrl'
            : '   ❌ FAILED — resolveStreamUrl returned null');
      } catch (e) {
        buf.writeln('   ❌ EXCEPTION: $e');
      }
    } else {
      buf.writeln('   ⏭ skipped — no test song available');
    }

    // Test REAL PLAYBACK — this is what was missing. Resolve succeeding
    // only proves the URL exists; it says nothing about whether
    // just_audio/ExoPlayer can actually open and decode it.
    //
    // v5 CHANGE: previously this spun up a THROWAWAY `AudioPlayer()` with
    // its own one-off setAudioSource(..., preload: true) call. That is a
    // DIFFERENT code path from the real app: production playback always
    // goes through `AurumAudioHandler` (audio_handler.dart) via
    // `playSong()`/`playQueue()`, which uses `preload: false`, a
    // `ConcatenatingAudioSource` wrapper, volume-mute/stop choreography,
    // and the shared `_player` instance with all its listeners attached.
    // A throwaway player skips ALL of that — so this test could pass or
    // fail independently of whether real in-app playback works, which is
    // exactly the ambiguity that made this bug hard to pin down.
    //
    // Fix: if [realPlaybackTest] is supplied (wired from home_screen.dart
    // to PlayerProvider.playSong, which forwards to the real
    // AurumAudioHandler), use the REAL handler/player instead of a
    // throwaway one. Falls back to the old throwaway-player behaviour if
    // no callback is supplied, so this function still works standalone.
    buf.writeln('▶ ${_kPipedInstances.length + 4}. REAL PLAYBACK TEST'
        '${realPlaybackTest != null ? " (via live AurumAudioHandler)" : " (throwaway player — no handler wired)"}');
    if (resolvedUrl != null && testSongs.isNotEmpty) {
      if (realPlaybackTest != null) {
        try {
          final sw = Stopwatch()..start();
          final result = await realPlaybackTest(testSongs.first)
              .timeout(const Duration(seconds: 15));
          sw.stop();
          buf.writeln('   setAudioSource+play attempted in ${sw.elapsedMilliseconds}ms');
          buf.writeln(result.success
              ? '   ✅ PLAYBACK CONFIRMED — position advanced to ${result.positionMs}ms, '
                'state=${result.processingState}'
              : '   ❌ PLAYBACK FAILED — position ${result.positionMs}ms after wait, '
                'state=${result.processingState}'
                '${result.errorMessage != null ? "\n      ERROR: ${result.errorMessage}" : ""}');
        } catch (e, st) {
          buf.writeln('   ❌ PLAYBACK EXCEPTION (real handler): $e');
          if (e is PlayerException) {
            buf.writeln('      code=${e.code} message=${e.message}');
          }
          buf.writeln('      STACK: $st');
          debugPrint('[Diagnostics] Real-handler playback test stack: $st');
        }
      } else {
        // Legacy throwaway-player fallback — kept so this function still
        // works if no PlayerProvider callback was wired in from the UI.
        final testPlayer = AudioPlayer();
        try {
          final sw = Stopwatch()..start();
          await testPlayer.setAudioSource(
            AudioSource.uri(
              Uri.parse(resolvedUrl),
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 11; Pixel 4) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
              },
            ),
            preload: true,
          ).timeout(const Duration(seconds: 15));
          sw.stop();
          final dur = testPlayer.duration;
          buf.writeln('   ✅ setAudioSource OK (${sw.elapsedMilliseconds}ms), '
              'duration=${dur ?? "null"}, state=${testPlayer.processingState}');

          await testPlayer.play();
          await Future.delayed(const Duration(seconds: 2));
          final pos = testPlayer.position;
          buf.writeln(pos.inMilliseconds > 200
              ? '   ✅ PLAYBACK CONFIRMED — position advanced to ${pos.inMilliseconds}ms'
              : '   ❌ PLAYBACK STUCK — position still ${pos.inMilliseconds}ms after 2s play, '
                'processingState=${testPlayer.processingState}');
        } catch (e, st) {
          buf.writeln('   ❌ PLAYBACK EXCEPTION: $e');
          if (e is PlayerException) {
            buf.writeln('      code=${e.code} message=${e.message}');
          }
          buf.writeln('      STACK: $st');
          debugPrint('[Diagnostics] Playback test stack: $st');
        } finally {
          await testPlayer.dispose();
        }
      }
    } else {
      buf.writeln('   ⏭ skipped — no resolved URL/test song to test');
    }

    return buf.toString();
  }

  static String _proxiedSaavnUrl(String url) {
    final decoded = Uri.decodeComponent(url);
    if (decoded.contains('/stream-proxy?url=') || url.contains('/stream-proxy?url=')) {
      return decoded; // already proxied, never double-wrap
    }
    if (decoded.contains('saavncdn.com') || url.contains('saavncdn.com')) {
      return '$_saavn/stream-proxy?url=${Uri.encodeComponent(decoded)}';
    }
    return decoded;
  }
}

// =============================================================================
// INTERNAL VALUE OBJECTS
// =============================================================================
class _CachedStream {
  final String   url;
  final DateTime resolvedAt;
  _CachedStream(this.url) : resolvedAt = DateTime.now();
  bool get isExpired =>
      DateTime.now().difference(resolvedAt) > ApiService._streamTtl;
}

class _CachedSearch {
  final List<Song> results;
  final DateTime   cachedAt;
  _CachedSearch(this.results) : cachedAt = DateTime.now();
  bool get isExpired =>
      DateTime.now().difference(cachedAt) > ApiService._searchTtl;
}

class _ScoredSong {
  final Song   song;
  final double score;
  _ScoredSong(this.song, this.score);
}

class _SignalResult {
  final List<Song> songs;
  final int        weight;
  _SignalResult(this.songs, this.weight);
}

class _SectionQuery {
  final String query;
  final String label;
  final bool priority;
  _SectionQuery(this.query, this.label, {this.priority = false});
}

class _PoolEntry {
  final String query;
  final String label;
  const _PoolEntry(this.query, this.label);
}

class _ArtistEntry {
  final String query;
  final String displayName;
  const _ArtistEntry(this.query, this.displayName);
}

class ArtistSimple {
  final String id;
  final String name;
  final String imageUrl;
  const ArtistSimple({required this.id, required this.name, required this.imageUrl});
}
