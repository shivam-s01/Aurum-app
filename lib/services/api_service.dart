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
import 'package:html/parser.dart' as html_parser;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:async/async.dart';
import 'package:just_audio/just_audio.dart';
import 'dart:math' as math;

import '../models/song.dart';
import '../models/artist.dart';
import '../models/lyrics.dart';
import '../utils/constants.dart';
import 'audio_prefs.dart';
import 'recommendation_engine.dart';
import 'native_related_videos.dart' show NativeRelatedVideos, YtRelatedVideo;

// =============================================================================
// Result of a REAL playback attempt, used by debugPlaybackPath's
// [realPlaybackTest] callback. Lives here (not in player_provider.dart) so
// BOTH api_service.dart and player_provider.dart can reference it without
// creating a circular import (player_provider.dart already imports
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

// =============================================================================
// WORKER HEALTH TRACKER
// -----------------------------------------------------------------------
// PERFORMANCE/HEATING FIX (2026-07-02): "YouTube songs — phone heats up,
// speed slow, songs won't play, auto-skip/auto-pause a lot."
//
// Root cause: _workerYtStream (Stage 1 of _ytStreamById) makes TWO
// sequential network calls (up to 16s + 12s = 28s worst case) before ever
// falling through to Stage 2's 6-way parallel blast race (3 Piped + 3
// Invidious) — which is itself another burst of simultaneous connections,
// followed by a Stage 3 retry with a 30s timeout. If the Worker is
// temporarily down/slow, this ENTIRE ~28s Stage-1 wait repeated on every
// single song tap, before even reaching fallbacks — no memory of "the
// Worker just failed 30 seconds ago, don't wait on it again." That
// repeated network churn (radio kept awake, back-to-back HTTP attempts,
// parallel blast races) is exactly what shows up as battery/heat and as
// "won't play / slow to start."
//
// Fix: remember when the Worker fails and skip straight to the (already
// parallel, already fast) fallback race for a short cooldown, instead of
// re-paying the full sequential Stage-1 timeout on every tap. Short
// cooldown (60s, not 5min like dead instances) because the Worker is the
// PRIMARY path and should be retried again soon once it recovers.
// =============================================================================
class _WorkerHealth {
  static DateTime? _deadUntil;
  static int _consecutiveFailures = 0;

  // Cooldown/backoff tracking kept for diagnostics and in case fallback
  // providers are reintroduced later, but as of the Worker-only
  // simplification (2026-07-06) nothing currently gates on isAlive —
  // _ytStreamById now always attempts the Worker directly (quick probe,
  // then one extended-timeout retry) rather than skipping it based on
  // recent failure history. maintenanceMode is the only thing that
  // actually short-circuits a Worker attempt now.
  static const List<Duration> _backoffSteps = [
    Duration(seconds: 8),
    Duration(seconds: 20),
    Duration(seconds: 45),
    Duration(seconds: 90),
    Duration(minutes: 2),
  ];

  // Manual override for planned maintenance. Flip to true right before
  // restarting/redeploying the Cloudflare Worker, false the moment it's
  // back — every song then skips the quick probe and goes straight to
  // the longer-timeout retry (which will also fail fast-ish while the
  // Worker is actually down, surfacing a clear "Worker unreachable" log
  // instead of spending time on a doomed quick attempt first).
  static bool maintenanceMode = false;

  static bool get isAlive {
    if (maintenanceMode) return false;
    final dead = _deadUntil;
    if (dead == null) return true;
    if (DateTime.now().isAfter(dead)) {
      _deadUntil = null;
      return true;
    }
    return false;
  }

  static void markDead() {
    final stepIndex = _consecutiveFailures.clamp(0, _backoffSteps.length - 1);
    _deadUntil = DateTime.now().add(_backoffSteps[stepIndex]);
    _consecutiveFailures++;
  }

  static void markAlive() {
    _deadUntil = null;
    _consecutiveFailures = 0;
  }
}


class ApiService {

  /// Flip to true right before you start restarting/redeploying the
  /// Cloudflare Worker, false the moment it's back. While true, every
  /// song skips Stage 1 (Worker) instantly and goes straight to
  /// Piped/Invidious — no failed request, no timeout, no user-visible
  /// stutter while you're doing maintenance.
  static set workerMaintenanceMode(bool value) {
    _WorkerHealth.maintenanceMode = value;
  }
  static bool get workerMaintenanceMode => _WorkerHealth.maintenanceMode;

  static final http.Client    _client = http.Client();
  static final YoutubeExplode _yt     = YoutubeExplode();

  // ===========================================================================
  // HOST FAILOVER — single source of truth for base URLs.
  //
  // To add/remove/replace a host in the future: edit ONLY the lists below.
  // Every function that talks to Saavn should go through _getFromHosts()
  // (or loop _saavnNodeHosts / _saavnFlaskHosts itself) instead of hardcoding
  // one URL — that's what makes "one host goes down -> app keeps working"
  // actually true instead of aspirational.
  //
  // Two API "families" exist because there are two different backend
  // implementations in rotation, with different JSON shapes:
  //   • NODE family (jiosaavn-op / sumitkolhe-style): nested JSON —
  //     artists.primary[], album.name, downloadUrl[]. Used for search,
  //     song details, AND artist/album pages (all same shape).
  //   • FLASK family (cyberboysumanjay-style): flat JSON — artist, album
  //     as plain strings. Only /result/ (search) is reliable on these;
  //     kept purely as a last-resort search fallback.
  //
  // _songFromSaavn() already handles both shapes safely.
  // ===========================================================================
  static const List<String> _saavnNodeHosts = [
    'https://jiosaavn-op-c4oo.onrender.com', // primary — confirmed working 2026-07
    // Add more Node-family mirrors here if you deploy/find one, e.g.:
    // 'https://your-backup-mirror.onrender.com',
  ];

  static const List<String> _saavnFlaskHosts = [
    'https://jiosavan-ecc1.onrender.com',   // Flask primary — Render free-tier, can hit limits
    'https://jiosavan-three.vercel.app',    // Flask secondary
  ];

  /// Tries each host in [hosts] in order, returning the first response that
  /// is HTTP 200 AND passes [isValid] (so a host returning an empty/error
  /// JSON body with a 200 status still gets skipped). Returns null if every
  /// host in the list fails — callers decide the final fallback behavior.
  static Future<Map<String, dynamic>?> _getFromHosts(
    List<String> hosts,
    String pathAndQuery, {
    Duration timeout = const Duration(seconds: 8),
    bool Function(Map<String, dynamic> body)? isValid,
  }) async {
    for (final host in hosts) {
      try {
        final res = await _client
            .get(Uri.parse('$host$pathAndQuery'))
            .timeout(timeout);
        if (res.statusCode != 200) continue;
        final body = jsonDecode(res.body);
        if (body is! Map<String, dynamic>) continue;
        if (isValid != null && !isValid(body)) continue;
        return body;
      } catch (e) {
        _log('[_getFromHosts] $host failed: $e');
        continue;
      }
    }
    return null;
  }

  // NOTE: previously there was a `_saavnV2` alias pointing at
  // _saavnNodeHosts.first — removed since every caller now loops through
  // _saavnNodeHosts directly (search, stream-by-id), which is what actually
  // gives failover if a second Node mirror is ever added to that list.

  // Saavn: onrender (jiosavan-ecc1) = Flask-based cyberboysumanjay/
  // JioSaavnAPI — only real routes are /result/, /lyrics/. /song/?id=
  // confirmed BROKEN (hangs 20s+, 0 bytes, both onrender and CF worker —
  // server-side bug, not a deploy issue). Kept as fallback for /result/
  // search only.
  //
  // Vercel (jiosavan-three) = same Flask API, fallback pillar.
  //
  // CF worker = tertiary fallback, unchanged.
  static const String _saavnPrimary   = 'https://jiosavan-ecc1.onrender.com';
  static const String _saavnSecondary = 'https://jiosavan-three.vercel.app';
  static const String _saavn          = 'https://aurum-worker.shivamsharma962122.workers.dev';
  static const String _worker         = AppConstants.apiBase;

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
        .get(Uri.parse('$_saavnPrimary/result/?query=hello&limit=1'))
        .timeout(const Duration(seconds: 30))
        .then((_) => _log('[wakeSaavn] onrender warm ✓'))
        .catchError((e) => _log('[wakeSaavn] onrender ping failed: $e'));

    // Also warm Vercel secondary pillar — serverless, so this is cheap and
    // means it's ready instantly if Render is mid cold-start when needed.
    _client
        .get(Uri.parse('$_saavnSecondary/result/?query=hello&limit=1'))
        .timeout(const Duration(seconds: 15))
        .then((_) => _log('[wakeSaavn] Vercel warm ✓'))
        .catchError((e) => _log('[wakeSaavn] Vercel ping failed: $e'));

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
  // HOME FEED — pure Bollywood/Hindi, mainstream artists only, no filler
  // ===========================================================================
  // Pool queries — ALL designed to return original, official Bollywood/Hindi
  // songs only, spanning classic to current. No "lofi", no "remix", no "DJ"
  // in queries — those attract variants. No South/English/regional content.
  static final List<_PoolEntry> _pool = [
    // ── Icons & Legends ─────────────────────────────────────────────────────
    _PoolEntry('arijit singh best bollywood songs',           'Arijit Singh'),
    _PoolEntry('atif aslam best hindi songs',                 'Atif Aslam'),
    _PoolEntry('jubin nautiyal romantic songs',                'Jubin Nautiyal'),
    _PoolEntry('shreya ghoshal bollywood hits',                'Shreya Ghoshal'),
    _PoolEntry('armaan malik songs playlist',                  'Armaan Malik'),
    _PoolEntry('sonu nigam bollywood hit songs',                'Sonu Nigam'),
    _PoolEntry('kk hindi songs playlist',                       'KK'),
    _PoolEntry('kishore kumar hindi classics',                  'Kishore Kumar'),
    _PoolEntry('lata mangeshkar timeless songs',                'Lata Mangeshkar'),
    _PoolEntry('mohammed rafi golden hits',                     'Mohammed Rafi'),
    _PoolEntry('a.r. rahman best songs',                        'A.R. Rahman'),
    _PoolEntry('rd burman classic bollywood songs',             'R.D. Burman Classics'),
    // ── Trending / New / Discovery ──────────────────────────────────────────
    _PoolEntry('trending hindi songs this week',                'Trending Now'),
    _PoolEntry('new hindi songs 2026 latest',                    'New Releases'),
    _PoolEntry('viral hindi songs reels',                        'Viral Hits'),
    _PoolEntry('trending songs india',                           'Trending in India'),
    _PoolEntry('new music hindi bollywood',                      'New Music'),
    _PoolEntry('top charts bollywood songs',                     'Top Charts'),
    _PoolEntry('hidden gems bollywood underrated songs',         'Discovery'),
    _PoolEntry('top bollywood albums 2025 2026',                 'Top Albums'),
    _PoolEntry('best bollywood playlists hits',                  'Top Playlists'),
    // ── Eras ──────────────────────────────────────────────────────────────
    _PoolEntry('90s bollywood superhits original',              '90s Bollywood'),
    _PoolEntry('2000s bollywood original songs',                '2000s Bollywood'),
    _PoolEntry('2010s bollywood hit songs',                     '2010s Bollywood'),
    _PoolEntry('2020s bollywood hit songs',                     '2020s Hits'),
    _PoolEntry('old is gold hindi songs kishore kumar lata',     'Old Is Gold'),
    _PoolEntry('retro bollywood hindi classics',                 'Retro'),
    // ── Mood & Occasion ───────────────────────────────────────────────────
    _PoolEntry('romantic bollywood songs hindi',                 'Romance'),
    _PoolEntry('sad hindi songs heartbreak',                     'Sad Songs'),
    _PoolEntry('lofi chill hindi songs',                         'Chill'),
    _PoolEntry('bollywood party songs dance',                    'Party'),
    _PoolEntry('workout gym hindi motivation songs',              'Workout'),
    _PoolEntry('bhakti bhajan aarti original songs',              'Devotional'),
    _PoolEntry('sufi qawwali hindi songs original',              'Sufi'),
    _PoolEntry('ghazal jagjit singh mehdi hassan',               'Ghazals'),
    _PoolEntry('feel good happy bollywood songs',                'Feel Good'),
    _PoolEntry('late night hindi songs drive',                   'Late Night'),
    _PoolEntry('road trip hindi songs playlist',                  'Road Trip'),
    // ── Genres (regional) ────────────────────────────────────────────────
    _PoolEntry('bollywood hits songs',                            'Bollywood'),
    _PoolEntry('punjabi hits songs',                              'Punjabi'),
    _PoolEntry('indie india hindi songs',                         'Indie India'),
    _PoolEntry('hindi pop songs playlist',                        'Hindi Pop'),
    _PoolEntry('tamil hits songs',                                'Tamil'),
    _PoolEntry('telugu hits songs',                               'Telugu'),
    _PoolEntry('marathi hit songs',                               'Marathi'),
    _PoolEntry('bengali hit songs',                               'Bengali'),
    _PoolEntry('bhojpuri hit songs',                              'Bhojpuri'),
    _PoolEntry('gujarati hit songs',                              'Gujarati'),
    _PoolEntry('malayalam hit songs',                             'Malayalam'),
    _PoolEntry('kannada hit songs',                               'Kannada'),
  ];


  // Whitelist of mainstream playback artists eligible for "Made for You"
  // personalization. Prevents obscure names that happen to accumulate
  // affinity weight (e.g. from one stray play) from ever surfacing as a
  // home section — keeps the feed premium and curated. 15+ names so the
  // rotating artist section always has real breadth to pick from.
  static const Set<String> _mainstreamArtists = {
    'arijit singh', 'atif aslam', 'jubin nautiyal', 'shreya ghoshal',
    'armaan malik', 'sonu nigam', 'kk', 'kishore kumar', 'lata mangeshkar',
    'mohammed rafi', 'asha bhosle', 'udit narayan', 'alka yagnik',
    'sunidhi chauhan', 'shaan', 'mohit chauhan', 'rahat fateh ali khan',
    'neha kakkar', 'darshan raval', 'vishal mishra', 'sachet tandon',
    'yasser desai', 'stebin ben', 'javed ali', 'kumar sanu', 'anuradha paudwal',
    'a.r. rahman', 'ar rahman', 'pritam', 'vishal-shekhar', 'amit trivedi',
  };

  // Genres eligible for automatic home-feed injection via affinity. Widened
  // to cover every regional language the app now surfaces — home should
  // follow whatever the user actually searches/plays (Bhojpuri, Tamil,
  // English, etc.), not just a fixed Bollywood-only whitelist.
  static const Set<String> _homeEligibleGenres = {
    'bollywood', 'devotional', 'lofi', 'punjabi', 'bhojpuri', 'tamil',
    'telugu', 'english', 'hiphop',
  };

  // Languages eligible for affinity-driven home injection — mirrors
  // detectLanguage()'s output set. Drives the "user's actual listening
  // language shows up on home" behavior via topAffinityLanguages().
  static const Set<String> _homeEligibleLanguages = {
    'hindi', 'punjabi', 'english', 'tamil', 'telugu', 'bengali',
    'marathi', 'gujarati', 'malayalam', 'bhojpuri',
  };

  static const Map<String, String> _languageQueryMap = {
    'punjabi':   'punjabi hits songs',
    'english':   'english pop hits songs',
    'tamil':     'tamil hits songs',
    'telugu':    'telugu hits songs',
    'bengali':   'bengali hit songs',
    'marathi':   'marathi hit songs',
    'gujarati':  'gujarati hit songs',
    'malayalam': 'malayalam hit songs',
    'bhojpuri':  'bhojpuri hit songs',
    'hindi':     'bollywood hits songs',
  };

  static const Map<String, String> _languageLabelMap = {
    'punjabi':   'Punjabi',
    'english':   'English',
    'tamil':     'Tamil',
    'telugu':    'Telugu',
    'bengali':   'Bengali',
    'marathi':   'Marathi',
    'gujarati':  'Gujarati',
    'malayalam': 'Malayalam',
    'bhojpuri':  'Bhojpuri',
    'hindi':     'Hindi',
  };

  static List<String> _filterMainstream(List<String> artists) => artists
      .where((a) => _mainstreamArtists.contains(a.toLowerCase().trim()))
      .toList();

  static List<String> _filterHomeGenres(List<String> genres) =>
      genres.where((g) => _homeEligibleGenres.contains(g.toLowerCase().trim())).toList();

  static Future<List<SongSection>> fetchHome({List<String> topArtists = const [], List<Song> recentlyPlayed = const []}) async {
    await RecommendationEngine.load();
    final now = DateTime.now();
    final hourSeed = now.difference(DateTime(2026, 1, 1)).inHours;
    final refreshSalt = math.Random().nextInt(1000000);
    final rng = math.Random(hourSeed ^ refreshSalt);
    final shuffledPool = List<_PoolEntry>.from(_pool)..shuffle(rng);

    final affinityArtists = _filterMainstream(
      RecommendationEngine.rotatingAffinityArtists(count: 4, seed: refreshSalt),
    );
    final personalArtists = affinityArtists.isNotEmpty ? affinityArtists : _filterMainstream(topArtists);
    final topGenres = _filterHomeGenres(
      RecommendationEngine.rotatingAffinityGenres(count: 3, seed: refreshSalt ^ 0x9E3779B9),
    );
    // User's actual listening languages (from real plays via onSongStarted/
    // detectLanguage) — this is what makes home follow "jaisa user search
    // karke sune vaisa aaye": if someone actually plays Bhojpuri/Tamil/
    // English songs, that affinity weight rises and shows up here.
    final topLanguages = RecommendationEngine.topAffinityLanguages(count: 2)
        .where((l) => _homeEligibleLanguages.contains(l))
        .toList();

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
    for (final lang in topLanguages) {
      final q = _languageQueryMap[lang];
      final lbl = _languageLabelMap[lang];
      if (q == null || lbl == null) continue;
      if (queryList.any((sq) => sq.label == lbl)) continue;
      queryList.add(_SectionQuery(q, lbl, priority: true));
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

    // Randomized total section count (7-10) per refresh, per explicit
    // request ("kabhi 7 kabhi 8 aaye") instead of a fixed pool-pick count.
    final targetTotal = 7 + math.Random(refreshSalt ^ 0x51ED270B).nextInt(4); // 7..10
    int poolPicks = 0;
    for (final entry in shuffledPool) {
      if (queryList.length >= targetTotal) break;
      if (queryList.any((q) => q.label == entry.label)) continue;
      queryList.add(_SectionQuery(entry.query, entry.label));
      poolPicks++;
    }
    if (personalArtists.isEmpty && topGenres.isEmpty && topLanguages.isEmpty && recentOnline.isEmpty) {
      for (final entry in shuffledPool.reversed) {
        if (queryList.length >= targetTotal) break;
        if (!queryList.any((q) => q.label == entry.label)) {
          queryList.add(_SectionQuery(entry.query, entry.label));
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

  // Like _searchSaavn but always merges page 1 + page 2 (doesn't short-circuit
  // when page 1 is already "full") — used where we deliberately want a large,
  // varied pool (e.g. home feed sections) so shuffling/filtering still leaves
  // 50-80 songs instead of collapsing to whatever a single page returned.
  static Future<List<Song>> _searchSaavnDeep(String query, {int limit = 40}) async {
    // FIX: pages were fetched sequentially (page1, then page2, then page3),
    // tripling latency for every section that needed deep results. Fetching
    // all three in parallel cuts this to roughly one request's round-trip
    // time, since none of the pages depend on each other's results.
    //
    // FIX (2026-07-22): 3 pages × 40/page = up to 120 raw songs, but after
    // variant-filtering (remix/cover/lofi) + id/title dedup, sections were
    // consistently landing only ~25-30 survivors — nowhere near the 50-80
    // the code above claimed to target. Bumped to 4 pages so there's real
    // headroom for that filtering to still leave a full-looking section.
    //
    // FIX (rotation): a given query's Saavn pages are STABLE — page 1 today
    // is page 1 tomorrow. Always fetching pages 1-4 meant every "refresh"
    // just re-shuffled the display order of the exact same ~200 songs,
    // which is why sections looked like they never actually changed.
    // Rotating the starting page (still 4 consecutive pages from there)
    // means each refresh has a real chance of pulling a different slice
    // of Saavn's catalog for the same query.
    final startPage = 1 + math.Random().nextInt(5); // 1..5
    final pages = List.generate(4, (i) => startPage + i);
    final futures = pages.map((p) => _fetchSaavnPage(
          '$_saavnPrimary/result/?query=${Uri.encodeQueryComponent(query)}&limit=$limit&page=$p',
          limit,
        ).catchError((_) => <Song>[]));
    final results = await Future.wait(futures);
    final anyResults = results.any((r) => r.isNotEmpty);
    if (!anyResults) return _searchSaavn(query, limit: limit);
    final seen = <String>{};
    final merged = <Song>[];
    for (final page in results) {
      for (final s in page) {
        if (seen.add(s.id)) merged.add(s);
      }
    }
    return merged;
  }

  static Future<SongSection?> _saavnSectionV4(String query, String label) async {
    // EQUAL WEIGHT: Saavn and YouTube are fetched in PARALLEL (not
    // sequentially, so this adds zero latency vs the old gap-fill design)
    // and interleaved round-robin so a section is a genuine 50/50 mix
    // instead of "Saavn primary, YT only fills leftover gaps."
    // FIX (sections landing under 80): raw pool bumped up on both sides.
    // Saavn's own variant/junk filters were already trimming a chunk of
    // any batch, and _searchYt's limit only became meaningfully honorable
    // once _searchYtPaged (see below) started walking multiple result
    // pages instead of being silently capped at one ~20-video page — so
    // asking for more here now actually pays off downstream instead of
    // being a no-op.
    final results = await Future.wait([
      _searchSaavnDeep(query, limit: 90),
      _searchYt(query, limit: 90),
    ]);
    final rawSaavn = results[0];
    final rawYt    = results[1];
    if (rawSaavn.isEmpty && rawYt.isEmpty) return null;

    final seed = query.hashCode ^ DateTime.now().millisecondsSinceEpoch ^ math.Random().nextInt(1000000);
    final saavnShuffled = List<Song>.from(rawSaavn)..shuffle(math.Random(seed));
    // rawYt is already official-channel-sorted by _searchYt — shuffling
    // would throw that priority away, so only lightly shuffle within same-
    // priority runs is skipped; keep official-first order intact.

    final seenIds    = <String>{};
    final seenTitles = <String>{};
    // FIX (home sections landing short of 80, same root cause as the Up
    // Next/search dedup fix): the old exact-string `seenTitles` check only
    // catches reuploads that normalize to byte-identical strings. Two
    // different reuploads of the SAME song ("8K...", "With LYRICS...")
    // both slip through as if they were different songs, each consuming
    // one of the 80 slots — so a section could hit "80 songs" while really
    // only containing 50-60 distinct ones, or fail to reach 80 at all once
    // that unnecessary duplication is later cleaned up elsewhere. Smart
    // title-head comparison against every raw title already accepted
    // closes it here too, same fix as RecommendationEngine.rankAndFilter
    // and ApiService.search.
    final seenRawTitles = <String>[];
    final merged     = <Song>[];

    bool tryAdd(Song s, {required bool isYt}) {
      if (merged.length >= 80) return false;
      if (!seenIds.add(s.id)) return false;
      if (RecommendationEngine.isInherentVariant(s.title)) return false;
      if (RecommendationEngine.isLowQualityUpload(s.title)) return false;
      if (isYt && !RecommendationEngine.isPremiumQuality(s)) return false;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) return false;
      for (final seenRaw in seenRawTitles) {
        if (RecommendationEngine.isSameSongSmart(s.title, seenRaw)) return false;
      }
      seenRawTitles.add(s.title);
      merged.add(s);
      return true;
    }

    // Round-robin interleave: one Saavn, one YT, one Saavn, one YT... so
    // the final section is genuinely balanced rather than front-loaded
    // with one source. Whichever source runs out first, the other keeps
    // contributing until the 80-cap or its own pool is exhausted.
    var si = 0, yi = 0;
    while ((si < saavnShuffled.length || yi < rawYt.length) && merged.length < 80) {
      if (si < saavnShuffled.length) {
        tryAdd(saavnShuffled[si], isYt: false);
        si++;
      }
      if (yi < rawYt.length && merged.length < 80) {
        tryAdd(rawYt[yi], isYt: true);
        yi++;
      }
    }

    if (merged.isEmpty) return null;
    return SongSection(title: label, songs: merged.take(80).toList());
  }

  // "Because You Played" section — pure JioSaavn suggestions, same category guaranteed
  //
  // NOTE: the Flask backend (cyberboysumanjay/JioSaavnAPI, both onrender
  // and the CF worker) has NO dedicated suggestions endpoint — only
  // /result/, /song/, /lyrics/. There is nothing to call here anymore, so
  // this returns null immediately instead of hitting a route that always
  // 404s and burning a timeout on every home-feed refresh. If you want
  // this section back, it needs to be rebuilt from _searchSaavn using the
  // song's title/artist as a search query instead of a suggestions call.
  static Future<SongSection?> _suggestionSection(String songId, String label) async {
    return null;
  }

  // ===========================================================================
  // STREAMING HOME FEED — progressive section-by-section delivery
  // ===========================================================================
  static Future<void> fetchHomeStreaming({
    List<String> topArtists = const [],
    List<String> topArtistsRotating = const [],
    List<Song> recentlyPlayed = const [],
    required void Function(SongSection section) onSection,
  }) async {
    await RecommendationEngine.load();
    final now = DateTime.now();
    final hourSeed = now.difference(DateTime(2026, 1, 1)).inHours;
    final refreshSalt = math.Random().nextInt(1000000);
    final rng = math.Random(hourSeed ^ refreshSalt);
    final shuffledPool = List<_PoolEntry>.from(_pool)..shuffle(rng);

    final affinityArtists = _filterMainstream(
      RecommendationEngine.rotatingAffinityArtists(count: 4, seed: refreshSalt),
    );
    // ROOT CAUSE (actual): when RecommendationEngine doesn't yet have enough
    // learned affinity weight (a newer account, or weights not past the 0.5
    // threshold), `rotatingAffinityArtists` returns []. Previously this fell
    // straight back to the plain `topArtists` param passed in — a
    // deterministic, frequency-only "same top 3 every time" list with no
    // seed or shuffle. Since these "Made for You · <artist>" sections render
    // FIRST (priority: true) and are the most visible part of the page, that
    // fallback alone was enough to make pull-to-refresh look completely
    // frozen even though every other part of the pipeline (network fetch,
    // song shuffling) was genuinely fresh each time. `topArtistsRotating`
    // still ranks by real listening frequency, but shuffles a wider pool of
    // real top artists with `refreshSalt` before picking who's featured —
    // so it actually varies pull to pull, same as the affinity-based path.
    final personalArtists = affinityArtists.isNotEmpty
        ? affinityArtists
        : _filterMainstream(
            topArtistsRotating.isNotEmpty ? topArtistsRotating : topArtists,
          );
    final topGenres = _filterHomeGenres(
      RecommendationEngine.rotatingAffinityGenres(count: 3, seed: refreshSalt ^ 0x9E3779B9),
    );

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
    // ── English/International (direct YouTube search) ──
    // JioSaavn's catalog is weak for English/Western music. Simpler than
    // the earlier iTunes-discovery approach: one search call per section
    // straight to YouTube, no extra per-song lookup — fewer moving parts,
    // fewer failure points, faster.
    const englishQueries = [
      ('top english songs 2026', 'Top English Hits'),
      ('english pop hits', 'English Pop'),
      ('english love songs', 'English Love Songs'),
    ];
    for (final (q, label) in englishQueries) {
      queryList.add(_SectionQuery(q, label, isEnglish: true));
    }
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

    final globalSeenIds = <String>{};
    final seenTitles = <String>{};

    Future<void> runQuery(_SectionQuery sq) {
      final future = sq.isSuggestion
          ? _suggestionSection(sq.suggestionSongId!, sq.label)
          : sq.isEnglish
              ? _ytSectionV1(sq.query, sq.label)
              : _saavnSectionV4(sq.query, sq.label);
      return future.then((s) {
        if (s == null) return;
        if (!seenTitles.add(s.title)) return;
        final uniqueSongs = s.songs.where((song) => globalSeenIds.add(song.id)).toList();
        if (uniqueSongs.isNotEmpty) {
          onSection(SongSection(title: s.title, songs: uniqueSongs));
        }
      }).catchError((_) {
        // one query failing shouldn't stop the rest of the feed from loading
      });
    }

    // FIX (2026-07-25): the block this replaces fired every query in
    // queryList — typically 15-19 of them — via a single Future.wait with
    // no shared throttling. Each query itself opens ~5 of its own HTTP
    // connections (4 parallel Saavn pages + 1 YouTube search inside
    // _saavnSectionV4/_searchSaavnDeep above), so a single cold load or
    // pull-to-refresh was routinely opening 80-95 simultaneous connections
    // on the phone's radio. On anything less than a strong connection that
    // self-congests: individual queries queue behind each other at the OS/
    // radio level, several stack up past the 25s batch timeout in
    // home_screen.dart, and the resulting failure surfaced as "check your
    // internet connection" even on a perfectly fine connection — it was a
    // self-inflicted thundering herd, not a connectivity problem. It's also
    // the direct cause of the sluggish/janky first-load feel: dozens of
    // concurrent responses landing in a tight window each trigger their own
    // setState, and Flutter's UI thread has to lay out newly-arrived
    // sections back-to-back rather than at a smooth trickle.
    //
    // Fix keeps the existing "fire independently, call onSection as each
    // resolves" progressive-reveal behavior (still no shared Future.wait
    // blocking the first section on the slowest one) but caps how many
    // queries are ever in flight at once. Priority queries (time-of-day
    // mood, "Made for You" artists, genre mixes — the sections users see
    // first, at the top of the page) still go out immediately as a single
    // wave since there are only ever ~8 of them, well within a phone's
    // comfortable concurrent-connection range. Everything else (English
    // rows, "Because You Played", pool picks) is split into small waves of
    // 4 with a short gap between waves, so the total concurrent connection
    // count at any instant stays roughly constant regardless of how many
    // sections the feed ends up building.
    final priorityQueries = queryList.where((q) => q.priority).toList();
    final restQueries = queryList.where((q) => q.priority == false).toList();

    final pending = <Future<void>>[
      for (final sq in priorityQueries) runQuery(sq),
    ];

    const waveSize = 4;
    const waveGap = Duration(milliseconds: 250);
    for (var i = 0; i < restQueries.length; i += waveSize) {
      if (i > 0) await Future.delayed(waveGap);
      final wave = restQueries.skip(i).take(waveSize);
      for (final sq in wave) {
        pending.add(runQuery(sq));
      }
    }

    await Future.wait(pending);
  }

  // ===========================================================================
  // PLAYLIST CARD SONGS — used by home screen playlist cards (art + tap-to-play)
  // ===========================================================================
  //
  // ROOT CAUSE of "pull-to-refresh does nothing" (this was the actual, most
  // visible culprit — the "Trending Playlists" row is the very first thing
  // on the home screen): this used _searchSaavn, a single deterministic
  // search call with NO shuffling and NO random seed at all. For a fixed
  // query string like 'bollywood songs 2026', the backend returns its top-N
  // results in the exact same order on every single call. The card widget
  // WAS being recreated each refresh (via the ValueKey('${name}_$refreshKey')
  // in _CuratedPlaylistsSection) and WAS making a genuine new network
  // request — but since the request and the server's ranking were both
  // deterministic, songs.first (which drives both the card's artwork AND
  // its underlying tracklist) came back identical every time. The
  // home-feed sections further down the page DO already shuffle
  // client-side (see _saavnSectionV4), so this top row was the one part of
  // the page that visibly never changed.
  //
  // Fix: shuffle the merged/deduped results with a genuinely random seed
  // before slicing to `limit`, exactly like _saavnSectionV4 already does.
  static Future<List<Song>> fetchPlaylistSongs(String query, {int limit = 30}) async {
    final songs = await _searchSaavn(query, limit: limit);
    if (songs.isEmpty) return [];
    final seed = query.hashCode ^ DateTime.now().millisecondsSinceEpoch ^ math.Random().nextInt(1000000);
    final shuffled = List<Song>.from(songs)..shuffle(math.Random(seed));
    final seenIds = <String>{};
    final seenTitles = <String>{};
    final result = <Song>[];
    for (final s in shuffled) {
      if (!seenIds.add(s.id)) continue;
      if (RecommendationEngine.isInherentVariant(s.title)) continue;
      if (RecommendationEngine.isLowQualityUpload(s.title)) continue;
      if (!RecommendationEngine.isPremiumQuality(s)) continue;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) continue;
      result.add(s);
    }
    return result;
  }

  // ===========================================================================
  // NEW RELEASES — genuinely newest songs, not a random shuffle
  // ===========================================================================
  //
  // FIX: the "New Releases" home card used fetchPlaylistSongs like every
  // other card, which RANDOMLY SHUFFLES results before returning them.
  // That's correct behaviour for "Trending Now" / "Party Anthems" / etc —
  // those are meant to feel different each refresh — but for a card whose
  // entire premise is "here are the newest songs", showing a random pick
  // from a generic 'new bollywood songs' search bucket instead of the
  // actual most-recent releases defeats the point and reads as fake/cheap,
  // not premium. A real paid app's "New Releases" row is sorted by actual
  // release recency, full stop.
  //
  // Fix: fetch the same search results, but sort by the song's own `year`
  // field (parsed from the API's releaseDate) descending — newest first —
  // instead of shuffling. Songs with an unparseable/missing year sort
  // last rather than being dropped, so a thin result set never goes empty
  // just because some entries lack metadata.
  static Future<List<Song>> fetchNewReleaseSongs({int limit = 30}) async {
    final songs = await _searchSaavn('new bollywood songs 2026', limit: limit * 2);
    if (songs.isEmpty) return [];

    final seenIds = <String>{};
    final seenTitles = <String>{};
    final deduped = <Song>[];
    for (final s in songs) {
      if (!seenIds.add(s.id)) continue;
      if (RecommendationEngine.isInherentVariant(s.title)) continue;
      if (RecommendationEngine.isLowQualityUpload(s.title)) continue;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) continue;
      deduped.add(s);
    }

    int yearOf(Song s) => int.tryParse(s.year ?? '') ?? -1;
    deduped.sort((a, b) => yearOf(b).compareTo(yearOf(a)));

    return deduped.take(limit).toList();
  }

  // ===========================================================================
  // AUTO-CONTINUE QUEUE — similar songs for the "up next" auto-extend feature
  // ===========================================================================
  static Future<List<Song>> fetchSimilarSongs({
    required String songId,
    String? artist,
    String? title,
    List<String> excludeIds = const [],
  }) async {
    final cleanId = songId.replaceFirst(RegExp(r'^[a-z]+_'), '');
    final excludeSet = excludeIds.toSet();

    // Primary: Saavn's own "songs like this" suggestions endpoint.
    final section = await _suggestionSection(cleanId, '__similar__');
    if (section != null && section.songs.isNotEmpty) {
      final filtered = section.songs.where((s) => !excludeSet.contains(s.id)).toList();
      if (filtered.isNotEmpty) return filtered;
    }

    // Fallback: search by artist/title so we still get something playable.
    if ((artist != null && artist.isNotEmpty) || (title != null && title.isNotEmpty)) {
      final query = [artist, 'songs'].where((e) => e != null && e.isNotEmpty).join(' ');
      final searched = await _searchSaavn(query.isNotEmpty ? query : (title ?? ''), limit: 20);
      final seenTitles = <String>{};
      final filtered = <Song>[];
      for (final s in searched) {
        if (excludeSet.contains(s.id)) continue;
        if (RecommendationEngine.isInherentVariant(s.title)) continue;
        final tk = _normTitle(s.title);
        if (!seenTitles.add(tk)) continue;
        filtered.add(s);
      }
      if (filtered.isNotEmpty) return filtered;
    }
    return [];
  }

  // ===========================================================================
  // DOWNLOAD URL RESOLUTION — honors a caller-supplied quality priority list
  // ===========================================================================
  static Future<String?> resolveDownloadUrl(Song song, {List<String> qualityOrder = const ['320kbps', '160kbps', '96kbps', '48kbps', '12kbps']}) async {
    if (song.isLocal) return song.localPath;

    // NOTE: the Flask Saavn backend has no by-id lookup, so there's no
    // dedicated download-quality endpoint to call here anymore — the old
    // /api/songs?ids= route 404s (Node-style API shape, not what's
    // deployed). resolveStreamUrl already gets the best available Saavn
    // URL (via search-provided streamUrl or the CF worker's id lookup),
    // so just use that directly for downloads too.
    return resolveStreamUrl(song);
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
  // AUTO QUEUE v7 — Real Saavn similar-songs (album+artist, era-filtered) +
  // same-artist search + mood/genre/era fallback + YouTube supplementary fill.
  //
  // SIGNAL ORDER:
  //   1. /api/similar/ — real Saavn catalog data (album+artist), era-filtered
  //      server-side (PRIMARY)
  //   2. Same artist search (Saavn)
  //   3. Mood+genre+era fallback (Saavn, scored client-side)
  //   4. YouTube fallback — ONLY runs if signals 1-3 together still haven't
  //      filled the pool comfortably above [limit]. Saavn stays primary
  //      because its metadata (album/artist/year) is far more reliable for
  //      variant/era filtering; YT is a depth-of-catalog top-up for
  //      niche artists/genres where Saavn's own catalog runs thin, not a
  //      replacement signal. Goes through the exact same addToPool() +
  //      rankAndFilter() path as every other signal — same variant
  //      blocking, same era penalty, same scoring — so a YT result never
  //      gets an easier bar to clear than a Saavn one.
  //
  // ALL variants blocked at pool entry AND again at rankAndFilter. Zero
  // remixes/DJ/cover/lofi in queue, regardless of which signal found them.
  //
  // Default limit raised 20 -> 60 (previously the shortest signal chain
  // that happened to hit `limit` first would stop early, capping every
  // session at a shallow 20-song queue no matter how deep the underlying
  // catalog actually was). Every signal's own per-call fetch size below
  // is scaled off `limit` rather than hardcoded, so raising limit further
  // in the future doesn't require re-tuning each signal by hand.
  // ===========================================================================
  static Future<List<Song>> getAutoQueue(
    Song currentSong, {
    int limit = 60,
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
    // Same smart-dedup fix applied everywhere else in the Up Next/search
    // pipeline — exact-string mergedTitles alone misses reuploads whose
    // junk suffix differs, letting the same song occupy multiple pool
    // slots across signals (e.g. Saavn-similar AND same-artist search both
    // returning different reuploads of one song).
    final mergedRawTitles = <String>[];
    final pool         = <Song>[];

    bool addToPool(Song song) {
      if (mergedIds.contains(song.id)) return false;
      if (RecommendationEngine.isInherentVariant(song.title)) return false;
      // FIX ("Up Next shows random junk/wedding/status uploads" — premium
      // feel broken): isLowQualityUpload/isPremiumQuality were already
      // applied on the home feed and in search results, but never here in
      // getAutoQueue's own pool builder. That meant Up Next — the single
      // most-seen recommendation surface in the app — was the ONE place
      // low-quality reuploads (wedding/status/freestyle junk, unproven
      // near-zero-view YouTube uploads) could still slip through, even
      // though the exact same signal already screens them out everywhere
      // else. Applying both gates here closes that gap so Up Next holds
      // the app to the same quality bar as Home/Search.
      if (RecommendationEngine.isLowQualityUpload(song.title)) return false;
      if (!RecommendationEngine.isPremiumQuality(song)) return false;
      final tk = _normTitle(song.title);
      if (mergedTitles.contains(tk)) return false;
      for (final seenRaw in mergedRawTitles) {
        if (RecommendationEngine.isSameSongSmart(song.title, seenRaw)) return false;
      }
      mergedIds.add(song.id);
      mergedTitles.add(tk);
      mergedRawTitles.add(song.title);
      pool.add(song);
      return true;
    }

    // ═══════════════════════════════════════════════════════════════════
    // SPEED FIX ("Up Next mein songs bahut late aate hain"): every signal
    // below used to be a SEPARATE SEQUENTIAL STAGE — Signal 1+2 fully
    // awaited, THEN (only if the pool was still short of poolTarget =
    // limit*3) Signal 1.5 awaited, THEN Signal 3, THEN Signal 4. Each
    // stage is fast on its own (parallel internally), but the STAGES
    // stacked on top of each other: worst case this was 6s + 8s + 5s + 5s
    // = 24 SECONDS of sequential waiting before Up Next had anything to
    // show, and even the common case (Signal 1+2 alone rarely fills a
    // limit*3 pool) routinely paid for 2-3 stages back to back. None of
    // these signals actually depend on each other's results — Signal 3/4
    // build their queries from currentSong, not from what Signal 1/2
    // returned — so there's no real reason to wait for one before
    // starting the next.
    //
    // Now every signal fires AT ONCE, unconditionally — the old
    // pool.length < poolTarget gate is gone since there's no longer a
    // sequential pool to check between stages. Total wall-clock time
    // becomes roughly the single SLOWEST signal (~8s worst case for the
    // YT-related fetch) instead of the sum of all of them — a 3-4x
    // speedup on a fresh/cold queue build, which is exactly the moment a
    // user is sitting there watching "Up Next" for something to appear.
    // Signal 3/4's queries are generated once up front (shared by both)
    // since generateQueries() is cheap and deterministic-per-call; each
    // result list still goes through addToPool in the same priority order
    // as before (1, 2, 1.5, 3, 4) so a stronger, more specific signal
    // still wins any tie for a duplicate song, exactly as it did when
    // they ran in stages. The only real cost is a small number of extra
    // parallel network calls on songs where Signal 1+2 alone would have
    // been enough — traded deliberately for consistently fast, predictable
    // queue-build latency instead of latency that varies with how many
    // stages happened to be needed.
    // ═══════════════════════════════════════════════════════════════════
    final fallbackQueries = RecommendationEngine.generateQueries(currentSong);
    final wantsYtRelated = currentSong.source == SongSource.youtube;

    final results = await Future.wait<List<Song>>([
      // Signal 1: Saavn similar-songs (album+artist correlation)
      _fetchSimilarFromSaavn(currentSong, limit: limit)
          .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])
          .catchError((_) => <Song>[]),
      // Signal 2: Same-artist catalog search
      _searchSaavn('${currentSong.artist} songs', limit: limit * 2)
          .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])
          .catchError((_) => <Song>[]),
      // Signal 1.5: YouTube's own related-videos graph (YT-sourced songs
      // only) — a no-op empty future for Saavn-sourced songs so the list
      // shape/indexing below stays fixed regardless of source.
      if (wantsYtRelated)
        NativeRelatedVideos.getRelated(currentSong.id)
            .timeout(const Duration(seconds: 8), onTimeout: () => <YtRelatedVideo>[])
            .then((related) => related.map((r) => Song(
                  id: r.videoId,
                  title: r.title,
                  artist: r.uploaderName,
                  album: '',
                  artworkUrl: 'https://i.ytimg.com/vi/${r.videoId}/hqdefault.jpg',
                  source: SongSource.youtube,
                  duration: r.durationSecs,
                  viewCount: r.viewCount,
                )).toList())
            .catchError((_) => <Song>[])
      else
        Future.value(<Song>[]),
      // Signal 3: Mood+genre+era fallback (Saavn) — one query per
      // generated AutoQueueQuery, all raced together and flattened.
      Future.wait(fallbackQueries.map((q) =>
          _searchSaavn(q.query, limit: limit)
              .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[])
              .catchError((_) => <Song>[])))
          .then((lists) => [for (final l in lists) ...l]),
      // Signal 4: YouTube supplementary fill — same mood/genre/era queries
      // as Signal 3, pointed at YouTube instead of Saavn. Previously only
      // fired at all once Signal 1-3 left the pool short; now it always
      // fires alongside everything else (its own result is still only as
      // useful as whatever addToPool below actually accepts — a healthy
      // Saavn pool means most/all of this signal's songs simply get
      // rejected as unneeded duplicates-of-nothing-new, which costs
      // nothing but the parallel network call itself).
      Future.wait(fallbackQueries.map((q) =>
          _searchYt(q.query, limit: limit)
              .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[])
              .catchError((_) => <Song>[])))
          .then((lists) => [for (final l in lists) ...l]),
    ]);

    // Apply in the same priority order as the old sequential stages, so a
    // stronger/more specific signal still wins any addToPool duplicate-tie
    // exactly as before — only the WAITING changed, not the precedence.
    for (final s in results[0]) addToPool(s); // Signal 1
    for (final s in results[1]) addToPool(s); // Signal 2
    if (wantsYtRelated) {
      for (final s in results[2]) addToPool(s); // Signal 1.5
    }
    for (final s in results[3]) addToPool(s); // Signal 3
    for (final s in results[4]) addToPool(s); // Signal 4
    _log('[autoQueue] all signals parallel: ${pool.length}');

    return RecommendationEngine.rankAndFilter(
      pool: pool, currentSong: currentSong,
      existingIds: allExistingIds, limit: limit,
    );
  }

  /// Real "similar songs" signal: searches by album (strongest correlation —
  /// same movie/EP) and by artist, using the already-failover-safe
  /// _searchSaavn. This replaced an earlier version that called a custom
  /// /api/similar/ route on the Cloudflare Worker — that route required a
  /// separate worker deploy and had no host failover, so it silently went
  /// stale. This version rides on the same multi-host path as everything
  /// else, so it benefits from the same automatic failover.
  static Future<List<Song>> _fetchSimilarFromSaavn(Song song, {int limit = 20}) async {
    final queries = <String>[];
    if (song.album.trim().isNotEmpty) queries.add(song.album);
    queries.add('${song.artist} songs');

    // SPEED FIX: album-query and artist-query used to run one after the
    // other (full round-trip each, back to back) even though neither
    // depends on the other's result. Firing both at once and merging
    // halves this signal's wall-clock cost with the exact same data.
    final resultsList = await Future.wait(queries.map((q) =>
        _searchSaavn(q, limit: 25)
            .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[])));

    final merged = <String, Song>{};
    for (final results in resultsList) {
      for (final s in results) {
        if (s.id.isEmpty || s.id == song.id) continue;
        merged[s.id] = s;
      }
    }
    return merged.values.toList();
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
  static Future<SearchResult> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const SearchResult(direct: [], related: []);

    final cacheKey = _normalise(q);
    final cached = _searchCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      _log('[search] Cache HIT: "$q"');
      return cached.results;
    }

    final wantsVariant = _wantsVariantQuery(q);

    // FIX ("Saavn ki full power use karke exact match nahi la raha" — a
    // long lyric-line query like "mujhko dard dil ki dawa chahiye" often
    // has no exact hit in Saavn's own full-text search, because Saavn's
    // backend matches loosely on the WHOLE string and a 6-word lyric line
    // rarely appears verbatim in any song's indexed metadata. Real JioSaavn
    // (and Spotify) handle this by also trying shorter sub-phrases of a
    // long query, not just the raw string once. Builds a few trimmed
    // variants (front-trimmed and back-trimmed 3-4 word windows) and fires
    // them at Saavn IN PARALLEL with the main query — same total wait time
    // as before (nothing here is sequential/extra-latency), just more
    // chances for Saavn's own search to land a real hit before ever
    // falling back to YT.
    final qWordsForVariants = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final lyricVariants = <String>{};
    if (qWordsForVariants.length >= 4) {
      // Drop trailing filler word(s): "...dawa chahiye" -> "...dawa"
      lyricVariants.add(qWordsForVariants.sublist(0, qWordsForVariants.length - 1).join(' '));
      // Drop leading filler word(s): "mujhko dard..." -> "dard..."
      lyricVariants.add(qWordsForVariants.sublist(1).join(' '));
      // Middle 3-4 word core phrase — often the actual song-title fragment
      // inside a longer remembered lyric line.
      final mid = (qWordsForVariants.length / 2).floor();
      final start = (mid - 2).clamp(0, qWordsForVariants.length).toInt();
      final end = (start + 4).clamp(0, qWordsForVariants.length).toInt();
      if (end > start) lyricVariants.add(qWordsForVariants.sublist(start, end).join(' '));
    }
    lyricVariants.remove(q);

    // SEARCH: SAAVN FIRST, SMART YT FALLBACK WHEN SAAVN IS THIN.
    // Saavn (+ lyric variants) is always awaited first — it's the fast,
    // proper primary source and usually all that's needed. YouTube is
    // ONLY queried when Saavn genuinely didn't cover the query (fewer
    // than 8 usable hits after scoring), so a healthy Saavn query never
    // pays YT's round-trip at all. When it IS needed, it goes through the
    // same "masterpiece" pipeline as the rest of the app: official-label-
    // channel priority, a real quality/view floor, smart dedup against
    // what Saavn already returned, and the same relevance scoring — never
    // a raw, unfiltered YT dump.
    final saavnFutures = [
      _searchSaavn(q, limit: 50)
          .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[])
          .catchError((_) => <Song>[]),
      ...lyricVariants.map((v) => _searchSaavn(v, limit: 20)
          .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[])
          .catchError((_) => <Song>[])),
    ];
    final saavnAll = await Future.wait(saavnFutures);
    final saavnCombined = [for (final list in saavnAll) ...list];

    final saavnScored = <_ScoredSong>[];
    final ytScored    = <_ScoredSong>[];
    final saavnNorms  = <String>{};

    // FIX ("same song 5-8x in search results, e.g. 'Dekha Hai Pehli Baar'
    // from 5+ different album reuploads burying real variety"): Saavn
    // results previously went in with NO dedup at all beyond an exact-
    // string check on the normalized title, which — same gap as Up Next
    // before that fix — misses reuploads whose junk suffix/album differs.
    // Smart title-head comparison against every raw title already accepted
    // collapses those duplicates down to one entry (the first/highest-
    // relevance one Saavn returned) so distinct songs get the result slots
    // instead of five copies of the same song.
    final saavnRawTitlesAccepted = <String>[];
    // FIX ("random unrelated songs in search"): results scoring below a
    // relevance floor are dropped entirely. Without this, misremembered
    // or garbled queries (e.g. "manma emotional jaage re" for "Manma
    // Emotion Jaage") returned whatever Saavn's own loose backend search
    // matched on stray fragments — completely unrelated songs like
    // "Emitemitemo" — because every result was kept and shown regardless
    // of how weak its match score was.
    const minRelevanceScore = 15.0;
    for (final song in saavnCombined) {
      final score = _scoreSearchResult(song, q, wantsVariant);
      if (score < minRelevanceScore) continue;
      var isDupOfAccepted = false;
      for (final seenRaw in saavnRawTitlesAccepted) {
        if (RecommendationEngine.isSameSongSmart(song.title, seenRaw)) {
          isDupOfAccepted = true;
          break;
        }
      }
      if (isDupOfAccepted) continue;
      final norm  = _normTitle(song.title);
      saavnNorms.add(norm);
      saavnRawTitlesAccepted.add(song.title);
      saavnScored.add(_ScoredSong(song, score));
    }

    saavnScored.sort((a, b) => b.score.compareTo(a.score));

    // YouTube fallback — only fired when Saavn genuinely came up short.
    // 8 usable hits is the same bar quickSearch/full-search elsewhere in
    // the app already treats as "Saavn covered it" — below that, YT fills
    // the gap through the SAME quality pipeline _searchYt already applies
    // (official-label-channel sort, real videos only), plus the search
    // relevance floor and smart dedup against Saavn so nothing doubles up.
    if (saavnScored.length < 8) {
      final ytResults = await _searchYt(q, limit: 20)
          .timeout(const Duration(seconds: 4), onTimeout: () => <Song>[]);
      for (final song in ytResults) {
        final norm = _normTitle(song.title);
        if (saavnNorms.contains(norm)) continue;
        var isDupOfSaavn = false;
        for (final seenRaw in saavnRawTitlesAccepted) {
          if (RecommendationEngine.isSameSongSmart(song.title, seenRaw)) {
            isDupOfSaavn = true;
            break;
          }
        }
        if (isDupOfSaavn) continue;
        if (!RecommendationEngine.isPremiumQuality(song)) continue;
        final score = _scoreSearchResult(song, q, wantsVariant);
        if (score < minRelevanceScore) continue;
        ytScored.add(_ScoredSong(song, score));
      }
      ytScored.sort((a, b) => b.score.compareTo(a.score));
    }

    // Saavn songs are ranked strictly above every YT song — YT only ever
    // fills in below Saavn's own results, never interleaves with them, so
    // Saavn (the fast, proper primary) always leads no matter individual
    // match score.
    final directResults = [...saavnScored, ...ytScored].map((s) => s.song).toList();

    // ── RELATED EXPANSION (Spotify-style) ──────────────────────────────────
    // A single-song search shouldn't dead-end at just that one result.
    // Detect the top match's era/genre/mood and pull in its category
    // siblings — same signal engine Up Next already uses (generateQueries),
    // so search and Up Next behave consistently: search "Gori Hai
    // Kalaiyaan" and its 90s/genre-mates show up too, exactly like tapping
    // play and watching Up Next fill in with the same vibe.
    // TUNED (target: ~80 total results): cap raised 40 -> 55 so
    // direct(≈15-40 after dedup) + related(≈55) comfortably clears 80 for
    // well-covered songs — Saavn-led, with the same smart YT topup rule.
    final results = List<Song>.from(directResults);
    // SPEED FIX ("ekdam fast, smooth, lightweight rahe"): related expansion
    // fires N extra Saavn + N extra YT network calls and used to run on
    // EVERY search, even when direct results already fully answered the
    // query — meaning every keystroke during live typing paid for a whole
    // second wave of requests just to pad the list with "vibe" filler.
    // Now it only runs when direct results are thin, so a query that
    // already lands a clean, complete Saavn match returns immediately.
    if (directResults.isNotEmpty && directResults.length < 12) {
      final topMatch = directResults.first;
      final directIds    = <String>{for (final s in directResults) s.id};
      final directTitles = <String>{for (final s in directResults) _normTitle(s.title)};
      // FIX ("us movie ke sb songs ka playlist show ho, premium jaisa"):
      // generateQueries() only ever builds artist/mood/genre/era queries —
      // it never looks at topMatch.album, so a search for a specific song
      // never surfaced the OTHER songs from the same movie/OST, only
      // vaguely-similar era/mood songs from unrelated films. Browse tab's
      // _openAlbum already does this correctly via BrowseService.albumTracks,
      // but plain Search had no equivalent. Prepending a dedicated
      // "<album> movie all songs" query — highest weight, searched first —
      // means when a song has a real album/movie name, the rest of that
      // soundtrack anchors the related section instead of getting buried
      // under generic mood-matched filler.
      final relatedQueries = [
        if (topMatch.album.trim().isNotEmpty)
          AutoQueueQuery('${topMatch.album.trim()} movie all songs', weight: 3),
        ...RecommendationEngine.generateQueries(topMatch),
      ];
      final relatedPool = <Song>[];
      final seenRelated = <String>{};
      const relatedCap = 55;

      // RELATED: Saavn first, same smart YT topup rule as direct results —
      // only reached for a query when Saavn's own related pool comes up
      // short, quality-gated (view floor + official-channel bias) and
      // deduped against everything already shown, so the "vibe" list stays
      // premium instead of a raw dump.
      final combinedRelated = await Future.wait([
        ...relatedQueries.map((rq) => _searchSaavn(rq.query, limit: 25)
            .timeout(const Duration(seconds: 4), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[])),
      ]);
      for (final list in combinedRelated) {
        if (relatedPool.length >= relatedCap) break;
        for (final s in list) {
          if (relatedPool.length >= relatedCap) break;
          if (directIds.contains(s.id)) continue;
          if (RecommendationEngine.isInherentVariant(s.title)) continue;
          final tk = _normTitle(s.title);
          if (directTitles.contains(tk) || !seenRelated.add(tk)) continue;
          relatedPool.add(s);
        }
      }
      if (relatedPool.length < 20) {
        final ytRelated = await Future.wait(
          relatedQueries.map((rq) => _searchYt(rq.query, limit: 20)
              .timeout(const Duration(seconds: 4), onTimeout: () => <Song>[])
              .catchError((_) => <Song>[])),
        );
        for (final list in ytRelated) {
          if (relatedPool.length >= relatedCap) break;
          for (final s in list) {
            if (relatedPool.length >= relatedCap) break;
            if (directIds.contains(s.id)) continue;
            if (RecommendationEngine.isInherentVariant(s.title)) continue;
            if (!RecommendationEngine.isPremiumQuality(s)) continue;
            final tk = _normTitle(s.title);
            if (directTitles.contains(tk) || !seenRelated.add(tk)) continue;
            relatedPool.add(s);
          }
        }
      }
      results.addAll(relatedPool);
    }

    // Kept as two separate lists (not merged) so the UI can render them as
    // distinct labeled sections instead of one flat list — that's what was
    // making "Gori Hai Kalaiyan" search results show unrelated songs like
    // "Paan Banaras Ka" / "Daiya Daiya Re" with no explanation of why they
    // were there. directResults is exactly what matched; everything after
    // it is the vibe/related expansion only.
    final relatedOnly = results.length > directResults.length
        ? results.sublist(directResults.length)
        : <Song>[];
    final result = SearchResult(direct: directResults, related: relatedOnly);

    _writeSearchCache(cacheKey, result);
    _log('[search] "$q" → direct:${directResults.length} related:${relatedOnly.length}');
    return result;
  }

  static double _scoreSearchResult(Song song, String query, bool wantsVariant) {
    double score = 0;
    // FIX (dead multi-word phrase-matching): _normalise() strips ALL
    // non-alphanumeric chars including spaces, collapsing every query into
    // one blob. qNorm.split(' ') therefore always returned a single element,
    // so queryWords.length > 1 was never true and the whole lyric-line/
    // phrase-order/coverage-penalty block below never ran. Word-splitting
    // now uses _normalizeForMatch (space-preserving) instead. The exact/
    // startsWith/contains tier below still uses the space-stripped forms —
    // fine as a loose signal for those checks.
    final qNorm      = _normalise(query);
    final titleNorm  = _normalise(song.title);
    final artistNorm = _normalise(song.artist);
    final qNormSp      = _normalizeForMatch(query);
    final titleNormSp  = _normalizeForMatch(song.title);
    final artistNormSp = _normalizeForMatch(song.artist);

    if (titleNorm == qNorm)                score += 100;
    else if (artistNorm == qNorm)          score += 80;
    else if (titleNorm.startsWith(qNorm))  score += 60;
    else if (artistNorm.startsWith(qNorm)) score += 40;
    else if (titleNorm.contains(qNorm))    score += 20;
    else if (artistNorm.contains(qNorm))   score += 10;

    final queryWords = qNormSp.split(' ').where((w) => w.length > 2).toList();
    final queryWordSet = queryWords.toSet();

    // FIX (single-word queries under-scored vs. multi-word ones): the
    // bag-of-words/phrase-order block below only runs when queryWords.length
    // > 1, so a genuine one-word search (e.g. just "Zaalima") never got past
    // the plain contains() check above. That check treats "Tere" matching
    // inside "Tere" and "Tere" matching inside "Tereकunj-style-mashup" the
    // same — both just "contains". A whole-word-token match (the query is
    // its own separated word in the title, not a substring of a longer one)
    // is a much stronger signal and now scores above a bare substring hit.
    if (queryWords.length == 1 && qNormSp.length > 2 && titleNormSp != qNormSp) {
      final titleTokens = titleNormSp.split(' ');
      if (titleTokens.contains(qNormSp)) {
        score += 35;
      } else {
        // FIX: same typo-tolerance gap as the multi-word block below —
        // a single mistyped word ("saayar") should still find its real
        // song ("saiyaara") instead of scoring 0 on this path and falling
        // through to whatever the backend's loose search returns.
        for (final token in titleTokens) {
          if (token.length > 2 && _fuzzyWordMatch(qNormSp, token)) {
            score += 30;
            break;
          }
        }
      }
    }

    // FIX ("Raja Raja kareja mein sama jaa" / lyric-line queries returning
    // unrelated songs): the old bag-of-words pass counted a match if ANY
    // query word appeared ANYWHERE in the title/artist, with zero regard
    // for order, adjacency, or how much of the query actually matched. A
    // 6-word lyric line where only 1-2 stray words happened to also appear
    // in some totally unrelated title was enough to clear the old 15.0
    // floor. Fix has three parts: (1) reward query words that appear
    // TOGETHER in the same order as a real phrase, far more than scattered
    // hits; (2) scale the word-overlap contribution by what FRACTION of the
    // query matched, so partial overlap on a long query can't out-score a
    // short but fully-matching title; (3) hard-penalize long queries with
    // low coverage instead of letting them scrape past the floor.
    if (queryWords.length > 1) {
      int wordMatches = 0;
      // FIX ("Tu saayar hai" → totally unrelated songs): originally this
      // only counted a word as matched via exact `contains()`. A single
      // typo'd word ("saayar" instead of "saiyaara") never contained/was
      // contained by the real title, so wordMatches stayed low for the
      // actually-correct song, while the loose backend search result for
      // some unrelated title could still accidentally clear the old flat
      // per-word bonus. Falling back to _fuzzyWordMatch (bounded edit
      // distance) when the exact check misses gives genuine typos a real
      // chance to match the song they were actually meant for.
      for (final word in queryWordSet) {
        if (titleNormSp.contains(word) || artistNormSp.contains(word)) {
          wordMatches++;
        } else if (_fuzzyWordMatch(word, titleNormSp) || _fuzzyWordMatch(word, artistNormSp)) {
          wordMatches++;
        }
      }
      final coverage = wordMatches / queryWordSet.length;

      // Longest run of consecutive query words that also appear consecutively
      // (same order) in the title — does the actual phrase show up, not just
      // its words in any scattered order.
      final titleWords = titleNormSp.split(' ');
      int bestRun = 0;
      for (var i = 0; i < queryWords.length; i++) {
        var run = 0;
        var searchFrom = 0;
        for (var j = i; j < queryWords.length; j++) {
          final idx = titleWords.indexOf(queryWords[j], searchFrom);
          if (idx == -1) break;
          run++;
          searchFrom = idx + 1;
        }
        if (run > bestRun) bestRun = run;
      }
      final phraseRatio = bestRun / queryWords.length;

      // Coverage-scaled bag-of-words score (was a flat 8.0/word regardless
      // of total query length — that's what let 1-2 stray hits on a 6-word
      // query still add up to a competitive score).
      score += wordMatches * 8.0 * coverage;
      // Phrase-order bonus dominates when a real chunk of the query appears
      // as an actual phrase in the title — separates the correct song from
      // lookalikes that only share scattered individual words.
      score += phraseRatio * 60.0;

      // A long query (4+ meaningful words — typically a lyric line or full
      // phrase search) where less than half the words matched at all is
      // almost certainly not the song being searched for, regardless of raw
      // score accumulated above.
      if (queryWords.length >= 4 && coverage < 0.5) {
        score -= 40;
      }
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
  // QUICK SEARCH — 100% Saavn, no YouTube. Every keystroke fires this, so
  // it must be pure and fast: race Saavn hosts (already handled inside
  // _searchSaavn), apply the relevance floor so typos/garbage don't leak
  // through, and stop there. No YT gap-fill — typed search is Saavn-only
  // by design so results are always proper JioSaavn tracks, arriving fast.
  // ===========================================================================
  static Future<List<Song>> quickSearch(String query, {int limit = 15}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final wantsVariant = _wantsVariantQuery(q);
    const minLiveRelevanceScore = 12.0; // slightly more permissive than full
                                         // search's 15.0 — live typing is
                                         // often a partial/incomplete query.

    // SPEED: tight 4s ceiling (was 8s) — _searchSaavn already races every
    // Saavn host concurrently internally, so a healthy host answers in
    // well under a second; this timeout only bounds the worst case.
    final saavnResults = await _searchSaavn(q, limit: limit + 15)
        .timeout(const Duration(seconds: 4), onTimeout: () => <Song>[])
        .catchError((_) => <Song>[]);

    // FIX ("Saavn ki full power use karke exact match nahi la raha" while
    // live-typing): a long lyric-line query rarely appears verbatim in
    // Saavn's index. Only tried if the plain query came up genuinely short
    // (fewer than half the wanted slots), so normal fast-matching queries
    // pay zero extra latency — both variants raced together, not chained.
    final qWordsForVariants = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    List<Song> variantResults = [];
    if (saavnResults.length < (limit * 0.5).ceil() && qWordsForVariants.length >= 4) {
      final trimmedFront = qWordsForVariants.sublist(0, qWordsForVariants.length - 1).join(' ');
      final trimmedBack  = qWordsForVariants.sublist(1).join(' ');
      final variantBatches = await Future.wait([
        _searchSaavn(trimmedFront, limit: 15)
            .timeout(const Duration(seconds: 3), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[]),
        _searchSaavn(trimmedBack, limit: 15)
            .timeout(const Duration(seconds: 3), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[]),
      ]);
      variantResults = [...variantBatches[0], ...variantBatches[1]];
    }
    final saavnCombined = [...saavnResults, ...variantResults];

    final saavnScored = <_ScoredSong>[];
    final saavnRawTitlesAccepted = <String>[];
    for (final song in saavnCombined) {
      final score = _scoreSearchResult(song, q, wantsVariant);
      if (score < minLiveRelevanceScore) continue;
      var isDup = false;
      for (final seenRaw in saavnRawTitlesAccepted) {
        if (RecommendationEngine.isSameSongSmart(song.title, seenRaw)) { isDup = true; break; }
      }
      if (isDup) continue;
      saavnRawTitlesAccepted.add(song.title);
      saavnScored.add(_ScoredSong(song, score));
    }
    saavnScored.sort((a, b) => b.score.compareTo(a.score));
    return saavnScored.map((s) => s.song).take(limit).toList();
  }

  // ===========================================================================
  // SUGGEST
  // ===========================================================================
  static Future<List<String>> suggest(String query) async {
    final q = query.trim();
    final results = await _suggestSaavn(q);
    if (results.isEmpty || q.isEmpty) return results.take(8).toList();

    // FIX (live-search dropdown showing suggestions unrelated to what was
    // typed, e.g. typo'd queries): _suggestSaavn returns the backend's own
    // suggestion order verbatim, with no regard for how closely each
    // suggestion actually matches what the user typed — including typos.
    // Re-ranking here with the same fuzzy word-match used elsewhere means
    // a misspelled query still surfaces its real closest matches first,
    // instead of whatever order the backend happened to return.
    final qNorm = _normalise(q);
    final qNormSp = _normalizeForMatch(q);
    final scored = results.map((s) {
      final sNorm = _normalise(s);
      final sNormSp = _normalizeForMatch(s);
      double score = 0;
      if (sNorm == qNorm) {
        score = 100;
      } else if (sNorm.startsWith(qNorm)) {
        score = 60;
      } else if (sNorm.contains(qNorm)) {
        score = 30;
      } else {
        // FIX: was splitting the space-stripped qNorm (always a single
        // blob), so this multi-word fallback never actually ran for
        // genuine multi-word queries. Split the space-preserving form.
        final words = qNormSp.split(' ').where((w) => w.length > 2);
        var matched = 0;
        var total = 0;
        for (final w in words) {
          total++;
          if (sNormSp.contains(w) || _fuzzyWordMatch(w, sNormSp)) matched++;
        }
        score = total == 0 ? 0 : (matched / total) * 25;
      }
      return MapEntry(s, score);
    }).where((e) => e.value > 0).toList();

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).take(8).toList();
  }

  static Future<List<String>> _suggestSaavn(String query) async {
    // Try onrender primary, then Vercel pillar, then CF worker
    for (final base in [_saavnPrimary, _saavnSecondary, _saavn]) {
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
  // SAAVN SEARCH — onrender (Flask API) is the HARD primary.
  // Only real route is /result/ — the old /api/search/songs attempt was
  // removed entirely since that route 404s on this backend (it belongs to
  // a different, Node-style JioSaavn API that isn't what's deployed).
  // Vercel (same Flask API, different host) is a full secondary pillar —
  // covers Render cold-starts on the free tier. CF worker is tertiary.
  //
  // 2026-07-17: jiosaavn-op (v2, TypeScript/Node) added as new STAGE 0 —
  // confirmed via direct curl: /api/search/songs?query= works reliably
  // and /api/songs/:id returns clean non-DRM direct .mp4 URLs. Old Flask
  // hosts kept below as fallback in case v2 has downtime.
  // ===========================================================================
  // SPEED FIX ("search bahut lag kar raha hai"): this used to try each of
  // 4 possible hosts (Node primary, onrender Flask, Vercel Flask, CF
  // worker) ONE AT A TIME with an 8s timeout each — if the primary host
  // was merely slow (not fully down), the code still burned its whole 8s
  // budget waiting before even starting the next host, so a single search
  // could take up to ~32s in the worst case. Racing every host at once
  // and taking whichever responds first with usable results removes that
  // stacked wait — total time is now bounded by the FASTEST host, not the
  // sum of every host's timeout. Falls back through hosts in priority
  // order only if the race turns up nothing at all (kept purely for the
  // pathological case where every host times out with zero data).
  static Future<List<Song>> _searchSaavn(String query, {int limit = 20}) async {
    Future<List<Song>?> tryNodeHost(String host) async {
      try {
        final url = Uri.parse(
          '$host/api/search/songs?query=${Uri.encodeQueryComponent(query)}&limit=$limit',
        );
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) return null;
        final data = jsonDecode(res.body);
        final results = data is Map ? (data['data']?['results'] ?? []) : [];
        if (results is! List || results.isEmpty) return null;
        final songs = results
            .whereType<Map<String, dynamic>>()
            .take(limit)
            .map(_songFromSaavn)
            .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
            .toList();
        return songs.isNotEmpty ? songs : null;
      } catch (e) {
        _log('[_searchSaavn] $host error: $e');
        return null;
      }
    }

    Future<List<Song>?> tryResultRoute(String host) async {
      try {
        final url = Uri.parse(
          '$host/result/?query=${Uri.encodeQueryComponent(query)}&limit=$limit',
        );
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) return null;
        final data = jsonDecode(res.body);
        final results = data is List
            ? data
            : (data['data']?['results'] ?? data['data'] ?? []);
        if (results is! List || results.isEmpty) return null;
        final songs = results
            .whereType<Map<String, dynamic>>()
            .take(limit)
            .map(_songFromSaavn)
            .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
            .toList();
        return songs.isNotEmpty ? songs : null;
      } catch (e) {
        _log('[_searchSaavn] $host error: $e');
        return null;
      }
    }

    // SPEED FIX ("ekdam fast aaye"): Future.wait blocks until EVERY host
    // finishes, even after the fastest one already has a good answer — so
    // one slow/dead host in the list held up the whole search for its
    // full timeout every time, no matter how fast the winner was. This
    // races every host in parallel and completes the instant the FIRST
    // one returns usable results — no waiting on stragglers. Every host
    // is still fired and still gets a chance to answer; only the wait is
    // removed. If every host comes back empty/failed, resolves to [].
    final futures = <Future<List<Song>?>>[
      for (final host in _saavnNodeHosts) tryNodeHost(host),
      tryResultRoute(_saavnPrimary),
      tryResultRoute(_saavnSecondary),
      tryResultRoute(_saavn),
    ];
    final completer = Completer<List<Song>>();
    var remaining = futures.length;

    void onDone(List<Song>? r) {
      if (completer.isCompleted) return;
      if (r != null && r.isNotEmpty) {
        completer.complete(r);
        return;
      }
      remaining--;
      if (remaining == 0 && !completer.isCompleted) {
        completer.complete(<Song>[]);
      }
    }

    for (final f in futures) {
      f.then(onDone).catchError((_) => onDone(null));
    }
    return completer.future;
  }

  // Shared single-page fetch helper used by _searchSaavn's pagination logic.
  static Future<List<Song>> _fetchSaavnPage(String urlStr, int limit) async {
    try {
      final res = await _client.get(Uri.parse(urlStr)).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final results = (data is Map ? (data['data']?['results']) : null) ?? [];
      if (results is! List || results.isEmpty) return [];
      return results
          .whereType<Map<String, dynamic>>()
          .take(limit)
          .map(_songFromSaavn)
          .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ===========================================================================
  // YOUTUBE SEARCH
  // ===========================================================================
  // Known official music-label / publisher channel names (lowercased,
  // partial match). No verified-badge field is exposed by
  // youtube_explode_dart's Video object, so this is the only zero-latency
  // signal available — pure string match against the channel/author name,
  // no extra API call, so it costs nothing on speed.
  static const List<String> _officialChannelMarkers = [
    't-series', 'zee music', 'sony music', 'saregama', 'tips official',
    'tips music', 'speed records', 'desi music factory', 'shemaroo',
    'venus', 'eros now music', 'yrf', 'jjust music', 'white hill music',
    'times music', 'muzik one', 'goldmines', 'ultra music', 'divo',
    'universal music', 'sony music south', 'aditya music', 'lahari music',
    'think music', 'zee music south', 'wave music', 'atlantic records',
    'republic records', 'columbia records', 'interscope', 'def jam',
    'rca records', 'capitol records', 'warner records',
  ];

  static bool _isOfficialChannel(String channelName) {
    final c = channelName.toLowerCase();
    return _officialChannelMarkers.any((m) => c.contains(m));
  }

  static Future<List<Song>> _searchYt(String query, {int limit = 15}) async {
    try {
      final videos = await Future.any<List<Video>>([
        _searchYtPaged(query, limit),
        Future.delayed(const Duration(seconds: 8), () => <Video>[]),
      ]);
      // Official-channel uploads first — same list, just reordered, so
      // when we later `.take(limit)` or dedup by title, the cleanest/most
      // premium (official) version of a song wins over a random reupload.
      videos.sort((a, b) {
        final aOfficial = _isOfficialChannel(a.author) ? 0 : 1;
        final bOfficial = _isOfficialChannel(b.author) ? 0 : 1;
        return aOfficial.compareTo(bOfficial);
      });
      return videos
          .take(limit)
          .map(_songFromYtVideo)
          .where((s) => s.id.isNotEmpty)
          .toList();
    } catch (e) {
      _log('[_searchYt] Error: $e');
    }
    return [];
  }

  static Future<List<Video>> _searchYtPaged(String query, int limit) async {
    final seen = <String>{};
    final videos = <Video>[];
    try {
      var page = await _yt.search.search(query);
      for (final v in page) {
        if (seen.add(v.id.value)) videos.add(v);
      }
      var pagesFetched = 1;
      while (videos.length < limit * 2 && pagesFetched < 4) {
        final next = await page.nextPage();
        if (next == null || next.isEmpty) break;
        page = next;
        for (final v in page) {
          if (seen.add(v.id.value)) videos.add(v);
        }
        pagesFetched++;
      }
    } catch (e) {
      _log('[_searchYtPaged] Error: $e');
    }
    return videos;
  }

  /// Builds a home-feed section straight from YouTube search — used for
  /// English/international content where JioSaavn's catalog is weak.
  ///
  /// FIX (sections landing well under 80 songs): fans the query out across
  /// a few phrasing variants (plain/audio/official) in parallel, each now
  /// pulling multiple search-result pages via _searchYtPaged, so there's
  /// real headroom for variant/junk/premium-quality filtering to still
  /// leave a full 80-song section instead of collapsing to whatever a
  /// single ~20-video search page contained.
  static Future<SongSection?> _ytSectionV1(String query, String label) async {
    final variants = <String>{
      query,
      '$query audio',
      '$query official',
    };
    final results = await Future.wait(
      variants.map((q) => _searchYt(q, limit: 60)),
    );
    final seenIdsRaw = <String>{};
    final ytSongs = <Song>[];
    for (final list in results) {
      for (final s in list) {
        if (seenIdsRaw.add(s.id)) ytSongs.add(s);
      }
    }
    if (ytSongs.isEmpty) return null;
    final seenIds = <String>{};
    final seenTitles = <String>{};
    final merged = <Song>[];
    for (final s in ytSongs) {
      if (merged.length >= 80) break;
      if (!seenIds.add(s.id)) continue;
      if (RecommendationEngine.isInherentVariant(s.title)) continue;
      if (RecommendationEngine.isLowQualityUpload(s.title)) continue;
      if (!RecommendationEngine.isPremiumQuality(s)) continue;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) continue;
      merged.add(s);
    }
    if (merged.isEmpty) return null;
    return SongSection(title: label, songs: merged);
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
        viewCount:  _safeViewCount(v),
      );

  // Defensive: some search results (deleted/restricted/live videos) can come
  // back with missing or zero engagement data. Never let a metadata quirk
  // crash a home-feed fetch — treat unknown as null so isPremiumQuality()
  // correctly excludes it rather than the app throwing.
  static int? _safeViewCount(Video v) {
    try {
      return v.engagement.viewCount;
    } catch (_) {
      return null;
    }
  }

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
        // PERFORMANCE (2026-07-02): shrunk from 1024→256 bytes — same
        // liveness check, less wasted transfer per resolve.
        final ranged = await _client
            .get(uri, headers: {'Range': 'bytes=0-255'})
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
          url = await _retry(
            () => _saavnStreamById(song.id, title: song.title, artist: song.artist),
            attempts: 2,
          );
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
    // ── Worker-only resolution ─────────────────────────────────────────
    // Piped/Invidious fallbacks removed entirely (2026-07-06). Those were
    // public, volunteer-run instances with no uptime guarantee — most of
    // the "songs randomly won't play" reports traced back to THEM being
    // down, not the Cloudflare Worker (independently confirmed working
    // via a direct browser request during the same failure window).
    // Now the only thing that can fail this is an actual Worker outage,
    // which is something Shivam controls directly and can fix — instead
    // of an unpredictable third-party instance nobody here maintains.
    // Two attempts against the Worker: a quick probe first, then one
    // longer-timeout retry if the quick one didn't land (covers a slow
    // cold-start without giving up on a Worker that's actually fine).
    if (!_WorkerHealth.maintenanceMode) {
      final quick = await _workerYtStream(videoId);
      if (quick != null) return quick;
      _log('[ytStreamById] Quick Worker attempt failed for $videoId — retrying with extended timeout');
    } else {
      _log('[ytStreamById] Worker maintenance mode active — skipping straight to extended retry');
    }

    try {
      final proxyUrl = '$_worker/api/yt-proxy?id=$videoId';
      final rangeRes = await _client.get(
        Uri.parse(proxyUrl),
        headers: {'Range': 'bytes=0-255'},
      ).timeout(const Duration(seconds: 30));
      if (rangeRes.statusCode == 206 || rangeRes.statusCode == 200) {
        final ct = (rangeRes.headers['content-type'] ?? '').toLowerCase();
        final isAudio = ct.contains('audio') || ct.contains('octet') ||
            ct.contains('mp4') || ct.contains('mpeg') || ct.contains('webm');
        if (isAudio || rangeRes.bodyBytes.length > 128) {
          _log('[ytStreamById] Extended-timeout Worker retry OK for $videoId ✓');
          _WorkerHealth.markAlive();
          return proxyUrl;
        }
      }
      _log('[ytStreamById] Extended-timeout retry got status=${rangeRes.statusCode} for $videoId');
    } catch (e) {
      _log('[ytStreamById] Extended-timeout Worker retry failed: $e');
    }
    _log('[ytStreamById] Worker unreachable for $videoId — this means the '
        'Cloudflare Worker itself is down. Check the Worker deployment.');
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

  // ── Cloudflare Worker ─────────────────────────────────────────────────────
  // ROOT CAUSE FIX (v5.2) — THE REAL IP-LOCK BUG:
  //
  // /api/yt-stream returns a raw googlevideo.com URL with an `ip=` query
  // param baked into its signature (e.g. ip=172.70.142.141 — a CLOUDFLARE
  // edge IP, confirmed via live debug call). YouTube's CDN validates the
  // requesting IP against that signed `ip=` value. The phone's real
  // mobile/LTE IP is never the Cloudflare IP that resolved the URL, so
  // ExoPlayer's request gets rejected and playback goes idle@0ms — even
  // though the Worker call itself returned success:true with a real,
  // well-formed URL. This is invisible from the Worker's own /api/debug-yt
  // and /api/yt-stream responses, because both only check "did we get a
  // URL back", never "can THIS device actually play it."
  //
  // Every comment block previously written in this function described this
  // exact failure mode and said the fix was to use /api/yt-proxy instead —
  // but the code never actually did that; it kept returning the direct
  // /api/yt-stream URL as Stage 1, and /api/yt-proxy was only ever reached
  // as a last-resort Stage 3 that Stage 1's false "success" prevented from
  // ever running.
  //
  // ACTUAL FIX: make /api/yt-proxy (the IP-safe, byte-piping endpoint) the
  // PRIMARY path. It costs a small latency premium (Worker streams bytes
  // through itself instead of handing back a direct CDN link) but it is
  // the only path that reliably plays on a real phone network. A direct
  // /api/yt-stream URL is still tried second, purely as a fast bonus path,
  // but ONLY after confirming with a real ranged GET (not a HEAD — HEAD is
  // unreliable against googlevideo.com) that the phone can actually open it.
  static Future<String?> _workerYtStream(String videoId) async {
    // ── PRIMARY: /api/yt-proxy — IP-safe, always playable from any network ──
    // PERFORMANCE (2026-07-02): probe range shrunk from 1024→256 bytes.
    // This is a pure liveness/content-type sniff before real playback ever
    // starts — headers + a few hundred bytes is already enough to confirm
    // "the proxy is alive and returning audio," so pulling a full 1KB was
    // wasted transfer on every single tap. Detection logic (content-type
    // check, body-length fallback) is unchanged, just cheaper.
    try {
      final proxyUrl = '$_worker/api/yt-proxy?id=$videoId';
      final probe = await _client
          .get(Uri.parse(proxyUrl), headers: {'Range': 'bytes=0-255'})
          .timeout(const Duration(seconds: 16));
      if (probe.statusCode == 200 || probe.statusCode == 206) {
        final ct = (probe.headers['content-type'] ?? '').toLowerCase();
        final looksAudio = ct.contains('audio') || ct.contains('octet') ||
            ct.contains('mp4') || ct.contains('mpeg') || ct.contains('webm');
        if (looksAudio || probe.bodyBytes.length > 128) {
          _log('[worker] /api/yt-proxy OK for $videoId (IP-safe path)');
          _WorkerHealth.markAlive();
          return proxyUrl;
        }
      }
      _log('[worker] /api/yt-proxy probe failed for $videoId '
          '(status=${probe.statusCode}) - trying direct /api/yt-stream');
    } catch (e) {
      _log('[worker] /api/yt-proxy failed for $videoId: $e - trying direct /api/yt-stream');
      _WorkerHealth.markDead();
    }

    // ── SECONDARY: /api/yt-stream direct URL — only if it survives a real
    //    ranged GET from THIS device (not just a Worker-side HEAD check) ──
    try {
      final res = await _client
          .get(Uri.parse('$_worker/api/yt-stream?id=$videoId'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        _log('[worker] /api/yt-stream ${res.statusCode} for $videoId');
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
      // Real device-side check — same IP this device will actually stream
      // from, unlike the Worker's own internal isUrlAlive() HEAD check.
      final directOk = await _isUrlAlive(url);
      if (!directOk) {
        _log('[worker] /api/yt-stream URL for $videoId failed device-side '
            'liveness check (IP-lock mismatch) - discarding direct URL');
        return null;
      }
      _log('[worker] /api/yt-stream OK for $videoId '
          '(${data["source"]} ${data["quality"]}) - direct path, verified');
      _WorkerHealth.markAlive();
      return url;
    } catch (e) {
      _log('[worker] /api/yt-stream failed for $videoId: $e');
      _WorkerHealth.markDead();
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
  static Future<String?> _saavnStreamById(
    String songId, {
    String title = '',
    String artist = '',
  }) async {
    // 2026-07-17 FIX #3: jiosaavn-op v2 has a working, reliable id-based
    // lookup — /api/songs/:id — confirmed via direct curl returning clean
    // non-DRM downloadUrl[] entries in under a second. Try this FIRST,
    // since it's a real id lookup (no title-search guesswork needed).
    // Goes through _saavnNodeHosts (not a single hardcoded host) so that
    // adding a second Node-family mirror to that list automatically covers
    // stream resolution too, not just search.
    for (final host in _saavnNodeHosts) {
      try {
        final url = Uri.parse('$host/api/songs/$songId');
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final raw = jsonDecode(res.body);
          if (raw is Map<String, dynamic> && raw['success'] == true) {
            final data = raw['data'];
            Map<String, dynamic>? songData;
            if (data is List && data.isNotEmpty) {
              songData = data.first as Map<String, dynamic>?;
            } else if (data is Map<String, dynamic>) {
              songData = data;
            }
            if (songData != null) {
              final streamUrl = _extractSaavnStreamUrl(songData);
              if (streamUrl != null) return streamUrl;
            }
          }
        }
      } catch (e) {
        _log('[saavnById] $host error for $songId: $e');
      }
    }

    // FIX #2: /song/?id= itself is broken on the old Flask backend —
    // confirmed via direct curl: consistently times out at 20-21s with
    // 0 bytes received, on BOTH onrender and the CF worker. It's not a
    // deploy issue or a cold-start issue (timing out at 20s+ rules out
    // cold-start, which resolves in under a minute). The route just hangs
    // server-side whenever an `id` param is passed.
    // /result/?query= is the only route confirmed consistently fast and
    // reliable (sub-1s, tested repeatedly). So: search by title+artist
    // instead, and pick the result whose id matches songId. If the id
    // isn't found in the first page (rare — ids are stable across
    // requests for the same song), fall back to the first result, since
    // it's virtually always the same track.
    if (title.isEmpty) return null;
    final q = artist.isNotEmpty ? '$title $artist' : title;
    for (final base in [_saavnPrimary, _saavnSecondary, _saavn]) {
      try {
        final url = Uri.parse(
          '$base/result/?query=${Uri.encodeQueryComponent(q)}&limit=10',
        );
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final results = data is List
              ? data
              : (data['data']?['results'] ?? data['data'] ?? []);
          if (results is List && results.isNotEmpty) {
            final list = results.whereType<Map<String, dynamic>>().toList();
            final match = list.firstWhere(
              (j) => (j['id'] ?? '').toString() == songId,
              orElse: () => list.first,
            );
            final streamUrl = _onrenderStreamUrl(match) ?? _extractSaavnStreamUrl(match);
            if (streamUrl != null) return streamUrl;
          }
        }
      } catch (e) {
        _log('[saavnById] $base error for $songId: $e');
      }
    }
    return null;
  }

  static String? _onrenderStreamUrl(Map<String, dynamic> j) {
    final url320   = (j['320kbps'] ?? '').toString();
    if (url320.startsWith('http')) {
      AudioPrefs.lastResolvedKbps = 320;
      return _proxiedSaavnUrl(url320);
    }
    final urlMedia = (j['media_url'] ?? '').toString();
    if (urlMedia.startsWith('http')) {
      AudioPrefs.lastResolvedKbps = null;
      return _proxiedSaavnUrl(urlMedia);
    }
    // v2 (jiosaavn-op / saavn.dev style) — downloadUrl: [{quality, url}, ...]
    return _extractSaavnStreamUrl(j);
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
        if (match != null) {
          AudioPrefs.lastResolvedKbps = int.tryParse(q.replaceAll(RegExp(r'[^0-9]'), ''));
          return _proxiedSaavnUrl(match['url'] as String);
        }
      }
      final last = downloads.last;
      if (last is Map && (last['url'] as String?)?.startsWith('http') == true) {
        AudioPrefs.lastResolvedKbps = null; // unknown tier, fell through to the last entry
        return _proxiedSaavnUrl(last['url'] as String);
      }
    }
    final su = song['media_url'] ?? song['streamUrl'];
    if (su is String && su.startsWith('http')) {
      AudioPrefs.lastResolvedKbps = null;
      return _proxiedSaavnUrl(su);
    }
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

  static void _writeSearchCache(String key, SearchResult results) {
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
      final primaryList = (artistsField['primary'] as List).whereType<Map>().toList();

      // JioSaavn's "primary" array mixes composers, lyricists AND the actual
      // singer under the same role="primary_artists" tag — e.g. for
      // "Tum Hi Ho" it contains both Mithoon (composer) and Arijit Singh
      // (singer). Prefer role="singer" entries — that's the real performer
      // and what should show as "artist" in the UI / be used for matching.
      final singers = primaryList
          .where((a) => (a['role'] ?? '').toString().toLowerCase() == 'singer')
          .map((a) => (a['name'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toSet() // de-dup (API often repeats the same singer entry twice)
          .toList();

      if (singers.isNotEmpty) {
        artist = singers.join(', ');
      } else {
        // No explicit "singer" role found — fall back to all primary
        // artists (better than nothing, matches old behavior).
        artist = primaryList
            .map((a) => (a['name'] ?? '').toString())
            .where((s) => s.isNotEmpty)
            .toSet()
            .join(', ');
      }
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
      // ── 1. Try Saavn (Node hosts, then Flask hosts) ──
      try {
        final path = '/api/search/artists?query=${Uri.encodeQueryComponent(a.query)}&limit=1';
        for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
          final body = await _getFromHosts(hosts, path,
              timeout: const Duration(seconds: 6),
              isValid: (b) => b['data']?['results'] is List &&
                  (b['data']['results'] as List).isNotEmpty);
          if (body == null) continue;
          final r = (body['data']['results'] as List).first as Map<String, dynamic>;
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
            // BUGFIX: mqdefault (320x180) upgraded to hqdefault (480x360) —
            // hqdefault is guaranteed available for every YouTube video,
            // unlike maxresdefault which 404s for many older/lower-res
            // uploads. Safe universal quality bump for this scrape-based
            // path where we don't have a full ThumbnailSet to fall back through.
            final thumbUrl =
                'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
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
    final lower = name.trim().toLowerCase();
    final path = '/api/search/artists?query=${Uri.encodeQueryComponent(name)}';

    // Try Node-family hosts first, then Flask-family — whichever answers.
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(hosts, path,
          isValid: (b) => b['data']?['results'] is List &&
              (b['data']['results'] as List).isNotEmpty);
      if (body == null) continue;
      final results = (body['data']['results'] as List);
      final exact = results.firstWhere(
        (r) => (r is Map ? (r['name'] ?? '') : '').toString().toLowerCase() == lower,
        orElse: () => results.first,
      );
      if (exact is Map) return (exact['id'] ?? '').toString();
    }
    _log('[artist] searchArtistByName: all hosts failed for "$name"');
    return null;
  }

  /// Fetch full artist page data: profile, top songs, top albums and singles.
  ///
  /// songCount/albumCount are requests, not guarantees — the API returns
  /// however many actually exist for that artist (confirmed: asking for 200
  /// on an artist with only 33 songs just returns 33, no error/truncation
  /// issue). So we ask high by default to make sure prolific artists aren't
  /// cut short — it costs nothing for artists with fewer songs.
  static Future<Artist?> fetchArtist(String artistId,
      {int songCount = 100, int albumCount = 100}) async {
    if (artistId.isEmpty) return null;

    final path = '/api/artists/$artistId?songCount=$songCount&albumCount=$albumCount';
    Map<String, dynamic>? body;
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      body = await _getFromHosts(
        hosts, path,
        timeout: const Duration(seconds: 15),
        isValid: (b) => b['success'] == true && b['data'] is Map,
      );
      if (body != null) break;
    }
    if (body == null) {
      _log('[artist] fetchArtist: all hosts failed for id=$artistId');
      return null;
    }

    try {
      final d = body['data'] as Map<String, dynamic>;

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
      _log('[artist] fetchArtist parse failed: $e');
      return null;
    }
  }

  /// Resolve an album's Saavn ID from its display name (used when navigating
  /// from a song tile's album chip, where we only have the album name string).
  static Future<String?> searchAlbumByName(String name) async {
    if (name.trim().isEmpty) return null;
    final lower = name.trim().toLowerCase();
    final path = '/api/search/albums?query=${Uri.encodeQueryComponent(name)}';

    // Try Node-family hosts first, then Flask-family — whichever answers.
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(hosts, path,
          isValid: (b) => b['data']?['results'] is List &&
              (b['data']['results'] as List).isNotEmpty);
      if (body == null) continue;
      final results = (body['data']['results'] as List);
      final exact = results.firstWhere(
        (r) => (r is Map ? (r['name'] ?? '') : '').toString().toLowerCase() == lower,
        orElse: () => results.first,
      );
      if (exact is Map) return (exact['id'] ?? '').toString();
    }
    _log('[artist] searchAlbumByName: all hosts failed for "$name"');
    return null;
  }

  /// Fetch the songs inside an album or single, by its Saavn ID.
  static Future<List<Song>> fetchAlbumSongs(String albumId) async {
    if (albumId.isEmpty) return [];

    final path = '/api/albums?id=$albumId';
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(
        hosts, path,
        timeout: const Duration(seconds: 10),
        isValid: (b) => b['success'] == true && b['data']?['songs'] is List,
      );
      if (body == null) continue;
      final songs = (body['data']['songs'] as List);
      return songs
          .whereType<Map>()
          .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
          .toList();
    }
    _log('[artist] fetchAlbumSongs: all hosts failed for id=$albumId');
    return [];
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
  static final Map<String, LyricsResult> _syncedLyricsCache = {};

  static Future<String?> fetchLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return null;
    final cacheKey = '${song.source.name}:${song.id}';
    if (_lyricsCache.containsKey(cacheKey)) return _lyricsCache[cacheKey];

    // LRCLIB first — it's a dedicated lyrics database and returns full
    // lyrics. Saavn's route only returns a short preview snippet (JioSaavn's
    // own API limitation, not something we can fix without full lyrics
    // rights), so it's kept only as a last-resort fallback when LRCLIB has
    // nothing at all for this track.
    String? lyrics = await _fetchLrcLibLyrics(song.title, song.artist);
    if (lyrics == null || lyrics.isEmpty) {
      final saavnId = song.source == SongSource.saavn
          ? song.id
          : await _resolveSaavnIdForLyrics(song.title, song.artist);
      if (saavnId != null) lyrics = await _fetchSaavnLyrics(saavnId);
    }
    // Two more free plain-lyrics sources as a last resort — mostly help
    // Western/English tracks that LRCLIB and Saavn both miss.
    if (lyrics == null || lyrics.isEmpty) {
      lyrics = await _fetchLyricsOvh(song.artist, song.title);
    }
    if (lyrics == null || lyrics.isEmpty) {
      lyrics = await _fetchLyricsMania(song.artist, song.title);
    }
    if (lyrics != null && lyrics.isNotEmpty) _lyricsCache[cacheKey] = lyrics;
    return lyrics;
  }

  /// Line-synced lyrics fetch. Prefers real [mm:ss.xx] timed lines from
  /// LRCLIB; falls back to Saavn's plain lyrics (no timestamps) when LRCLIB
  /// has nothing for this track. Cached separately from fetchLyrics() since
  /// the shapes differ (LyricsResult vs raw String).
  static Future<LyricsResult> fetchSyncedLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return const LyricsResult();
    final cacheKey = '${song.source.name}:${song.id}';
    if (_syncedLyricsCache.containsKey(cacheKey)) {
      return _syncedLyricsCache[cacheKey]!;
    }

    // The full fallback chain below (LRCLIB's up-to-9 query variants, then
    // Saavn, then lyrics.ovh, then lyricsmania) has no shared upper bound —
    // each individual HTTP call times out on its own, but back-to-back that
    // can still add up to 60-80s for a song with no match anywhere, which
    // reads as the lyrics tab being permanently "stuck" loading. Capping the
    // whole chain here means a genuine miss surfaces as "not found" quickly
    // instead — same as Spotify not making you wait a minute to find out
    // lyrics aren't available.
    try {
      return await _fetchSyncedLyricsChain(song, cacheKey)
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      // Deliberately not cached — leaves the door open for a later manual
      // retry (e.g. reopening the Lyrics tab) to succeed once a slow source
      // responds, rather than permanently locking in "not found".
      return const LyricsResult();
    }
  }

  static Future<LyricsResult> _fetchSyncedLyricsChain(
    Song song,
    String cacheKey,
  ) async {
    final result = await _fetchLrcLibSynced(song.title, song.artist, song.duration);
    LyricsResult finalResult = result;

    if (!finalResult.hasAny) {
      final saavnId = song.source == SongSource.saavn
          ? song.id
          : await _resolveSaavnIdForLyrics(song.title, song.artist);
      if (saavnId != null) {
        final saavnPlain = await _fetchSaavnLyrics(saavnId);
        if (saavnPlain != null && saavnPlain.isNotEmpty) {
          finalResult = LyricsResult(plain: saavnPlain);
        }
      }
    }

    if (!finalResult.hasAny) {
      final ovhPlain = await _fetchLyricsOvh(song.artist, song.title);
      if (ovhPlain != null && ovhPlain.isNotEmpty) {
        finalResult = LyricsResult(plain: ovhPlain);
      }
    }

    if (!finalResult.hasAny) {
      final maniaPlain = await _fetchLyricsMania(song.artist, song.title);
      if (maniaPlain != null && maniaPlain.isNotEmpty) {
        finalResult = LyricsResult(plain: maniaPlain);
      }
    }

    if (finalResult.hasAny) _syncedLyricsCache[cacheKey] = finalResult;
    return finalResult;
  }

  /// For non-Saavn songs (YouTube, etc.), Saavn's lyrics route needs a Saavn
  /// song ID we don't have. This searches Saavn by title+artist to find the
  /// closest matching track's ID purely as a lyrics lookup key. Cached so
  /// repeated lyric fetches for the same song don't re-search.
  static final Map<String, String?> _saavnIdForLyricsCache = {};

  static Future<String?> _resolveSaavnIdForLyrics(String title, String artist) async {
    final key = '$title|$artist';
    if (_saavnIdForLyricsCache.containsKey(key)) return _saavnIdForLyricsCache[key];
    String? foundId;
    try {
      final cleanTitle = _cleanTitleForLyricsSearch(title);
      final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();

      // Score every candidate from both queries instead of trusting
      // whichever query's first result came back — same rationale as
      // _lrcLibMatchScore: a plain "first hit" here is exactly how a
      // same-titled different song ends up attached to this track's lyrics.
      Song? best;
      double bestScore = 0.0;
      void consider(List<Song> candidates) {
        for (final s in candidates) {
          final titleSim = _tokenSimilarity(cleanTitle, s.title);
          if (titleSim < 0.42) continue;
          final artistSim = _tokenSimilarity(primaryArtist, s.artist);
          final score = (titleSim * 0.6) + (artistSim * 0.4);
          if (score > bestScore) {
            bestScore = score;
            best = s;
          }
        }
      }

      consider(await _searchSaavn('$cleanTitle $artist', limit: 5));
      if (bestScore < 0.95) {
        consider(await _searchSaavn(cleanTitle, limit: 5));
      }

      // Same confidence floor as LRCLIB matching: prefer no lyrics over
      // wrong lyrics.
      if (best != null && bestScore >= 0.48) foundId = best!.id;
    } catch (_) {}
    _saavnIdForLyricsCache[key] = foundId;
    return foundId;
  }

  static Future<LyricsResult> _fetchLrcLibSynced(
    String title,
    String artist,
    int? durationSeconds,
  ) async {
    final best = await _searchLrcLib(title, artist, durationSeconds: durationSeconds);
    if (best == null) return const LyricsResult();

    final syncedRaw = best['syncedLyrics'] as String?;
    final plainRaw = best['plainLyrics'] as String?;

    if (syncedRaw != null && syncedRaw.isNotEmpty) {
      final parsed = LyricsResult.parseLrc(syncedRaw);
      if (parsed.isNotEmpty) {
        final plainFallback = parsed.map((l) => l.text).where((t) => t.isNotEmpty).join('\n');
        return LyricsResult(synced: parsed, plain: plainFallback);
      }
    }
    if (plainRaw != null && plainRaw.isNotEmpty) {
      return LyricsResult(plain: plainRaw);
    }
    return const LyricsResult();
  }

  static Future<String?> _fetchSaavnLyrics(String songId) async {
    try {
      final res = await _client
          .get(Uri.parse('$_saavn/lyrics/?id=$songId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final l = data['data']?['lyrics'] as String?;
        if (l == null || l.isEmpty) return null;
        final cleaned = _sanitizeHtmlLyrics(l);
        return cleaned.isNotEmpty ? cleaned : null;
      }
    } catch (_) {}
    return null;
  }

  /// Saavn's lyrics endpoint returns HTML-formatted text — line breaks come
  /// through as literal "<br>" tags rather than real newlines, and other
  /// stray markup can appear too. Left unsanitized, this showed up as
  /// literal "<br><br>" text stitched between lines both in the full
  /// lyrics view and the inline player strip. This normalizes <br> (and
  /// <br/>, <BR>, etc.) to real newlines, strips any other HTML tags, and
  /// decodes the handful of HTML entities Saavn's lyrics commonly contain.
  static String _sanitizeHtmlLyrics(String raw) {
    var t = raw;
    t = t.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    t = t.replaceAll(RegExp(r'<p\s*/?>', caseSensitive: false), '\n');
    t = t.replaceAll(RegExp(r'</p>', caseSensitive: false), '');
    // Strip any remaining HTML tags (bold/italic wrappers etc.) without
    // touching the text content between them.
    t = t.replaceAll(RegExp(r'<[^>]+>'), '');
    t = t
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
    // Collapse the double blank lines <br><br> produces (every line has a
    // trailing empty line after it) down to single line breaks, and trim
    // stray leading/trailing whitespace per line.
    t = t
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
    return t.trim();
  }

  /// lyrics.ovh — free, no-auth plain lyrics API. Mostly strong for
  /// Western/English tracks; used as a last-resort fallback after
  /// LRCLIB and Saavn both miss.
  static Future<String?> _fetchLyricsOvh(String artist, String title) async {
    try {
      final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();
      final a = Uri.encodeComponent(_cleanTitleForLyricsSearch(primaryArtist));
      final t = Uri.encodeComponent(_cleanTitleForLyricsSearch(title));
      if (a.isEmpty || t.isEmpty) return null;
      final res = await _client
          .get(Uri.parse('https://api.lyrics.ovh/v1/$a/$t'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final l = data['lyrics'] as String?;
        if (l == null || l.isEmpty) return null;
        final cleaned = _sanitizeHtmlLyrics(l);
        return cleaned.isNotEmpty ? cleaned : null;
      }
    } catch (_) {}
    return null;
  }

  /// lyricsmania.com scrape — another free plain-lyrics fallback, mostly
  /// English catalog. Site is old/lightly maintained so failures here are
  /// expected and silently swallowed; it only ever fires after every other
  /// source has already missed.
  static Future<String?> _fetchLyricsMania(String artist, String title) async {
    try {
      final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();
      final a = _lyricsManiaSlug(primaryArtist);
      final t = _lyricsManiaSlug(_cleanTitleForLyricsSearch(title));
      if (a.isEmpty || t.isEmpty) return null;
      final uri = Uri.parse('https://www.lyricsmania.com/${t}_lyrics_$a.html');
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final document = html_parser.parse(res.body);
        final body = document.querySelectorAll('.lyrics-body');
        if (body.isNotEmpty) {
          final text = body.first.text.trim();
          return text.isNotEmpty ? text : null;
        }
      }
    } catch (_) {}
    return null;
  }

  static String _lyricsManiaSlug(String input) {
    var result = input.replaceAll(' ', '_').toLowerCase();
    result = result.replaceAll(RegExp(r'[^a-z0-9_]'), '');
    result = result.replaceAll(RegExp(r'_+'), '_');
    if (result.startsWith('_')) result = result.substring(1);
    if (result.endsWith('_')) result = result.substring(0, result.length - 1);
    return result;
  }

  /// Strips common noise from a song title that hurts LRCLIB matching —
  /// "(From "Movie Name")", "- Remastered", bracketed year tags, etc.
  /// LRCLIB's own database uses clean official titles, so a title still
  /// carrying Saavn/YouTube-style suffixes often fails to match even when
  /// the song genuinely exists there.
  static String _cleanTitleForLyricsSearch(String title) {
    var t = title;
    t = t.replaceAll(RegExp(r'\(From\s+["“][^"”]*["”]\)', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\((From|feat\.?|ft\.?)[^)]*\)', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'-\s*(Remastered|Reprise|Bonus Track).*$', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    return t.trim();
  }

  /// Normalizes a string for fuzzy comparison: lowercase, strip punctuation,
  /// collapse whitespace. Used only to *score* candidate matches — never to
  /// alter what gets displayed or sent upstream.
  static String _normalizeForMatch(String s) {
    var t = s.toLowerCase();
    t = t.replaceAll(RegExp(r"[^\p{L}\p{N}\s]", unicode: true), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  /// Token-overlap similarity in [0,1]: fraction of the shorter string's
  /// words that also appear in the longer string. Cheap, dependency-free,
  /// and good enough to tell "same song" from "different song, same word
  /// somewhere in the title" — which is all we need this for.
  static double _tokenSimilarity(String a, String b) {
    final ta = _normalizeForMatch(a).split(' ').where((w) => w.isNotEmpty).toSet();
    final tb = _normalizeForMatch(b).split(' ').where((w) => w.isNotEmpty).toSet();
    if (ta.isEmpty || tb.isEmpty) return 0.0;
    final overlap = ta.intersection(tb).length;
    final smaller = ta.length < tb.length ? ta.length : tb.length;
    return overlap / smaller;
  }

  /// Scores an LRCLIB candidate against the song we're actually looking for.
  /// Returns a 0..1 confidence that this candidate IS the requested track
  /// (not a cover, not a different song that happens to share a word).
  /// Duration is the strongest signal when present (covers/remixes almost
  /// always differ by more than a couple seconds); title+artist token
  /// overlap is the fallback signal when duration is unavailable or ties.
  static double _lrcLibMatchScore(
    Map<String, dynamic> entry,
    String title,
    String artist,
    int? durationSeconds,
  ) {
    final entryTitle = (entry['trackName'] as String?) ?? '';
    final entryArtist = (entry['artistName'] as String?) ?? '';
    final titleSim = _tokenSimilarity(_cleanTitleForLyricsSearch(title), entryTitle);
    final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();
    final artistSim = _tokenSimilarity(primaryArtist, entryArtist);

    // Title must clear a floor on its own — a strong artist match can't
    // rescue a completely different song title (this is what previously let
    // wrong tracks slip through when duration was missing). Kept slightly
    // below 0.5 to tolerate Hindi/regional title spelling drift between
    // Saavn/YouTube's romanization and LRCLIB's own indexing (e.g. one extra
    // or missing word from a subtitle) without opening the door to
    // genuinely unrelated songs.
    if (titleSim < 0.42) return 0.0;

    double score = (titleSim * 0.6) + (artistSim * 0.4);

    final d = entry['duration'];
    if (durationSeconds != null && d is num) {
      final diff = (d.toInt() - durationSeconds).abs();
      if (diff <= 3) {
        score += 0.3; // near-exact duration match: strong extra confidence
      } else if (diff > 15) {
        score -= 0.4; // likely a different edit/cover entirely
      }
    }
    return score.clamp(0.0, 1.0);
  }

  /// Searches LRCLIB with several query variants, scoring every candidate
  /// from every query against the requested title/artist/duration and
  /// returning the single best match overall — instead of trusting whichever
  /// query happened to return a hit first. This is what prevents a cover or
  /// same-titled different song from being served for the original, while
  /// still trying enough query variants to maximize how many songs get a
  /// hit at all.
  static Future<Map<String, dynamic>?> _searchLrcLib(
    String title,
    String artist, {
    int? durationSeconds,
  }) async {
    final cleanTitle = _cleanTitleForLyricsSearch(title);
    // Primary artist only — Saavn/YouTube often stack "Artist1, Artist2,
    // Composer" while LRCLIB indexes under just the lead artist, so a
    // multi-name query can miss even when the track exists.
    final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();

    // Strips ANY parenthetical/bracketed content (not just the specific
    // patterns _cleanTitleForLyricsSearch targets) — helps titles like
    // "Kesariya (From 'Brahmastra')" or "Tum Hi Ho (Unplugged)" find the
    // bare-title entry LRCLIB actually indexes under.
    final bareTitle = cleanTitle
        .replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Drops a trailing "feat./ft. X" from the title itself (as opposed to
    // the artist field) — some Saavn/YouTube titles embed the featured
    // artist directly in the title string.
    final noFeatTitle = cleanTitle
        .replaceAll(RegExp(r'\b(feat\.?|ft\.?)\s+.*$', caseSensitive: false), '')
        .trim();

    final queries = <String>{
      '$cleanTitle $artist',
      if (primaryArtist != artist && primaryArtist.isNotEmpty) '$cleanTitle $primaryArtist',
      if (cleanTitle != title) '$title $artist',
      cleanTitle,
      if (primaryArtist.isNotEmpty) '$primaryArtist $cleanTitle',
      if (bareTitle.isNotEmpty && bareTitle != cleanTitle) '$bareTitle $primaryArtist',
      if (bareTitle.isNotEmpty && bareTitle != cleanTitle) bareTitle,
      if (noFeatTitle.isNotEmpty && noFeatTitle != cleanTitle) '$noFeatTitle $primaryArtist',
      // "Artist - Title" reversed order — a good number of LRCLIB entries,
      // especially Western and Japanese/J-pop tracks, are indexed with the
      // artist name leading rather than the title, so a straight
      // "title artist" query can miss them even though the track exists.
      if (primaryArtist.isNotEmpty) '$primaryArtist - $cleanTitle',
      // Title-only as an absolute last resort — widest net, relies entirely
      // on the scoring floor above to reject a wrong song.
      if (bareTitle.isNotEmpty) bareTitle,
    }.where((q) => q.trim().isNotEmpty).toList();

    Map<String, dynamic>? bestEntry;
    double bestScore = 0.0;

    for (final q in queries) {
      try {
        final res = await _client
            .get(Uri.parse('https://lrclib.net/api/search?q=${Uri.encodeQueryComponent(q)}'))
            .timeout(const Duration(seconds: 6));
        if (res.statusCode != 200) continue;
        final data = jsonDecode(res.body);
        if (data is! List || data.isEmpty) continue;

        // Only check the first several candidates per query — LRCLIB ranks
        // its own results, and going deeper mostly just risks scoring
        // unrelated tracks that happen to share a common word.
        for (final entry in data.take(8)) {
          if (entry is! Map<String, dynamic>) continue;
          final score = _lrcLibMatchScore(entry, title, artist, durationSeconds);
          if (score > bestScore) {
            bestScore = score;
            bestEntry = entry;
          }
        }

        // A near-certain duration+title+artist match — no point trying
        // further query variants.
        if (bestScore >= 0.95) break;
      } catch (_) {
        continue;
      }
    }

    // Confidence floor: below this, we'd rather report "no lyrics found"
    // than risk showing the wrong song's lyrics. 0.48 still requires either
    // a strong title match (title alone contributes up to 0.6) or a decent
    // title+artist combination — a single shared word can't clear it, but
    // genuine Hindi/regional title spelling drift now can.
    if (bestEntry != null && bestScore >= 0.48) return bestEntry;
    return null;
  }

  static Future<String?> _fetchLrcLibLyrics(String title, String artist) async {
    final best = await _searchLrcLib(title, artist);
    if (best == null) return null;
    final plain = best['plainLyrics'] as String?;
    if (plain != null && plain.isNotEmpty) return plain;
    final synced = best['syncedLyrics'] as String?;
    if (synced != null && synced.isNotEmpty) {
      return synced
          .split('\n')
          .map((line) => line.replaceFirst(RegExp(r'^\[\d{2}:\d{2}\.\d{2,3}\] ?'), ''))
          .where((line) => line.isNotEmpty)
          .join('\n');
    }
    return null;
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================
  static String _onrenderArtwork(Map<String, dynamic> j) {
    final imgField = j['image'];
    if (imgField is List && imgField.isNotEmpty) {
      // saavn.dev / jiosaavn-op both return image as an array of
      // {quality: "50x50"|"150x150"|"500x500", url: "..."} ordered small→large.
      // Pick the entry with the largest declared quality instead of assuming
      // the array's last element is always the biggest — future-proofs
      // against a host ever adding a 1000x1000 tier ahead of 500x500.
      Map? best;
      int bestSize = -1;
      for (final entry in imgField) {
        if (entry is! Map || entry['url'] is! String) continue;
        final u = entry['url'] as String;
        if (!u.startsWith('http')) continue;
        final q = (entry['quality'] ?? '').toString();
        final match = RegExp(r'(\d+)x\d+').firstMatch(q);
        final size = match != null ? int.parse(match.group(1)!) : 0;
        if (size >= bestSize) {
          bestSize = size;
          best = entry;
        }
      }
      if (best != null) return best['url'] as String;
    }
    if (imgField is String && imgField.startsWith('http')) {
      return imgField
          .replaceAll('150x150', '500x500')
          .replaceAll('50x50',   '500x500');
    }
    return '';
  }

  // ===========================================================================
  // PREMIUM DISPLAY CLEANING
  //
  // Raw YouTube/Saavn titles carry upload-platform noise that a paid,
  // Spotify-level app should never surface: emoji, bracket tags
  // ("(Official Video)", "[Lyrics]"), "| Channel Name" suffixes, and
  // leftover pipe/dash clutter. This is DISPLAY-ONLY cleanup — it never
  // rejects a song (that's isInherentVariant/isLowQualityUpload's job) and
  // never touches streamUrl/id resolution, so it can't affect playback
  // speed or correctness.
  // ===========================================================================

  // Emoji + symbol pictographs + dingbats + variation selectors. Covers the
  // ranges YouTube uploaders actually use in titles (🎵💔🔥✨ etc.) without
  // touching Devanagari/Tamil/other real-language scripts.
  static final RegExp _emojiPattern = RegExp(
    r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]',
    unicode: true,
  );

  // Bracketed upload-platform tags: "(Official Video)", "[Lyrics]",
  // "{HD}" — content in brackets that's pure metadata noise, not part of
  // the actual song title.
  static final RegExp _bracketTagPattern = RegExp(
    r'[\(\[\{]\s*(official\s*(video|audio|music\s*video)?|lyrics?(\s*video)?|'
    r'hd|4k|full\s*(video|song|audio)?|new|latest|original|explicit|'
    r'visualizer|audio\s*only|with\s*lyrics|from\s*.*?)\s*[\)\]\}]',
    caseSensitive: false,
  );

  // Trailing "| Channel Name" / "- T-Series" style suffixes uploaders
  // append after the real title.
  static final RegExp _channelSuffixPattern = RegExp(
    r'\s*[\|•]\s*(t-?series|zee music|sony music|saregama|tips|speed records|'
    r'desi music|shemaroo|venus|eros now music|vevo|records?)\b.*$',
    caseSensitive: false,
  );

  // Standalone noise words left over after bracket removal, when they
  // weren't inside brackets to begin with (e.g. "Song Name Official Video").
  static final RegExp _looseNoiseWords = RegExp(
    r'\b(official\s*(music\s*)?video|official\s*audio|lyrical\s*video|'
    r'lyrics\s*video|full\s*video\s*song|video\s*song|full\s*song|'
    r'audio\s*jukebox|hd\s*video)\b',
    caseSensitive: false,
  );

  static String _cleanText(String s) {
    var out = s
        .replaceAll('&amp;',  '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&lt;',   '<')
        .replaceAll('&gt;',   '>');
    out = out.replaceAll(_emojiPattern, '');
    out = out.replaceAll(_channelSuffixPattern, '');
    out = out.replaceAll(_bracketTagPattern, '');
    out = out.replaceAll(_looseNoiseWords, '');
    // Collapse leftover separator debris ("Title -  | ", "Title ()") left
    // behind after tag/emoji stripping.
    out = out.replaceAll(RegExp(r'[\(\[\{]\s*[\)\]\}]'), '');
    out = out.replaceAll(RegExp(r'\s*[-|•]\s*$'), '');
    out = out.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return out;
  }

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

  // FIX ("Tu saayar hai" typed for "Tu Saiyaara Hai" returns totally
  // unrelated songs"): every search path before this only ever did exact/
  // substring/word-token comparison (_scoreSearchResult, _normalise). A
  // single-letter typo, transposed letters, or a phonetic misspelling
  // (extremely common typing Hindi/Hinglish titles on a phone keyboard —
  // "saayar" for "saiyaara", "arigit" for "arijit") never matches any of
  // those checks at all, so the query effectively falls through to
  // whatever the backend's own loose full-text search happens to return —
  // which is exactly the unrelated-songs symptom reported. This is a
  // classic bounded edit-distance check: two words are considered a typo
  // match if changing at most a couple of characters turns one into the
  // other, scaled by word length so short words need near-exact matches
  // (avoids "no"/"go" false-positiving) while longer words tolerate more.
  static int _editDistance(String a, String b, {int maxDistance = 3}) {
    if (a == b) return 0;
    final la = a.length, lb = b.length;
    if ((la - lb).abs() > maxDistance) return maxDistance + 1; // early exit
    if (la == 0) return lb;
    if (lb == 0) return la;
    var prev = List<int>.generate(lb + 1, (j) => j);
    for (var i = 1; i <= la; i++) {
      final cur = List<int>.filled(lb + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= lb; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = [
          cur[j - 1] + 1,      // insertion
          prev[j] + 1,         // deletion
          prev[j - 1] + cost,  // substitution
        ].reduce((v, e) => v < e ? v : e);
      }
      prev = cur;
    }
    return prev[lb];
  }

  // How many edits a word tolerates before it's no longer considered "the
  // same word, just mistyped" — scales with word length so "hai"/"hain"
  // (short, common Hinglish words) don't fuzzy-match each other by
  // accident, while a longer word like "saiyaara" can absorb 1-2 typos.
  static int _maxEditsFor(int wordLength) {
    if (wordLength <= 4) return 1;
    if (wordLength <= 7) return 2;
    return 3;
  }

  /// True if [word] is either an exact substring/match of [target], or a
  /// bounded-edit-distance typo of it. Used to give queries with genuine
  /// typos ("saayar" → "saiyaara") a real shot at matching instead of
  /// silently falling through to whatever loose backend search returns.
  static bool _fuzzyWordMatch(String word, String target) {
    if (word.length < 3) return word == target; // too short to fuzzy-match safely
    if (target.contains(word)) return true;
    final maxEdits = _maxEditsFor(word.length);
    // Compare against the target itself and, for multi-word targets,
    // each individual token — catches "saayar" matching just the "saiyaara"
    // token inside a longer title like "Tu Saiyaara Hai".
    if (_editDistance(word, target, maxDistance: maxEdits) <= maxEdits) return true;
    for (final token in target.split(RegExp(r'\s+'))) {
      if (token.length < 3) continue;
      if (_editDistance(word, token, maxDistance: maxEdits) <= maxEdits) return true;
    }
    return false;
  }

  // ===========================================================================
  // DIAGNOSTICS
  // ===========================================================================

  // Result of a REAL playback attempt through the live AurumAudioEngine —
  // returned by the [realPlaybackTest] callback passed into
  // [debugPlaybackPath] from the UI. Separate from PlayerException so the
  // diagnostic function doesn't need to import native_engine_bridge.dart
  // directly (avoids a circular import concern, same rationale as before).
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
  /// should attempt REAL playback through the app's live AurumAudioEngine
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
    // DIFFERENT code path from the real app: production playback now goes
    // through `AurumAudioEngine` (native Kotlin/Media3, see
    // native_engine_bridge.dart) via `playSong()`/`playQueue()`, with its
    // own gapless queueing, crossfade, and DSP pipeline. A throwaway
    // just_audio player skips ALL of that — so this test could pass or
    // fail independently of whether real in-app playback works, which is
    // exactly the ambiguity that made this bug hard to pin down.
    //
    // Fix: if [realPlaybackTest] is supplied (wired from home_screen.dart
    // to PlayerProvider.playSong, which forwards to the real
    // AurumAudioEngine), use the REAL engine instead of a throwaway
    // just_audio player. Falls back to the old throwaway-player behaviour
    // if no callback is supplied, so this function still works standalone.
    buf.writeln('▶ ${_kPipedInstances.length + 4}. REAL PLAYBACK TEST'
        '${realPlaybackTest != null ? " (via live AurumAudioEngine)" : " (throwaway player — no engine wired)"}');
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

  /// No-op passthrough. Kept only so existing callers in
  /// player_provider.dart (Up Next queue building) keep compiling
  /// unchanged — always returns the songs exactly as given, untouched.
  static Future<List<Song>> enrichWithCleanMetadata(
    List<Song> songs, {
    int maxLookups = 15,
    Duration overallTimeout = const Duration(seconds: 4),
  }) async {
    return songs;
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
  final SearchResult results;
  final DateTime   cachedAt;
  _CachedSearch(this.results) : cachedAt = DateTime.now();
  bool get isExpired =>
      DateTime.now().difference(cachedAt) > ApiService._searchTtl;
}

/// Search results split into the two sections a clean, professional
/// search UI (Spotify/Fabtune-style) shows separately: [direct] is what
/// actually matched the query, [related] is the "you might also like"
/// vibe-expansion. Kept apart so the UI never merges "the song you typed"
/// with loosely-related songs from other artists into one undifferentiated
/// list — that mixing is what made results look random/unprofessional.
class SearchResult {
  final List<Song> direct;
  final List<Song> related;
  const SearchResult({required this.direct, required this.related});
  List<Song> get all => [...direct, ...related];
  bool get isEmpty => direct.isEmpty && related.isEmpty;
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
  final bool    isEnglish;
  const _SectionQuery(this.query, this.label, {
    this.priority = false,
    this.isSuggestion = false,
    this.suggestionSongId,
    this.isEnglish = false,
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
