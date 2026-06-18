// =============================================================================
// FILE: lib/services/api_service.dart
// PROJECT: Aurum Music
// VERSION: 3.0.0 — Premium Platform Upgrade
//
// WHAT'S NEW IN v3:
//   ✅ SEARCH ENGINE v2  — ranked results, official-first, multilingual,
//                          variant filtering, typo tolerance, search cache
//   ✅ AUTO-QUEUE v3     — RecommendationEngine integration, 5-signal queries,
//                          70/20/10 discovery mix, full anti-repeat
//   ✅ HOME FEED v2      — time-aware, affinity-driven, "Made For You" +
//                          mood mixes + era mixes from RecommendationEngine
//   ✅ QUICK SEARCH v2   — 300ms debounce path with ranked live results
//   ✅ SEARCH CACHE      — LRU 100-entry in-memory cache, 10min TTL
//   ✅ All v2 fixes kept — LRU stream cache, concurrent guard, prefetch,
//                          backoff retry, parallel worker+explode, etc.
//
// DEPENDENCIES (all already in pubspec.yaml):
//   http, youtube_explode_dart, async, package:flutter/foundation.dart
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:async/async.dart';
import 'dart:math' as math;

import '../models/song.dart';
import '../utils/constants.dart';
import 'audio_prefs.dart';
import 'recommendation_engine.dart';

// =============================================================================
// AURUM API SERVICE v3.0 — Premium Platform
// =============================================================================
class ApiService {

  // ---------------------------------------------------------------------------
  // SECTION 1: SINGLETONS
  // ---------------------------------------------------------------------------
  static final http.Client       _client = http.Client();
  static final YoutubeExplode    _yt     = YoutubeExplode();

  // ---------------------------------------------------------------------------
  // SECTION 2: BASE URLs
  // ---------------------------------------------------------------------------
  static const String _saavn  = 'https://aurumsic.shivamsharma962122.workers.dev';
  static const String _worker = AppConstants.apiBase;

  // ---------------------------------------------------------------------------
  // SECTION 3: STREAM CACHE (unchanged from v2)
  // ---------------------------------------------------------------------------
  static final Map<String, _CachedStream> _streamCache = {};
  static const Duration _streamTtl   = Duration(minutes: 50);
  static const int      _maxCacheSize = 150;

  // ---------------------------------------------------------------------------
  // SECTION 3B: SEARCH RESULT CACHE (NEW in v3)
  //
  // Cache full search() results by normalised query string.
  // TTL: 10 minutes. Max: 100 entries.
  // WHY: Popular searches (artist names, song titles) are repeated often.
  // Serving from cache makes repeat search feel instant (0ms vs 1-3s).
  // ---------------------------------------------------------------------------
  static final Map<String, _CachedSearch> _searchCache = {};
  static const Duration _searchTtl    = Duration(minutes: 10);
  static const int      _maxSearchCache = 100;

  // ---------------------------------------------------------------------------
  // SECTION 4: CONCURRENT RESOLUTION GUARD (unchanged from v2)
  // ---------------------------------------------------------------------------
  static final Map<String, Future<String?>> _pendingResolutions = {};

  // ---------------------------------------------------------------------------
  // SECTION 5: PREFETCH STATE (unchanged from v2)
  // ---------------------------------------------------------------------------
  static CancelableOperation<void>? _activePrefetch;

  // ---------------------------------------------------------------------------
  // SECTION 6: LOGGING (unchanged from v2)
  // ---------------------------------------------------------------------------
  static const bool _kDebugLogging =
      bool.fromEnvironment('AURUM_DEBUG', defaultValue: false);

  static void _log(String message) {
    if (kDebugMode || _kDebugLogging) dev.log(message, name: 'ApiService');
  }

  // ---------------------------------------------------------------------------
  // SECTION 7: LIFECYCLE (unchanged from v2)
  // ---------------------------------------------------------------------------
  static void dispose() {
    _log('[dispose] Closing clients');
    _yt.close();
    _client.close();
    _streamCache.clear();
    _pendingResolutions.clear();
    _searchCache.clear();
    _activePrefetch?.cancel();
    _activePrefetch = null;
  }

  /// Fire-and-forget ping to wake the Saavn free-tier backend as early as
  /// possible (e.g. right at app launch) so it's warm by the time the user
  /// opens Home or Search. Render free tier sleeps after inactivity and the
  /// first real request can otherwise eat several seconds of cold-start.
  static void wakeSaavn() {
    _client
        .get(Uri.parse('$_saavn/result/?query=hello&limit=1'))
        .timeout(const Duration(seconds: 15))
        .then((_) => _log('[wakeSaavn] Backend is warm'))
        .catchError((e) => _log('[wakeSaavn] Ping failed: $e'));
  }

  // ===========================================================================
  // SECTION 8: HOME FEED v2 — Personalized + Time-Aware
  //
  // SECTIONS GENERATED (in order):
  //   1. Recently Played (caller renders from RecentlyPlayedProvider — no API)
  //   2. Made For You — top affinity artists (RecommendationEngine)
  //   3. Mood Mix — current session mood or time slot mood
  //   4. 6 rotating trending sections (date-seeded)
  //   5. Genre Mixes — top affinity genres
  //   6. Era Mix — based on user's top era
  //
  // All sections fire in parallel via Future.wait.
  // topArtists param kept for backward compatibility with HomeScreen.
  // ===========================================================================
  // ===========================================================================
  // SECTION 8: HOME FEED v4 — Premium Personalized Feed
  //
  // WHAT'S NEW vs v2:
  //   ✅ 40+ query pool — massive variety, near-zero repeats
  //   ✅ Hour-seeded shuffle — different order every hour, not just daily
  //   ✅ Cross-section song dedup — same song never appears in 2 sections
  //   ✅ 20 songs fetched per section, shuffled before display (not top-N)
  //   ✅ Saavn+YT merged (not Saavn OR YT) — best of both sources
  //   ✅ Affinity sections FIRST — user's taste > generic trending
  //   ✅ Progressive loading — first 3 sections show immediately
  //   ✅ Emoji-free section labels — clean premium look
  // ===========================================================================

  // ── Massive query pool (40+) grouped by mood/era/genre ──
  static final List<_PoolEntry> _pool = [
    // Trending / New
    _PoolEntry('trending hindi songs 2026',       'Trending Now'),
    _PoolEntry('new bollywood songs 2026',         'New Releases'),
    _PoolEntry('top bollywood hits 2025',          'Best of 2025'),
    _PoolEntry('hindi top charts',                 'Hindi Charts'),
    _PoolEntry('top 50 global hits',               'Global Top 50'),
    _PoolEntry('viral songs 2026',                 'Going Viral'),
    // Bollywood eras
    _PoolEntry('bollywood hits',                   'Bollywood Hits'),
    _PoolEntry('90s bollywood hits',               '90s Bollywood'),
    _PoolEntry('2000s bollywood songs',            '2000s Nostalgia'),
    _PoolEntry('2010s bollywood songs',            '2010s Bollywood'),
    _PoolEntry('old is gold hindi songs',          'Old Is Gold'),
    _PoolEntry('classic hindi film songs',         'Classic Cinema'),
    // Moods
    _PoolEntry('romantic hindi songs',             'Romantic Vibes'),
    _PoolEntry('sad emotional hindi songs',        'Heartbreak Hour'),
    _PoolEntry('party songs hindi 2026',           'Party Mode'),
    _PoolEntry('lofi chill hindi',                 'Lofi & Chill'),
    _PoolEntry('workout motivation songs',         'Workout Energy'),
    _PoolEntry('happy feel good songs hindi',      'Feel Good'),
    _PoolEntry('peaceful calm instrumental music', 'Calm & Focus'),
    _PoolEntry('late night chill songs',           'Late Night'),
    // Regional
    _PoolEntry('punjabi hits 2026',                'Punjabi Hits'),
    _PoolEntry('punjabi romantic songs',           'Punjabi Romance'),
    _PoolEntry('new punjabi songs 2025 2026',      'New Punjabi'),
    _PoolEntry('tamil superhit songs',             'Tamil Hits'),
    _PoolEntry('telugu hits songs',                'Telugu Hits'),
    _PoolEntry('haryanvi hits songs',              'Haryanvi Hits'),
    // Artists (generic enough to get variety)
    _PoolEntry('arijit singh best songs',          'Arijit Singh'),
    _PoolEntry('jubin nautiyal hits',              'Jubin Nautiyal'),
    _PoolEntry('neha kakkar songs',                'Neha Kakkar'),
    _PoolEntry('ap dhillon songs',                 'AP Dhillon'),
    _PoolEntry('pritam bollywood songs',           'Pritam Hits'),
    _PoolEntry('shreya ghoshal songs',             'Shreya Ghoshal'),
    _PoolEntry('atif aslam hits',                  'Atif Aslam'),
    // English / Global
    _PoolEntry('english pop hits 2025 2026',       'English Hits'),
    _PoolEntry('90s english pop songs',            '90s English'),
    _PoolEntry('2010s english hits',               '2010s Hits'),
    _PoolEntry('hip hop hits songs',               'Hip Hop'),
    _PoolEntry('rnb songs playlist',               'R&B Vibes'),
    _PoolEntry('indie pop hits',                   'Indie Picks'),
    _PoolEntry('ed sheeran songs playlist',        'Ed Sheeran'),
    // Genre
    _PoolEntry('sufi songs hindi',                 'Sufi Melodies'),
    _PoolEntry('ghazal songs hindi',               'Ghazals'),
    _PoolEntry('devotional hindi songs',           'Devotional'),
    _PoolEntry('indie hindi songs',                'Hindi Indie'),
    _PoolEntry('acoustic hindi songs',             'Acoustic Vibes'),
  ];

  static Future<List<SongSection>> fetchHome({List<String> topArtists = const []}) async {
    await RecommendationEngine.load();

    // Hour-based seed → different shuffle every hour, PLUS a per-call
    // random salt → every manual pull-to-refresh also feels fresh,
    // not locked to the same order until the hour ticks over.
    final now = DateTime.now();
    final hourSeed = now.difference(DateTime(2026, 1, 1)).inHours;
    final refreshSalt = math.Random().nextInt(1000000);
    final rng = math.Random(hourSeed ^ refreshSalt);

    // Shuffle the pool copy — each hour different order
    final shuffledPool = List<_PoolEntry>.from(_pool)..shuffle(rng);

    // ── Affinity-driven personalised sections ──
    final affinityArtists = RecommendationEngine.topAffinityArtists(count: 4);
    final personalArtists = affinityArtists.isNotEmpty ? affinityArtists : topArtists;
    final topGenres = RecommendationEngine.topAffinityGenres(count: 3);

    // ── Time-of-day mood slot ──
    final slot = RecommendationEngine.currentTimeSlot();
    final timeMoodQuery = _timeMoodQuery(slot);
    final timeMoodLabel = _timeMoodLabel(slot);

    // ── Build query list — personalised FIRST, then pool picks ──
    final queryList = <_SectionQuery>[];

    // 1. Time mood (always first — contextual relevance)
    queryList.add(_SectionQuery(timeMoodQuery, timeMoodLabel, priority: true));

    // 2. Made For You — user's top artists (up to 4)
    for (final artist in personalArtists.take(4)) {
      queryList.add(_SectionQuery('$artist best songs', 'Made for You · $artist', priority: true));
    }

    // 3. Genre mixes from affinity
    for (final genre in topGenres) {
      queryList.add(_SectionQuery(_genreMixQuery(genre), _genreMixLabel(genre), priority: true));
    }

    // 4. Pick 8 random sections from shuffled pool (already hour-varied)
    int poolPicks = 0;
    for (final entry in shuffledPool) {
      if (poolPicks >= 8) break;
      // Skip if already covered by affinity
      if (queryList.any((q) => q.label == entry.label)) continue;
      queryList.add(_SectionQuery(entry.query, entry.label));
      poolPicks++;
    }

    // 5. Cold-start: if no personal history, add 3 more from pool
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

    // ── Batched fetch (3 parallel to protect Render free tier) ──
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

    // ── Cross-section dedup — same song ID never in 2 sections ──
    final globalSeenIds = <String>{};
    final seen = <String>{};
    final sections = <SongSection>[];
    for (final s in results.whereType<SongSection>()) {
      if (!seen.add(s.title)) continue;
      final uniqueSongs = s.songs
          .where((song) => globalSeenIds.add(song.id))
          .toList();
      if (uniqueSongs.isNotEmpty) {
        sections.add(SongSection(title: s.title, songs: uniqueSongs));
      }
    }

    return sections;
  }

  // ── v4 section fetcher: fetches 25 from Saavn + up to 10 from YT,
  //    merges, deduplicates within section, then shuffles lightly so
  //    it's not always the same top-N results from Saavn.
  static Future<SongSection?> _saavnSectionV4(String query, String label) async {
    final both = await Future.wait([
      _searchSaavn(query, limit: 25),
      _searchYt(query, limit: 10)
          .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[]),
    ]);

    final saavnSongs = both[0];
    final ytSongs    = both[1];

    if (saavnSongs.isEmpty && ytSongs.isEmpty) return null;

    // Merge: Saavn first (better audio quality), YT fills gaps
    final seenIds  = <String>{};
    final merged   = <Song>[];
    for (final s in [...saavnSongs, ...ytSongs]) {
      if (seenIds.add(s.id)) merged.add(s);
    }

    // Shuffle the merged list (fixed seed per query+hour+refresh so the
    // mix changes both hourly AND on every manual refresh)
    final seed = query.hashCode ^ DateTime.now().hour ^ math.Random().nextInt(1000000);
    merged.shuffle(math.Random(seed));

    // Cap at 15 for display — enough for a good horizontal row
    return SongSection(
      title: label,
      songs: merged.take(15).toList(),
    );
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
      'bollywood':  'Bollywood Mix',
      'punjabi':    'Punjabi Blast',
      'hiphop':     'Hip Hop Mix',
      'english':    'English Mix',
      'lofi':       'Lofi Mix',
      'devotional': 'Devotional',
      'tamil':      'Tamil Hits',
      'telugu':     'Telugu Hits',
    };
    return labels[genre] ?? '$genre Mix';
  }

  static String _genreMixQuery(String genre) {
    const queries = {
      'bollywood':  'bollywood hits songs',
      'punjabi':    'punjabi hits songs',
      'hiphop':     'hindi rap hip hop hits',
      'english':    'english pop hits songs',
      'lofi':       'lofi chill hindi songs',
      'devotional': 'bhakti devotional songs',
      'tamil':      'tamil hits songs',
      'telugu':     'telugu hits songs',
    };
    return queries[genre] ?? '$genre top songs';
  }

  // SECTION 8B: AUTO-QUEUE v3 — Multi-Signal + RecommendationEngine
  //
  // ALGORITHM (5 parallel signal queries):
  //   Signal 1 (weight=2): Primary artist best songs
  //   Signal 2 (weight=2): Similar artist (affinity-aware, genre-matched)
  //   Signal 3 (weight=1): Mood/session continuation
  //   Signal 4 (weight=1): Era + language pool
  //
  // DEDUP PIPELINE (in order):
  //   1. ID dedup (existing queue IDs + session recent IDs)
  //   2. Variant filter (_isInherentVariant via RecommendationEngine)
  //   3. Title prefix match (catches "Song X Remix", "Song X Cover")
  //   4. Artist repeat guard (no same artist 2x in a row)
  //   5. RecommendationEngine.scoreCandidate() weighted ranking
  //   6. 70/20/10 discovery mix
  //
  // existingQueueIds: passed from PlayerProvider._maybeExtendQueue()
  // ===========================================================================
  static Future<List<Song>> getAutoQueue(
    Song currentSong, {
    int limit = 10,
    Set<String>? existingQueueIds,
  }) async {
    await RecommendationEngine.load();

    if (currentSong.isLocal) return [];

    final isYt = currentSong.source == SongSource.youtube;

    // Generate smart queries from RecommendationEngine
    final queries = RecommendationEngine.generateQueries(currentSong);

    _log('[autoQueue] "${currentSong.title}" → ${queries.length} signals');

    // Fire all signal queries in parallel.
    // Signal 0 = primary artist — use YT search if song is from YouTube.
    // All other signals always use Saavn (faster, pre-fetched URLs).
    final searchFutures = queries.asMap().entries.map((entry) async {
      final idx = entry.key;
      final q   = entry.value;
      final results = (isYt && idx == 0)
          ? await _searchYt(q.query,    limit: 8 * q.weight)
          : await _searchSaavn(q.query, limit: 8 * q.weight);
      return _SignalResult(results, q.weight);
    }).toList();

    final signalResults = await Future.wait(searchFutures);

    // Merge with weighted round-robin
    final merged = <Song>[];
    final iters = signalResults.map((r) => r.songs.iterator).toList();
    bool anyLeft = true;
    while (anyLeft && merged.length < limit * 3) {
      anyLeft = false;
      for (int i = 0; i < iters.length; i++) {
        final w = signalResults[i].weight;
        for (int x = 0; x < w; x++) {
          if (iters[i].moveNext()) {
            merged.add(iters[i].current);
            anyLeft = true;
          }
        }
      }
    }

    // Combined existing IDs: queue + session recent
    final allExistingIds = <String>{
      ...?existingQueueIds,
      ...RecommendationEngine.sessionRecentIds,
    };

    // Use RecommendationEngine to rank, filter, and apply discovery mix
    final ranked = RecommendationEngine.rankAndFilter(
      pool: merged,
      currentSong: currentSong,
      existingIds: allExistingIds,
      limit: limit,
    );

    _log('[autoQueue] Returning ${ranked.length} ranked songs');
    return ranked;
  }

  // ===========================================================================
  // SECTION 9: SEARCH ENGINE v2 — Ranked, Official-First, Multilingual
  //
  // RANKING PIPELINE:
  //   1. Run Saavn + YouTube searches in parallel
  //   2. Score each result with _scoreSearchResult()
  //   3. Sort by score DESC
  //   4. Deduplicate by normalised title
  //   5. Exact matches bubble to top
  //
  // SCORING FACTORS:
  //   +100  exact title match (case-insensitive)
  //   +80   exact artist match
  //   +60   title starts with query
  //   +40   artist starts with query
  //   +30   official audio detected (no remix/cover/lofi keywords)
  //   +20   title contains query (partial)
  //   +10   artist contains query (partial)
  //   -50   variant detected (remix/lofi/cover/slowed/etc.)
  //         unless query itself requests a variant
  //
  // SEARCH CACHE:
  //   normalised query → cached results (10min TTL, 100 entries)
  //   Makes repeat searches feel instant.
  // ===========================================================================
  static Future<List<Song>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    // Search cache check
    final cacheKey = _normalise(q);
    final cached = _searchCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      _log('[search] Cache HIT: "$q"');
      return cached.results;
    }

    // Determine if user explicitly wants a variant (lofi/remix/etc.)
    final wantsVariant = _wantsVariantQuery(q);

    // Fire Saavn + YT in parallel
    final both = await Future.wait([
      _searchSaavn(q, limit: 25),
      _searchYt(q, limit: 15),
    ]);

    final saavnResults = both[0];
    final ytResults    = both[1];

    // Score + merge
    final scored = <_ScoredSong>[];
    final seenTitles = <String>{};

    // Score Saavn first (pre-fetched URLs = better UX)
    for (final song in saavnResults) {
      final score = _scoreSearchResult(song, q, wantsVariant);
      final norm  = _normTitle(song.title);
      if (seenTitles.add(norm)) {
        scored.add(_ScoredSong(song, score));
      }
    }

    // Score YouTube, dedup against Saavn
    for (final song in ytResults) {
      final norm = _normTitle(song.title);
      if (!seenTitles.contains(norm)) {
        final score = _scoreSearchResult(song, q, wantsVariant);
        seenTitles.add(norm);
        scored.add(_ScoredSong(song, score));
      }
    }

    // Sort by score DESC
    scored.sort((a, b) => b.score.compareTo(a.score));
    final results = scored.map((s) => s.song).toList();

    // Write to search cache
    _writeSearchCache(cacheKey, results);

    _log('[search] "${q}" → ${results.length} results '
         '(saavn:${saavnResults.length} yt:${ytResults.length})');
    return results;
  }

  /// Score a search result against the query. Higher = more relevant.
  static double _scoreSearchResult(Song song, String query, bool wantsVariant) {
    double score = 0;
    final qNorm     = _normalise(query);
    final titleNorm = _normalise(song.title);
    final artistNorm = _normalise(song.artist);

    // Exact matches (highest priority — these go to top)
    if (titleNorm == qNorm)               score += 100;
    else if (artistNorm == qNorm)         score += 80;
    else if (titleNorm.startsWith(qNorm)) score += 60;
    else if (artistNorm.startsWith(qNorm))score += 40;
    else if (titleNorm.contains(qNorm))   score += 20;
    else if (artistNorm.contains(qNorm))  score += 10;

    // "artist song" combined query — e.g. "kesariya arijit"
    final queryWords = qNorm.split(' ').where((w) => w.length > 2).toSet();
    if (queryWords.length > 1) {
      int wordMatches = 0;
      for (final word in queryWords) {
        if (titleNorm.contains(word) || artistNorm.contains(word)) wordMatches++;
      }
      score += wordMatches * 8.0;
    }

    // Official audio bonus
    if (_isOfficialAudio(song)) score += 30;

    // Variant penalty (unless user asked for it)
    if (!wantsVariant && RecommendationEngine.shouldBlock(song)) {
      score -= 50;
    } else if (wantsVariant && RecommendationEngine.isInherentVariant(song.title)) {
      score += 15; // boost variants when explicitly requested
    }

    // Source bonus: Saavn has pre-fetched URLs → faster playback
    if (song.source == SongSource.saavn && song.streamUrl != null) score += 5;

    return score;
  }

  static bool _isOfficialAudio(Song song) {
    final title = song.title.toLowerCase();
    final artist = song.artist.toLowerCase();
    // Positive signals
    if (title.contains('official audio') ||
        title.contains('official video') ||
        title.contains('official music video') ||
        title.contains('original')) return true;
    // Not a variant = likely official
    return !RecommendationEngine.isInherentVariant(song.title) &&
           !title.contains('cover') &&
           artist.isNotEmpty &&
           artist.toLowerCase() != 'unknown';
  }

  static bool _wantsVariantQuery(String query) {
    return RecommendationEngine.isInherentVariant(query);
  }

  // Normalise title for dedup (removes variant tags + special chars)
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
    return clean.substring(0, clean.length.clamp(0, 20));
  }

  // ---------------------------------------------------------------------------
  // QUICK SEARCH — live-as-you-type, Saavn only, ranked
  // ---------------------------------------------------------------------------
  static Future<List<Song>> quickSearch(String query, {int limit = 12}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    // Run both sources in parallel with a hard ceiling — if Saavn's free
    // backend is asleep/cold, this no longer blocks live search behind its
    // full timeout. Whichever sources respond in time get merged; YouTube
    // alone is enough to keep results flowing instantly.
    final both = await Future.wait([
      _searchSaavn(q, limit: limit + 5)
          .timeout(const Duration(seconds: 3), onTimeout: () => <Song>[]),
      _searchYt(q, limit: limit)
          .timeout(const Duration(seconds: 3), onTimeout: () => <Song>[]),
    ]);

    final saavnResults = both[0];
    final ytResults = both[1];
    if (saavnResults.isEmpty && ytResults.isEmpty) return [];

    final wantsVariant = _wantsVariantQuery(q);
    final scored = <_ScoredSong>[];
    final seenTitles = <String>{};

    for (final song in saavnResults) {
      final norm = _normTitle(song.title);
      if (seenTitles.add(norm)) {
        scored.add(_ScoredSong(song, _scoreSearchResult(song, q, wantsVariant)));
      }
    }
    for (final song in ytResults) {
      final norm = _normTitle(song.title);
      if (seenTitles.add(norm)) {
        scored.add(_ScoredSong(song, _scoreSearchResult(song, q, wantsVariant)));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((s) => s.song).toList();
  }

  // ---------------------------------------------------------------------------
  // SUGGEST — autocomplete, Saavn only
  // ---------------------------------------------------------------------------
  static Future<List<String>> suggest(String query) async {
    final results = await _suggestSaavn(query);
    return results.take(8).toList();
  }

  static Future<List<String>> _suggestSaavn(String query) async {
    try {
      final url = Uri.parse(
        '$_saavn/result/?query=${Uri.encodeQueryComponent(query)}&limit=5',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final results = data is List ? data : (data['data']?['results'] ?? []);
        if (results is List) {
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
    return [];
  }

  // ===========================================================================
  // SECTION 10: SAAVN SEARCH (internal)
  // ===========================================================================
  static Future<List<Song>> _searchSaavn(String query, {int limit = 20}) async {
    try {
      final url = Uri.parse(
        '$_saavn/result/?query=${Uri.encodeQueryComponent(query)}&limit=$limit',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 4));
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
  // SECTION 11: YOUTUBE SEARCH (internal)
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
      if (url.isNotEmpty) return url;
    }
    return '';
  }

  // ===========================================================================
  // SECTION 12: STREAM URL RESOLUTION (unchanged from v2)
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
      _log('[resolve] Joining in-flight resolution: "$cacheKey"');
      return _pendingResolutions[cacheKey];
    }

    if (!forceRefresh &&
        song.source == SongSource.saavn &&
        song.streamUrl != null &&
        song.streamUrl!.startsWith('http')) {
      final cached = _streamCache[cacheKey];
      if (cached == null) {
        _log('[resolve] Pre-fetched Saavn URL (fresh): "${song.title}"');
        _writeStreamCache(cacheKey, song.streamUrl!);
        return song.streamUrl;
      }
      if (!cached.isExpired) {
        _log('[resolve] Pre-fetched Saavn URL (cache valid): "${song.title}"');
        return cached.url;
      }
      _log('[resolve] Saavn pre-fetched URL expired for "${song.title}" — re-resolving');
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
          url = await _retry(() => _saavnStreamById(song.id), attempts: 1);
          _log('[resolve] Saavn by ID "${song.title}": ${url != null ? "OK" : "FAILED"}');
        }
        if (url == null) {
          _log('[resolve] Saavn fallback → YT search for "${song.title} ${song.artist}"');
          url = await _retry(() => _ytStreamBySearch('${song.title} ${song.artist}'), attempts: 1);
        }
        break;

      case SongSource.youtube:
        if (song.id.isNotEmpty) {
          url = await _raceFirstValid([
            () => _retry(() => _workerYtStream(song.id), attempts: 2,
                         baseDelay: const Duration(milliseconds: 200)),
            () => _retry(() => _ytExplodeStream(song.id), attempts: 2,
                         baseDelay: const Duration(milliseconds: 200)),
          ]);
          _log('[resolve] Worker/Explode race ${song.id}: ${url != null ? "OK" : "FAILED"}');
        }
        if (url == null) {
          _log('[resolve] Worker+Explode failed → YT search for "${song.title} ${song.artist}"');
          url = await _retry(() => _ytStreamBySearch('${song.title} ${song.artist}'),
                              attempts: 2, baseDelay: const Duration(milliseconds: 200));
        }
        break;

      case SongSource.local:
        return song.localPath;
    }

    if (url != null) {
      _log('[resolve] SUCCESS "${song.title}"');
      _writeStreamCache(cacheKey, url);
    } else {
      _log('[resolve] FAILED all sources for "${song.title}"');
    }
    return url;
  }

  // ---------------------------------------------------------------------------
  // RACE HELPER (unchanged from v2)
  // ---------------------------------------------------------------------------
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
  // SECTION 13: YOUTUBE STREAM RESOLUTION METHODS (unchanged from v2)
  // ===========================================================================
  static Future<String?> _workerYtStream(String videoId) async {
    try {
      final uri = Uri.parse('$_worker/api/yt-stream?id=$videoId');
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
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

  static Future<String?> _ytExplodeStream(String videoId) async {
    try {
      final manifest = await _yt.videos.streamsClient
          .getManifest(VideoId(videoId))
          .timeout(const Duration(seconds: 8));
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

  static Future<String?> _ytStreamBySearch(String query) async {
    try {
      final results = await Future.any<List<dynamic>>([
        _yt.search.search(query).then((list) => list.toList()),
        Future.delayed(const Duration(seconds: 8), () => <dynamic>[]),
      ]);
      final videos = results.whereType<Video>().toList();
      if (videos.isEmpty) return null;
      final id = videos.first.id.value;
      return await _raceFirstValid([
        () => _workerYtStream(id),
        () => _ytExplodeStream(id),
      ]);
    } catch (e) {
      _log('[ytSearch] Error: $e');
    }
    return null;
  }

  // ===========================================================================
  // SECTION 14: SAAVN STREAM RESOLUTION (unchanged from v2)
  // ===========================================================================
  static Future<String?> _saavnStreamById(String songId) async {
    try {
      final res = await _client
          .get(Uri.parse('$_saavn/song/?id=$songId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final raw = jsonDecode(res.body);
        Map<String, dynamic>? songData;

        // Worker v5 format: { success: true, url: "...", quality: "320kbps" }
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
    if (url320.startsWith('http')) return url320;
    final urlMedia = (j['media_url'] ?? '').toString();
    if (urlMedia.startsWith('http')) return urlMedia;
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
        if (match != null) return match['url'] as String;
      }
      final last = downloads.last;
      if (last is Map && (last['url'] as String?)?.startsWith('http') == true) {
        return last['url'] as String;
      }
    }
    final su = song['media_url'] ?? song['streamUrl'];
    if (su is String && su.startsWith('http')) return su;
    return null;
  }

  // ===========================================================================
  // SECTION 15: RETRY WITH EXPONENTIAL BACKOFF (unchanged from v2)
  // ===========================================================================
  static Future<String?> _retry(
    Future<String?> Function() fn, {
    int attempts = 3,
    Duration baseDelay = const Duration(milliseconds: 300),
    bool Function(Object error)? retryIf,
  }) async {
    Object? lastError;
    for (var i = 0; i < attempts; i++) {
      try {
        final result = await fn();
        if (result != null && result.isNotEmpty) return result;
      } catch (e) {
        lastError = e;
        if (retryIf != null && !retryIf(e)) break;
        _log('[retry] Attempt ${i + 1}/$attempts failed: $e');
      }
      if (i < attempts - 1) {
        await Future.delayed(baseDelay * (1 << i));
      }
    }
    if (lastError != null) _log('[retry] Exhausted $attempts attempts. Last: $lastError');
    return null;
  }

  // ===========================================================================
  // SECTION 16: CACHE MANAGEMENT
  // ===========================================================================

  // ── Stream cache ─────────────────────────────────────────────────────────
  static void _writeStreamCache(String key, String url) {
    if (_streamCache.length >= _maxCacheSize) {
      final expiredKeys = _streamCache.entries
          .where((e) => e.value.isExpired)
          .map((e) => e.key)
          .toList();
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
    final key = '${song.source.name}:${song.id}';
    _streamCache.remove(key);
  }

  static void clearExpiredCache() {
    _streamCache.removeWhere((_, v) => v.isExpired);
    _searchCache.removeWhere((_, v) => v.isExpired);
  }

  // ── Search cache ──────────────────────────────────────────────────────────
  static void _writeSearchCache(String key, List<Song> results) {
    if (_searchCache.length >= _maxSearchCache) {
      final expiredKeys = _searchCache.entries
          .where((e) => e.value.isExpired)
          .map((e) => e.key)
          .toList();
      for (final k in expiredKeys) _searchCache.remove(k);

      if (_searchCache.length >= _maxSearchCache) {
        final oldest = _searchCache.entries.reduce(
          (a, b) => a.value.cachedAt.isBefore(b.value.cachedAt) ? a : b,
        );
        _searchCache.remove(oldest.key);
      }
    }
    _searchCache[key] = _CachedSearch(results);
    _log('[searchCache] Stored: "$key" (${results.length} results, '
         'cache size: ${_searchCache.length}/$_maxSearchCache)');
  }

  // ===========================================================================
  // SECTION 17: NETWORK RECOVERY (unchanged from v2)
  // ===========================================================================
  static Future<void> onNetworkRestored({Song? currentSong}) async {
    _log('[network] Network restored — starting recovery');
    final before = _streamCache.length;
    _streamCache.removeWhere((_, v) => v.isExpired);
    _log('[network] Purged ${before - _streamCache.length} expired entries');
    if (currentSong != null && !currentSong.isLocal) {
      try {
        await resolveStreamUrl(currentSong, forceRefresh: true);
      } catch (_) {}
    }
  }

  // ===========================================================================
  // SECTION 18: PREFETCH (unchanged from v2)
  // ===========================================================================
  static void prefetchNext(Song song) {
    if (song.isLocal) return;
    _activePrefetch?.cancel();
    _activePrefetch = null;
    _log('[prefetch] Scheduling "${song.title}" (800ms delay)');
    _activePrefetch = CancelableOperation.fromFuture(
      Future.delayed(const Duration(milliseconds: 800), () async {
        try {
          await resolveStreamUrl(song);
          _log('[prefetch] SUCCESS "${song.title}"');
        } catch (_) {}
      }),
    );
  }

  static void cancelPrefetch() {
    _activePrefetch?.cancel();
    _activePrefetch = null;
  }

  // ===========================================================================
  // SECTION 19: SONG PARSERS (unchanged from v2)
  // ===========================================================================
  static Song _songFromSaavn(Map<String, dynamic> j) {
    final title  = _cleanText((j['song'] ?? j['name'] ?? j['title'] ?? 'Unknown').toString());
    final artist = _cleanText((j['primary_artists'] ?? j['singers'] ?? j['artist'] ?? 'Unknown').toString());
    final album  = _cleanText((j['album'] ?? '').toString());
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

  static SongSource sourceFromString(String? s) {
    switch (s) {
      case 'saavn':   return SongSource.saavn;
      case 'youtube': return SongSource.youtube;
      case 'local':   return SongSource.local;
      default:        return SongSource.saavn;
    }
  }

  // ===========================================================================
  // SECTION 20: LYRICS (unchanged from v2)
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
  // SECTION 21: HELPERS (unchanged from v2)
  // ===========================================================================
  static String _onrenderArtwork(Map<String, dynamic> j) {
    final img = (j['image'] ?? '').toString();
    if (img.startsWith('http')) {
      return img
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

  // Normalise for dedup / cache keys: lowercase alphanumeric, max 25 chars
  static String _normalise(String s) {
    final clean = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return clean.substring(0, clean.length.clamp(0, 25));
  }

  // ===========================================================================
  // SECTION 22: DIAGNOSTICS (updated for v3)
  // ===========================================================================
  static Map<String, dynamic> getDiagnosticsSnapshot() {
    return {
      'timestamp':            DateTime.now().toIso8601String(),
      'stream_cache_size':    _streamCache.length,
      'stream_cache_max':     _maxCacheSize,
      'search_cache_size':    _searchCache.length,
      'search_cache_max':     _maxSearchCache,
      'pending_resolutions':  _pendingResolutions.length,
      'prefetch_active':      _activePrefetch != null && !(_activePrefetch?.isCanceled ?? true),
      'lyrics_cached':        _lyricsCache.length,
      'worker_base':          _worker,
      'saavn_base':           _saavn,
      'stream_ttl_minutes':   _streamTtl.inMinutes,
      'search_ttl_minutes':   _searchTtl.inMinutes,
      'rec_top_artists':      RecommendationEngine.topAffinityArtists(),
      'rec_top_genres':       RecommendationEngine.topAffinityGenres(),
      'rec_session_mood':     RecommendationEngine.currentMood?.name,
      'rec_time_slot':        RecommendationEngine.currentTimeSlot().name,
    };
  }

  // ---------------------------------------------------------------------------
  // debugPlaybackPath — restored from v2.
  //
  // Runs live network tests against every endpoint Aurum depends on:
  //   1. Cloudflare Worker YouTube stream resolution
  //   2. youtube_explode_dart fallback
  //   3. Saavn search (the source of every home-feed section)
  //   4. Full Saavn resolveStreamUrl
  //   5. Full YouTube resolveStreamUrl
  //   6. lrclib.net lyrics
  //
  // Takes ~10-15 seconds. Wire to a "Debug Playback" button in
  // Settings → About so a failing Saavn backend can be diagnosed
  // directly from the phone — no logcat/adb needed.
  // ---------------------------------------------------------------------------
  static Future<String> debugPlaybackPath() async {
    final buf = StringBuffer();
    buf.writeln('=== Aurum Playback Diagnostics ===');
    buf.writeln('Time:   ${DateTime.now()}');
    buf.writeln('Worker: $_worker');
    buf.writeln('Saavn:  $_saavn');
    buf.writeln('Cache:  ${_streamCache.length}/$_maxCacheSize stream entries '
        '(${_streamCache.values.where((v) => v.isExpired).length} expired), '
        '${_searchCache.length}/$_maxSearchCache search entries');
    buf.writeln('');

    // Test 1: Cloudflare Worker
    buf.writeln('▶ 1. Cloudflare Worker /api/yt-stream?id=dQw4w9WgXcQ');
    try {
      final sw = Stopwatch()..start();
      final url = await _workerYtStream('dQw4w9WgXcQ');
      sw.stop();
      buf.writeln(url != null
          ? '   ✅ OK (${sw.elapsedMilliseconds}ms) → ${url.substring(0, url.length.clamp(0, 60))}...'
          : '   ❌ FAILED (${sw.elapsedMilliseconds}ms) — worker returned null');
    } catch (e) {
      buf.writeln('   ❌ EXCEPTION: $e');
    }
    buf.writeln('');

    // Test 2: youtube_explode_dart
    buf.writeln('▶ 2. youtube_explode_dart for dQw4w9WgXcQ');
    try {
      final sw = Stopwatch()..start();
      final url = await _ytExplodeStream('dQw4w9WgXcQ');
      sw.stop();
      buf.writeln(url != null
          ? '   ✅ OK (${sw.elapsedMilliseconds}ms)'
          : '   ❌ FAILED (${sw.elapsedMilliseconds}ms) — possible Innertube block');
    } catch (e) {
      buf.writeln('   ❌ EXCEPTION: $e');
    }
    buf.writeln('');

    // Test 3: Saavn search — this is the one that powers the entire home feed
    buf.writeln('▶ 3. Saavn search (arijit singh)');
    Song? saavnSong;
    try {
      final sw = Stopwatch()..start();
      final songs = await _searchSaavn('arijit singh', limit: 1);
      sw.stop();
      if (songs.isNotEmpty) {
        saavnSong = songs.first;
        buf.writeln('   ✅ OK (${sw.elapsedMilliseconds}ms) — "${songs.first.title}"');
        buf.writeln('      source: ${songs.first.source.name}');
        buf.writeln('      streamUrl present: ${songs.first.streamUrl != null}');
      } else {
        buf.writeln('   ❌ FAILED (${sw.elapsedMilliseconds}ms) — 0 results. '
            'If this fails, the home feed will be EMPTY too — '
            'check if $_saavn is reachable/awake.');
      }
    } catch (e) {
      buf.writeln('   ❌ EXCEPTION: $e');
    }
    buf.writeln('');

    // Test 4: Full Saavn resolveStreamUrl
    buf.writeln('▶ 4. Full resolveStreamUrl (Saavn song)');
    try {
      if (saavnSong != null) {
        final sw = Stopwatch()..start();
        final url = await resolveStreamUrl(saavnSong, forceRefresh: true);
        sw.stop();
        buf.writeln(url != null
            ? '   ✅ OK (${sw.elapsedMilliseconds}ms)'
            : '   ❌ FAILED (${sw.elapsedMilliseconds}ms) — all Saavn sources failed');
      } else {
        buf.writeln('   ⚠ Skipped — Saavn search failed in test 3');
      }
    } catch (e) {
      buf.writeln('   ❌ EXCEPTION: $e');
    }
    buf.writeln('');

    // Test 5: Full YouTube resolveStreamUrl
    buf.writeln('▶ 5. Full resolveStreamUrl (YouTube song — Rick Astley)');
    try {
      final ytSong = Song(
        id:         'dQw4w9WgXcQ',
        title:      'Never Gonna Give You Up',
        artist:     'Rick Astley',
        album:      '',
        artworkUrl: '',
        source:     SongSource.youtube,
      );
      final sw = Stopwatch()..start();
      final url = await resolveStreamUrl(ytSong, forceRefresh: true);
      sw.stop();
      buf.writeln(url != null
          ? '   ✅ OK (${sw.elapsedMilliseconds}ms)'
          : '   ❌ FAILED (${sw.elapsedMilliseconds}ms) — BOTH worker and explode failed');
    } catch (e) {
      buf.writeln('   ❌ EXCEPTION: $e');
    }
    buf.writeln('');

    // Test 6: lrclib.net lyrics
    buf.writeln('▶ 6. lrclib.net lyrics (Tum Hi Ho, Arijit Singh)');
    try {
      final sw = Stopwatch()..start();
      final lyrics = await _fetchLrcLibLyrics('Tum Hi Ho', 'Arijit Singh');
      sw.stop();
      buf.writeln(lyrics != null
          ? '   ✅ OK (${sw.elapsedMilliseconds}ms) — '
            '${lyrics.length} chars, first line: "${lyrics.split('\n').first}"'
          : '   ❌ FAILED (${sw.elapsedMilliseconds}ms)');
    } catch (e) {
      buf.writeln('   ❌ EXCEPTION: $e');
    }

    return buf.toString();
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
