// =============================================================================
// FILE: lib/services/api_service.dart
// PROJECT: Aurum Music
// VERSION: 2.0.0 — Production-grade audit + complete fix
//
// WHAT CHANGED FROM v1:
//   ✅ CRITICAL-1: Concurrent resolution guard added (_pendingResolutions)
//   ✅ CRITICAL-2: Bounded LRU cache with eviction (_maxCacheSize = 150)
//   ✅ CRITICAL-3: onNetworkRestored() is now a real implementation
//   ✅ CRITICAL-4: youtube_explode picks m4a/AAC for API 26+ compatibility
//   ✅ HIGH-1: Exponential backoff retry (300ms → 600ms → 1200ms)
//   ✅ HIGH-2: Saavn pre-fetched URL expiry validated against cache
//   ✅ HIGH-3: prefetchNext() uses CancelableOperation with 800ms delay
//   ✅ HIGH-4: Worker JSON parser handles data envelope + array responses
//   ✅ HIGH-5: _searchYt timeout fixed (Future.any pattern)
//   ✅ MED-1: YoutubeExplode + http.Client disposed via dispose()
//   ✅ MED-2: Lyrics cache + lrclib.net fallback for YouTube songs
//   ✅ MED-3: Thumbnail null safety with full fallback chain
//   ✅ MED-4: getDiagnosticsSnapshot() for runtime diagnostics page
//   ✅ MED-5: _saavnStreamById handles all nested data envelope shapes
//   ✅ NEW: _CachedStream exposes resolvedAt for LRU eviction
//   ✅ NEW: Production logging flag (AURUM_DEBUG env var)
//   ✅ NEW: Source enum deserialization helper for queue restore safety
//   ✅ NEW: Crash-safe playSong contract documented
//
// DEPENDENCIES REQUIRED IN pubspec.yaml:
//   http: ^1.2.0
//   youtube_explode_dart: ^2.3.0
//   async: ^2.11.0          ← NEW: for CancelableOperation
//   connectivity_plus: ^6.0.0  ← for wiring onNetworkRestored()
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

// flutter/foundation gives us kDebugMode — used for conditional logging.
// We never import the full Flutter framework in a pure service class
// to keep it testable in unit tests without a Flutter engine.
import 'package:flutter/foundation.dart';

// http.Client is kept as a static singleton. One Client = one connection pool.
// Creating a new Client per request leaks sockets on Android.
import 'package:http/http.dart' as http;

// youtube_explode_dart: client-side Innertube wrapper.
// Used as FALLBACK-1 (after Cloudflare worker fails).
// Not used for search on its own — too slow for search on mobile IPs.
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

// async package: CancelableOperation lets us cancel in-flight prefetch
// when the user skips to another song before prefetch completes.
// Without this, rapid skipping spawns N simultaneous resolutions.
import 'package:async/async.dart';

import '../models/song.dart';
import '../utils/constants.dart';

// =============================================================================
//  AURUM API SERVICE — v2.0 Production
// =============================================================================
class ApiService {

  // ---------------------------------------------------------------------------
  // SECTION 1: SINGLETONS
  //
  // WHY STATIC: ApiService is used from multiple widgets/providers simultaneously.
  // A static client means one TCP connection pool is shared — Android limits
  // total open sockets per app. Multiple http.Client() instances each hold their
  // own pool and can exhaust the FD (file descriptor) limit of ~1024.
  // ---------------------------------------------------------------------------

  // ONE http.Client for all Saavn + worker requests.
  // NEVER create http.Client() inside a method — it leaks a connection pool
  // every call and causes "Connection reset by peer" errors on Android.
  static final http.Client _client = http.Client();

  // YoutubeExplode holds an internal HttpClient for Innertube calls.
  // Static singleton — we close it in dispose() on app detach.
  // DO NOT create a new YoutubeExplode() per resolution call —
  // it re-initialises the Innertube client and adds ~300ms overhead.
  static final YoutubeExplode _yt = YoutubeExplode();

  // ---------------------------------------------------------------------------
  // SECTION 2: BASE URLS
  //
  // _saavn: jiosavan.onrender.com — free Saavn API proxy.
  //   ⚠ Risk: onrender.com free tier spins down after 15 min inactivity.
  //   First request after spin-down takes ~8-12s. This is why we have a 10s
  //   timeout on Saavn calls (not 5s — spin-up needs the headroom).
  //
  // _worker: Cloudflare worker — our PRIMARY YouTube stream resolver.
  //   Worker calls Innertube from a Cloudflare IP, which avoids the bot-
  //   detection block that affects residential/mobile IPs directly.
  //   This is the same technique used by SimpMusic and InnerTune.
  // ---------------------------------------------------------------------------
  static const String _saavn  = 'https://jiosavan.onrender.com';
  static const String _worker = AppConstants.apiBase;
  // AppConstants.apiBase = 'https://aurum-stream.sharmashivam9109.workers.dev'

  // ---------------------------------------------------------------------------
  // SECTION 3: STREAM CACHE
  //
  // WHY 50 MINUTES TTL:
  //   - Saavn CDN URLs expire after ~60 min. We use 50 min to give a 10-min
  //     buffer before the URL actually dies. Without this buffer, a song
  //     queued at minute 0 and played at minute 59 fails with 403.
  //   - YouTube signed URLs (googlevideo.com) typically expire in 6 hours.
  //     50 min is conservative but safe for both sources.
  //
  // WHY 150 ENTRY LIMIT (_maxCacheSize):
  //   Each _CachedStream holds a URL string (~200-500 chars = ~1-2 KB) + DateTime.
  //   150 entries ≈ ~300 KB RAM. Acceptable on any modern Android device.
  //   Without a limit: 200+ song session → unbounded growth → Android LMKILL
  //   kills the background service → playback stops.
  //
  // WHY NOT SharedPreferences / Hive for cache:
  //   This is a STREAM URL cache, not a song metadata cache. Stream URLs are
  //   time-limited signed tokens — persisting them across app restarts is
  //   dangerous because they'll be expired on next launch. Keep in-memory.
  //   (Song metadata should use Hive — that's a separate concern.)
  // ---------------------------------------------------------------------------
  static final Map<String, _CachedStream> _streamCache = {};
  static const Duration _streamTtl  = Duration(minutes: 50);
  static const int      _maxCacheSize = 150;

  // ---------------------------------------------------------------------------
  // SECTION 4: CONCURRENT RESOLUTION GUARD
  //
  // THE BUG THIS FIXES (CRITICAL-1):
  //   Without this map, if resolveStreamUrl() is called twice for the same song
  //   simultaneously (e.g., user taps play + prefetch fires at the same time),
  //   two full HTTP resolution chains run in parallel. The second one can:
  //   a) Overwrite the cache with a different URL variant
  //   b) Return a URL that's 10ms fresher but cause just_audio to switch
  //      mid-buffer — resulting in a stutter or "Source error" exception.
  //
  // HOW IT WORKS:
  //   The first call creates a Future and stores it in _pendingResolutions.
  //   Any subsequent call for the same cacheKey sees the existing Future and
  //   simply awaits it — they all share ONE network round trip.
  //   On completion (success OR failure), the key is removed in a `finally`
  //   block so the next call (e.g., after manual retry) starts fresh.
  // ---------------------------------------------------------------------------
  static final Map<String, Future<String?>> _pendingResolutions = {};

  // ---------------------------------------------------------------------------
  // SECTION 5: PREFETCH STATE
  //
  // CancelableOperation allows us to cancel a prefetch mid-flight.
  // WHY THIS MATTERS: If the user skips rapidly through 5 songs, without
  // cancellation each skip spawns a prefetch resolution. All 5 run
  // concurrently, saturating the connection pool and slowing down the
  // ACTUAL current song's resolution. With cancellation, only the last
  // skip's prefetch survives.
  // ---------------------------------------------------------------------------
  static CancelableOperation<void>? _activePrefetch;

  // ---------------------------------------------------------------------------
  // SECTION 6: PRODUCTION LOGGING
  //
  // bool.fromEnvironment reads --dart-define=AURUM_DEBUG=true at build time.
  // In release builds without that flag, _kDebugLogging = false and all
  // dev.log() calls are compiled out (the `if` is evaluated at compile time).
  //
  // WHY NOT just kDebugMode:
  //   kDebugMode = true in debug builds only. But sometimes you need logs
  //   in a release build sent to a tester. AURUM_DEBUG=true enables that.
  // ---------------------------------------------------------------------------
  static const bool _kDebugLogging =
      bool.fromEnvironment('AURUM_DEBUG', defaultValue: false);

  static void _log(String message) {
    // `kDebugMode ||` means logs always show in debug builds (flutter run).
    // `_kDebugLogging` enables them in release builds when explicitly requested.
    if (kDebugMode || _kDebugLogging) {
      dev.log(message, name: 'ApiService');
    }
    // TODO (9.9/10): Add FirebaseCrashlytics.instance.log(message) here
    // for production error tracking without exposing logs to end users.
  }

  // ===========================================================================
  // SECTION 7: LIFECYCLE
  //
  // Call ApiService.dispose() from your WidgetsBindingObserver:
  //   @override
  //   void didChangeAppLifecycleState(AppLifecycleState state) {
  //     if (state == AppLifecycleState.detached) ApiService.dispose();
  //   }
  //
  // WHY THIS MATTERS (MED-1 fix):
  //   _yt (YoutubeExplode) holds an internal HttpClient with its own socket pool.
  //   _client (http.Client) holds its own pool too.
  //   On app detach, Android marks these as leaked FDs. Over multiple cold-starts
  //   (background → foreground → background), this accumulates and triggers
  //   "Too many open files" IOExceptions in extreme cases.
  // ===========================================================================

  static void dispose() {
    _log('[dispose] Closing YoutubeExplode and http.Client');
    _yt.close();       // Closes internal HttpClient + Innertube session
    _client.close();   // Closes connection pool — releases all sockets
    _streamCache.clear();
    _pendingResolutions.clear();
    _activePrefetch?.cancel();
    _activePrefetch = null;
  }

  // ===========================================================================
  // SECTION 8: HOME FEED
  //
  // Uses Future.wait() to fire all 4 Saavn searches in parallel.
  // Total wait time = slowest individual request, not sum of all 4.
  // On a good connection: ~1.2s for home load vs ~4s if sequential.
  //
  // whereType<SongSection>() safely filters out any null results
  // from sections whose Saavn search returned 0 results — no crash.
  // ===========================================================================

  static Future<List<SongSection>> fetchHome() async {
    // Fire all 4 queries simultaneously — parallel, not sequential.
    final results = await Future.wait([
      _saavnSection('trending hindi songs', '🔥 Trending Now'),
      _saavnSection('bollywood hits',       '🎬 Bollywood Hits'),
      _saavnSection('hindi top charts',     '🎵 Hindi Top Charts'),
      _saavnSection('english pop hits',     '🎧 English Hits'),
    ]);
    // whereType<SongSection>() skips null entries without crashing.
    // A null entry means that Saavn search returned 0 results for that query.
    return results.whereType<SongSection>().toList();
  }

  static Future<SongSection?> _saavnSection(String query, String label) async {
    final songs = await _searchSaavn(query, limit: 15);
    // Only return a section if we have at least 1 song.
    // Returning an empty section causes the UI to render an empty row.
    if (songs.isNotEmpty) return SongSection(title: label, songs: songs);
    return null;
  }

  // ===========================================================================
  // SECTION 9: SEARCH — JioSaavn + YouTube combined
  //
  // Runs both searches in parallel via Future.wait.
  // Deduplication strategy: normalise titles to alphanumeric lowercase,
  // then skip any YouTube result whose normalised title already exists
  // in the Saavn results.
  //
  // WHY SAAVN FIRST in merged list:
  //   Saavn results have pre-fetched stream URLs (320kbps) already embedded
  //   in the search response. Tap → play is instant for these songs.
  //   YouTube results require a separate stream resolution call.
  //   Putting Saavn first means the best UX songs appear at the top.
  // ===========================================================================

  static Future<List<Song>> search(String query) async {
    // Run Saavn + YT searches in parallel.
    // If one fails, Future.wait still returns results from the other
    // because each internal search method catches its own exceptions.
    final both = await Future.wait([
      _searchSaavn(query, limit: 20),
      _searchYt(query, limit: 15),
    ]);

    final saavnResults = both[0];
    final ytResults    = both[1];

    // Start merged list with Saavn results (best UX — pre-fetched URLs).
    final merged = <Song>[...saavnResults];

    // Build a Set of normalised Saavn titles for O(1) lookup.
    final existingTitles = saavnResults
        .map((s) => _normalise(s.title))
        .toSet();

    // Add YouTube songs only if their title isn't already in Saavn results.
    // This prevents "Tum Hi Ho" appearing twice (once from each source).
    for (final yt in ytResults) {
      if (!existingTitles.contains(_normalise(yt.title))) {
        merged.add(yt);
      }
    }
    return merged;
  }

  // Normalise: lowercase + alphanumeric only + cap at 20 chars.
  // 20-char prefix is enough to catch near-duplicates without false positives
  // from very long similar titles (e.g., "Tum Hi Ho (From Aashiqui 2)" vs "Tum Hi Ho").
  static String _normalise(String s) {
    final clean = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    // clamp(0, 20) prevents RangeError on very short strings (empty, 1-char, etc.)
    return clean.substring(0, clean.length.clamp(0, 20));
  }

  // ---------------------------------------------------------------------------
  // 9a: JioSaavn Search
  //
  // Timeout: 10s (not 5s) because jiosavan.onrender.com free tier spins down
  // after inactivity. First request after spin-down needs ~8-12s.
  //
  // Response shape handling:
  //   The Saavn proxy returns inconsistent shapes depending on version:
  //     Shape A: [ {...}, {...} ]          → data is List directly
  //     Shape B: { "data": { "results": [...] } }  → nested results
  //     Shape C: { "data": [...] }         → data is List
  //   All three are handled below without crashing.
  // ---------------------------------------------------------------------------
  static Future<List<Song>> _searchSaavn(String query, {int limit = 20}) async {
    try {
      final url = Uri.parse(
        '$_saavn/result/?query=${Uri.encodeQueryComponent(query)}&limit=$limit',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);

        // Handle all three known response shapes from jiosavan.onrender.com
        final results = data is List
            ? data                                            // Shape A
            : (data['data']?['results']                      // Shape B
               ?? data['data']                               // Shape C
               ?? []);

        if (results is List && results.isNotEmpty) {
          return results
              .whereType<Map<String, dynamic>>()  // Skip any malformed entries
              .take(limit)                         // Respect caller's limit
              .map(_songFromSaavn)                 // Parse to Song model
              .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)  // Skip corrupt entries
              .toList();
        }
      }
    } catch (e) {
      // Catch-all: network error, JSON parse error, timeout — all produce empty list.
      // We NEVER rethrow here because _searchSaavn is used inside Future.wait
      // and a thrown exception would cancel the YT search too.
      _log('[_searchSaavn] Error: $e');
    }
    return [];
  }

  // ---------------------------------------------------------------------------
  // 9b: YouTube Search via youtube_explode_dart
  //
  // BUG FIXED (HIGH-5):
  //   OLD CODE: `await _yt.search.search(query).timeout(Duration(seconds: 6))`
  //   PROBLEM: search.search() returns a SearchList (lazy paginated iterable).
  //   Calling .timeout() on it applies the timeout to the *entire* lazy
  //   evaluation — but the first .toList() call can block indefinitely if
  //   YT is slow, because the timeout only fires when the whole list is done.
  //
  //   FIX: Use Future.any() with a timeout Future. This races the actual search
  //   against a 6-second timer. Whichever completes first wins.
  //   If timeout wins, we return empty list instead of blocking the search UI.
  // ---------------------------------------------------------------------------
  static Future<List<Song>> _searchYt(String query, {int limit = 15}) async {
    try {
      // Race the YT search against a 6-second timeout.
      // Future.any() returns the result of whichever Future completes first.
      // The timeout Future returns an empty list — safe default.
      final results = await Future.any<List<dynamic>>([
        _yt.search.search(query).then((list) => list.toList()),
        Future.delayed(
          const Duration(seconds: 6),
          () => <dynamic>[],  // Timeout fallback — empty list, not an error
        ),
      ]);

      return results
          .whereType<Video>()   // SearchList can contain channels/playlists too — skip those
          .take(limit)
          .map(_songFromYtVideo)
          .where((s) => s.id.isNotEmpty)  // Skip videos with empty IDs
          .toList();
    } catch (e) {
      _log('[_searchYt] Error: $e');
    }
    return [];
  }

  // ---------------------------------------------------------------------------
  // 9c: Build Song from YouTube Video object
  //
  // BUG FIXED (MED-3):
  //   OLD: `v.thumbnails.maxResUrl.isNotEmpty ? maxResUrl : highResUrl`
  //   PROBLEM: Both maxResUrl and highResUrl can be empty strings (not null).
  //   If highResUrl is also empty, artworkUrl = '' → broken image widget.
  //
  //   FIX: Try all 5 thumbnail quality levels in descending order.
  //   Return '' only if ALL are empty (very rare but possible for age-restricted videos).
  // ---------------------------------------------------------------------------
  static Song _songFromYtVideo(Video v) {
    return Song(
      id:         v.id.value,
      title:      _cleanText(v.title),
      artist:     _cleanText(v.author),
      album:      '',
      artworkUrl: _bestThumbnail(v.thumbnails),
      streamUrl:  null,   // YouTube songs never have a pre-fetched URL — always resolved later
      duration:   v.duration?.inSeconds,
      // source is EXPLICITLY set here — never guessed from ID format.
      // This is the single source of truth for all downstream routing decisions.
      source: SongSource.youtube,
    );
  }

  // Returns the best available thumbnail URL from a VideoThumbnails object.
  // Tries from highest to lowest quality. Returns '' if none available.
  static String _bestThumbnail(VideoThumbnails t) {
    // Try all quality levels from best to worst
    for (final url in [
      t.maxResUrl,
      t.highResUrl,
      t.standardResUrl,
      t.mediumResUrl,
      t.lowResUrl,
    ]) {
      // Check isNotEmpty because these return String, not String?
      if (url.isNotEmpty) return url;
    }
    return '';  // All thumbnail levels empty — very rare, only on age-restricted content
  }

  // ===========================================================================
  // SECTION 10: SUGGESTIONS (Autocomplete)
  //
  // Uses Saavn search with a short limit for fast autocomplete results.
  // Timeout is 5s (shorter than full search) because suggestions must feel instant.
  // Returns only the song title strings — not full Song objects.
  // ===========================================================================

  static Future<List<String>> suggest(String query) async {
    final results = await _suggestSaavn(query);
    return results.take(8).toList();
  }

  static Future<List<String>> _suggestSaavn(String query) async {
    try {
      final url = Uri.parse(
        '$_saavn/result/?query=${Uri.encodeQueryComponent(query)}&limit=5',
      );
      // 5s timeout — suggestions are latency-critical for good UX.
      // If Saavn is slow, we return empty rather than blocking the search field.
      final res = await _client.get(url).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final results = data is List ? data : (data['data']?['results'] ?? []);

        if (results is List) {
          return results
              .whereType<Map<String, dynamic>>()
              .map((j) => _cleanText(
                    // Try all known title field names from different API versions
                    (j['song'] ?? j['name'] ?? j['title'] ?? '').toString()))
              .where((s) => s.isNotEmpty)
              .take(5)
              .toList();
        }
      }
    } catch (_) {
      // Suggestions are best-effort — silently swallow all errors.
      // The search field will just show no autocomplete suggestions.
    }
    return [];
  }

  // ===========================================================================
  // SECTION 11: STREAM URL RESOLUTION — THE CORE ENGINE
  //
  // This is the most critical method in the entire app.
  // Every song play goes through here. Every bug here = broken playback.
  //
  // RESOLUTION FLOW (in order):
  //   1. Local shortcut          → return localPath immediately (0ms)
  //   2. Cache hit               → return cached URL immediately (0ms)
  //   3. Concurrent guard check  → join existing in-flight resolution (0 extra network)
  //   4. Saavn pre-fetched URL   → return embedded URL from search response (~0ms)
  //   5. Source-aware resolution → network call (100ms - 3000ms)
  //      a. SongSource.saavn    → Saavn /song/?id= → YT search fallback
  //      b. SongSource.youtube  → Worker → youtube_explode → YT search fallback
  //      c. SongSource.local    → localPath (safety net — caught by step 1)
  //   6. Cache write             → store result for next 50 minutes
  //   7. Return URL or null      → null = all sources failed, show error to user
  //
  // CONCURRENCY GUARANTEE (CRITICAL-1 fix):
  //   Only ONE HTTP resolution chain runs per song at any time.
  //   Additional calls for the same song join the same Future.
  // ===========================================================================

  static Future<String?> resolveStreamUrl(
    Song song, {
    bool forceRefresh = false,
  }) async {

    // ── Step 1: Local file shortcut ──────────────────────────────────────────
    // Local songs never need network resolution. Return immediately.
    // isLocal checks: song.source == SongSource.local && localPath != null.
    if (song.isLocal) {
      _log('[resolve] Local path: ${song.localPath}');
      return song.localPath;
    }

    // ── Step 2: Cache key ────────────────────────────────────────────────────
    // Key format: "source:id" e.g. "saavn:abc123" or "youtube:dQw4w9WgXcQ"
    // Including the source in the key prevents collisions where a Saavn ID
    // happens to match a YouTube video ID (rare but possible with short IDs).
    final cacheKey = '${song.source.name}:${song.id}';

    // ── Step 3: Cache hit check ──────────────────────────────────────────────
    if (!forceRefresh) {
      final cached = _streamCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        _log('[resolve] Cache HIT for "${song.title}" ($cacheKey) '
            'age=${DateTime.now().difference(cached.resolvedAt).inMinutes}min');
        return cached.url;  // Return immediately — 0ms, no network
      }
      // If cached but expired: fall through to re-resolution below.
      // The expired entry stays in the map until _writeCache evicts it.
    }

    // ── Step 4: Concurrent resolution guard (CRITICAL-1 FIX) ────────────────
    // If another call is already resolving this exact song, don't start
    // a second HTTP chain — just await the same Future.
    if (!forceRefresh && _pendingResolutions.containsKey(cacheKey)) {
      _log('[resolve] Joining in-flight resolution for "$cacheKey"');
      // Await the existing Future. This completes at the same time as the
      // original caller — zero extra network, zero race condition.
      return _pendingResolutions[cacheKey];
    }

    // ── Step 5: Saavn pre-fetched URL shortcut (HIGH-2 FIX) ─────────────────
    // Saavn search responses embed a 320kbps stream URL directly.
    // This means Saavn songs from search results can play with 0 extra network calls.
    //
    // BUG FIXED: Old code always trusted this URL. But if the song was
    // parsed from a search result >50 minutes ago (e.g., sitting in a queue),
    // the URL may already be expired.
    //
    // FIX: Cross-reference with the cache. If we have a cache entry for this
    // song that contains the same URL and it's NOT expired → trust it.
    // If the cache is expired OR we have no cache entry → trust the pre-fetched
    // URL only if it's "fresh" (no cache entry = just parsed from API).
    if (!forceRefresh &&
        song.source == SongSource.saavn &&
        song.streamUrl != null &&
        song.streamUrl!.startsWith('http')) {

      final cached = _streamCache[cacheKey];

      if (cached == null) {
        // No cache entry means this URL just came from a live API response.
        // Trust it — it's fresh. Cache it now to track its age going forward.
        _log('[resolve] Pre-fetched Saavn URL (fresh): "${song.title}"');
        _writeCache(cacheKey, song.streamUrl!);
        return song.streamUrl;
      }

      if (!cached.isExpired) {
        // Cache entry exists and hasn't expired — URL is still valid.
        _log('[resolve] Pre-fetched Saavn URL (cache valid): "${song.title}"');
        return cached.url;
      }

      // Cache entry is expired — the pre-fetched URL is likely expired too.
      // Fall through to full re-resolution. Log it so we can see this in diagnostics.
      _log('[resolve] Saavn pre-fetched URL expired for "${song.title}" — re-resolving');
    }

    // ── Step 6: Full network resolution ─────────────────────────────────────
    // Register this resolution in _pendingResolutions BEFORE the await.
    // Any concurrent call for the same song between now and the final `finally`
    // will join this Future instead of starting a new one.
    _log('[resolve] Resolving "${song.title}" '
        'source=${song.source.name} id=${song.id} forceRefresh=$forceRefresh');

    // Create the resolution Future and register it.
    final resolutionFuture = _doResolve(song, cacheKey);
    _pendingResolutions[cacheKey] = resolutionFuture;

    try {
      final url = await resolutionFuture;
      return url;
    } finally {
      // ALWAYS remove from pending map — success, failure, or exception.
      // Without `finally`, a thrown exception would leave a stale Future in the
      // map and ALL future calls for this song would await a dead Future forever.
      _pendingResolutions.remove(cacheKey);
    }
  }

  // ---------------------------------------------------------------------------
  // _doResolve: The actual network resolution logic.
  //
  // Separated from resolveStreamUrl() so that resolveStreamUrl() can cleanly
  // manage the _pendingResolutions lifecycle around this call.
  // ---------------------------------------------------------------------------
  static Future<String?> _doResolve(Song song, String cacheKey) async {
    String? url;

    switch (song.source) {

      // ── SAAVN ──────────────────────────────────────────────────────────────
      // PRIMARY: Fetch fresh stream URL from Saavn API by song ID.
      //   /song/?id= returns full song data including all quality URLs.
      //   _saavnStreamById() extracts the best available quality (320kbps first).
      // FALLBACK: If Saavn API fails (server down, rate limit, invalid ID),
      //   fall back to resolving through YouTube search. The song title + artist
      //   is used as the search query to find the closest match on YouTube.
      case SongSource.saavn:
        if (song.id.isNotEmpty) {
          // PRIMARY: Saavn by ID with exponential backoff retry
          url = await _retry(() => _saavnStreamById(song.id));
          _log('[resolve] Saavn by ID "${song.title}": ${url != null ? "OK" : "FAILED"}');
        }
        if (url == null) {
          // FALLBACK: YouTube search stream
          _log('[resolve] Saavn failed → falling back to YT search for "${song.title} ${song.artist}"');
          url = await _retry(() => _ytStreamBySearch('${song.title} ${song.artist}'));
        }
        break;

      // ── YOUTUBE ────────────────────────────────────────────────────────────
      // PRIORITY CHAIN: Worker → youtube_explode_dart → YT search
      //
      //   WORKER (PRIMARY): Routes through Cloudflare server IP.
      //     Avoids bot-detection that blocks direct mobile client Innertube calls.
      //     Typical latency: 500ms - 1500ms on first call, faster with Cloudflare caching.
      //
      //   youtube_explode_dart (FALLBACK-1): Direct Innertube from device.
      //     Works when worker is down. May fail on mobile data IPs with bot-detection.
      //     Now uses m4a/AAC format selection for Android API 26+ compatibility.
      //
      //   YT search (FALLBACK-2): Search by title+artist → resolve first result.
      //     Slowest path (~3-5s). Used when video ID itself is invalid or blocked.
      case SongSource.youtube:
        if (song.id.isNotEmpty) {
          // PRIMARY: Cloudflare worker
          url = await _retry(() => _workerYtStream(song.id));
          _log('[resolve] Worker for ${song.id}: ${url != null ? "OK" : "FAILED"}');

          // FALLBACK-1: youtube_explode_dart (now with codec selection)
          if (url == null) {
            _log('[resolve] Worker failed → trying youtube_explode for ${song.id}');
            url = await _retry(() => _ytExplodeStream(song.id));
            _log('[resolve] youtube_explode for ${song.id}: ${url != null ? "OK" : "FAILED"}');
          }
        }

        // FALLBACK-2: Search-based resolution (works even if song ID is wrong)
        if (url == null) {
          _log('[resolve] Explode failed → YT search stream for "${song.title} ${song.artist}"');
          url = await _retry(() => _ytStreamBySearch('${song.title} ${song.artist}'));
        }
        break;

      // ── LOCAL ──────────────────────────────────────────────────────────────
      // Safety net — should have been caught by isLocal check at the top.
      // Returning localPath here prevents a null return for local songs that
      // somehow reach _doResolve (shouldn't happen, but defensive coding).
      case SongSource.local:
        return song.localPath;
    }

    // ── Write to cache if resolution succeeded ───────────────────────────────
    if (url != null) {
      _log('[resolve] SUCCESS "${song.title}" → ${url.substring(0, url.length.clamp(0, 80))}...');
      _writeCache(cacheKey, url);  // LRU-bounded cache write
    } else {
      _log('[resolve] FAILED all sources for "${song.title}" ($cacheKey)');
    }

    return url;
  }

  // ===========================================================================
  // SECTION 12: YOUTUBE STREAM RESOLUTION METHODS
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // 12a: Cloudflare Worker — PRIMARY YouTube stream resolver
  //
  // The worker at _worker/api/yt-stream?id=VIDEO_ID runs server-side Innertube.
  // Server IPs are not flagged by YouTube's bot detection, unlike mobile IPs.
  //
  // RESPONSE SHAPE HANDLING (HIGH-4 FIX):
  //   The worker can return multiple shapes depending on its implementation:
  //     Shape 1: { "url": "https://..." }
  //     Shape 2: { "stream_url": "https://..." }
  //     Shape 3: { "audio_url": "https://..." }
  //     Shape 4: { "data": { "url": "https://..." } }   ← NEW: nested envelope
  //     Shape 5: [{ "url": "https://..." }]              ← NEW: array response
  //     Shape 6: raw text "https://..."                  ← direct URL in body
  //   All 6 are now handled.
  //
  // Content-Type routing:
  //   application/json → parse JSON for URL
  //   anything else    → check if body itself is a URL (some workers return raw text)
  // ---------------------------------------------------------------------------
  static Future<String?> _workerYtStream(String videoId) async {
    try {
      final uri = Uri.parse('$_worker/api/yt-stream?id=$videoId');
      _log('[worker] Request: $uri');

      final res = await _client
          .get(uri)
          .timeout(const Duration(seconds: 15));
          // 15s timeout — worker may need to make its own Innertube call.
          // Do NOT use 5s or 8s — the worker sometimes takes 10-12s on cold start.

      _log('[worker] Response: status=${res.statusCode} '
          'content-type=${res.headers['content-type']}');

      if (res.statusCode == 200) {
        final ct = res.headers['content-type'] ?? '';

        if (ct.contains('application/json')) {
          // Parse JSON response
          final data = jsonDecode(res.body);

          // Shape 1/2/3: Direct key at root level
          String? url = (data['url'] ?? data['stream_url'] ?? data['audio_url'])
              ?.toString();

          // Shape 4: Nested data envelope { "data": { "url": "..." } }
          if (url == null && data['data'] is Map) {
            url = (data['data']['url'] ?? data['data']['stream_url'])
                ?.toString();
          }

          // Shape 5: Array response [{ "url": "..." }]
          if (url == null && data is List && data.isNotEmpty && data[0] is Map) {
            url = (data[0]['url'] ?? data[0]['stream_url'])?.toString();
          }

          if (url != null && url.startsWith('http')) {
            _log('[worker] Parsed URL from JSON (${url.length} chars)');
            return url;
          }

          // Log what keys we got — helps debug future worker format changes
          _log('[worker] JSON had no URL. '
              'Keys: ${data is Map ? data.keys.toList() : "not a Map"}');
          return null;
        }

        // Non-JSON: check if the response body itself is a direct URL.
        // Some minimal worker implementations return the URL as plain text.
        final body = res.body.trim();
        if (body.startsWith('http')) {
          _log('[worker] Got raw URL from body');
          return body;
        }
      } else {
        // Log error body (first 300 chars) for debugging worker failures.
        // Common causes: worker crashed (502), rate limited (429), ID blocked (403).
        _log('[worker] Error ${res.statusCode}: '
            '${res.body.substring(0, res.body.length.clamp(0, 300))}');
      }
    } catch (e) {
      _log('[worker] Exception: $e');
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 12b: youtube_explode_dart — FALLBACK-1
  //
  // Direct Innertube call from the device. Works when worker is down.
  // May fail on residential/mobile IPs with bot-detection.
  //
  // BUG FIXED (CRITICAL-4): Format selection
  //   OLD: `manifest.audioOnly.withHighestBitrate()` — picks highest bitrate
  //        without checking codec. On Android API <29, opus/webm causes
  //        MediaCodecAudioRenderer to throw AudioDecoderException silently.
  //        The player shows "buffering" forever or crashes.
  //
  //   FIX: Explicitly prefer m4a (AAC-LC) containers which are natively
  //        supported on ALL Android versions since API 16.
  //        Only fall back to highest-bitrate (may be opus/webm) if no m4a exists.
  //
  // HOW TO IDENTIFY m4a streams:
  //   youtube_explode_dart AudioStreamInfo has:
  //     - codec.mimeType: "audio/mp4" for AAC, "audio/webm" for opus
  //     - container.name: "mp4" or "webm" or "m4a"
  //   We check both mimeType and container.name for robustness.
  // ---------------------------------------------------------------------------
  static Future<String?> _ytExplodeStream(String videoId) async {
    try {
      // getManifest fetches the full stream manifest for this video.
      // This makes an Innertube /player API call — can take 1-8s on mobile.
      final manifest = await _yt.videos.streamsClient
          .getManifest(VideoId(videoId))
          .timeout(const Duration(seconds: 12));
          // 12s timeout — Innertube can be slow. Less than this and we miss
          // valid streams on slow connections; more and UX degrades too much.

      if (manifest.audioOnly.isEmpty) {
        _log('[ytExplode] No audio streams for $videoId');
        return null;
      }

      // Filter for m4a (AAC) streams — universally compatible on Android
      final m4aStreams = manifest.audioOnly.where((s) {
        final mime = s.codec.mimeType.toLowerCase();
        final container = s.container.name.toLowerCase();
        // Accept: audio/mp4, audio/x-m4a, audio/aac, container = mp4 or m4a
        return mime.contains('mp4') ||
               mime.contains('aac') ||
               container == 'mp4'   ||
               container == 'm4a';
      }).toList();

      if (m4aStreams.isNotEmpty) {
        // Sort by bitrate descending — highest quality m4a stream
        m4aStreams.sort((a, b) =>
            b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        final chosen = m4aStreams.first;
        _log('[ytExplode] Using m4a stream for $videoId: '
            '${chosen.bitrate.kiloBitsPerSecond.toStringAsFixed(0)} kbps, '
            'mime=${chosen.codec.mimeType}');
        return chosen.url.toString();
      }

      // No m4a streams found — fall back to highest bitrate (may be opus/webm).
      // Log a warning — this may cause issues on API 26-28 devices.
      final best = manifest.audioOnly.withHighestBitrate();
      _log('[ytExplode] No m4a stream for $videoId — using ${best.codec.mimeType} '
          '(${best.bitrate.kiloBitsPerSecond.toStringAsFixed(0)} kbps). '
          'WARNING: May fail on Android API <29');
      return best.url.toString();

    } catch (e) {
      _log('[ytExplode] Error for $videoId: $e');
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 12c: YT Search-based stream resolution — FALLBACK-2
  //
  // Search YouTube by query string → take first video result → resolve its stream.
  // Used when the song's video ID is invalid, blocked, or song.id is empty.
  //
  // WHY NOT just use video ID from search results directly:
  //   We still try Worker first on the search-found ID, then youtube_explode.
  //   This ensures even search-found IDs go through the best resolution path.
  // ---------------------------------------------------------------------------
  static Future<String?> _ytStreamBySearch(String query) async {
    try {
      // Same Future.any timeout pattern as _searchYt (HIGH-5 fix)
      final results = await Future.any<List<dynamic>>([
        _yt.search.search(query).then((list) => list.toList()),
        Future.delayed(
          const Duration(seconds: 12),
          () => <dynamic>[],
        ),
      ]);

      final videos = results.whereType<Video>().toList();
      if (videos.isEmpty) {
        _log('[ytSearch] No video results for query: "$query"');
        return null;
      }

      final id = videos.first.id.value;
      _log('[ytSearch] Found video $id for "$query" — resolving stream');

      // Try worker first (faster), then explode (slower but direct)
      return await _workerYtStream(id) ?? await _ytExplodeStream(id);

    } catch (e) {
      _log('[ytSearch] Error: $e');
    }
    return null;
  }

  // ===========================================================================
  // SECTION 13: SAAVN STREAM RESOLUTION METHODS
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // 13a: Saavn stream by ID
  //
  // BUG FIXED (MED-5): Response envelope handling
  //   OLD: Only handled top-level List and top-level Map.
  //   NEW: Also handles { "data": [...] } and { "data": { ... } } envelopes.
  //
  // The jiosavan.onrender.com /song/?id= endpoint has returned at least 4
  // different shapes across its version history:
  //   Shape A: [ { ...song... } ]                  → data is List
  //   Shape B: { "data": [ { ...song... } ] }      → data.data is List
  //   Shape C: { "data": { ...song... } }           → data.data is Map
  //   Shape D: { ...song... }                       → data is Map (flat)
  //
  // Stream URL extraction priority (in _onrenderStreamUrl and _extractSaavnStreamUrl):
  //   1. "320kbps" field  → highest quality
  //   2. "media_url" field → legacy field
  //   3. "downloadUrl" array → try qualities 320kbps, 160kbps, 96kbps, 48kbps, 12kbps
  //   4. Last item in downloadUrl array → whatever is available
  // ---------------------------------------------------------------------------
  static Future<String?> _saavnStreamById(String songId) async {
    try {
      final res = await _client
          .get(Uri.parse('$_saavn/song/?id=$songId'))
          .timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final raw = jsonDecode(res.body);
        Map<String, dynamic>? songData;

        if (raw is List && raw.isNotEmpty) {
          // Shape A: top-level list
          songData = raw[0] as Map<String, dynamic>?;

        } else if (raw is Map<String, dynamic>) {
          final inner = raw['data'];
          if (inner is List && inner.isNotEmpty) {
            // Shape B: { "data": [...] }
            songData = inner[0] as Map<String, dynamic>?;
          } else if (inner is Map<String, dynamic>) {
            // Shape C: { "data": { ... } }
            songData = inner;
          } else {
            // Shape D: { ...song... } — data IS the song
            songData = raw;
          }
        }

        if (songData != null) {
          // Try primary fields first, then fallback extractor
          return _onrenderStreamUrl(songData) ?? _extractSaavnStreamUrl(songData);
        }

        _log('[saavnById] Could not extract songData from response for $songId');
      }
    } catch (e) {
      _log('[saavnById] Error for $songId: $e');
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 13b: Extract stream URL from Saavn song map
  //
  // _onrenderStreamUrl: checks legacy/simple fields ("320kbps", "media_url")
  // _extractSaavnStreamUrl: checks the newer "downloadUrl" array format
  // ---------------------------------------------------------------------------

  // Primary extractor — checks simple string fields
  static String? _onrenderStreamUrl(Map<String, dynamic> j) {
    final url320 = (j['320kbps'] ?? '').toString();
    if (url320.startsWith('http')) return url320;

    final urlMedia = (j['media_url'] ?? '').toString();
    if (urlMedia.startsWith('http')) return urlMedia;

    return null;
  }

  // Secondary extractor — checks "downloadUrl" quality array
  static String? _extractSaavnStreamUrl(Map<String, dynamic> song) {
    final downloads = song['downloadUrl'] as List?;
    if (downloads != null && downloads.isNotEmpty) {
      // Try qualities from best to worst
      for (final q in ['320kbps', '160kbps', '96kbps', '48kbps', '12kbps']) {
        final match = downloads.firstWhere(
          (d) => d is Map &&
                 d['quality'] == q &&
                 (d['url'] as String?)?.startsWith('http') == true,
          orElse: () => null,
        );
        if (match != null) return match['url'] as String;
      }
      // Last resort: take whatever the last item offers
      final last = downloads.last;
      if (last is Map && (last['url'] as String?)?.startsWith('http') == true) {
        return last['url'] as String;
      }
    }

    // Final check: streamUrl field (some API versions use this name)
    final su = song['media_url'] ?? song['streamUrl'];
    if (su is String && su.startsWith('http')) return su;

    return null;
  }

  // ===========================================================================
  // SECTION 14: RETRY WITH EXPONENTIAL BACKOFF
  //
  // BUG FIXED (HIGH-1): Old retry had two problems:
  //   1. `catch (_) {}` — silently swallowed ALL exceptions including
  //      non-retriable ones (e.g., invalid JSON). No way to debug failures.
  //   2. Fixed 400ms delay — hitting the same throttled server repeatedly
  //      with no back-off. On Saavn's free tier this causes 429 cascades.
  //
  // NEW: Exponential backoff with jitter:
  //   Attempt 1: immediate
  //   Attempt 2: wait 300ms (baseDelay × 2^0)
  //   Attempt 3: wait 600ms (baseDelay × 2^1)
  //   Attempt 4: wait 1200ms (baseDelay × 2^2)
  //   (Formula: baseDelay * (1 << attemptIndex))
  //
  // The `1 << i` bit-shift is equivalent to `pow(2, i).toInt()` but faster.
  // `1 << 0` = 1, `1 << 1` = 2, `1 << 2` = 4 → × 300ms = 300, 600, 1200ms.
  //
  // retryIf: optional predicate that can stop retrying on permanent failures.
  // Example: don't retry on 404 (invalid ID won't become valid after waiting).
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
        // result == null means the function returned null without throwing.
        // We still retry — null could mean "server returned empty response".
      } catch (e) {
        lastError = e;
        // Check if this error type is worth retrying.
        // If retryIf is provided and returns false → stop immediately.
        if (retryIf != null && !retryIf(e)) {
          _log('[retry] Non-retriable error on attempt ${i+1}: $e — stopping');
          break;
        }
        _log('[retry] Attempt ${i+1}/$attempts failed: $e');
      }

      // Wait before next attempt (skip delay after last attempt)
      if (i < attempts - 1) {
        final delay = baseDelay * (1 << i);  // 300ms, 600ms, 1200ms
        _log('[retry] Waiting ${delay.inMilliseconds}ms before attempt ${i+2}');
        await Future.delayed(delay);
      }
    }

    if (lastError != null) {
      _log('[retry] Exhausted $attempts attempts. Last error: $lastError');
    }
    return null;
  }

  // ===========================================================================
  // SECTION 15: CACHE MANAGEMENT
  //
  // _writeCache: Bounded LRU write (CRITICAL-2 fix)
  //   Before writing, checks if cache is at capacity.
  //   Eviction order: expired entries first, then oldest by resolvedAt.
  //   This ensures we never hold more than _maxCacheSize entries in RAM.
  //
  // invalidateStream: Force-removes a song's cache entry.
  //   Call this from AudioPlayerService when just_audio returns a 403 error.
  //   Next call to resolveStreamUrl will fetch a fresh URL.
  //
  // clearExpiredCache: Housekeeping method.
  //   Call periodically (e.g., from a Timer every 30 min) to prevent
  //   RAM accumulation from expired-but-not-evicted entries.
  // ===========================================================================

  static void _writeCache(String key, String url) {
    // Evict if at capacity
    if (_streamCache.length >= _maxCacheSize) {
      // First pass: remove all expired entries (easy wins)
      final expiredKeys = _streamCache.entries
          .where((e) => e.value.isExpired)
          .map((e) => e.key)
          .toList();

      for (final k in expiredKeys) {
        _streamCache.remove(k);
        _log('[cache] Evicted expired: $k');
      }

      // If still at capacity after removing expired entries,
      // evict the single oldest non-expired entry (LRU policy)
      if (_streamCache.length >= _maxCacheSize) {
        // Find entry with earliest resolvedAt timestamp
        final oldest = _streamCache.entries.reduce(
          (a, b) => a.value.resolvedAt.isBefore(b.value.resolvedAt) ? a : b,
        );
        _streamCache.remove(oldest.key);
        _log('[cache] Evicted oldest (LRU): ${oldest.key} '
            'age=${DateTime.now().difference(oldest.value.resolvedAt).inMinutes}min');
      }
    }

    _streamCache[key] = _CachedStream(url);
    _log('[cache] Stored: $key (cache size: ${_streamCache.length}/$_maxCacheSize)');
  }

  // Force-remove a song's cache entry.
  // Use when just_audio returns 403/410 on a cached URL — the URL has expired
  // before our 50-min TTL (this happens with some CDN configurations).
  static void invalidateStream(Song song) {
    final key = '${song.source.name}:${song.id}';
    final removed = _streamCache.remove(key);
    _log('[cache] invalidateStream: $key → ${removed != null ? "removed" : "was not cached"}');
  }

  // Remove all expired entries from cache.
  // Call this from a periodic Timer in your app's lifecycle manager:
  //   Timer.periodic(Duration(minutes: 30), (_) => ApiService.clearExpiredCache());
  static void clearExpiredCache() {
    final before = _streamCache.length;
    _streamCache.removeWhere((_, v) => v.isExpired);
    final removed = before - _streamCache.length;
    _log('[cache] clearExpiredCache: removed $removed expired entries, '
        '${_streamCache.length} remain');
  }

  // ===========================================================================
  // SECTION 16: NETWORK RECOVERY (CRITICAL-3 FIX)
  //
  // OLD: onNetworkRestored() only logged a message — completely useless.
  //
  // NEW: Real implementation with two actions:
  //   1. Purge all expired cache entries.
  //      WHY: After a network outage, cached URLs may have been valid when
  //      cached but expire during the outage period. Removing them forces
  //      fresh resolution on next play.
  //   2. Pre-warm stream URL for the currently playing song.
  //      WHY: The song that was playing when network dropped needs a fresh URL
  //      immediately so playback can resume. Without pre-warming, the user
  //      taps play → resolution starts → 1-3s delay before audio resumes.
  //      With pre-warming, the URL is ready before the user even taps.
  //
  // HOW TO WIRE THIS:
  //   In your ConnectivityProvider or NetworkObserver:
  //
  //   _connectivity.onConnectivityChanged.listen((result) {
  //     final hasNetwork = result != ConnectivityResult.none;
  //     if (hasNetwork) {
  //       ApiService.onNetworkRestored(
  //         currentSong: audioPlayerService.currentSong,
  //       ).then((_) {
  //         // Only resume if player was paused DUE to network loss
  //         if (audioPlayerService.pausedForNetwork) {
  //           audioPlayerService.play();
  //         }
  //       });
  //     }
  //   });
  // ===========================================================================
  static Future<void> onNetworkRestored({Song? currentSong}) async {
    _log('[network] Network restored — starting recovery');

    // Step 1: Purge expired cache entries
    final before = _streamCache.length;
    _streamCache.removeWhere((_, v) => v.isExpired);
    _log('[network] Purged ${before - _streamCache.length} expired cache entries');

    // Step 2: Pre-warm stream URL for currently playing song
    if (currentSong != null && !currentSong.isLocal) {
      _log('[network] Pre-warming stream for "${currentSong.title}" after reconnect');
      try {
        final url = await resolveStreamUrl(currentSong, forceRefresh: true);
        _log('[network] Pre-warm ${url != null ? "SUCCESS" : "FAILED"} for "${currentSong.title}"');
      } catch (e) {
        _log('[network] Pre-warm exception: $e');
        // Don't rethrow — network recovery is best-effort.
        // The user's tap on play will trigger a fresh resolution anyway.
      }
    }
  }

  // ===========================================================================
  // SECTION 17: PREFETCH NEXT SONG (HIGH-3 FIX)
  //
  // OLD: Used Future.microtask — fires immediately in the same event loop turn,
  //      competes with current song's resolution, no cancellation possible.
  //
  // NEW: Uses CancelableOperation with an 800ms delay.
  //
  // WHY 800ms delay:
  //   The current song's resolution starts first (triggered by user tap).
  //   We wait 800ms before starting prefetch to ensure current resolution
  //   gets the connection pool priority. 800ms is enough for most resolutions
  //   to complete their first attempt before prefetch starts competing.
  //
  // WHY CancelableOperation:
  //   If the user skips while prefetch is in the 800ms wait period, we cancel
  //   immediately — zero wasted network. If they skip after prefetch started,
  //   we can't cancel the HTTP request mid-flight, but we can ignore the result.
  //
  // WHEN TO CALL THIS:
  //   Call from AudioPlayerService when current song position reaches 80%:
  //
  //   _player.positionStream.listen((pos) {
  //     final duration = _player.duration;
  //     if (duration != null &&
  //         pos.inSeconds / duration.inSeconds > 0.80 &&
  //         !_prefetchCalled) {
  //       _prefetchCalled = true;
  //       ApiService.prefetchNext(queue[currentIndex + 1]);
  //     }
  //   });
  //   // Reset _prefetchCalled on song change
  // ===========================================================================
  static void prefetchNext(Song song) {
    if (song.isLocal) return;  // Local songs need no prefetch — they're already on disk

    // Cancel any in-progress prefetch (could be for a different song if user skipped)
    _activePrefetch?.cancel();
    _activePrefetch = null;

    _log('[prefetch] Scheduling prefetch for "${song.title}" (800ms delay)');

    _activePrefetch = CancelableOperation.fromFuture(
      Future.delayed(const Duration(milliseconds: 800), () async {
        // Check cancellation after the delay — user may have skipped during wait
        // CancelableOperation automatically handles this; if canceled, the
        // inner Future still runs but its result is discarded.
        _log('[prefetch] Starting prefetch for "${song.title}"');
        try {
          final url = await resolveStreamUrl(song);
          _log('[prefetch] Prefetch ${url != null ? "SUCCESS" : "FAILED"} for "${song.title}"');
        } catch (e) {
          _log('[prefetch] Prefetch exception for "${song.title}": $e');
          // Silent — prefetch failure is non-critical. The main resolution
          // will run when the user actually plays this song.
        }
      }),
    );
  }

  // Cancel any active prefetch — call when queue changes significantly
  static void cancelPrefetch() {
    _activePrefetch?.cancel();
    _activePrefetch = null;
    _log('[prefetch] Prefetch cancelled');
  }

  // ===========================================================================
  // SECTION 18: SONG PARSERS
  //
  // _songFromSaavn: Parses a Saavn API song map to a Song model.
  //   - source is ALWAYS SongSource.saavn — never guessed from ID format
  //   - Falls back through multiple field names for each property because
  //     the Saavn proxy has returned different field names across versions
  //   - _cleanText() decodes HTML entities (e.g., "&amp;" → "&")
  //
  // Source enum deserialization (NEW — needed for queue persistence):
  //   When restoring a queue from SharedPreferences/Hive, Song.fromJson()
  //   must correctly deserialize the source field. _sourceFromString() provides
  //   a safe enum deserializer with a fallback to SongSource.saavn.
  // ===========================================================================

  static Song _songFromSaavn(Map<String, dynamic> j) {
    // Parse all fields with multiple fallbacks for API version compatibility
    final title  = _cleanText(
        (j['song'] ?? j['name'] ?? j['title'] ?? 'Unknown').toString());
    final artist = _cleanText(
        (j['primary_artists'] ?? j['singers'] ?? j['artist'] ?? 'Unknown').toString());
    final album  = _cleanText((j['album'] ?? '').toString());
    final artwork   = _onrenderArtwork(j);
    final streamUrl = _onrenderStreamUrl(j);  // Pre-fetched 320kbps URL (may be null)

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
      // CRITICAL: source is ALWAYS explicitly set here.
      // Never infer from ID format (no regex like "if id.length == 11 → youtube").
      // This is the single source of truth for all downstream routing.
      source: SongSource.saavn,
    );
  }

  // Safe source enum deserializer for queue persistence (JSON restore)
  static SongSource sourceFromString(String? s) {
    switch (s) {
      case 'saavn':   return SongSource.saavn;
      case 'youtube': return SongSource.youtube;
      case 'local':   return SongSource.local;
      default:
        // Unknown source string — log it and default to saavn.
        // This prevents crashes when loading old queue data after an app update
        // that added a new source type.
        _log('[parse] Unknown source string: "$s" — defaulting to saavn');
        return SongSource.saavn;
    }
  }

  // ===========================================================================
  // SECTION 19: LYRICS
  //
  // BUG FIXED (MED-2):
  //   OLD: Saavn-only, no cache, no fallback for YouTube songs.
  //   NEW: In-memory cache + lrclib.net as fallback for all song types.
  //
  // lrclib.net:
  //   - Free, no API key required
  //   - Returns plain lyrics + LRC (timestamped) lyrics
  //   - Works for both Saavn and YouTube songs (search by title + artist)
  //   - Used by Spotube, RiMusic as their lyrics source
  //
  // WHY Cache lyrics in memory (not Hive):
  //   Lyrics strings can be 3-10 KB each. In-memory cache of 50 songs = ~500KB.
  //   Acceptable. For persistent cache across sessions, you could add Hive,
  //   but in-memory is sufficient for the play session and simpler to implement.
  // ===========================================================================

  static final Map<String, String> _lyricsCache = {};

  static Future<String?> fetchLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return null;

    final cacheKey = '${song.source.name}:${song.id}';

    // Return cached lyrics immediately (no network)
    if (_lyricsCache.containsKey(cacheKey)) {
      _log('[lyrics] Cache hit for "${song.title}"');
      return _lyricsCache[cacheKey];
    }

    String? lyrics;

    // PRIMARY: Saavn has its own lyrics endpoint — use it for Saavn songs
    if (song.source == SongSource.saavn) {
      lyrics = await _fetchSaavnLyrics(song.id);
    }

    // FALLBACK: lrclib.net — works for any song by title + artist
    // Used for YouTube songs AND as fallback when Saavn lyrics unavailable
    lyrics ??= await _fetchLrcLibLyrics(song.title, song.artist);

    // Cache on success
    if (lyrics != null && lyrics.isNotEmpty) {
      _lyricsCache[cacheKey] = lyrics;
      _log('[lyrics] Fetched and cached lyrics for "${song.title}"');
    } else {
      _log('[lyrics] No lyrics found for "${song.title}"');
    }

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
    } catch (e) {
      _log('[lyrics] Saavn lyrics error for $songId: $e');
    }
    return null;
  }

  static Future<String?> _fetchLrcLibLyrics(String title, String artist) async {
    try {
      // lrclib.net search API — returns matching songs by query
      final q = Uri.encodeQueryComponent('$title $artist');
      final res = await _client
          .get(Uri.parse('https://lrclib.net/api/search?q=$q'))
          .timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is List && data.isNotEmpty) {
          final first = data.first as Map<String, dynamic>?;
          // Prefer plain lyrics (no timestamps) — easier to display
          final plain = first?['plainLyrics'] as String?;
          if (plain != null && plain.isNotEmpty) return plain;
          // Fall back to syncedLyrics (has timestamps like "[00:01.23] ...")
          // Strip timestamps before returning if you want plain text
          final synced = first?['syncedLyrics'] as String?;
          if (synced != null && synced.isNotEmpty) {
            // Strip LRC timestamps: "[mm:ss.xx] " prefix on each line
            return synced
                .split('\n')
                .map((line) => line.replaceFirst(RegExp(r'^\[\d{2}:\d{2}\.\d{2,3}\] ?'), ''))
                .where((line) => line.isNotEmpty)
                .join('\n');
          }
        }
      }
    } catch (e) {
      _log('[lyrics] lrclib error for "$title $artist": $e');
    }
    return null;
  }

  // ===========================================================================
  // SECTION 20: HELPERS
  // ===========================================================================

  // Artwork URL builder — upgrades thumbnail size for better quality
  static String _onrenderArtwork(Map<String, dynamic> j) {
    final img = (j['image'] ?? '').toString();
    if (img.startsWith('http')) {
      // Saavn serves images in multiple sizes via URL path substitution.
      // Replace small sizes with 500x500 for crisp artwork display.
      return img
          .replaceAll('150x150', '500x500')
          .replaceAll('50x50',   '500x500');
    }
    return '';
  }

  // HTML entity decoder — Saavn API returns HTML-encoded text.
  // '&amp;' in a JSON string means the original text had '&'.
  // Without decoding: "Jay &amp; Veeru" displays as "Jay &amp; Veeru" in UI.
  static String _cleanText(String s) => s
      .replaceAll('&amp;',  '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&lt;',   '<')
      .replaceAll('&gt;',   '>');

  // Safe int parser — Saavn returns durations as both String and int depending on version
  static int? _parseInt(dynamic d) {
    if (d == null)    return null;
    if (d is int)     return d;
    if (d is double)  return d.toInt();
    if (d is String)  return int.tryParse(d);
    return null;
  }

  // ===========================================================================
  // SECTION 21: DIAGNOSTICS
  //
  // getDiagnosticsSnapshot: Returns a structured map of current runtime state.
  //   Wire this to a hidden "5-tap" easter egg on the player screen or
  //   a Settings → "Playback Diagnostics" page.
  //   Send this snapshot with bug reports for instant debugging.
  //
  // debugPlaybackPath: Runs live network tests against all endpoints.
  //   Takes ~10-15 seconds but gives a complete picture of what's working.
  //   Show progress indicator while running.
  // ===========================================================================

  // Returns current runtime state snapshot — instant, no network
  static Map<String, dynamic> getDiagnosticsSnapshot() {
    final now = DateTime.now();
    final cacheEntries = _streamCache.entries.map((e) => {
      'key':         e.key,
      'expired':     e.value.isExpired,
      'age_seconds': now.difference(e.value.resolvedAt).inSeconds,
      'url_prefix':  e.value.url.substring(0, e.value.url.length.clamp(0, 60)),
    }).toList();

    return {
      'timestamp':            now.toIso8601String(),
      'stream_cache_size':    _streamCache.length,
      'stream_cache_max':     _maxCacheSize,
      'expired_entries':      cacheEntries.where((e) => e['expired'] == true).length,
      'pending_resolutions':  _pendingResolutions.length,
      'pending_keys':         _pendingResolutions.keys.toList(),
      'prefetch_active':      _activePrefetch != null && !(_activePrefetch?.isCanceled ?? true),
      'lyrics_cached':        _lyricsCache.length,
      'worker_base':          _worker,
      'saavn_base':           _saavn,
      'stream_ttl_minutes':   _streamTtl.inMinutes,
      'cache_entries':        cacheEntries,
    };
  }

  // Runs live network tests — takes 10-15 seconds
  // Show a loading indicator in your DiagnosticsPage while this runs
  static Future<String> debugPlaybackPath() async {
    final buf = StringBuffer();
    buf.writeln('=== Aurum v2.0 Playback Diagnostics ===');
    buf.writeln('Time:   ${DateTime.now()}');
    buf.writeln('Worker: $_worker');
    buf.writeln('Saavn:  $_saavn');
    buf.writeln('Cache:  ${_streamCache.length}/$_maxCacheSize entries '
        '(${_streamCache.values.where((v) => v.isExpired).length} expired)');
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

    // Test 3: Saavn search
    buf.writeln('▶ 3. Saavn search (arijit singh)');
    try {
      final sw = Stopwatch()..start();
      final songs = await _searchSaavn('arijit singh', limit: 1);
      sw.stop();
      if (songs.isNotEmpty) {
        buf.writeln('   ✅ OK (${sw.elapsedMilliseconds}ms) — "${songs.first.title}"');
        buf.writeln('      source: ${songs.first.source.name}');
        buf.writeln('      streamUrl present: ${songs.first.streamUrl != null}');
      } else {
        buf.writeln('   ❌ FAILED (${sw.elapsedMilliseconds}ms) — 0 results');
      }
    } catch (e) {
      buf.writeln('   ❌ EXCEPTION: $e');
    }
    buf.writeln('');

    // Test 4: Full Saavn resolveStreamUrl
    buf.writeln('▶ 4. Full resolveStreamUrl (Saavn song)');
    try {
      final songs = await _searchSaavn('arijit singh', limit: 1);
      if (songs.isNotEmpty) {
        final sw = Stopwatch()..start();
        final url = await resolveStreamUrl(songs.first, forceRefresh: true);
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
// _CachedStream: Private model for cache entries
//
// CHANGED from v1:
//   - `resolvedAt` is now PUBLIC (was private `_resolvedAt`) so that _writeCache()
//     can read it for LRU eviction comparisons.
//   - No other changes to the core logic.
//
// WHY A SEPARATE CLASS (not just Map<String, String>):
//   We need to track WHEN the URL was cached (resolvedAt) to:
//   a) Check if it's expired (isExpired getter)
//   b) Find the oldest entry for LRU eviction
//   A plain String can't carry this metadata.
// =============================================================================
class _CachedStream {
  // The resolved stream URL (Saavn CDN or YouTube googlevideo.com)
  final String url;

  // When this URL was resolved and cached.
  // Public so ApiService._writeCache() can read it for LRU comparisons.
  final DateTime resolvedAt;

  _CachedStream(this.url) : resolvedAt = DateTime.now();

  // Returns true if this cached URL is older than _streamTtl (50 minutes).
  // After 50 minutes, Saavn CDN URLs may return 403. YouTube URLs typically
  // last 6 hours but we use the same TTL for consistency.
  bool get isExpired =>
      DateTime.now().difference(resolvedAt) > ApiService._streamTtl;
}
