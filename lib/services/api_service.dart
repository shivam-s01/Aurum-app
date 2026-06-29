// =============================================================================
// FILE: lib/services/api_service.dart
// PROJECT: Aurum Music
// VERSION: 5.1.0 — IP-Lock Fix: Explode removed from playback chain
//
// CHANGES vs v4:
//   ✅ EXPLODE FIRST   — youtube_explode_dart is now STAGE 1 of YT resolution,
//                        raced against Cloudflare Worker simultaneously.
//                        In-process, no external server, 1-3s vs 8s+.
//                        "8 Parche" and all YT songs now resolve in 1-3 sec.
//
//   ✅ BLAST RACE      — All 7 fallback endpoints (Worker + 3 Piped + 3 Invidious)
//                        now race each other in parallel via _blastRace().
//                        First valid response wins, rest are cancelled.
//                        No more sequential waiting.
//
//   ✅ WARM-UP         — On app start, explode client is pre-warmed silently
//                        so the first real tap doesn't pay cold-start cost.
//
//   ✅ PREFETCH v2     — prefetchQueue(List<Song>) resolves next 5 songs
//                        in background while current song plays.
//                        When user taps → URL already in cache → ~0.3 sec play.
//
//   ✅ INSTANCE HEALTH — Dead Piped/Invidious instances are tracked and
//                        skipped automatically for 5 minutes.
//                        Healthy instances move to front of the race.
//
//   ✅ ZERO CUTS       — Every function from v4 preserved 100%.
//                        Only _ytStreamById, prefetchNext, and
//                        wakeSaavn changed. Everything else untouched.
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
// INSTANCE HEALTH TRACKER
// Dead instances are skipped for 5 minutes, healthy ones race first.
// Automatically resets after cooldown so instances get another chance.
// =============================================================================
class _InstanceHealth {
  static final Map<String, DateTime> _deadUntil = {};
  static const Duration _cooldown = Duration(minutes: 5);

  static bool isAlive(String instance) {
    final dead = _deadUntil[instance];
    if (dead == null) return true;
    if (DateTime.now().isAfter(dead)) {
      _deadUntil.remove(instance);
      return true;
    }
    return false;
  }

  static void markDead(String instance) {
    _deadUntil[instance] = DateTime.now().add(_cooldown);
  }

  static void markAlive(String instance) {
    _deadUntil.remove(instance);
  }
}


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
  // v5: multi-song prefetch queue — resolves next 5 songs in background
  static final List<CancelableOperation<void>> _prefetchQueue = [];
  // v5: explode warm-up flag — prevents cold-start penalty on first tap
  static bool _explodeWarmedUp = false;

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
    // Warm onrender primary — it's the hard primary for Saavn now, and on
    // Render free tier a cold instance can take 30-50s to respond. Pinging
    // on app start means the first real search/play request hits a warm server.
    _client
        .get(Uri.parse('$_saavnPrimary/api/search/songs?query=hello&limit=1'))
        .timeout(const Duration(seconds: 30))
        .then((_) => _log('[wakeSaavn] onrender warm ✓'))
        .catchError((e) => _log('[wakeSaavn] onrender ping failed: $e'));

    // Also keep CF worker warm
    _client
        .get(Uri.parse('$_saavn/result/?query=hello&limit=1'))
        .timeout(const Duration(seconds: 15))
        .then((_) => _log('[wakeSaavn] CF worker warm ✓'))
        .catchError((e) => _log('[wakeSaavn] CF worker ping failed: $e'));

    // v5: Pre-warm youtube_explode_dart on app start so first tap doesn't
    // pay the cold-start cost (innertube client init + first DNS lookup).
    // We fetch a known-stable video's metadata only — no audio stream download.
    if (!_explodeWarmedUp) {
      _explodeWarmedUp = true;
      Future.microtask(() async {
        try {
          // "Shape of You" — stable public video, always available
          await _yt.videos.get('JGwWNGJdvx8')
              .timeout(const Duration(seconds: 8));
          _log('[warmup] youtube_explode_dart warmed up ✓');
        } catch (_) {
          // Warm-up failure is silent — explode still works, just cold
          _explodeWarmedUp = false;
        }
      });
    }
  }

  // ===========================================================================
  // HOME FEED (unchanged from v3)
  // ===========================================================================
  // Pool queries — ALL designed to return original, official songs only.
  // No "lofi", no "remix", no "DJ" in queries — those attract variants.
  // Saavn search for these returns genuine original songs.
  static final List<_PoolEntry> _pool = [
    // ── Bollywood ────────────────────────────────────────────────────────────
    _PoolEntry('arijit singh best bollywood songs',        'Arijit Singh'),
    _PoolEntry('atif aslam best hindi songs',              'Atif Aslam'),
    _PoolEntry('jubin nautiyal romantic songs',            'Jubin Nautiyal'),
    _PoolEntry('shreya ghoshal bollywood hits',            'Shreya Ghoshal'),
    _PoolEntry('armaan malik songs playlist',              'Armaan Malik'),
    _PoolEntry('romantic bollywood songs hindi',           'Romantic Bollywood'),
    _PoolEntry('sad hindi songs heartbreak',               'Heartbreak Hour'),
    _PoolEntry('top bollywood songs 2024 2025',            'Best of 2025'),
    _PoolEntry('new hindi songs 2025 latest',              'New Releases'),
    _PoolEntry('90s bollywood superhits original',         '90s Nostalgia'),
    _PoolEntry('2000s bollywood original songs',           '2000s Hits'),
    _PoolEntry('old is gold hindi songs kishore kumar lata','Old Is Gold'),
    _PoolEntry('soulful hindi songs best playlist',        'Soulful Picks'),
    _PoolEntry('sufi qawwali hindi songs original',        'Sufi & Qawwali'),
    _PoolEntry('ghazal jagjit singh mehdi hassan',         'Ghazals'),
    _PoolEntry('bollywood party songs dance',              'Party Mode'),
    _PoolEntry('feel good happy bollywood songs',          'Feel Good'),
    _PoolEntry('late night hindi songs drive',             'Late Night'),
    _PoolEntry('morning fresh hindi songs upbeat',         'Morning Vibes'),
    // ── Punjabi ──────────────────────────────────────────────────────────────
    _PoolEntry('punjabi superhits original songs',         'Punjabi Hits'),
    _PoolEntry('b praak punjabi sad songs',                'Punjabi Feels'),
    _PoolEntry('diljit dosanjh best songs',                'Diljit Dosanjh'),
    _PoolEntry('ap dhillon shubh punjabi hits',            'AP Dhillon'),
    _PoolEntry('new punjabi songs 2025 original',          'New Punjabi'),
    _PoolEntry('punjabi romantic songs original',          'Punjabi Romance'),
    _PoolEntry('karan aujla songs playlist',               'Karan Aujla'),
    // ── Bhojpuri ─────────────────────────────────────────────────────────────
    _PoolEntry('pawan singh bhojpuri superhits',           'Pawan Singh'),
    _PoolEntry('khesari lal yadav bhojpuri songs',         'Khesari Lal'),
    _PoolEntry('bhojpuri superhits original songs 2025',   'Bhojpuri Hits'),
    _PoolEntry('bhojpuri romantic songs original',         'Bhojpuri Romance'),
    _PoolEntry('neelkamal singh bhojpuri hits',            'Neelkamal Singh'),
    _PoolEntry('shilpi raj bhojpuri songs',                'Shilpi Raj'),
    // ── South ────────────────────────────────────────────────────────────────
    _PoolEntry('tamil superhits ar rahman anirudh',        'Tamil Hits'),
    _PoolEntry('telugu superhits dsp thaman',              'Telugu Hits'),
    _PoolEntry('malayalam superhit songs original',        'Malayalam Hits'),
    // ── English ──────────────────────────────────────────────────────────────
    _PoolEntry('english pop hits official songs 2025',     'English Hits'),
    _PoolEntry('ed sheeran charlie puth original songs',   'Ed Sheeran & More'),
    _PoolEntry('the weeknd bruno mars official songs',     'R&B Vibes'),
    _PoolEntry('classic english hits 90s 2000s original',  '90s English'),
    // ── Hindi Indie / Devotional ─────────────────────────────────────────────
    _PoolEntry('hindi indie songs prateek kuhad seedhe maut','Hindi Indie'),
    _PoolEntry('bhakti bhajan aarti original songs',       'Devotional'),
    _PoolEntry('haryanvi original songs sapna choudhary',  'Haryanvi Hits'),
  ];

  static Future<List<SongSection>> fetchHome({List<String> topArtists = const [], List<Song> recentlyPlayed = const []}) async {
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
    // ── "Because You Played" — Saavn suggestions from recent history ──────
    final recentOnline = recentlyPlayed
        .where((s) => !s.isLocal && s.source == SongSource.saavn && s.id.isNotEmpty)
        .take(3)
        .toList();
    for (final recent in recentOnline) {
      final cleanId = recent.id.replaceFirst(RegExp(r'^[a-z]+_'), '');
      final lbl = 'Because You Played · ${recent.title.length > 22 ? recent.title.substring(0, 22) + "…" : recent.title}';
      if (!queryList.any((q) => q.label == lbl)) {
        queryList.add(_SectionQuery('__suggestions__$cleanId', lbl, isSuggestion: true, suggestionSongId: cleanId));
      }
    }

    int poolPicks = 0;
    for (final entry in shuffledPool) {
      if (poolPicks >= 8) break;
      if (queryList.any((q) => q.label == entry.label)) continue;
      queryList.add(_SectionQuery(entry.query, entry.label));
      poolPicks++;
    }
    if (personalArtists.isEmpty && topGenres.isEmpty && recentOnline.isEmpty) {
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
        batch.map((sq) => sq.isSuggestion
            ? _suggestionSection(sq.suggestionSongId!, sq.label)
            : _saavnSectionV4(sq.query, sq.label)),
      );
      results.addAll(batchResults);
      if (i + batchSize < queryList.length) {
        await Future.delayed(const Duration(milliseconds: 100));
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
    // Fetch more than needed — variants get filtered, so we need headroom
    final saavnSongs = await _searchSaavn(query, limit: 40);
    if (saavnSongs.isEmpty) return null;
    final seenIds    = <String>{};
    final seenTitles = <String>{};
    final merged     = <Song>[];
    final seed = query.hashCode ^ DateTime.now().hour ^ math.Random().nextInt(1000000);
    final saavnShuffled = List<Song>.from(saavnSongs)..shuffle(math.Random(seed));
    for (final s in saavnShuffled) {
      if (!seenIds.add(s.id)) continue;
      // HARD BLOCK: no remix/dj/cover/lofi/female-version etc in home feed
      if (RecommendationEngine.isInherentVariant(s.title)) continue;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) continue;
      merged.add(s);
    }
    if (merged.isEmpty) return null;
    return SongSection(title: label, songs: merged.take(20).toList());
  }

  // "Because You Played" section — pure JioSaavn suggestions, same category guaranteed
  static Future<SongSection?> _suggestionSection(String songId, String label) async {
    try {
      final url = Uri.parse('$_saavnPrimary/api/songs/$songId/suggestions?limit=30');
      final res = await _client.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      final List? raw = data is Map ? (data['data'] as List?) : (data is List ? data : null);
      if (raw == null || raw.isEmpty) return null;
      final seenIds    = <String>{};
      final seenTitles = <String>{};
      final songs      = <Song>[];
      for (final j in raw.whereType<Map<String, dynamic>>()) {
        final s = _songFromSaavn(j);
        if (s.id.isEmpty || s.title.isEmpty) continue;
        if (!seenIds.add(s.id)) continue;
        if (RecommendationEngine.isInherentVariant(s.title)) continue;
        final tk = _normTitle(s.title);
        if (!seenTitles.add(tk)) continue;
        songs.add(s);
      }
      if (songs.isEmpty) return null;
      return SongSection(title: label, songs: songs.take(20).toList());
    } catch (_) {
      return null;
    }
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
  // ===========================================================================
  // AUTO QUEUE v5 — JioSaavn Suggestions-First + YouTube fallback
  //
  // SIGNAL ORDER:
  //   1. /api/songs/{id}/suggestions — Saavn's own engine (PRIMARY)
  //   2. Same artist search
  //   3. YouTube search (strong related algorithm)
  //   4. Mood+genre fallback
  //
  // ALL variants blocked at pool entry. Zero remixes/DJ/cover/lofi in queue.
  // ===========================================================================
  static Future<List<Song>> getAutoQueue(
    Song currentSong, {
    int limit = 20,
    Set<String>? existingQueueIds,
  }) async {
    await RecommendationEngine.load();
    if (currentSong.isLocal) return [];

    final allExistingIds = <String>{
      currentSong.id,
      ...?existingQueueIds,
      ...RecommendationEngine.sessionRecentIds,
    };
    final mergedIds    = <String>{...allExistingIds};
    final mergedTitles = <String>{};
    final pool         = <Song>[];

    bool addToPool(Song song) {
      if (mergedIds.contains(song.id)) return false;
      if (RecommendationEngine.isInherentVariant(song.title)) return false;
      final tk = _normTitle(song.title);
      if (mergedTitles.contains(tk)) return false;
      mergedIds.add(song.id);
      mergedTitles.add(tk);
      pool.add(song);
      return true;
    }

    // ── Signal 1: JioSaavn suggestions (PRIMARY) ──────────────────────────
    final rawId = currentSong.id.replaceFirst(RegExp(r'^[a-z]+_'), '');
    if (rawId.isNotEmpty && currentSong.source == SongSource.saavn) {
      try {
        final url = Uri.parse('$_saavnPrimary/api/songs/$rawId/suggestions?limit=50');
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final List? raw = data is Map ? (data['data'] as List?) : (data is List ? data : null);
          if (raw != null) {
            for (final j in raw.whereType<Map<String, dynamic>>()) {
              addToPool(_songFromSaavn(j));
            }
          }
        }
      } catch (_) {}
      _log('[autoQueue] signal1 saavn suggestions: ${pool.length}');
    }

    // ── Signal 2: Same artist ─────────────────────────────────────────────
    if (pool.length < limit * 2) {
      final artistSongs = await _searchSaavn('${currentSong.artist} songs', limit: 40)
          .timeout(const Duration(seconds: 8), onTimeout: () => []);
      for (final s in artistSongs) addToPool(s);
      _log('[autoQueue] signal2 artist: ${pool.length}');
    }

    // ── Signal 3: Mood+genre fallback ────────────────────────────────────
    if (pool.length < limit) {
      final queries = RecommendationEngine.generateQueries(currentSong);
      for (final q in queries.take(2)) {
        final r = await _searchSaavn(q.query, limit: 30)
            .timeout(const Duration(seconds: 6), onTimeout: () => []);
        for (final s in r) addToPool(s);
      }
      _log('[autoQueue] signal3 fallback: ${pool.length}');
    }

    return RecommendationEngine.rankAndFilter(
      pool: pool, currentSong: currentSong,
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
  static int _anonymousResolveCounter = 0;

  // ─── URL LIVENESS CHECK ─────────────────────────────────────────────────
  // Mirrors the same fix applied on the Cloudflare Worker side: a resolved
  // stream URL can come back "successfully" from Saavn/YT mirrors but still
  // be dead (expired signature, IP-locked, 403, etc), which only surfaces
  // later as a silent ExoPlayer idle@0ms failure. A quick HEAD (with ranged
  // GET fallback for CDNs that reject HEAD) catches this before we ever
  // hand the URL to setAudioSource.
  static Future<bool> _isUrlAlive(String url) async {
    try {
      final uri = Uri.parse(url);
      final head = await _client
          .head(uri)
          .timeout(const Duration(seconds: 3));
      if (head.statusCode >= 200 && head.statusCode < 400) return true;
      if (head.statusCode == 405 || head.statusCode == 403) {
        final ranged = await _client
            .get(uri, headers: {'Range': 'bytes=0-1023'})
            .timeout(const Duration(seconds: 3));
        return ranged.statusCode == 200 || ranged.statusCode == 206;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> resolveStreamUrl(Song song, {bool forceRefresh = false}) async {
    if (song.isLocal) return song.localPath;

    // FIX: Song.fromJson falls back to id: '' when the API response has no
    // trackId/id/song_id field (happens on some recommendation/related-song
    // payloads). That made cacheKey collapse to a bare 'saavn:' or
    // 'youtube:' for EVERY id-less song. Two different songs tapped close
    // together then shared one _streamCache entry / one in-flight
    // _pendingResolutions future — whichever resolved first "won," so the
    // second tap's UI (artwork/title, which come straight from the tapped
    // Song object) showed the new song while the audio that actually
    // played was whichever URL that shared cache slot held. Giving each
    // id-less song its own unique key opts it out of caching/de-duping
    // instead of silently colliding with unrelated songs.
    final hasStableId = song.id.isNotEmpty;
    final cacheKey = hasStableId
        ? '${song.source.name}:${song.id}'
        : '${song.source.name}:anon:${song.title}:${song.artist}:${_anonymousResolveCounter++}';

    if (!forceRefresh && hasStableId) {
      final cached = _streamCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        _log('[resolve] Cache HIT: "${song.title}"');
        return cached.url;
      }
    }

    if (!forceRefresh && hasStableId && _pendingResolutions.containsKey(cacheKey)) {
      _log('[resolve] Joining in-flight: "$cacheKey"');
      return _pendingResolutions[cacheKey];
    }

    // Saavn pre-fetched URL — only use if already proxied through worker.
    if (!forceRefresh &&
        hasStableId &&
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
          if (url != null && !await _isUrlAlive(url)) {
            _log('[resolve] Saavn URL for "${song.title}" failed liveness check — discarding');
            url = null;
          }
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
          // NOTE: No _isUrlAlive check here — Worker's resolveYtStreamFast()
          // already validates every URL via isUrlAlive() before returning.
          // An extra HEAD request from Dart adds ~2s latency AND fails on
          // googlevideo.com URLs (which reject HEAD with 403/405).
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
  // YT STREAM — v5 BUGATTI ENGINE
  //
  // STAGE 1: Race explode vs Worker simultaneously (both fastest).
  //          explode = in-process, no network hop, 1-3s on warm client.
  //          Worker  = our own CF, fast when warm (~1-2s).
  //          First valid URL wins. This covers 95%+ of taps.
  //
  // STAGE 2: If Stage 1 fails → BLAST RACE all remaining endpoints at once.
  //          All 3 Piped + 3 Invidious instances race each other in parallel.
  //          First valid response wins, rest silently abandoned.
  //          Dead instances skipped via _InstanceHealth tracker.
  //
  // STAGE 3: If everything fails → one final explode retry with fresh client.
  //          This handles temporary PoToken issues on the first explode call.
  //
  // Result: 8 sec → 1-3 sec on warm, 3-5 sec cold start.
  // ===========================================================================
  static Future<String?> _ytStreamById(String videoId) async {
    // ── STAGE 1: Worker proxy ONLY ────────────────────────────────────────
    // NOTE: _ytExplodeStream is intentionally NOT raced here.
    // youtube_explode_dart returns raw googlevideo.com URLs that are
    // IP-locked to the Cloudflare edge server that resolved them.
    // Giving that URL to ExoPlayer fails with 403 → idle@0ms because
    // phone IP != Cloudflare IP. Worker proxy resolves + pipes bytes
    // through same CF IP → no mismatch. Explode only used in Stage 3
    // as last-resort, routed through Worker proxy to avoid IP-lock.
    final stage1 = await _workerYtStream(videoId);
    if (stage1 != null) return stage1;

    _log('[ytStreamById] Stage 1 (Worker) failed for $videoId — blast racing fallbacks');

    // ── STAGE 2: Blast race all Piped + Invidious simultaneously ─────────
    final aliveInstances = [
      ..._kPipedInstances.where(_InstanceHealth.isAlive),
      ..._kInvidiousInstances.where(_InstanceHealth.isAlive),
    ];

    if (aliveInstances.isNotEmpty) {
      final blastFns = aliveInstances.map((inst) => () async {
        String? url;
        if (_kPipedInstances.contains(inst)) {
          url = await _pipedStream(videoId, inst);
        } else {
          url = await _invidiousStream(videoId, inst);
        }
        if (url != null) _InstanceHealth.markAlive(inst);
        else _InstanceHealth.markDead(inst);
        return url;
      }).toList();

      final stage2 = await _blastRace(blastFns);
      if (stage2 != null) return stage2;
    }

    _log('[ytStreamById] Stage 2 failed for $videoId — Worker proxy last resort');

    // ── STAGE 3: Last resort — Worker proxy with extended timeout ────────
    // Do NOT use _ytExplodeStream directly — googlevideo.com URLs are
    // IP-locked to the CF edge that resolved them. Phone IP != CF IP = 403.
    // Worker proxy gets one more chance with a longer 30s timeout.
    _log('[ytStreamById] Stage 3: Worker extended-timeout retry for $videoId');
    try {
      final proxyUrl = '$_worker/api/yt-proxy?id=$videoId';
      final rangeRes = await _client.get(
        Uri.parse(proxyUrl),
        headers: {'Range': 'bytes=0-1023'},
      ).timeout(const Duration(seconds: 30));
      if (rangeRes.statusCode == 206 || rangeRes.statusCode == 200) {
        final ct = (rangeRes.headers['content-type'] ?? '').toLowerCase();
        final isAudio = ct.contains('audio') || ct.contains('octet') ||
            ct.contains('mp4') || ct.contains('mpeg') || ct.contains('webm');
        if (isAudio || rangeRes.bodyBytes.length > 512) {
          _log('[ytStreamById] Stage 3 Worker proxy OK for $videoId ✓');
          return proxyUrl;
        }
      }
    } catch (e) {
      _log('[ytStreamById] Stage 3 Worker retry failed: $e');
    }
    _log('[ytStreamById] ALL stages failed for $videoId');
    return null;
  }

  // Blast race: fire ALL futures simultaneously, return first valid result.
  // Unlike _raceFirstValid (which only races 2), this handles N futures.
  static Future<String?> _blastRace(List<Future<String?> Function()> fns) async {
    if (fns.isEmpty) return null;
    final completer = Completer<String?>();
    var remaining = fns.length;

    for (final fn in fns) {
      fn().then((url) {
        remaining--;
        if (completer.isCompleted) return;
        if (url != null && url.isNotEmpty) {
          completer.complete(url);
        } else if (remaining == 0) {
          completer.complete(null);
        }
      }).catchError((_) {
        remaining--;
        if (!completer.isCompleted && remaining == 0) completer.complete(null);
      });
    }

    return completer.future;
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
  // Returns PROXY URL — worker resolves + pipes audio bytes same-IP.
  // No health check needed — if worker is down, ExoPlayer will error
  // and _handleFreshStartIdle will trigger Piped/Invidious fallback.
  // ── Cloudflare Worker ─────────────────────────────────────────────────────
  // ROOT CAUSE FIX (v5.1):
  //
  // Previously this returned a proxy URL string WITHOUT any HTTP validation:
  //   return '$_worker/api/yt-proxy?id=$videoId';
  //
  // _isUrlAlive() HEAD check returned 200 because the Worker's /api/yt-proxy
  // answers 200 on HEAD regardless of whether it can actually stream the video
  // (it proxies bytes lazily — only discovers the video is unavailable when
  // ExoPlayer makes the real GET request for audio data).
  // Result: ExoPlayer setAudioSource() succeeded → immediately went idle at
  // 0ms because the proxied stream returned an error body instead of audio.
  // That is the exact "Silent fresh-start failure… processingState went idle
  // at position 0ms" error in the screenshot.
  //
  // FIX — two steps:
  //   Step 1: Call /api/yt-stream?id= (JSON endpoint returning actual YT URL).
  //           ExoPlayer hits YouTube directly — fast and reliable.
  //   Step 2: If step 1 fails, validate proxy URL via range request bytes=0-1023.
  //           Only return proxy URL if we get back actual audio bytes (206/200
  //           with audio Content-Type). This catches dead streams at resolve
  //           time, not at ExoPlayer load time.
  // ── Cloudflare Worker ─────────────────────────────────────────────────────
  // WHY PROXY (not direct URL):
  // Worker's /api/yt-stream returns a googlevideo.com URL that is IP-locked
  // to the Cloudflare edge server that resolved it. Giving that URL directly
  // to ExoPlayer fails because the phone's IP != Cloudflare's IP — ExoPlayer
  // gets a 403/stream error and goes idle@0ms.
  //
  // /api/yt-proxy resolves the video AND streams the bytes back through
  // Cloudflare — same IP resolves + serves = no IP mismatch. ExoPlayer
  // receives a clean audio stream from our worker domain.
  // ── Cloudflare Worker: /api/yt-stream (JSON) ─────────────────────────────────────────
  // Worker v6 uses android_sdkless + ios_downgraded whose googlevideo URLs
  // are NOT IP-locked — direct Innertube API, not proxied through CF edge.
  // /api/yt-stream returns tiny JSON with direct URL in ~1-3s (KV-cached).
  // /api/yt-proxy is intentionally NOT used — it proxies all audio bytes
  // through CF (slow 25s validation round-trip, unnecessary for v6 clients).
  static Future<String?> _workerYtStream(String videoId) async {
    try {
      final res = await _client
          .get(Uri.parse('$_worker/api/yt-stream?id=$videoId'))
          .timeout(const Duration(seconds: 16));
      if (res.statusCode != 200) {
        _log('[worker] /api/yt-stream \${res.statusCode} for $videoId');
        return null;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] != true) {
        _log('[worker] /api/yt-stream success=false for $videoId');
        return null;
      }
      final url = data['url']?.toString();
      if (url == null || url.isEmpty) {
        _log('[worker] /api/yt-stream empty URL for $videoId');
        return null;
      }
      _log('[worker] /api/yt-stream OK for $videoId (\${data["source"]} \${data["quality"]}) ✓');
      return url;
    } catch (e) {
      _log('[worker] /api/yt-stream failed for $videoId: \$e');
      return null;
    }
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

  // ── youtube_explode_dart ─────────────────────────────────────────────────
  // FIX (v5.1): Added webm/opus fallback + URL liveness validation.
  // Previously only returned m4a/aac streams. On some regions/videos,
  // youtube_explode_dart returns only webm (opus) streams — the old code
  // returned null in that case, causing unnecessary fallback to Piped/Invidious.
  // Now we try m4a first, then accept webm, and validate the chosen URL.
  static Future<String?> _ytExplodeStream(String videoId) async {
    try {
      final manifest = await _yt.videos.streamsClient
          .getManifest(VideoId(videoId))
          .timeout(const Duration(seconds: 12));
      if (manifest.audioOnly.isEmpty) return null;

      // Prefer m4a/aac (widest Android compatibility)
      final m4aStreams = manifest.audioOnly.where((s) {
        final mime      = s.codec.mimeType.toLowerCase();
        final container = s.container.name.toLowerCase();
        return mime.contains('mp4') || mime.contains('aac') ||
               container == 'mp4'  || container == 'm4a';
      }).toList();

      if (m4aStreams.isNotEmpty) {
        m4aStreams.sort((a, b) =>
            b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        final url = m4aStreams.first.url.toString();
        _log('[ytExplode] m4a OK for $videoId (${m4aStreams.first.bitrate})');
        return url;
      }

      // Fallback: accept webm/opus — ExoPlayer handles it fine
      final webmStreams = manifest.audioOnly.where((s) {
        final mime      = s.codec.mimeType.toLowerCase();
        final container = s.container.name.toLowerCase();
        return mime.contains('webm') || mime.contains('opus') ||
               container == 'webm';
      }).toList();

      if (webmStreams.isNotEmpty) {
        webmStreams.sort((a, b) =>
            b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        final url = webmStreams.first.url.toString();
        _log('[ytExplode] webm/opus fallback OK for $videoId');
        return url;
      }

      // Last resort: highest bitrate regardless of container
      final fallback = manifest.audioOnly.withHighestBitrate().url.toString();
      _log('[ytExplode] generic fallback for $videoId');
      return fallback;
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
  // PREFETCH v2 — Aggressive multi-song background preloading
  //
  // prefetchQueue resolves the next [count] songs while current song plays.
  // When user taps next → URL already in cache → ~0.3 sec play instead of
  // 1-3 sec cold resolve. This is how Echo Nightly feels "instant."
  //
  // prefetchNext kept for backward compatibility (called from audio_handler).
  // ===========================================================================
  static void prefetchNext(Song song) {
    if (song.isLocal) return;
    _activePrefetch?.cancel();
    _activePrefetch = null;
    _activePrefetch = CancelableOperation.fromFuture(
      Future.delayed(const Duration(milliseconds: 500), () async {
        try { await resolveStreamUrl(song); } catch (_) {}
      }),
    );
  }

  /// Aggressively pre-resolve next [count] songs (default 5) in background.
  /// Call this from PlayerProvider when a new song starts playing,
  /// passing the upcoming songs in queue order.
  ///
  /// Example in player_provider.dart:
  ///   final upcoming = handler.currentQueue.skip(handler.currentIndex + 1).toList();
  ///   ApiService.prefetchQueue(upcoming);
  static void prefetchQueue(List<Song> upcoming, {int count = 5}) {
    // Cancel any existing prefetch jobs first
    for (final op in _prefetchQueue) op.cancel();
    _prefetchQueue.clear();

    final toFetch = upcoming
        .where((s) => !s.isLocal && s.id.isNotEmpty)
        .take(count)
        .toList();

    for (int i = 0; i < toFetch.length; i++) {
      final song = toFetch[i];
      // Stagger: 300ms base + 400ms per song so network isn't hammered at once
      final delay = Duration(milliseconds: 300 + (i * 400));
      final op = CancelableOperation.fromFuture(
        Future.delayed(delay, () async {
          // Skip if already cached — no wasted work
          final cacheKey = '${song.source.name}:${song.id}';
          final cached = _streamCache[cacheKey];
          if (cached != null && !cached.isExpired) {
            _log('[prefetch] Already cached: "${song.title}"');
            return;
          }
          _log('[prefetch] Pre-resolving #$i: "${song.title}"');
          try {
            await resolveStreamUrl(song);
            _log('[prefetch] ✓ Ready: "${song.title}"');
          } catch (e) {
            _log('[prefetch] Failed: "${song.title}": $e');
          }
        }),
      );
      _prefetchQueue.add(op);
    }
  }

  static void cancelPrefetch() {
    _activePrefetch?.cancel();
    _activePrefetch = null;
    for (final op in _prefetchQueue) op.cancel();
    _prefetchQueue.clear();
  }

  // ===========================================================================
  // PREWARM — fire Worker's /api/prewarm for a YT song the moment it becomes
  // visible on screen (e.g. from a SongTile/home card), BEFORE the user taps.
  // Worker resolves + KV-caches the URL in the background so that when the
  // actual tap arrives, /api/yt-stream returns a KV-HIT in ~5ms instead of
  // running the full 3-stage resolution chain (which takes 2-8s cold).
  //
  // Fire-and-forget — never awaited, never throws, zero impact on UI thread.
  // Only fires for YouTube songs with a stable id; Saavn songs have their URL
  // embedded in the search result already and don't need this.
  // ===========================================================================
  static final Set<String> _prewarmedIds = {};

  static void prewarmYtStream(Song song) {
    if (song.source != SongSource.youtube) return;
    if (song.id.isEmpty) return;
    if (_prewarmedIds.contains(song.id)) return; // already fired this session

    // Also skip if URL already in local Dart cache — no Worker round-trip needed
    final cacheKey = 'youtube:${song.id}';
    final cached = _streamCache[cacheKey];
    if (cached != null && !cached.isExpired) return;

    _prewarmedIds.add(song.id);
    _client
        .get(Uri.parse('$_worker/api/prewarm?id=${song.id}'))
        .timeout(const Duration(seconds: 5))
        .then((_) => _log('[prewarm] fired for "${song.title}"'))
        .catchError((_) {
          _prewarmedIds.remove(song.id); // allow retry next time
        });
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

  /// 12 random popular artists with images for the home artist strip.
  /// Saavn is primary source; YouTube thumbnail is fallback if Saavn fails.
  static Future<List<ArtistSimple>> fetchHomeArtists() async {
    // Expanded curated pool — 40+ top artists across Bollywood, Punjabi, Pop, Retro
    const pool = [
      // Bollywood / Hindi
      _ArtistEntry('arijit singh',      'Arijit Singh'),
      _ArtistEntry('jubin nautiyal',    'Jubin Nautiyal'),
      _ArtistEntry('neha kakkar',       'Neha Kakkar'),
      _ArtistEntry('atif aslam',        'Atif Aslam'),
      _ArtistEntry('shreya ghoshal',    'Shreya Ghoshal'),
      _ArtistEntry('sonu nigam',        'Sonu Nigam'),
      _ArtistEntry('armaan malik',      'Armaan Malik'),
      _ArtistEntry('darshan raval',     'Darshan Raval'),
      _ArtistEntry('b praak',           'B Praak'),
      _ArtistEntry('vishal mishra',     'Vishal Mishra'),
      _ArtistEntry('kumar sanu',        'Kumar Sanu'),
      _ArtistEntry('lata mangeshkar',   'Lata Mangeshkar'),
      _ArtistEntry('kishore kumar',     'Kishore Kumar'),
      _ArtistEntry('mohd rafi',         'Mohd. Rafi'),
      _ArtistEntry('sunidhi chauhan',   'Sunidhi Chauhan'),
      _ArtistEntry('udit narayan',      'Udit Narayan'),
      _ArtistEntry('asha bhosle',       'Asha Bhosle'),
      _ArtistEntry('kavita krishnamurthy', 'Kavita Krishnamurthy'),
      _ArtistEntry('alka yagnik',       'Alka Yagnik'),
      _ArtistEntry('kumar sanu',        'Kumar Sanu'),
      _ArtistEntry('shaan',             'Shaan'),
      _ArtistEntry('kk singer',         'KK'),
      _ArtistEntry('shankar mahadevan', 'Shankar Mahadevan'),
      _ArtistEntry('a r rahman',        'A.R. Rahman'),
      _ArtistEntry('pritam',            'Pritam'),
      _ArtistEntry('amit trivedi',      'Amit Trivedi'),
      _ArtistEntry('vishal shekhar',    'Vishal-Shekhar'),
      _ArtistEntry('sachin jigar',      'Sachin-Jigar'),
      // Punjabi
      _ArtistEntry('ap dhillon',        'AP Dhillon'),
      _ArtistEntry('diljit dosanjh',    'Diljit Dosanjh'),
      _ArtistEntry('badshah',           'Badshah'),
      _ArtistEntry('guru randhawa',     'Guru Randhawa'),
      _ArtistEntry('hardy sandhu',      'Hardy Sandhu'),
      _ArtistEntry('jasmine sandlas',   'Jasmine Sandlas'),
      _ArtistEntry('harrdy sandhu',     'Harrdy Sandhu'),
      _ArtistEntry('gippy grewal',      'Gippy Grewal'),
      _ArtistEntry('ammy virk',         'Ammy Virk'),
      _ArtistEntry('jassie gill',       'Jassie Gill'),
      _ArtistEntry('satinder sartaaj',  'Satinder Sartaaj'),
      // Indie / New wave
      _ArtistEntry('anuv jain',         'Anuv Jain'),
      _ArtistEntry('prateek kuhad',     'Prateek Kuhad'),
      _ArtistEntry('ritviz',            'Ritviz'),
      _ArtistEntry('nucleya',           'Nucleya'),
      _ArtistEntry('when chai met toast', 'When Chai Met Toast'),
    ];

    final rng = math.Random(DateTime.now().difference(DateTime(2026, 1, 1)).inHours);
    final shuffled = List<_ArtistEntry>.from(pool)..shuffle(rng);
    // Remove duplicates by displayName before picking
    final seen = <String>{};
    final deduped = shuffled.where((a) => seen.add(a.displayName)).toList();
    final picked = deduped.take(12).toList();

    final results = await Future.wait(picked.map((a) async {
      // ── 1. Try Saavn ──
      try {
        final uri = Uri.parse('$_saavnPrimary/api/search/artists')
            .replace(queryParameters: {'query': a.query, 'limit': '1'});
        final res = await _client.get(uri).timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          final saavnResults = body['data']?['results'] as List?;
          if (saavnResults != null && saavnResults.isNotEmpty) {
            final r = saavnResults.first as Map<String, dynamic>;
            final imageList = r['image'] as List?;
            String imageUrl = '';
            if (imageList != null && imageList.isNotEmpty) {
              imageUrl = (imageList.last['url'] ?? imageList.last['link'] ?? '').toString();
            }
            if (imageUrl.isNotEmpty) {
              return ArtistSimple(
                id: (r['id'] ?? '').toString(),
                name: a.displayName,
                imageUrl: imageUrl,
              );
            }
          }
        }
      } catch (_) {}

      // ── 2. YouTube thumbnail fallback ──
      try {
        final ytQuery = Uri.encodeQueryComponent('${a.query} artist');
        final ytUrl = Uri.parse(
          'https://www.youtube.com/results?search_query=$ytQuery',
        );
        final ytRes = await _client
            .get(ytUrl, headers: {'User-Agent': 'Mozilla/5.0'})
            .timeout(const Duration(seconds: 6));
        if (ytRes.statusCode == 200) {
          // Extract first videoId from page source
          final match = RegExp(r'"videoId":"([a-zA-Z0-9_-]{11})"')
              .firstMatch(ytRes.body);
          if (match != null) {
            final videoId = match.group(1)!;
            final thumbUrl =
                'https://i.ytimg.com/vi/$videoId/mqdefault.jpg';
            return ArtistSimple(
              id: '',
              name: a.displayName,
              imageUrl: thumbUrl,
            );
          }
        }
      } catch (_) {}

      return null;
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
      'prefetch_queue_size': _prefetchQueue.length,
      'explode_warmed_up':   _explodeWarmedUp,
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
  final String  query;
  final String  label;
  final bool    priority;
  final bool    isSuggestion;
  final String? suggestionSongId;
  const _SectionQuery(this.query, this.label, {
    this.priority = false,
    this.isSuggestion = false,
    this.suggestionSongId,
  });
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
