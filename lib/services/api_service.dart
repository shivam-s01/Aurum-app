// =============================================================================
// FILE: lib/services/api_service.dart
// PROJECT: Astra Music
// VERSION: 5.2.0 — Worker-only playback chain (see _ytStreamById), search
// speed fixes, dead prewarm-endpoint fix.
//
// CORRECTION (2026-08-13): the v5.1.0 changelog previously kept here
// ("EXPLODE FIRST — youtube_explode_dart raced against Worker", "BLAST RACE
// — 7 fallback endpoints", "INSTANCE HEALTH — Piped/Invidious tracking")
// described an EARLIER iteration of this file and directly contradicted
// this same file's own v5.1.0 title ("Explode removed from playback
// chain") and _ytStreamById's own in-code comment ("Piped/Invidious
// fallbacks removed entirely (2026-07-06)"). Kept as stale doc drift this
// long, it actively misleads anyone reading this header before the actual
// code below. Current, verified-against-code state:
//
//   ✅ WORKER-ONLY PLAYBACK — _ytStreamById resolves purely via the
//                        Cloudflare Worker (/api/yt-proxy primary,
//                        /api/yt-stream secondary bonus path, each
//                        confirmed with a real device-side ranged GET,
//                        not just a Worker-side check). No
//                        youtube_explode_dart, no Piped, no Invidious in
//                        this path — those were removed for reliability
//                        (public volunteer instances with no uptime
//                        guarantee), not because they were slow.
//
//   ✅ PREFETCH          — prefetchQueue(List<Song>) resolves next 5 songs
//                        in background while current song plays, staggered
//                        so the network isn't hammered all at once.
//                        When user taps → URL already in _streamCache →
//                        near-instant play instead of a cold resolve.
//
//   ✅ PREWARM FIX (2026-08-13) — prewarmYtStream() used to call a
//                        `/api/prewarm` Worker route that never existed
//                        (confirmed against worker.js — no handler, no KV
//                        binding), so every call silently 404'd and
//                        re-fired on every re-scroll past the same song —
//                        pure wasted network traffic for zero benefit. Now
//                        calls resolveStreamUrl() directly so a song
//                        visible on screen actually gets cached
//                        client-side ahead of the tap, via the cache that
//                        actually exists.
//
//   ✅ SEARCH SPEED FIX (2026-08-13) — related-expansion's YT and Saavn
//                        futures were awaited in two separate sequential
//                        Future.wait calls (up to 5s+5s=10s); now raced
//                        together in one Future.wait (max ~5s). Typo-variant
//                        retry timeout tightened 5s→3s. See search().
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io' show HttpClient;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:html/parser.dart' as html_parser;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:async/async.dart';
import 'package:just_audio/just_audio.dart';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../models/artist.dart';
import '../models/lyrics.dart';
import 'browse_service.dart' show BrowseAlbum, BrowseArtist;
import '../utils/constants.dart';
import 'audio_prefs.dart';
import 'recommendation_engine.dart';
import 'music_source.dart';
import 'native_related_videos.dart' show NativeRelatedVideos, YtRelatedVideo;
import 'lightweight_stream_cache.dart';
import 'lyrics_cache.dart';

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

// Lightweight, SEPARATE health tracker for the YT Music search route
// specifically (kept apart from _WorkerHealth above, which only governs
// stream/playback resolution) — a worker that's down for search doesn't
// necessarily mean playback is down too, and vice versa. Short cooldowns
// only (never long backoff like playback's tracker) since search health
// can flap quickly and a stale "dead" mark would wrongly suppress YT
// results for longer than the outage actually lasted.
class _YtSearchHealth {
  static DateTime? _skipUntil;
  static bool get isLikelyDown {
    final until = _skipUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) { _skipUntil = null; return false; }
    return true;
  }
  static void markFailure() {
    _skipUntil = DateTime.now().add(const Duration(seconds: 20));
  }
  static void markSuccess() { _skipUntil = null; }
}


// ══════════════════════════════════════════════════════════════════════════
// YouTube playlist import — typed failure reasons
// ══════════════════════════════════════════════════════════════════════════
//
// fetchYtPlaylistSongs used to collapse every failure mode (bad link, a
// YouTube Mix with no fixed track list, network/parse failure, a playlist
// that's genuinely empty) into a single `[]` return, so the import dialog
// could only ever show one generic "Couldn't import" message no matter
// what actually went wrong. That made the real problem (e.g. pasting a
// Mix link, which can never work) indistinguishable from a transient
// network hiccup (which just needs a retry). This throws instead, so the
// UI layer can map each reason to accurate, actionable copy.
enum YtPlaylistImportError {
  /// The pasted text isn't a recognizable playlist URL or ID — no `list=`
  /// query param, and not a bare ID either.
  invalidLink,

  /// The link resolved to a YouTube Mix / radio / watch-history pseudo-
  /// playlist (IDs starting RD/UL/LM). These are generated on-demand by
  /// YouTube and have no fixed, enumerable track list — there is nothing
  /// to import, this isn't a bug.
  isMix,

  /// The playlist ID looked valid but YouTube returned zero videos —
  /// either it's private/deleted, or it's a real playlist with 0 songs.
  empty,

  /// The playlist ID looked valid but the fetch itself failed (parsing
  /// error, YouTube-side hiccup, unexpected response shape) after a
  /// retry already happened.
  notFound,

  /// Request timed out both attempts — almost always the device's
  /// connection, not YouTube.
  network,
}

class YtPlaylistImportException implements Exception {
  final YtPlaylistImportError reason;
  const YtPlaylistImportException(this.reason);
  @override
  String toString() => 'YtPlaylistImportException($reason)';
}

// Tiny value holder for a single "Playlists For You" sub-category card
// definition — an id (used for the card's key/history tracking), a
// display title, and the actual search query fired at both sources.
class _MoodSubQuery {
  final String id;
  final String title;
  final String query;
  const _MoodSubQuery(this.id, this.title, this.query);
}

// Lightweight card for the home screen's "Playlists For You" row.
// REDESIGNED (2026-08-14 — "faltu ka kya karna hai, ekdam simple
// playlist jaisa"): this used to wrap a YT Music PLAYLIST id — tapping
// a card meant a separate network round-trip (fetchYtPlaylistSongs) to
// "import" that playlist before anything could play, and that import
// step was the actual thing failing (playlist ids resolving to nothing,
// "Couldn't import that playlist"). Now each card just wraps its own
// ALREADY-FETCHED list of real Song objects (from a category search —
// see fetchYtMusicHomePlaylists below), so there's nothing left to
// import: tapping a card opens MixScreen directly with `songs` already
// in hand, ready to play immediately, exactly like tapping any other
// mix/playlist row elsewhere in this app.
class YtHomePlaylistCard {
  final String id;
  final String title;
  final String subtitle;
  final String artworkUrl;
  final List<Song> songs;
  const YtHomePlaylistCard({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    required this.songs,
  });
}

// ═══════════════════════════════════════════════════════════════════
// MOOD CHIPS for the "Playlists For You" row. Each id maps to a plain
// YT Music search query (see _kMoodSearchQuery below) — no Worker-side
// mood table to keep in sync anymore.
// ═══════════════════════════════════════════════════════════════════
class HomeMoodChip {
  final String id;
  final String label;
  const HomeMoodChip(this.id, this.label);
}

const List<HomeMoodChip> kHomeMoodChips = [
  // India-market chips first — biggest draw for this app's actual
  // audience, so they're explicit chips rather than left to chance.
  HomeMoodChip('bollywood', 'Bollywood'),
  HomeMoodChip('nineties', '90s'),
  HomeMoodChip('trendingIndia', 'Trending'),
  HomeMoodChip('podcasts', 'Podcasts'),
  HomeMoodChip('relax', 'Relax'),
  HomeMoodChip('workout', 'Workout'),
  HomeMoodChip('energize', 'Energize'),
  HomeMoodChip('romantic', 'Romantic'),
  HomeMoodChip('party', 'Party'),
  HomeMoodChip('focus', 'Focus'),
  HomeMoodChip('sad', 'Sad'),
];

// ═══════════════════════════════════════════════════════════════════
// NO-REPEAT HISTORY for the "Playlists For You" row — persists the
// song ids already shown to the user (across app sessions, not just
// in-memory), scoped per-mood so switching chips can't exhaust a
// completely different mood's history. Capped at 60: a single category
// search returns up to ~40-50 songs per card build, so this needs more
// headroom than the old playlist-id version (which only ever tracked a
// handful of playlist ids at a time) to actually cover a few refresh
// cycles' worth of individual songs.
// ═══════════════════════════════════════════════════════════════════
class HomePlaylistHistory {
  static const _keyPrefix = 'home_playlists_for_you_shown_song_ids';
  static const _cap = 60;

  static String _keyFor(String? mood) =>
      '$_keyPrefix${(mood == null || mood.isEmpty) ? '' : '_$mood'}';

  static Future<List<String>> getShownIds(String? mood) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_keyFor(mood)) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> recordShown(String? mood, List<String> songIds) async {
    if (songIds.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _keyFor(mood);
      final existing = prefs.getStringList(key) ?? const [];
      final merged = <String>[];
      final seen = <String>{};
      for (final id in [...songIds, ...existing]) {
        if (seen.contains(id)) continue;
        seen.add(id);
        merged.add(id);
        if (merged.length >= _cap) break;
      }
      await prefs.setStringList(key, merged);
    } catch (_) {
      // Best-effort — a failed write just means this refresh cycle
      // won't benefit from no-repeat, not worth surfacing to the user.
    }
  }
}

// Lightweight artist-card metadata for the home screen's artist strip —
// sourced from the Worker's /api/yt-music-home-artists route (YT Music's
// own FEmusic_home shelves). channelId is YouTube's own stable per-artist
// identifier (format "UC..."), used as ArtistSimple.id below — this is
// what YT Music itself treats as the artist's canonical key, so it can
// never collide across shelves, re-shuffles, or app sessions the way a
// name-only key could.
class YtHomeArtist {
  final String channelId;
  final String name;
  final String imageUrl;
  const YtHomeArtist({
    required this.channelId,
    required this.name,
    required this.imageUrl,
  });
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

  // FIX ("search 1 min tak wait karna padta hai, Saavn results late/missing
  // aate hain" — production bug): _client used to be a bare http.Client()
  // with zero connection tuning underneath. Two compounding problems came
  // from that:
  //   1. _saavnPrimary (jiosavan-ecc1.onrender.com) is a documented Render
  //      free-tier host that cold-sleeps after inactivity (see the FIX
  //      comment above _saavnPrimary's definition — confirmed hanging 20s+
  //      when asleep). It's hit on page 1 of EVERY search.
  //   2. A single search fires _saavnNodeHosts + 3 named hosts +
  //      _saavnNoPaginationFlaskHosts, each × pagesNeeded (up to 10) pages,
  //      ALL in parallel, THEN _withRetry (SaavnSource) can fire that
  //      entire stampede a SECOND time if the first attempt came up empty,
  //      PLUS lyric-variant and typo-variant queries each repeat the whole
  //      thing again. Every one of those requests shares this one
  //      unconfigured http.Client(). Dart's `.timeout()` on a request only
  //      stops the code from WAITING on it — it doesn't force the
  //      underlying socket to close — so a slow/sleeping host's connection
  //      can keep occupying a pool slot well past its nominal 8s timeout,
  //      starving later requests in the same search of an available
  //      connection and compounding toward exactly the ~1 minute reported.
  // Fix: back _client with an explicit HttpClient that gives up on
  // establishing a TCP connection after 5s (separate from and tighter than
  // the request-level 8s .timeout() used everywhere below — this cuts off
  // a dead/sleeping host at the SOCKET level, before it can occupy a pool
  // slot for the full request lifetime) and caps idle-connection reuse so
  // a stalled connection to a sleeping Render host doesn't get silently
  // reused for the next request.
  static final http.Client _client = IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 3)
      ..maxConnectionsPerHost = 6,
  );
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

  // FIX ("naya mirror jiosaavnapi-il2o.onrender.com use kar sakte hain?"):
  // added as an extra resilience mirror after live testing (2026-08) —
  // response shape matches the other Flask-family hosts fine (same
  // /result/ list-of-song-objects format tryResultRoute already parses).
  // BUT this specific host's own `page` query param is a no-op: page=1
  // and page=2 returned byte-identical results in testing, unlike
  // _saavnPrimary/_saavnSecondary/_saavn below which genuinely paginate.
  // Kept in its own list (not merged into _saavnFlaskHosts) so
  // _searchSaavn can special-case it to always request page=1 only,
  // regardless of pagesNeeded — sending it page=2/3 would just be a
  // wasted duplicate network call for zero extra depth, since it would
  // silently return the exact same page-1 data every time.
  static const List<String> _saavnNoPaginationFlaskHosts = [
    'https://jiosaavnapi-il2o.onrender.com',
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
  // NOTE: variable name is legacy — this is the Cloudflare Worker base URL,
  // used for BOTH Saavn endpoints AND the YT Music worker endpoint
  // (/api/yt-music-search). Search's YT path hits the same worker here,
  // just a different route — it is NOT Saavn data.
  static const String _saavn          = 'https://aurum-worker.shivamsharma962122.workers.dev';
  static const String _worker         = AppConstants.apiBase;

  // ✅ LIGHTWEIGHT CACHE (v1.0): Replaces unbounded Map
  // Old: 150 URLs max (but often 500KB+), slow cleanup
  // New: 30 URLs max, auto-cleanup, ~3KB memory
  static final LightweightStreamCache _streamCache = LightweightStreamCache();
  static const Duration _streamTtl   = Duration(minutes: 50);
  static const int      _maxCacheSize = 30; // Lightweight!

  // Search cache
  static final Map<String, _CachedSearch> _searchCache = {};
  static const Duration _searchTtl     = Duration(minutes: 5); // FIX: cache jaldi expire ho taaki fresh Saavn results milein
  static const int      _maxSearchCache = 100;

  // LIGHTWEIGHT FIX ("ekdam lightweight aur fast, hang na ho"): quickSearch
  // (live-typing search) had no cache at all — every keystroke that landed
  // on a query already seen this session (very common: type → backspace →
  // retype same partial word, or re-focus the search bar with the same
  // text) refired the full Saavn host race + scoring pipeline from zero.
  // A short TTL (much shorter than the full search() cache above) is
  // deliberate: live results are meant to feel responsive to fresh catalog
  // data, this only kills the redundant network round-trip for the exact
  // same partial query typed again within a few seconds — not a general
  // long-lived cache like full search's.
  static final Map<String, _CachedQuickSearch> _quickSearchCache = {};
  static const Duration _quickSearchTtl      = Duration(seconds: 45);
  static const int      _maxQuickSearchCache = 60;

  static void _writeQuickSearchCache(String key, List<Song> results) {
    if (_quickSearchCache.length >= _maxQuickSearchCache) {
      final expiredKeys = _quickSearchCache.entries
          .where((e) => e.value.isExpired).map((e) => e.key).toList();
      for (final k in expiredKeys) _quickSearchCache.remove(k);
      if (_quickSearchCache.length >= _maxQuickSearchCache) {
        final oldest = _quickSearchCache.entries.reduce(
          (a, b) => a.value.cachedAt.isBefore(b.value.cachedAt) ? a : b,
        );
        _quickSearchCache.remove(oldest.key);
      }
    }
    _quickSearchCache[key] = _CachedQuickSearch(results);
  }

  // ===========================================================================
  // SEARCH-HISTORY LEARNING ("search history se seekhe — jo pehle click/play
  // kiya wahi type-ahead me priority mile"): real personalization, not just a
  // list of past query strings. Every time a person actually taps a search
  // result, we remember which SONG they picked FOR that normalized query.
  // Next time the same (or a close variant of the same) query comes back —
  // this session or a future one, since it's persisted — that exact song
  // gets a ranking boost so it surfaces at/near the top immediately instead
  // of the engine re-deriving "best match" from scratch every time. This is
  // the same behavior Spotify/YouTube Music show: search "arjit" once, tap
  // the right Arijit Singh track, and it's the first thing that comes back
  // next time you type "arjit" again.
  //
  // Kept intentionally small and cheap: an in-memory map for instant same-
  // session reads (no async needed on the scoring hot path), lazily loaded
  // from and periodically flushed to SharedPreferences for persistence
  // across app restarts. Bounded (_maxSelectionQueries) with LRU-ish
  // eviction so this can never grow unbounded on a heavy user's device.
  // ===========================================================================
  static final Map<String, List<String>> _selectionHistory = {}; // normQuery -> [songId, ...recency order, most-recent first]
  static bool _selectionHistoryLoaded = false;
  static const String _selectionPrefsKey = 'aurum_search_selection_learning';
  static const int _maxSelectionQueries = 200; // distinct queries remembered
  static const int _maxSongsPerQuery = 3;      // recent picks kept per query

  static Future<void>? _selectionHistoryLoadFuture;
  static Future<void> _ensureSelectionHistoryLoaded() {
    // BUG FIX (found on recheck): this used to set _selectionHistoryLoaded
    // = true SYNCHRONOUSLY before the actual disk read finished, so (1) a
    // boost lookup that ran during the load window silently saw "loaded"
    // with an empty map and returned 0 instead of genuinely waiting, and
    // (2) worse — if recordSearchSelection wrote a fresh selection into
    // _selectionHistory WHILE the disk load was still in-flight, the load
    // finishing afterward would blindly assign over that key with stale
    // disk data, silently losing the fresh tap that just happened. Now
    // every caller shares and awaits the SAME in-flight Future (so the
    // flag only flips true once the read is genuinely done), and the merge
    // step skips any key that already picked up an in-memory write during
    // the load instead of unconditionally overwriting it.
    if (_selectionHistoryLoaded) return Future.value();
    return _selectionHistoryLoadFuture ??= () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_selectionPrefsKey);
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((key, value) {
              // Don't clobber a key that already got a real-time write
              // (e.g. a tap recorded) while this disk read was in flight.
              if (_selectionHistory.containsKey(key)) return;
              if (key is String && value is List) {
                _selectionHistory[key] = value.whereType<String>().toList();
              }
            });
          }
        }
      } catch (e) {
        _log('[selectionHistory] load failed: $e');
      } finally {
        _selectionHistoryLoaded = true;
      }
    }();
  }

  static Timer? _selectionPersistDebounce;
  static void _persistSelectionHistorySoon() {
    // Debounced write — a person tapping several results in a row (browsing
    // search results) shouldn't hit disk on every single tap.
    _selectionPersistDebounce?.cancel();
    _selectionPersistDebounce = Timer(const Duration(seconds: 2), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_selectionPrefsKey, jsonEncode(_selectionHistory));
      } catch (e) {
        _log('[selectionHistory] persist failed: $e');
      }
    });
  }

  /// Call this the moment a person taps/plays a search result. Records that
  /// [song] was the pick for [query], so future searches for the same (or a
  /// close variant of the same) query rank it higher. Fire-and-forget by
  /// design — never awaited by the UI, never blocks or delays playback.
  static void recordSearchSelection(String query, Song song) {
    final key = _normalise(query);
    // BUG FIX (found on recheck): no minimum-length guard meant a tap on a
    // result while only 1-2 characters had been typed (quickSearch fires
    // from the very first keystroke) could get recorded as a learned
    // "exact match" for that tiny query — later colliding with a totally
    // unrelated short search and wrongly boosting an unrelated song.
    // Require at least 3 normalized characters before learning from it.
    if (key.length < 3) return;
    () async {
      await _ensureSelectionHistoryLoaded();
      final list = _selectionHistory.putIfAbsent(key, () => <String>[]);
      list.remove(song.id); // move to front if already present
      list.insert(0, song.id);
      if (list.length > _maxSongsPerQuery) list.removeRange(_maxSongsPerQuery, list.length);
      // Bound total distinct queries remembered — drop the query that's been
      // touched least recently (map insertion order in Dart is stable, so
      // the first key is the oldest-untouched one once we re-insert on hit).
      _selectionHistory.remove(key);
      _selectionHistory[key] = list;
      if (_selectionHistory.length > _maxSelectionQueries) {
        _selectionHistory.remove(_selectionHistory.keys.first);
      }
      _persistSelectionHistorySoon();
    }();
  }

  /// Returns a ranking boost for [song] against [query] based on past
  /// selection history — a strong boost if this exact song was picked for
  /// this exact query before, a smaller boost if it was picked for a
  /// closely-related (prefix) query. Synchronous and cheap: reads only the
  /// in-memory map, so it's safe to call from inside the scoring hot path.
  /// Returns 0 if history hasn't loaded yet or there's no relevant match —
  /// never blocks, never throws.
  static double _selectionHistoryBoost(String query, String songId) {
    if (!_selectionHistoryLoaded || _selectionHistory.isEmpty) return 0;
    final key = _normalise(query);
    final exact = _selectionHistory[key];
    if (exact != null) {
      final idx = exact.indexOf(songId);
      if (idx == 0) return 45; // most recent pick for this exact query
      if (idx > 0)  return 25; // picked before, just not most recently
    }
    // BUG FIX (found on recheck): this prefix check originally had NO
    // minimum-length floor. A single past search on a short/generic query
    // (even something as short as "a" or "ar") would then silently boost
    // that one song for almost EVERY future query starting with those
    // letters — real ranking pollution, and a serious bug for a paid app
    // where "smart" search needs to actually earn trust. Now requires
    // BOTH keys to be at least 4 normalized characters (short queries
    // carry too little signal to safely generalize from) AND the shorter
    // key must be at least 70% the length of the longer one (so a stray
    // 2-letter overlap on a long stored query like "arijit singh" can't
    // trigger the boost — the overlap has to be substantial, not just a
    // couple of matching letters).
    if (key.length >= 4) {
      for (final entry in _selectionHistory.entries) {
        if (entry.key == key) continue;
        if (entry.key.length < 4) continue;
        final shorter = key.length < entry.key.length ? key : entry.key;
        final longer  = key.length < entry.key.length ? entry.key : key;
        if (!longer.startsWith(shorter)) continue;
        if (shorter.length / longer.length < 0.7) continue;
        if (entry.value.isNotEmpty && entry.value.first == songId) return 15;
      }
    }
    return 0;
  }

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
    _quickSearchCache.clear();
    LyricsCache.clear();
    _activePrefetch?.cancel();
    _activePrefetch = null;
    _selectionPersistDebounce?.cancel();
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
    _PoolEntry('best bollywood playlists hits',                  'Fan Favorites'),
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
  static Future<List<Song>> _searchSaavnDeep(String query, {int limit = 80}) async {
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
    final startPage = 1 + math.Random().nextInt(4); // 1..4
    final pages = List.generate(3, (i) => startPage + i); // 3 pages
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

  // Per-section song target for the YouTube-only home feed. Every home
  // section (time-mood, "Made for You" artist, genre mix, language,
  // pool pick) now goes through this single path — Saavn is kept in the
  // codebase (SaavnSource/_searchSaavnDeep/etc. all still work exactly as
  // before) but is no longer called from anywhere in the home-feed
  // pipeline, so it's a clean re-enable (flip the call sites back) rather
  // than a rewrite if it's ever needed again.
  static const int _kHomeSectionTarget = 100;

  static Future<SongSection?> _saavnSectionV4(String query, String label) async {
    // YOUTUBE-ONLY HOME FEED: this used to be a 50/50 Saavn+YouTube merge.
    // Saavn is now fully backed out of the home-feed pipeline (kept intact
    // elsewhere in the app — search, playlists, charts endpoints are all
    // untouched) so every home section is pure YouTube, sourced the same
    // way _ytSectionV1's English rows already prove out: several query
    // variants fired in parallel (widens the raw pool well past what one
    // query alone returns) PLUS a deep multi-page explode search for extra
    // volume, then merged/deduped/quality-filtered down to a genuine
    // 100-song shelf. Name kept as _saavnSectionV4 so every existing call
    // site (queryList.map, fetchHome, fetchHomeStreaming) needs zero
    // changes elsewhere.
    final variants = <String>{
      query,
      '$query audio',
      '$query official',
      '$query hd',
      '$query hits',
    };
    final variantResults = await Future.wait(
      variants.map((q) => _searchYt(q, limit: 60)),
    );
    // Deep multi-page pass (youtube_explode_dart, walks up to 6 pages) on
    // the bare query for extra raw volume beyond what the worker/direct
    // single-page search above returns — this is what makes a genuine
    // 100-song post-filter shelf realistic instead of hoping 5 queries'
    // worth of ~60-limit calls happen to clear the bar.
    final deepVideos = await _searchYtPaged(query, 100).catchError((_) => <Video>[]);
    final deepSongs = deepVideos.map(_songFromYtVideo).toList();

    final rawYt = <Song>[];
    final seenRawIds = <String>{};
    for (final list in [...variantResults, deepSongs]) {
      for (final s in list) {
        if (s.id.isNotEmpty && seenRawIds.add(s.id)) rawYt.add(s);
      }
    }
    if (rawYt.isEmpty) return null;

    final seenIds    = <String>{};
    final seenTitles = <String>{};
    // Same smart-dedup pass _ytSectionV1/RecommendationEngine already use
    // elsewhere — catches reuploads ("8K...", "With LYRICS...") that a
    // plain exact-title check would let through as if they were different
    // songs, so the 100-slot cap isn't quietly wasted on duplicates.
    final seenRawTitles = <String>[];
    final merged = <Song>[];

    bool tryAdd(Song s) {
      if (merged.length >= _kHomeSectionTarget) return false;
      if (!seenIds.add(s.id)) return false;
      if (RecommendationEngine.isInherentVariant(s.title)) return false;
      if (RecommendationEngine.isLowQualityUpload(s.title)) return false;
      if (!RecommendationEngine.isPremiumQuality(s)) return false;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) return false;
      for (final seenRaw in seenRawTitles) {
        if (RecommendationEngine.isSameSongSmart(s.title, seenRaw)) return false;
      }
      seenRawTitles.add(s.title);
      merged.add(s);
      return true;
    }

    for (final s in rawYt) {
      if (merged.length >= _kHomeSectionTarget) break;
      tryAdd(s);
    }

    if (merged.isEmpty) return null;
    return SongSection(title: label, songs: merged.take(_kHomeSectionTarget).toList());
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

    // TRIMMED HOME FEED (2026-08-30): previously this built out 15-19
    // total sections (time-mood + up to 4 personal artists + up to 3
    // genres + 3 English + up to 3 recently-played + up to 8 random pool
    // picks). Combined with the one-shot reveal in home_screen.dart (which
    // now waits for the ENTIRE batch before painting anything), that many
    // sections meant a long wait before the user saw anything at all —
    // each section itself already fans out to ~100 songs via 5 query
    // variants + a deep paged search (see _saavnSectionV4 above), so more
    // sections means more of those expensive fetches stacking up.
    // Now capped at 6-7 sections total: the time-of-day mood row, top 2
    // personal artists (was 4), top 1 genre mix (was up to 3), 1 English
    // row (was 3), top 1 recently-played (was up to 3), and the random
    // pool/cold-start padding below is skipped entirely once this list
    // already has enough sections. Every section still targets up to 100
    // songs each — only the section COUNT dropped, not depth per shelf.
    const int _kMaxHomeSections = 7;
    final queryList = <_SectionQuery>[];
    queryList.add(_SectionQuery(timeMoodQuery, timeMoodLabel, priority: true));
    for (final artist in personalArtists.take(2)) {
      queryList.add(_SectionQuery('$artist best songs', 'Made for You · $artist', priority: true));
    }
    for (final genre in topGenres.take(1)) {
      queryList.add(_SectionQuery(_genreMixQuery(genre), _genreMixLabel(genre), priority: true));
    }
    // ── English/International (direct YouTube search) ──
    // JioSaavn's catalog is weak for English/Western music. Simpler than
    // the earlier iTunes-discovery approach: one search call per section
    // straight to YouTube, no extra per-song lookup — fewer moving parts,
    // fewer failure points, faster.
    // Trimmed to just the single strongest English row instead of 3 — see
    // _kMaxHomeSections note above.
    const englishQueries = [
      ('top english songs 2026', 'Top English Hits'),
    ];
    for (final (q, label) in englishQueries) {
      queryList.add(_SectionQuery(q, label, isEnglish: true));
    }
    final recentOnline = recentlyPlayed
        .where((s) => !s.isLocal && s.source == SongSource.saavn && s.id.isNotEmpty)
        .take(1)
        .toList();
    for (final recent in recentOnline) {
      final cleanId = recent.id.replaceFirst(RegExp(r'^[a-z]+_'), '');
      final lbl = 'Because You Played · ${recent.title.length > 22 ? recent.title.substring(0, 22) + "…" : recent.title}';
      if (!queryList.any((q) => q.label == lbl)) {
        queryList.add(_SectionQuery('__suggestions__$cleanId', lbl, isSuggestion: true, suggestionSongId: cleanId));
      }
    }

    int poolPicks = 0;
    // Only pad with random pool picks if we're still short of
    // _kMaxHomeSections — previously this always added up to 8 more
    // regardless of how many sections already existed.
    for (final entry in shuffledPool) {
      if (queryList.length >= _kMaxHomeSections) break;
      if (poolPicks >= 3) break;
      if (queryList.any((q) => q.label == entry.label)) continue;
      queryList.add(_SectionQuery(entry.query, entry.label));
      poolPicks++;
    }
    // FIX ("cold start pe faltu categories aa rahe hai, important songs
    // nahi aa rahe jaise Spotify"): on a brand-new account (no listening
    // history yet → personalArtists/topGenres/recentOnline all empty),
    // this used to pad the feed from `shuffledPool` (pure random) and
    // then `shuffledPool.reversed` (an arbitrary tail slice) — so which
    // sections a first-time user saw, and in what order, was down to
    // chance. Since onSection() fires as each query resolves and
    // priority queries go out in wave 1, whatever lands in
    // `priorityQueries` here is genuinely what the user sees first. A
    // first-time user has no taste data to personalize from yet, so the
    // one thing home can reliably lead with — same as Spotify/YT Music
    // do for a brand new account — is what's actually popular right
    // now: Trending Now / New Releases / Top Charts, plus a couple of
    // universally-recognized icon artists. Inserted as priority: true so
    // they go out in the very first wave, ahead of the random pool
    // picks above (which stay as later, lower-priority sections instead
    // of being the whole first screen).
    if (personalArtists.isEmpty && topGenres.isEmpty && recentOnline.isEmpty) {
      // Trimmed to the 3 strongest cold-start rows (was 5 + 3 icons + 3
      // extra = up to 11 more) — see _kMaxHomeSections note above. A
      // brand-new account gets: greeting, Trending Now, New Releases,
      // Top Charts, capped by _kMaxHomeSections same as everyone else.
      const coldStartLabels = [
        'Trending Now',
        'New Releases',
        'Top Charts',
      ];
      for (final label in coldStartLabels.reversed) {
        if (queryList.length >= _kMaxHomeSections) break;
        final entry = _pool.firstWhere(
          (e) => e.label == label,
          orElse: () => _PoolEntry('', ''),
        );
        if (entry.label.isEmpty) continue;
        final existingIndex = queryList.indexWhere((q) => q.label == entry.label);
        if (existingIndex != -1) {
          // Already queued as a random (non-priority) pool pick above —
          // upgrade it to priority so it moves into wave 1 instead of
          // waiting behind everything else.
          if (!queryList[existingIndex].priority) {
            queryList[existingIndex] = _SectionQuery(entry.query, entry.label, priority: true);
          }
          continue;
        }
        // Insert right after the time-of-day greeting (index 0), not at
        // the absolute front — that keeps the contextual "Good evening"
        // style opener first, exactly like Spotify still leads with a
        // greeting row even on a brand-new account.
        queryList.insert(1, _SectionQuery(entry.query, entry.label, priority: true));
      }
    }

    // Hard safety cap: whatever path built queryList (returning user,
    // cold-start new account, etc.), never fire more than
    // _kMaxHomeSections network-heavy section fetches. Priority sections
    // (greeting/personalized/genre/cold-start trending) are kept over
    // plain random pool picks since take() below reads in insertion order
    // and priority entries were always inserted/added first.
    final _trimmedQueryList = queryList.length > _kMaxHomeSections
        ? queryList.take(_kMaxHomeSections).toList()
        : queryList;

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
    final priorityQueries = _trimmedQueryList.where((q) => q.priority).toList();
    final restQueries = _trimmedQueryList.where((q) => q.priority == false).toList();

    // FIX (cold-start lag/data spike): priorityQueries used to all fire in
    // one single wave with zero throttling ("there are only ever ~8 of
    // them, well within a phone's comfortable concurrent-connection range"
    // — see the comment above, from the 2026-07-25 fix that only throttled
    // restQueries). In practice ~8 priority queries × ~4-5 HTTP connections
    // each is still 32-40 simultaneous connections firing in the very first
    // instant of every cold start/refresh — on top of whatever the
    // just-hydrated cache is still rendering — which is exactly the
    // "everything jerks/lags and burns a lot of data until fresh titles
    // show up" window. Same root cause the restQueries fix already
    // targeted, just left unpatched on this half.
    //
    // Fix: reuse the exact same small-wave throttle for priorityQueries
    // instead of giving it special "no gate" treatment. Section COUNT is
    // completely unchanged — every query in priorityQueries still runs and
    // still calls onSection exactly as before, just spread across a couple
    // of waves a beat apart instead of one big burst, so sections still
    // reveal progressively (now closer to one/two-by-one, which also reads
    // as smoother) and the phone's radio never has to open dozens of
    // connections in the same instant.
    const waveSize = 3;
    const waveGap = Duration(milliseconds: 200);
    final pending = <Future<void>>[];
    for (var i = 0; i < priorityQueries.length; i += waveSize) {
      if (i > 0) await Future.delayed(waveGap);
      final wave = priorityQueries.skip(i).take(waveSize);
      for (final sq in wave) {
        pending.add(runQuery(sq));
      }
    }

    for (var i = 0; i < restQueries.length; i += waveSize) {
      await Future.delayed(waveGap);
      final wave = restQueries.skip(i).take(waveSize);
      for (final sq in wave) {
        pending.add(runQuery(sq));
      }
    }

    await Future.wait(pending);

    // SAAVN CHARTS — language-wise featured playlists parallel fire
    // Ye search se alag hai: Saavn ke curated Top 50 playlists directly
    // fetch karta hai. fetchHomeStreaming ke baad fire hota hai taaki main
    // feed pehle load ho, charts sections baad mein aayein (same as YT
    // sections).
    // FIX (data usage): trimmed from all 10 languages down to the top 4
    // most broadly-listened Indian charts (see _saavnHomeDefaultLanguages)
    // — was a major contributor to cold-start data spikes/lag. The rest of
    // _saavnLanguages is kept for future per-user personalization.
    await fetchSaavnChartsStreaming(onSection: onSection);
  }

  // ===========================================================================
  // SAAVN FEATURED PLAYLISTS + CHARTS — Direct Saavn catalog access
  // ===========================================================================
  // Saavn ka internal API — featured playlists per language fetch karta hai.
  // Ye search se bilkul alag hai: search query-based hai, ye Saavn ke
  // curated/editorial playlists directly laata hai — "Top 50 Hindi",
  // "Top 50 Punjabi" etc. 100M songs tak pahunchne ka real rasta.
  // ===========================================================================

  static const String _saavnInternalApi = 'https://www.jiosaavn.com/api.php';

  // Language codes Saavn ke internal API ke liye — full catalog kept for
  // reference / future per-user personalization, but only a subset is
  // actually fetched on the home feed (see _saavnHomeDefaultLanguages
  // below) to keep cold-start data usage and load time reasonable.
  static const List<String> _saavnLanguages = [
    'hindi', 'punjabi', 'tamil', 'telugu', 'kannada',
    'malayalam', 'marathi', 'bengali', 'bhojpuri', 'gujarati',
    'english', 'rajasthani', 'odia', 'haryanvi', 'assamese',
  ];

  // FIX (cold-start data usage): fetchSaavnChartsStreaming used to pull
  // charts for all 15 languages above on every cold start/refresh — each
  // one a full Top 50 playlist + artwork, which is the main source of the
  // 4MB+ data spike and lag reported on slower connections. Most Aurum
  // users only care about a handful of these. Default home feed now only
  // fetches the top 4 most broadly-listened Indian charts; the rest of
  // _saavnLanguages stays available for later per-user personalization
  // (e.g. keyed off the user's own listening history/region) without
  // needing another data-model change.
  static const List<String> _saavnHomeDefaultLanguages = [
    'hindi', 'punjabi', 'tamil', 'telugu',
  ];

  // Clean, no-emoji, Spotify/YT-Music-style naming — "Top 50" is exactly
  // how those apps label a language/region chart shelf.
  static const Map<String, String> _languageLabels = {
    'hindi':      'Hindi Top 50',
    'punjabi':    'Punjabi Top 50',
    'tamil':      'Tamil Top 50',
    'telugu':     'Telugu Top 50',
    'kannada':    'Kannada Top 50',
    'malayalam':  'Malayalam Top 50',
    'marathi':    'Marathi Top 50',
    'bengali':    'Bengali Top 50',
    'bhojpuri':   'Bhojpuri Top 50',
    'gujarati':   'Gujarati Top 50',
    'english':    'English Top 50',
    'rajasthani': 'Rajasthani Hits',
    'odia':       'Odia Hits',
    'haryanvi':   'Haryanvi Hits',
    'assamese':   'Assamese Hits',
  };

  /// Saavn ke featured playlists fetch karo ek language ke liye.
  /// Returns list of {id, name, image, songCount} maps.
  static Future<List<Map<String, dynamic>>> fetchSaavnFeaturedPlaylists({
    String language = 'hindi',
    int limit = 10,
  }) async {
    try {
      final url = Uri.parse(_saavnInternalApi).replace(queryParameters: {
        '__call': 'playlist.getFeaturedPlaylists',
        '_format': 'json',
        '_marker': 'false',
        'language': language,
        'offset': '0',
        'size': '$limit',
      });
      final res = await _client.get(url, headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final playlists = data is Map
          ? (data['featuredPlaylists'] ?? data['playlist'] ?? data['data'] ?? [])
          : (data is List ? data : []);
      if (playlists is! List) return [];
      return playlists.whereType<Map<String, dynamic>>().map((p) => {
        'id': (p['listid'] ?? p['id'] ?? '').toString(),
        'name': _cleanText((p['listname'] ?? p['name'] ?? p['title'] ?? '').toString()),
        'image': _cleanText((p['image'] ?? '').toString()),
        'songCount': int.tryParse((p['numsongs'] ?? p['song_count'] ?? p['songCount'] ?? '0').toString()) ?? 0,
        'language': language,
      }).where((p) => p['id']!.toString().isNotEmpty).toList();
    } catch (e) {
      _log('[fetchSaavnFeaturedPlaylists] $language error: $e');
      return [];
    }
  }

  /// Saavn playlist ke songs fetch karo by playlist ID.
  /// Node API: /api/playlists?id=ID&limit=N
  static Future<List<Song>> fetchSaavnPlaylistById(String playlistId, {int limit = 50}) async {
    if (playlistId.isEmpty) return [];
    try {
      final path = '/api/playlists?id=${Uri.encodeQueryComponent(playlistId)}&limit=$limit';
      for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
        final body = await _getFromHosts(hosts, path,
            timeout: const Duration(seconds: 10),
            isValid: (b) => b['success'] == true && b['data'] != null);
        if (body == null) continue;
        final data = body['data'];
        if (data is! Map) continue;
        // Songs can be under data.songs or data directly
        final rawSongs = (data['songs'] as List?) ??
            (data['list'] as List?) ??
            (data['data'] as List?) ?? [];
        if (rawSongs.isEmpty) continue;
        final songs = rawSongs
            .whereType<Map>()
            .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
            .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
            .toList();
        if (songs.isNotEmpty) return songs;
      }
      // Fallback: Saavn internal API direct
      return await _fetchSaavnPlaylistInternal(playlistId, limit: limit);
    } catch (e) {
      _log('[fetchSaavnPlaylistById] $playlistId error: $e');
      return [];
    }
  }

  /// Saavn internal API se playlist songs fetch — Node API fail ho toh
  static Future<List<Song>> _fetchSaavnPlaylistInternal(String listId, {int limit = 50}) async {
    try {
      final url = Uri.parse(_saavnInternalApi).replace(queryParameters: {
        '__call': 'playlist.getDetails',
        '_format': 'json',
        '_marker': 'false',
        'listid': listId,
        'limit': '$limit',
      });
      final res = await _client.get(url, headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final rawSongs = (data is Map)
          ? ((data['list'] as List?) ?? (data['songs'] as List?) ?? [])
          : [];
      if (rawSongs is! List || rawSongs.isEmpty) return [];
      return rawSongs
          .whereType<Map>()
          .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
          .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
          .toList();
    } catch (e) {
      _log('[_fetchSaavnPlaylistInternal] $listId error: $e');
      return [];
    }
  }

  /// Home feed ke liye: ek language ke featured playlists fetch karo
  /// aur unke songs ko ek SongSection mein merge karo.
  // YOUTUBE-ONLY REWRITE: this used to be a 3-step Saavn pipeline (featured
  // playlists → top-3 playlist songs → merge). Saavn's featured-playlists
  // and playlist-by-id endpoints (fetchSaavnFeaturedPlaylists,
  // fetchSaavnPlaylistById above) are untouched and still fully working —
  // they're just no longer called from this home-feed path. Same
  // name/signature/label as before so fetchSaavnChartsStreaming (the only
  // caller) needed zero changes. Routes through the same
  // multi-variant + deep-page YouTube pipeline as _saavnSectionV4 for a
  // consistent, genuine 100-song per-language shelf.
  static Future<SongSection?> fetchSaavnLanguageSection(String language) async {
    final label = _languageLabels[language] ?? '$language Hits';
    try {
      return await _saavnSectionV4('$language top songs', label);
    } catch (e) {
      _log('[fetchSaavnLanguageSection] $language error: $e');
      return null;
    }
  }

  /// Saavn ke ALL languages ke charts ek saath stream karo —
  /// home feed mein call karo for maximum Saavn coverage.
  static Future<void> fetchSaavnChartsStreaming({
    required void Function(SongSection section) onSection,
    List<String> languages = _saavnHomeDefaultLanguages,
  }) async {
    // FIX (cold-start data spike / 4MB+ burst): this used a single
    // unthrottled Future.wait firing all 10 languages' chart fetches at
    // once, right after fetchHomeStreaming's own (already-throttled, see
    // its comments above) wave finishes. Each language pulls a full Top 50
    // playlist plus per-song artwork, so 10 of these landing in the same
    // instant is the same "thundering herd" problem the main feed queries
    // were fixed for — just left unpatched here. This is the direct cause
    // of the multi-MB/s spike and stutter right as fresh titles replace
    // the cache: 10 large simultaneous responses, each triggering their
    // own onSection/setState, all in one tight window.
    // Fix: same small-wave throttle pattern already used above — a few
    // languages at a time with a short gap between waves, so charts still
    // stream in progressively but never spike the radio/UI thread at once.
    const waveSize = 3;
    const waveGap = Duration(milliseconds: 200);
    for (var i = 0; i < languages.length; i += waveSize) {
      if (i > 0) await Future.delayed(waveGap);
      final wave = languages.skip(i).take(waveSize);
      await Future.wait(wave.map((lang) async {
        try {
          final section = await fetchSaavnLanguageSection(lang)
              .timeout(const Duration(seconds: 12), onTimeout: () => null);
          if (section != null) onSection(section);
        } catch (_) {}
      }));
    }
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
  static Future<List<Song>> fetchPlaylistSongs(String query, {int limit = 79}) async {
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
  static Future<List<Song>> fetchNewReleaseSongs({int limit = 80}) async {
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
  static Future<String?> resolveDownloadUrl(Song song, {List<String> qualityOrder = const ['320kbps', '160kbps']}) async {
    if (song.isLocal) return song.localPath;

    // FIX ("download quality select karo to usi quality mein download ho,
    // 320kbps select kiya to top-level quality"): this used to just call
    // resolveStreamUrl(song), which resolves via AudioPrefs.qualityOrder()
    // — the PLAYBACK quality ladder (streamQuality/dataSaver settings) —
    // completely ignoring the qualityOrder the caller (DownloadProvider)
    // built from the user's chosen Downloads quality setting. A user on
    // "Data Saver" playback but "320kbps" download quality was silently
    // getting low-bitrate files. Now the download path resolves Saavn
    // directly by id using the CALLER's qualityOrder, so the Downloads
    // screen's own quality selector is what actually decides the bitrate.
    if (song.source == SongSource.saavn && song.id.isNotEmpty) {
      final url = await _retry(
        () => _saavnStreamById(
          song.id,
          title: song.title,
          artist: song.artist,
          qualityOrder: qualityOrder,
        ),
        attempts: 2,
      );
      if (url != null) return url;
      // Fall through to the generic resolver only if the quality-aware
      // by-id path genuinely found nothing (e.g. song has no downloadUrl
      // list at all) — better to get SOME file than none.
    }
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
    // Signal 1.5 (see below) used to only run for YT-sourced plays — this
    // resolver lets it run for EVERY current song, including Saavn/local-
    // catalog sourced ones, by first finding a YouTube-equivalent video ID
    // via a quick title+artist search, then feeding that into getRelated.
    Future<String?> resolveYtIdForRelated() async {
      if (currentSong.source == SongSource.youtube) return currentSong.id;
      try {
        final hits = await _searchYt('${currentSong.title} ${currentSong.artist}', limit: 5)
            .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[]);
        return hits.isNotEmpty ? hits.first.id : null;
      } catch (_) {
        return null;
      }
    }

    // SEARCH: YT ONLY — Saavn removed from auto-queue too, matching search's
    // "YT se replace karo a to z" directive so Up Next never hands off from
    // clean YT metadata to a looser Saavn match right as one song ends and
    // the next begins. ("ekdam production level, ekdam YouTube/Spotify jaisa
    // feel" — user directive: real YT Music/Spotify never blend a second
    // catalog into their own "Up Next", and Saavn's 8s/8s/7s timeouts were
    // this function's dominant source of latency — removing them drops the
    // worst case from 24s-ceiling-in-parallel down to _searchYt's own
    // ~3.2s ceiling.) Signal 1.5 (YouTube's own related-videos graph) is now
    // the PRIMARY signal — same graph that actually powers YT Music's own
    // Up Next — with YT text-search signals (same-artist, mood/genre/era)
    // filling in behind it. Saavn stays wired for playback/albums/browse —
    // this only changes what feeds the auto-queue pool.
    final results = await Future.wait<List<Song>>([
      // Signal 1: YouTube's own related-videos graph — the single deepest,
      // most YT-Music-like signal here, now PRIMARY instead of a
      // supplement to Saavn. Runs for every current song (Saavn-sourced
      // plays first resolve a YouTube-equivalent ID via resolveYtIdForRelated).
      () async {
        try {
          final ytId = await resolveYtIdForRelated();
          if (ytId == null) return <Song>[];
          final related = await NativeRelatedVideos.getRelated(ytId)
              .timeout(const Duration(seconds: 5), onTimeout: () => <YtRelatedVideo>[]);
          // FIX (raw "You Might Also Like" titles): showing uncleaned
          // "प्यार हुआ इक़रार हुआ | Pyar Hua Ikrar Hua..." and channel-style
          // artist names like "Shemaroo Romantic Songs", "HD Songs
          // Bollywood", "Goldmines Gaane Sune Ansune" — this signal comes
          // straight from YouTube's own related-videos graph, a completely
          // separate data path from the worker/explode_dart search
          // functions above; it never passed through _cleanText() the way
          // every other YT-sourced title in this file does, so none of the
          // bracket-tag/pipe-separator/channel-suffix stripping applied
          // here. Also apply the same quality gates the search path
          // applies (isLowQualityUpload / isNonMusicContent /
          // isPremiumQuality) — this signal was never filtered at all
          // before, so a low-quality personal-channel upload from
          // YouTube's related graph could surface in "You Might Also Like"
          // even though the equivalent search path already screens it out.
          return related
              .map((r) => Song(
                    id: r.videoId,
                    title: _cleanText(r.title),
                    artist: _cleanText(r.uploaderName, collapseJukeboxTitle: false),
                    album: '',
                    artworkUrl: 'https://i.ytimg.com/vi/${r.videoId}/hqdefault.jpg',
                    source: SongSource.youtube,
                    duration: r.durationSecs,
                    viewCount: r.viewCount,
                  ))
              .where((s) {
                if (s.id.isEmpty || s.title.isEmpty) return false;
                if (RecommendationEngine.isLowQualityUpload(s.title)) return false;
                if (RecommendationEngine.isNonMusicContent(s)) return false;
                if (!RecommendationEngine.isPremiumQuality(s)) return false;
                return true;
              })
              .toList();
        } catch (_) {
          return <Song>[];
        }
      }(),
      // Signal 2: Same-artist catalog search — now YT instead of Saavn.
      // FIX ("Up Next ek hi junk uploader channel se flood ho jaata hai"):
      // when currentSong.artist itself looks like an uploader/channel
      // name (not a real singer credit), a same-artist query just
      // re-surfaces that same channel's other uploads instead of genuine
      // similar-artist recommendations — see looksLikeChannelName's doc
      // comment. Skip this signal entirely in that case so it can't seed
      // the pool with more of the same channel; Signal 1/3 (related-graph +
      // mood/genre/era) still run normally and cover the gap with
      // genuinely relevant songs instead.
      if (RecommendationEngine.looksLikeChannelName(currentSong.artist))
        Future.value(<Song>[])
      else
        _searchYt('${currentSong.artist} songs', limit: limit * 2)
            .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[]),
      // Signal 3: Mood+genre+era fill — one query per generated
      // AutoQueueQuery, all raced together and flattened. YT-only now.
      Future.wait(fallbackQueries.map((q) =>
          _searchYt(q.query, limit: limit * 2)
              .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])
              .catchError((_) => <Song>[])))
          .then((lists) => [for (final l in lists) ...l]),
    ]);

    // Apply in priority order — strongest/most specific signal wins any
    // addToPool duplicate-tie: related-graph first (closest to what YT
    // Music itself would queue next), then same-artist, then mood/genre/era.
    for (final s in results[0]) addToPool(s); // Signal 1: related-graph
    for (final s in results[1]) addToPool(s); // Signal 2: same-artist
    for (final s in results[2]) addToPool(s); // Signal 3: mood/genre/era
    _log('[autoQueue] all signals parallel (YT-only): ${pool.length}');

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

  /// Public entry point for MusicSource (see music_source.dart) — a thin,
  /// unchanged alias for _fetchSimilarFromSaavn.
  static Future<List<Song>> similarFromSaavnRaw(Song song, {int limit = 20}) {
    return _fetchSimilarFromSaavn(song, limit: limit);
  }

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

    // Fire-and-forget: warms _selectionHistory so the personalization boost
    // in _scoreSearchResult has data ready by the time results come back.
    // Never awaited — first search of a session may miss the boost by a
    // beat, every search after is instant since it's a one-time load.
    _ensureSelectionHistoryLoaded();
    // Same reasoning for listening-taste affinity data (artist/genre/
    // language weights) — RecommendationEngine.load() is idempotent
    // (returns immediately if already loaded elsewhere, e.g. PlayerProvider
    // on song start), so this costs nothing on the common case where it's
    // already warm, and only helps the cold-start case where search is the
    // very first thing touched this session.
    RecommendationEngine.load();

    final cacheKey = _normalise(q);
    final cached = _searchCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      _log('[search] Cache HIT: "$q"');
      return cached.results;
    }

    final wantsVariant = _wantsVariantQuery(q);

    // FIX ("movie names se aur us category ke songs ekdam fast/perfect
    // aaye, ekdam YT Music jaisa" — user directive): plain-song search on
    // YT Music's Songs shelf is genuinely weak for a MOVIE/ALBUM name
    // query, because a movie title usually isn't itself a song title — the
    // Songs shelf then falls back to whatever loosely matches, which is
    // how a query like "phool aur kante movie" landed on an unrelated
    // Bhojpuri track as its #1 result. Detecting that shape upfront and
    // firing a dedicated "<core title> all songs" YT query IN PARALLEL
    // with the normal query (not gated behind how the normal query's own
    // top match scored) means the soundtrack search fires unconditionally
    // whenever the query itself signals "movie/album", not only as a
    // related-section afterthought once a plain match already happened to
    // land well.
    // FIX ("movie ka naam sirf likh do, bina 'movie'/'soundtrack' word ke,
    // ekdam YT Music/Spotify jaisa" — user directive): trigger-word gating
    // (query having to literally end in "movie"/"soundtrack"/"all songs")
    // is gone. YT Music/Spotify don't require that either — typing just
    // "Kabir Singh" or "Jawan" with no extra word still surfaces the whole
    // soundtrack alongside any direct title match. Every search query now
    // ALWAYS fires a parallel "<query> all songs" YT lookup, unconditionally,
    // exactly like the old trigger-word path did — the only thing that
    // changed is what decides whether to fire it (now: every query) not how
    // its results are scored/merged (unchanged, see movieMatchScore below).
    // A prefix strip still runs first for the small set of queries that DO
    // carry an explicit trigger word (so "Kabir Singh movie" -> core query
    // "Kabir Singh", not "Kabir Singh movie all songs" which would double up
    // "movie" and return worse matches) — _extractMovieCoreQuery falling
    // through to the raw query otherwise means both phrasings behave
    // identically.
    final movieCoreQuery = _extractMovieCoreQuery(q) ?? q;
    final movieSearchFuture = _searchYt('$movieCoreQuery all songs', limit: 40)
        .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])
        .catchError((_) => <Song>[]);

    // SEARCH: YT ONLY — Saavn fully removed from this path. ("search wala
    // complete YT se replace karo a to z, YT music se data aaye aur
    // workers se, search mein Saavn kaha se aa raha hai" — user directive,
    // explicit correction to the earlier "near-exclusive" version which
    // still fired MusicCatalog.saavn.search() + lyric-variant Saavn calls
    // on every submit search and merged them in whenever YT's count dipped
    // below a floor. That merge condition was easy to hit in practice
    // (region-locked/low-view songs, niche queries), so Saavn songs kept
    // showing up in results despite the "primary" framing. Now there is no
    // Saavn call anywhere in this function — not the main query, not
    // lyric-line sub-phrase variants, not typo variants, not the related-
    // expansion backfill. Saavn stays wired for playback/albums/browse —
    // this only removes it from populating the SEARCH results list.
    final earlySearchYtFuture = _searchYt(q, limit: 100)
        .timeout(const Duration(seconds: 10), onTimeout: () => <Song>[])
        .catchError((_) => <Song>[]);

    final ytScored = <_ScoredSong>[];

    // FIX ("random unrelated songs in search"): results scoring below a
    // relevance floor are dropped entirely. Without this, misremembered
    // or garbled queries (e.g. "manma emotional jaage re" for "Manma
    // Emotion Jaage") returned whatever the backend's own loose search
    // matched on stray fragments — completely unrelated songs — because
    // every result was kept and shown regardless of how weak its match
    // score was.
    const minRelevanceScore = 5.0;

    // SEARCH: YT ONLY. Saavn's scoring/dedup loop and the Saavn-backfill
    // merge below it are removed entirely — there is no Saavn result set
    // left to score by this point (see earlySearchYtFuture above), so
    // nothing to merge in regardless of how thin YT's count is.
    final ytResults = await earlySearchYtFuture; // already firing in parallel since above
    final ytRawTitlesAccepted = <String>[];
    for (final song in ytResults) {
      // FIX: isPremiumQuality's 500k-view floor (built for the home feed)
      // was silently dropping legit niche-channel search matches — anime
      // AMVs, lofi/remix channels, fan covers. isSearchQuality keeps the
      // duration sanity check but drops the view-count requirement, since
      // _scoreSearchResult below already confirms query relevance.
      if (!RecommendationEngine.isSearchQuality(song)) continue;
      // Same non-music/news-vlog/bare-label-reupload filter as
      // getAutoQueue — search's YT results shouldn't surface this content.
      if (RecommendationEngine.isNonMusicContent(song)) continue;
      final score = _scoreSearchResult(song, q, wantsVariant);
      if (score < minRelevanceScore) continue;
      if (_isDupOfAny(song.title, ytRawTitlesAccepted)) continue;
      ytRawTitlesAccepted.add(song.title);
      ytScored.add(_ScoredSong(song, score));
    }

    // FIX (movie/album-name query — see movieSearchFuture above): songs
    // from the dedicated "<movie> all songs" query won't literally contain
    // the word "movie"/"film" from the original query text, so scoring
    // them against the RAW query q via _scoreSearchResult would wrongly
    // drop almost all of them below the relevance floor even though
    // they're exactly the soundtrack the person is looking for. They're
    // trusted by construction (came from a query built specifically to
    // find this movie's songs), so they get a flat, healthy score instead
    // of a text-match score — placed below the true text-matched results
    // (if any) but ahead of anything in the related/discovery section.
    // Same quality/dedup filters as the main YT loop still apply — this
    // only changes how they're SCORED, not whether junk/reuploads get in.
    //
    // Now fires for EVERY query (see movieSearchFuture above), including
    // plain song-title searches like "Tum Hi Ho" — but that's safe here:
    // a plain song title's "<title> all songs" query naturally returns
    // that song plus close siblings from the same release, which just
    // reinforces/duplicates what the main loop above already found (and
    // gets deduped against it via _isDupOfAny) rather than injecting
    // unrelated noise. The person only ever *sees* extra songs here when
    // the query really was movie/album-shaped and had more than one real
    // track behind it — exactly the YT Music/Spotify behavior being matched.
    {
      final movieResults = await movieSearchFuture;
      const movieMatchScore = 55.0; // just under the 60.0 "confident top match" bar used below
      for (final song in movieResults) {
        if (!RecommendationEngine.isSearchQuality(song)) continue;
        if (RecommendationEngine.isNonMusicContent(song)) continue;
        if (RecommendationEngine.isInherentVariant(song.title)) continue;
        if (_isDupOfAny(song.title, ytRawTitlesAccepted)) continue;
        ytRawTitlesAccepted.add(song.title);
        ytScored.add(_ScoredSong(song, movieMatchScore));
      }
    }
    ytScored.sort((a, b) => b.score.compareTo(a.score));

    // SEARCH: YT ONLY — directResults is exactly ytScored now, nothing
    // merged in from Saavn.
    final directResults = ytScored.map((s) => s.song).toList();
    // FIX ("related section anchors on a weak/wrong top match" — e.g.
    // "phool aur kante movie" landing on an unrelated Bhojpuri Birha track
    // as its #1 result, then generateQueries() detecting THAT track's
    // genre/mood and filling "You might also like" with more random
    // Bhojpuri songs that have nothing to do with the actual movie): the
    // combined direct-results list was flattened to plain Song before this
    // point, so the score that produced the ranking was thrown away right
    // before the one place it actually mattered — deciding whether the top
    // match is trustworthy enough to build a whole related section around.
    // Kept alongside directResults (not merged into the Song model) so nothing
    // about scoring/dedup/ranking above this line changes.
    final directScores = ytScored.map((s) => s.score).toList();

    // ── RELATED EXPANSION (Spotify-style) ──────────────────────────────────
    // A single-song search shouldn't dead-end at just that one result.
    // Detect the top match's era/genre/mood and pull in its category
    // siblings — same signal engine Up Next already uses (generateQueries),
    // so search and Up Next behave consistently: search "Gori Hai
    // Kalaiyaan" and its 90s/genre-mates show up too, exactly like tapping
    // play and watching Up Next fill in with the same vibe.
    // TUNED (target: ~80 total results): cap raised 40 -> 55 so
    // direct(≈15-40 after dedup) + related(≈55) comfortably clears 80 for
    // well-covered songs — YT-led, with Saavn backfilling any gaps.
    final results = List<Song>.from(directResults);
    // SPEED FIX ("ekdam fast, smooth, lightweight rahe"): related expansion
    // fires N extra Saavn + N extra YT network calls and used to run on
    // EVERY search, even when direct results already fully answered the
    // query — meaning every keystroke during live typing paid for a whole
    // second wave of requests just to pad the list with "vibe" filler.
    // Now it only runs when direct results are thin, so a query that
    // already lands a clean, complete Saavn match returns immediately.
    // FIX ("related section poora bakwaas ho jata hai jab top match hi
    // weak/wrong hota hai"): generateQueries() below builds queries purely
    // from topMatch's DETECTED genre/mood/era — it has no idea whether
    // topMatch itself is a confident, correct answer to the user's query or
    // just the least-bad loose-match Saavn/YT happened to return (e.g. a
    // random Bhojpuri Birha track "matching" a movie-name search). A weak
    // top match's genre/mood is itself unreliable, so anchoring an entire
    // "You might also like" section on it compounds one bad guess into 40-
    // 80 more. score >= 60 corresponds to _scoreSearchResult's own
    // startsWith-or-better tier (exact title/artist match, or title
    // starting with the query) — the same bar the scorer already uses to
    // mean "this is genuinely the thing they searched for", not just
    // "scraped past the 5.0 relevance floor". Below that, related expansion
    // is skipped entirely rather than built on a shaky foundation; the
    // person still gets their (filtered, relevant) direct results, just
    // without a misleading "you might also like" tacked underneath.
    final topMatchScore = directScores.isNotEmpty ? directScores.first : 0.0;
    if (directResults.isNotEmpty && directResults.length < 45 && topMatchScore >= 60) { // TUNED: 30 -> 45 — category expansion aur zyada reliably chale
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
      // FIX ("ek jaise hi songs formation change karke aate hain" — same
      // song reappearing under a different reupload/channel/tag suffix):
      // dedup here was keyed on _normTitle alone, an EXACT normalized-
      // string match. A reupload with even a slightly different title
      // ("Tera Ban Jaunga | Kabir Singh" vs "Tera Ban Jaunga (Lyrical)")
      // normalizes to two different strings and sailed straight past this
      // check — same gap Search's direct-results dedup and Up Next's
      // dedup already had fixed via RecommendationEngine.isSameSongSmart's
      // fuzzy title-head comparison; this related/"you might also like"
      // section was the one place that fix never reached. Raw titles are
      // now tracked alongside the normalized-key set so every accepted
      // song is smart-compared against everything already in the pool,
      // not just exact-matched.
      final seenRelatedRawTitles = <String>[];
      // TUNED ("us category ke aur bhi songs zyada aaye"): 50 -> 80.
      const relatedCap = 80;

      // FIX ("har baar ekdam same category but NEW songs aaye"): exclude
      // songs already played this session from the DISCOVERY expansion
      // only — never from directResults, so an exact search match is
      // never hidden just because it was played earlier.
      final sessionPlayedIds = RecommendationEngine.sessionRecentIds;

      // YT-PRIMARY: category/related expansion now queries YT first — the
      // 30% YT cap is gone, YT is no longer treated as filler here either.
      // Saavn futures still fire in full parallel and are used purely as
      // backup/gap-fill below, same shape as the direct-results merge
      // above.
      // SEARCH: YT ONLY — related expansion now only queries YT. Saavn's
      // parallel related-query futures and the gap-fill merge below are
      // removed; nothing left to fall back to regardless of how thin YT's
      // related pool is.
      final ytRelatedFutures = relatedQueries.map((rq) => _searchYt(rq.query, limit: 50)
          .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[])
          .catchError((_) => <Song>[])).toList();
      final ytRelatedLists = await Future.wait(ytRelatedFutures);

      void addToPool(Song s) {
        if (relatedPool.length >= relatedCap) return;
        if (directIds.contains(s.id)) return;
        if (sessionPlayedIds.contains(s.id)) return;
        if (RecommendationEngine.isInherentVariant(s.title)) return;
        // FIX: same view-floor-too-strict-for-search issue as direct
        // results — isSearchQuality (duration sanity only, no view-count
        // requirement) instead of isPremiumQuality, so niche-channel YT
        // matches (anime AMVs, lofi/remix, fan covers) aren't dropped here.
        if (s.source == SongSource.youtube && !RecommendationEngine.isSearchQuality(s)) return;
        final tk = _normTitle(s.title);
        if (directTitles.contains(tk) || seenRelated.contains(tk)) return;
        if (_isDupOfAny(s.title, seenRelatedRawTitles)) return;
        seenRelated.add(tk);
        seenRelatedRawTitles.add(s.title);
        relatedPool.add(s);
      }

      for (final list in ytRelatedLists) {
        for (final s in list) {
          if (relatedPool.length >= relatedCap) break;
          addToPool(s);
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
    else if (titleNorm.startsWith(qNorm))  {
      score += 60;
      // FIX ("mujhse mohabbat ka" surfacing "Mujhse Mohabbat Ka Izhaar"
      // ahead of the real, well-known "Mujhse Mohabbat Ka" song when both
      // are startsWith matches and the shorter/exact one either wasn't
      // returned by the backend for this query or tied on every other
      // signal): among startsWith matches, prefer the title that is
      // CLOSER in length to the query — a title extending only slightly
      // past what the person typed reads as an exact/near-exact match,
      // while a title extending it into a materially different, longer
      // song name is a weaker match even though it also technically
      // starts with the query. Capped at +8 (kept below the score gap to
      // the true 100-point exact-match tier) so it only breaks ties
      // between startsWith candidates — it never lets a long, barely-
      // related title outrank a real exact match, and never fires when
      // titleNorm == qNorm is already true (that branch already returned
      // the full 100).
      final extraChars = titleNorm.length - qNorm.length;
      score += (8 - extraChars.clamp(0, 8)).toDouble();
    }
    else if (artistNorm.startsWith(qNorm)) score += 40;
    else if (titleNorm.contains(qNorm))    score += 20;
    else if (artistNorm.contains(qNorm))   score += 10;

    final queryWords = qNormSp.split(' ').where((w) => w.length > 2).toList();
    final queryWordSet = queryWords.toSet();

    // FIX ("Raja Hindustani" surfacing every random Bhojpuri/regional song
    // with the word "Raja" in it; "Aaye ho mere jindgi mai" surfacing any
    // title sharing only filler words "aaye"/"ho"/"mere"): connector/filler
    // words ("ho", "hai", "mai", "mein", "aaye", "ke", "ki", "ka", "se",
    // "ko", "ye", "wo", "nahi", "kya", "kar") appear in a huge fraction of
    // Hindi/Bhojpuri song titles and carry almost no identifying power —
    // scoring them the same as a real content word ("raja", "hindustani",
    // "jindagi") is what let unrelated titles clear the relevance floor on
    // pure word overlap. Excluding them from the coverage/distinctive-word
    // math below means a match now has to come from words that actually
    // identify the song, not just words every third title happens to share.
    const _fillerWords = {
      'aap', 'aaye', 'aaya', 'aayi', 'hai', 'hain', 'mai', 'main', 'mein',
      'mera', 'meri', 'mere', 'tera', 'teri', 'tere', 'uska', 'uski', 'uske',
      'iska', 'iski', 'iske', 'hum', 'humara', 'tum', 'tumhara', 'aur',
      'nahi', 'nahin', 'kya', 'kar', 'kyun', 'kyu', 'kaise', 'kaisi',
      'kaisa', 'jab', 'tab', 'yeh', 'woh', 'wo', 'ye', 'ka', 'ki', 'ke',
      'ko', 'se', 'hi', 'bhi', 'toh', 'to', 'na', 'wala', 'wali',
      'wale', 'sab', 'sabhi', 'kisi', 'koi', 'kuch', 'ab', 'phir', 'thi',
      'tha', 'the', 'hoga', 'hogi', 'hoye', 'hoja', 'jaye', 'jaa', 'jao',
    };
    final distinctiveQueryWords =
        queryWordSet.where((w) => !_fillerWords.contains(w)).toSet();

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
        var titleFuzzyMatched = false;
        for (final token in titleTokens) {
          if (token.length > 2 && _fuzzyWordMatch(qNormSp, token)) {
            score += 30;
            titleFuzzyMatched = true;
            break;
          }
        }
        // FIX ("arigit singh" -> "Arijit Singh" songs never surface): a
        // single-word query that's a misspelled ARTIST name had no path
        // to match here before — only the title tokens were checked.
        if (!titleFuzzyMatched) {
          final artistTokens = artistNormSp.split(' ');
          for (final token in artistTokens) {
            if (token.length > 2 && _fuzzyWordMatch(qNormSp, token)) {
              score += 30;
              break;
            }
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

      // FIX ("Raja Hindustani" surfacing every Bhojpuri song with "Raja" in
      // the title; "kisi disco mai jaaye" surfacing unrelated bhajan/
      // devotional titles; "Aaye ho mere jindgi mai" surfacing anything
      // sharing only "aaye"/"ho"/"mere"): a title that only shares common
      // connector/filler words with the query — "mai", "hai", "ho", "mere",
      // or in the 2-word case just one generic word like "raja" — was
      // clearing the floor purely on those stray overlaps, with no real
      // requirement that the DISTINCTIVE words (the ones that actually
      // identify the song — "disco", "kisi", "hindustani", "jindagi")
      // matched anything. Lowered from a 4+-word-only gate to 2+ words, and
      // now sourced from distinctiveQueryWords (filler words excluded)
      // instead of raw queryWords by length — a 2-word query like "Raja
      // Hindustani" used to get NO distinctive-word protection at all
      // (gate only fired at 4+ words), letting "Hamar Raja Bhang Pike"
      // qualify on the word "raja" alone. Falls back to the longest raw
      // query words only if every word turned out to be filler (e.g. a
      // query that's ALL connector words — rare, but must not crash on an
      // empty distinctive set).
      if (queryWords.length >= 2) {
        final sourceWords = distinctiveQueryWords.isNotEmpty
            ? distinctiveQueryWords
            : queryWordSet;
        final distinctiveWords = ([...sourceWords]..sort((a, b) => b.length.compareTo(a.length)))
            .take(2)
            .toList();
        final distinctiveMatched = distinctiveWords.every((w) =>
            titleNormSp.contains(w) ||
            artistNormSp.contains(w) ||
            _fuzzyWordMatch(w, titleNormSp) ||
            _fuzzyWordMatch(w, artistNormSp));
        if (!distinctiveMatched) score -= 35;
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

    // PERSONALIZATION ("search history se seekhe"): if this exact song was
    // what the person actually picked last time they searched this (or a
    // near-identical) query, surface it again — see
    // recordSearchSelection/_selectionHistoryBoost doc comments above.
    score += _selectionHistoryBoost(query, song.id);

    // LISTENING-TASTE PERSONALIZATION ("jaisa songs sune vaisa aane lage,
    // ekdam Spotify/YT jaisa"): when a query is genuinely AMBIGUOUS —
    // several different songs/artists could reasonably answer it, and
    // nothing here has already pinned one specific title — tilt toward
    // what this person actually listens to. Reuses RecommendationEngine's
    // existing artist/genre/language affinity weights, which are already
    // learned from real plays/completes/skips/replays elsewhere in the
    // app (Up Next, Home feed) — this doesn't add new tracking, it just
    // lets search read the same signal.
    //
    // SAFETY (why this is capped small and gated, not a big blanket
    // bonus): taste must only ever break a TIE between otherwise-similar
    // candidates, never outrank a real match. If it could, typing an
    // artist's exact name could surface a DIFFERENT favorite artist's
    // song instead just because that other artist is played more overall
    // — which would make search feel broken, not smart. Two guards
    // enforce this:
    //  1. Gate: only applies when score is still below 60 at this point —
    //     that threshold sits below a real title-exact (100), title-
    //     startsWith (60+), or a strong phrase-order match, so a query
    //     that already clearly identifies a specific song is untouched.
    //     Only genuinely loose/ambiguous matches (a bare artist-name
    //     search, a mood word, a generic query) are still under 60 by
    //     this point and eligible for the taste tilt.
    //  2. Magnitude: total possible taste bonus tops out around 10 — small
    //     enough to reorder among already-similar-scoring candidates
    //     without ever letting a low-relevance song leapfrog a
    //     meaningfully-more-relevant one.
    if (score < 60 && score > 0) {
      double tasteBoost = 0;
      // BUG FIX (found before shipping): RecommendationEngine stores
      // artist-affinity keys through its own normalization, which strips
      // ALL non-alphanumeric characters INCLUDING SPACES (e.g. "Arijit
      // Singh" -> "arijitsingh"). Comparing against a plain
      // lowercase-with-spaces string would never match anything, silently
      // making this whole check dead code. Replicating the exact same
      // stripping here so the comparison actually lines up with what
      // topAffinityArtists() returns.
      final artistKey = song.artist.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (artistKey.isNotEmpty &&
          RecommendationEngine.topAffinityArtists(count: 8).contains(artistKey)) {
        tasteBoost += 5;
      }
      if (RecommendationEngine.topAffinityGenres(count: 3)
          .contains(RecommendationEngine.detectGenre(song))) {
        tasteBoost += 3;
      }
      if (RecommendationEngine.topAffinityLanguages(count: 2)
          .contains(RecommendationEngine.detectLanguage(song))) {
        tasteBoost += 2;
      }
      score += tasteBoost;
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

  // FIX ("movie names se us category ke songs aaye, ekdam YT Music jaisa"):
  // detects a movie/album/soundtrack-shaped query and returns the CORE
  // title with the trigger word stripped — "phool aur kante movie" ->
  // "phool aur kante", "kabir singh soundtrack" -> "kabir singh" — so the
  // dedicated all-songs query built from it (see movieSearchFuture in
  // search()) searches for the actual movie name, not "phool aur kante
  // movie all songs" (which would double up the word "movie" and often
  // returns worse matches than the clean title does). Returns null for a
  // query with no such trigger word, so plain song-title/artist/lyric
  // searches are completely unaffected — this only fires for the specific
  // shape of query it's built for.
  static final List<RegExp> _movieTriggerPatterns = [
    RegExp(r'^(.*?)\s+(movie|film|picture)$', caseSensitive: false),
    RegExp(r'^(.*?)\s+(soundtrack|ost)$', caseSensitive: false),
    RegExp(r'^(.*?)\s+(all songs|full album|album songs)$', caseSensitive: false),
  ];
  static String? _extractMovieCoreQuery(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;
    for (final pattern in _movieTriggerPatterns) {
      final match = pattern.firstMatch(trimmed);
      final core = match?.group(1)?.trim();
      if (core != null && core.isNotEmpty && core.split(RegExp(r'\s+')).length >= 1) {
        return core;
      }
    }
    return null;
  }

  // CLEANUP: the same "is this song a smart-dedup match against anything
  // already accepted" loop was copy-pasted 4+ times across search()/
  // quickSearch() — identical shape every time (loop the accepted-titles
  // list, call isSameSongSmart, break on first hit). One shared helper,
  // zero behavior change — every call site below produces the exact same
  // accept/reject decision it did before.
  static bool _isDupOfAny(String title, List<String> acceptedTitles) {
    for (final t in acceptedTitles) {
      if (RecommendationEngine.isSameSongSmart(title, t)) return true;
    }
    return false;
  }

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
  // QUICK SEARCH — YT ONLY, live-typing path. Fires on every keystroke, so
  // stays pure and fast: no Saavn call at all (see note below), fully
  // mirrors search()'s YT-only result construction so live-typing and
  // committed search never visibly disagree on the same query.
  // ===========================================================================
  static Future<List<Song>> quickSearch(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    // LIGHTWEIGHT FIX ("ekdam lightweight aur fast"): same short-TTL cache
    // read pattern as search()'s _searchCache above — see the doc comment
    // on _quickSearchCache for why this needed its own cache (different
    // TTL, different return shape). A cache hit skips every network call
    // below entirely, which matters most for exactly the case this fires
    // hundreds of times a session: retyping/re-focusing the same partial
    // query while live-typing.
    final quickCacheKey = '${_normalise(q)}::$limit';
    final cachedQuick = _quickSearchCache[quickCacheKey];
    if (cachedQuick != null && !cachedQuick.isExpired) {
      return cachedQuick.results;
    }

    // Fire-and-forget — same reasoning as search() above. Cheap no-op after
    // the first call since _ensureSelectionHistoryLoaded short-circuits once loaded.
    _ensureSelectionHistoryLoaded();
    RecommendationEngine.load();

    final wantsVariant = _wantsVariantQuery(q);
    const minLiveRelevanceScore = 5.0; // FIX: live typing mein bhi Saavn ke songs miss ho rahe the

    // QUICKSEARCH: YT ONLY — matches search()'s "complete YT se replace
    // karo a to z" directive. This used to keep a lazy Saavn gap-fill
    // (fired only when YT's own accepted count came up thin), which meant
    // live-typing could show Saavn-mixed results while the committed
    // search() path showed pure-YT results for the exact same query —
    // a visible jump/flicker the instant the user hit submit. Removed
    // entirely so both paths are identically YT-only end-to-end; Saavn
    // stays wired for playback/albums/browse, just not for populating
    // quickSearch's result list.
    // SLOW-NETWORK FIX ("search slow network pe sahi se handle nahi kar
    // raha"): this used to wrap _searchYt in its own hard 4s timeout with
    // onTimeout: [] — a SEPARATE, SHORTER cutoff than _searchYt's own
    // internal race logic, so even a healthy-but-slow call that was about
    // to succeed got discarded here and silently replaced with an empty
    // list. This is the actual per-keystroke path the search bar calls,
    // so this was the real reason live search looked broken on a slow
    // connection. Fast path is unchanged (still ~4s for the normal case);
    // if nothing has landed by then, we now wait a real extra window
    // instead of giving up, so a slow-but-working network still gets its
    // results shown instead of a false empty state.
    List<Song> ytQuickResults;
    final ytFuture = _searchYt(q, limit: limit + 20);
    try {
      ytQuickResults = await ytFuture.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      // Fast path didn't land in time — do NOT fire a second _searchYt
      // call (that would double the network traffic on the exact slow
      // connection this is meant to help). Keep waiting on the SAME
      // future; _searchYt's own internal legs run up to 9s, so this
      // gives the already-in-flight call a real chance to finish.
      try {
        ytQuickResults = await ytFuture.timeout(const Duration(seconds: 5));
      } catch (_) {
        ytQuickResults = const <Song>[];
      }
    } catch (_) {
      ytQuickResults = const <Song>[];
    }

    // SPEED FIX (2026-08-13 — per-keystroke path, highest speed sensitivity
    // in the whole file): this used to be TWO SEPARATE if-blocks, each with
    // its own `await Future.wait(...)` — typo-variants awaited fully (up to
    // 10s) BEFORE the lyric-trim-variant block even started being awaited
    // (up to 3s more). The lyric-trim block's own comment claimed "both
    // variants raced together, not chained" but the code directly below it
    // did not do that — a genuinely thin/misspelled 4+-word query could
    // trigger both blocks and pay up to 13s sequentially, on a path that
    // fires on nearly every keystroke while live-typing. Both escalation
    // conditions are now checked up front and every resulting query (typo
    // variants + lyric-trim variants) fires in ONE combined Future.wait, so
    // total extra wait is bounded by the slowest single call, not the sum.
    // Same trigger thresholds, same per-query limits, same 3s timeout for
    // lyric-trim; typo-variant timeout tightened 10s→5s to match how
    // aggressively time-bounded a live-typing path should be — a typo
    // fallback that still hasn't answered in 5s on a per-keystroke call
    // isn't worth waiting out further before the next keystroke supersedes
    // it anyway.
    // LIGHTWEIGHT FIX ("ekdam smooth ekdam low-end device pe bhi fast" —
    // real per-keystroke cost): typo/lyric-trim variants used to fire on
    // EVERY keystroke whenever the raw Saavn count dipped below the
    // threshold — meaning up to 3 EXTRA network calls stacked on top of
    // the 2 already firing (Saavn + YT), so a single keystroke could
    // trigger 5 parallel requests. On a slow/low-end network that's what
    // actually made live typing feel laggy, not the debounce timer itself.
    // quickSearch() IS the live per-keystroke path (search()'s committed
    // path calls _searchSaavn directly with its own full variant logic),
    // so variant expansion here is pure waste — the very next keystroke
    // supersedes this result before the extra calls even return. Disabled
    // entirely; committed search (Enter / submit) still gets full variant
    // coverage via the separate search() path.
    const needsTypoVariants = false;
    const needsLyricVariants = false;
    final qWordsForVariants = needsTypoVariants || needsLyricVariants
        ? q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList()
        : const <String>[];

    final typoVariants = needsTypoVariants
        ? _generateTypoVariants(q, qWordsForVariants)
        : <String>{};

    final extraFutures = <Future<List<Song>>>[
      for (final v in typoVariants)
        _searchSaavn(v, limit: 15)
            .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[]),
      if (needsLyricVariants) ...[
        _searchSaavn(qWordsForVariants.sublist(0, qWordsForVariants.length - 1).join(' '), limit: 15)
            .timeout(const Duration(seconds: 3), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[]),
        _searchSaavn(qWordsForVariants.sublist(1).join(' '), limit: 15)
            .timeout(const Duration(seconds: 3), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[]),
      ],
    ];

    final variantResults = <Song>[];
    if (extraFutures.isNotEmpty) {
      final variantBatches = await Future.wait(extraFutures);
      for (final l in variantBatches) variantResults.addAll(l);
    }
    ytQuickResults = [...ytQuickResults, ...variantResults];

    // YT-PRIMARY: scored/filtered — YT Music's worker path already gives
    // clean title/artist/square art, so these results are trustworthy by
    // construction (see the viewCount:1000000 sentinel in _searchYtMusic).
    final ytScoredQuick = <_ScoredSong>[];
    final ytRawTitlesAcceptedQuick = <String>[];
    for (final ys in ytQuickResults) {
      if (!RecommendationEngine.isSearchQuality(ys)) continue;
      if (RecommendationEngine.isLowQualityUpload(ys.title)) continue;
      if (RecommendationEngine.isNonMusicContent(ys)) continue;
      final score = _scoreSearchResult(ys, q, wantsVariant);
      if (score < minLiveRelevanceScore) continue;
      if (_isDupOfAny(ys.title, ytRawTitlesAcceptedQuick)) continue;
      ytRawTitlesAcceptedQuick.add(ys.title);
      ytScoredQuick.add(_ScoredSong(ys, score));
    }
    ytScoredQuick.sort((a, b) => b.score.compareTo(a.score));

    // QUICKSEARCH: YT ONLY — directResults is exactly ytScoredQuick now,
    // nothing merged in from Saavn. Mirrors search()'s directResults
    // construction exactly (see search() above) so live-typing and
    // committed-search never disagree on the same query.
    final mergedQuick = <Song>[...ytScoredQuick.map((s) => s.song)];

    final quickResult = mergedQuick.take(limit).toList();
    _writeQuickSearchCache(quickCacheKey, quickResult);
    return quickResult;
  }

  // ===========================================================================
  // SUGGEST
  // ===========================================================================
  // YT MUSIC IS HARD PRIMARY — Saavn ekdam last-resort fallback hai, ab
  // parallel race nahi hai. Har keystroke pe pehle real YT Music
  // search-suggestions try hote hain (fast, "premium" YT Music jaisa feel);
  // Saavn ko sirf tabhi chhua jaata hai jab YT Music genuinely kuch na de
  // (timeout ya empty) — isliye dropdown Saavn ki wajah se distracted/
  // gandi feel nahi karta, phir bhi kabhi poora blank nahi rehta.
  static Future<List<String>> suggest(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    List<String> results = await _suggestYtMusic(q);

    if (results.isEmpty) {
      // YT Music ne kuch nahi diya (down/slow/no match) — sirf ab Saavn ko
      // aakhri fallback ke taur pe try karo, taaki dropdown blank na rahe.
      results = await _suggestSaavn(q).catchError((_) => const <String>[]);
    }

    // Dedup: kabhi kabhi duplicate suggestions aa jaate hain
    final deduped = results.toSet().toList();
    if (deduped.isEmpty) return deduped;

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
    return scored.map((e) => e.key).take(10).toList();
  }

  static Future<List<String>> _suggestSaavn(String query) async {
    // FIX ("suggestions bhi late aate hain"): this used to try
    // _saavnPrimary/_saavnSecondary FIRST — both Render/Vercel free-tier
    // hosts that can cold-sleep 30-50s (see wakeSaavn()'s doc comment and
    // the matching fix in _searchSaavn above). Since this loop is
    // SEQUENTIAL (tries one host, only moves to the next on failure), a
    // sleeping primary meant every autocomplete keystroke paid its full
    // 3s timeout before even reaching the fast CF Worker. Reordered so
    // the Worker (Cloudflare — never cold-sleeps) is tried first; Render
    // hosts stay as a last-resort fallback rather than the default path.
    for (final base in [_saavn, _saavnPrimary, _saavnSecondary]) {
      try {
        final url = Uri.parse(
          '$base/result/?query=${Uri.encodeQueryComponent(query)}&limit=10', // FIX: suggestions zyada
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
                // FIX ("Not Ramaiya Vastavaiya" suggestions): Saavn ka
                // autocomplete kabhi kabhi "Not <query>" prefix wali entries
                // return karta hai — filter kar do
                .where((s) => !s.toLowerCase().startsWith('not '))
                .take(5)
                .toList();
          }
        }
      } catch (_) {}
    }
    return [];
  }

  /// Real YT Music search-suggestions ("YouTube Music jaisa" autocomplete)
  /// via the CF Worker's `/api/yt-suggest`. This is the "primary" source in
  /// [suggest] — short timeout here is intentional since [suggest] already
  /// races this against Saavn and has its own head-start window; this
  /// function itself just needs to never hang past a sane ceiling.
  static Future<List<String>> _suggestYtMusic(String query) async {
    try {
      final url = Uri.parse(
        '$_worker/api/yt-suggest?query=${Uri.encodeQueryComponent(query)}&limit=8',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final results = data?['data']?['results'];
        if (results is List && results.isNotEmpty) {
          return results
              .map((s) => _cleanText(s.toString()))
              .where((s) => s.isNotEmpty)
              .toList();
        }
      }
    } catch (_) {}
    return const [];
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

  /// Public entry point for MusicSource (see music_source.dart) — a thin,
  /// unchanged alias for _searchSaavn. Kept separate from the private name
  /// so the multi-host race/failover internals below can keep evolving
  /// without ever becoming public API themselves.
  static Future<List<Song>> searchSaavnRaw(String query, {int limit = 20}) {
    return _searchSaavn(query, limit: limit);
  }

  static Future<List<Song>> _searchSaavn(String query, {int limit = 20, bool allowMultiPage = true}) async {
    // FIX ("Saavn se bhi full song library nahi utha raha" — real
    // production gap): every OTHER Saavn caller in this file that wants
    // deep results (_searchSaavnDeep, used by home sections) already walks
    // multiple pages via `&page=N`, because JioSaavn's own backend caps
    // each individual page response well below whatever `limit` is asked
    // for — a single request with limit=90 still only returns one page's
    // worth of real results (typically ~20-40), the rest of `limit` was
    // just silently unused. _searchSaavn (used by EVERY OTHER Saavn path
    // in the app — Up Next Signals 1-4, search(), quickSearch(), related
    // expansion) never did this — it always fetched exactly ONE page no
    // matter how high `limit` was raised, so all of last session's
    // "raise the limit" tuning was capped by this ceiling underneath it
    // the whole time. Walking enough pages to actually cover `limit` here
    // is what makes every one of those upstream limit increases (Saavn
    // similarTo, same-artist search, mood/genre fallback, main search
    // query, category-related expansion) actually reach Saavn's real
    // catalog depth instead of quietly re-returning the same first page.
    //
    // [allowMultiPage] defaults true for every normal caller (submit
    // search, Up Next signals, related expansion). quickSearch (live,
    // per-KEYSTROKE typing) explicitly passes false — see the LIGHTWEIGHT
    // FIX comments in quickSearch itself for why per-keystroke calls stay
    // single-page: multi-page there would multiply the exact per-keystroke
    // request storm that fix was written to prevent.
    // PRODUCTION-SAFE DEPTH CAP ("Saavn ki A-to-Z poori library uthao"):
    // there's no such thing as a single "whole Saavn library" endpoint —
    // JioSaavn itself is query/category-driven, same as every other
    // streaming catalog. What "pull everything relevant" means in
    // practice is: walk as many real result pages as a query genuinely
    // has, for whatever query/artist/mood is being searched — which is
    // exactly what page-walking already does below. Two independent caps
    // keep that safe at production scale instead of ever letting a caller
    // accidentally trigger hundreds of parallel requests or multi-MB
    // responses:
    //   1. `effectiveLimit` — the per-PAGE size sent to each host is
    //      capped at 40 regardless of what `limit` a caller passes in.
    //      JioSaavn's own backend already has an effective per-page
    //      ceiling around this size; asking for more per page doesn't
    //      return more real songs, it just risks a slower/heavier
    //      response for zero extra depth. A caller that wants MORE total
    //      songs should walk more pages (below), not ask for a bigger
    //      single page.
    //   2. `pagesNeeded` — walks up to 10 pages (~400 real songs per host
    //      before dedup, ~1600 raw across all 4 hosts) when `limit` asks
    //      for real depth. 10 was chosen as the ceiling most JioSaavn
    //      mirrors' search index realistically has fresh distinct results
    //      for before pages start recycling/thinning out — walking further
    //      would mostly return late-arriving stragglers or repeats
    //      dedup was already discarding, at real cost (more parallel
    //      requests hitting free-tier Render hosts, more phone battery/
    //      data per search). This is already 2x deeper than before.
    final effectiveLimit = limit > 40 ? 40 : limit;
    final pagesNeeded = allowMultiPage
        ? (limit / effectiveLimit).ceil().clamp(1, 10)
        : 1;

    Future<List<Song>?> tryNodeHost(String host, int page) async {
      try {
        final url = Uri.parse(
          '$host/api/search/songs?query=${Uri.encodeQueryComponent(query)}&limit=$effectiveLimit&page=$page',
        );
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) return null;
        final data = jsonDecode(res.body);
        final results = data is Map ? (data['data']?['results'] ?? []) : [];
        if (results is! List || results.isEmpty) return null;
        final songs = results
            .whereType<Map<String, dynamic>>()
            .take(effectiveLimit)
            .map(_songFromSaavn)
            .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
            .toList();
        return songs.isNotEmpty ? songs : null;
      } catch (e) {
        _log('[_searchSaavn] $host page $page error: $e');
        return null;
      }
    }

    Future<List<Song>?> tryResultRoute(String host, int page) async {
      try {
        final url = Uri.parse(
          '$host/result/?query=${Uri.encodeQueryComponent(query)}&limit=$effectiveLimit&page=$page',
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
            .take(effectiveLimit)
            .map(_songFromSaavn)
            .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
            .toList();
        return songs.isNotEmpty ? songs : null;
      } catch (e) {
        _log('[_searchSaavn] $host page $page error: $e');
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
    // FIX ("Saavn pe song hai lekin search mein nahi aata"): pehle sirf
    // pehle winner ki results use hoti thi — agar Node host ne 3 songs
    // diye aur Flask host ne 40 diye, toh sirf 3 milte the. Ab SAARE
    // parallel hosts ke results merge hote hain — koi bhi song miss
    // nahi hoga. Speed same rahegi kyunki sab parallel fire hote hain.
    // Duplicate dedup search() mein isSameSongSmart se hoti hai.
    //
    // Page 1 always fires from every host (unchanged latency for a normal
    // `limit`-sized request). Pages 2+ only fire when `limit` actually
    // asks for more than one page's worth — a plain limit:20 caller (e.g.
    // a quick single-song lookup) pays zero extra requests; only the
    // higher-limit callers (Up Next signals, main search, category
    // expansion) that need real depth pay for the extra parallel pages.
    // FIX ("search 1 min tak wait karna padta hai, itna late aata hai" —
    // production bug, continuation of the connection-pool fix above): even
    // with a tuned connection pool, _saavnPrimary/_saavnSecondary are
    // Render/Vercel free-tier hosts that can cold-sleep for 30-50s (see
    // wakeSaavn()'s own doc comment acknowledging this). Future.wait below
    // waits for the WHOLE batch, so including a possibly-sleeping host in
    // this race means every single search pays for that host's worst case
    // whenever it happens to be asleep — even though the Node host and CF
    // Worker below almost always answer in well under a second (Cloudflare
    // Workers don't cold-sleep; the Node host has its own proven uptime).
    // Removed _saavnPrimary/_saavnSecondary from this live user-facing
    // race — they're still kept warm in the background by wakeSaavn() and
    // still used by _searchSaavnDeep/similarTo's own narrower fallback
    // chains, just no longer able to stall the single most latency-
    // sensitive path (what the user is actively waiting on: search-as-
    // you-type and submit-search results).
    final allResults = await Future.wait(<Future<List<Song>?>>[
      for (final host in _saavnNodeHosts)
        for (int p = 1; p <= pagesNeeded; p++) tryNodeHost(host, p),
      for (int p = 1; p <= pagesNeeded; p++) tryResultRoute(_saavn, p),
      // Extra resilience mirror — ALWAYS page=1 only, never pagesNeeded,
      // since this host's own `page` param is a confirmed no-op (see
      // _saavnNoPaginationFlaskHosts doc comment above). Requesting more
      // pages from it would just be a wasted duplicate network call
      // returning identical data every time.
      for (final host in _saavnNoPaginationFlaskHosts) tryResultRoute(host, 1),
    ]);
    final seenIds = <String>{};
    final merged = <Song>[];
    for (final r in allResults) {
      if (r == null) continue;
      for (final s in r) {
        if (seenIds.add(s.id)) merged.add(s);
      }
    }
    return merged;
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

  /// Public entry point for MusicSource (see music_source.dart) — a thin,
  /// unchanged alias for _searchYt.
  static Future<List<Song>> searchYtRaw(String query, {int limit = 30}) {
    return _searchYt(query, limit: limit);
  }

  // FEATURE (YT Music-quality metadata): search now goes through the
  // Cloudflare Worker's /api/yt-music-search route FIRST — that calls
  // YouTube Music's own internal API (WEB_REMIX client), so title/artist/
  // thumbnail arrive exactly as YT Music itself shows them: real artist
  // (not channel/uploader name), no "Official Video"/"Lyrics" junk, clean
  // square high-res album art, real duration.
  //
  // PLAYBACK IS UNCHANGED: these Song objects carry streamUrl:null and
  // source:SongSource.youtube exactly like the old path — when the user
  // taps play, the existing resolveYtStream()/_ytStreamById() chain
  // resolves the actual audio the same way it always has, keyed off the
  // same YouTube videoId. Only where the metadata (title/artist/art) came
  // from has changed.
  //
  // PRODUCTION-QUALITY FIX ("ekdam clean, ekdam YouTube Music jaisa —
  // explode_dart ke jagah yaha bhi YT Music laga do"): explode_dart's raw
  // video search is a LOW-TRUST source by nature — its "artist" field is
  // literally whatever the uploading channel is named ("Shemaroo Romantic
  // Songs", "Ms Lofi Shorts", "Missi technical services"), because
  // regular YouTube has no concept of a verified artist, only an
  // uploader. No amount of filtering on top of that ever produces a real
  // artist name — the field itself is the wrong data. The worker's
  // /api/yt-music-search route calls YT MUSIC's own internal catalog
  // (WEB_REMIX client), which is curated release data — real artist,
  // clean title, square high-res art — exactly like the official YouTube
  // Music app shows. So this function no longer falls back to
  // explode_dart at all.
  //
  // DIRECT-DART FALLBACK ("worker kabhi down ho to bhi YT Music jaisa hi
  // result aaye"): if the Cloudflare Worker route fails/errors/times out,
  // _searchYtMusicDirect below calls YT Music's own WEB_REMIX InnerTube
  // endpoint straight from the phone (same public, unauthenticated
  // endpoint/key music.youtube.com's own web frontend calls — mirrors
  // the worker's ytMusicSearchRaw/parseYtMusicSearch in worker.js
  // exactly), so results stay YT-Music-quality even with the worker
  // completely unreachable. Fires whenever the worker returned nothing —
  // down, errored, timed out, OR a genuine "no matches" — since a second
  // 3s call is a small, bounded cost and this way a real hit from the
  // direct path is never left on the table just because the worker
  // happened to (correctly) find zero results for that exact query
  // phrasing.
  //
  // Playback is completely unaffected by any of this — the returned Song
  // still carries streamUrl:null / source:SongSource.youtube, and the
  // existing resolveYtStream()/_ytStreamById() chain (untouched) resolves
  // the actual audio off the same videoId exactly as before.
  static Future<List<Song>> _searchYt(String query, {int limit = 30}) async {
    // TRUE-PARALLEL FIX ("dono ko primary kro, jo pehle jawab de wahi
    // use ho — 1-3 sec mein Spotify-level result"): both the worker
    // (Cloudflare edge, /api/yt-music-search) and the direct-dart call
    // (phone → YT Music InnerTube directly) now fire at the SAME time,
    // every search — no head start, no sequential wait. Whichever
    // responds first with a non-empty result answers immediately; the
    // other is left running but no longer blocks the return. This costs
    // one extra network call per search versus the old head-start
    // approach, but on a live-typing search bar that's the right trade:
    // worst case is now bounded by whichever source is faster right now,
    // not by waiting out the worker's own timeout first.
    //
    // SLOW-NETWORK FIX ("search slow network pe sahi se handle nahi kar
    // raha"): each leg used to get a hard 3s cutoff with onTimeout: []
    // — on a genuinely slow but working connection (weak wifi, 3G),
    // 3s often isn't enough for either call to land, so BOTH legs would
    // silently return empty and the user would see "no results" for a
    // query that just needed a couple more seconds. Individual leg
    // timeouts are now longer (9s) so a slow call still gets to
    // finish instead of being cut off exactly when it was about to
    // succeed, and the leg futures are no longer discarded after the
    // fast path — a late-arriving result still updates the completer
    // via checkDone() same as a fast one would. The 3s window below is
    // now only a FAST-PATH short-circuit for the common good-network
    // case, not the only chance the search gets.
    final workerFuture = _searchYtMusic(query, limit)
        .timeout(const Duration(seconds: 9), onTimeout: () => <Song>[])
        .catchError((e) {
          _log('[_searchYt] yt-music-search (worker) error: $e');
          return <Song>[];
        });
    final directFuture = _searchYtMusicDirect(query, limit)
        .timeout(const Duration(seconds: 9), onTimeout: () => <Song>[])
        .catchError((e) {
          _log('[_searchYt] yt-music-search (direct) error: $e');
          return <Song>[];
        });

    List<Song>? workerResult;
    List<Song>? directResult;
    final firstNonEmpty = Completer<List<Song>>();
    void checkDone() {
      if (firstNonEmpty.isCompleted) return;
      if (workerResult != null && workerResult!.isNotEmpty) {
        firstNonEmpty.complete(workerResult!);
      } else if (directResult != null && directResult!.isNotEmpty) {
        firstNonEmpty.complete(directResult!);
      } else if (workerResult != null && directResult != null) {
        // Both finished, both empty — genuinely no matches from either.
        firstNonEmpty.complete(const <Song>[]);
      }
    }

    workerFuture.then((r) {
      workerResult = r;
      checkDone();
    });
    directFuture.then((r) {
      directResult = r;
      checkDone();
    });

    // FAST PATH: on a healthy connection this resolves in 1-3s exactly
    // like before — no change to the common case. If neither leg has
    // answered by then, we do NOT give up: we keep waiting on the same
    // firstNonEmpty completer (which workerFuture/directFuture above
    // will still complete whenever they actually finish, up to their
    // own 9s ceiling) instead of returning a false empty result. Total
    // worst-case wait is bounded by the 9s leg timeout, not by this
    // fast-path window.
    try {
      return await firstNonEmpty.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      return firstNonEmpty.future.timeout(
        const Duration(seconds: 7),
        onTimeout: () => workerResult ?? directResult ?? const <Song>[],
      );
    }
  }

  // Fixed, public, unauthenticated INNERTUBE key used by the WEB_REMIX web
  // client itself (music.youtube.com's own frontend JS uses this exact
  // key) — not a secret, not tied to any account. Mirrors YTM_API_KEY in
  // worker.js so the direct-Dart path returns identically-shaped, equally
  // clean results.
  static const String _ytmApiKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
  static const String _ytmClientVersion = '1.20250310.01.00';

  // ═══════════════════════════════════════════════════════════════════
  // GENERIC RECURSIVE RENDERER FINDER ("production-grade" artist parsing)
  //
  // Every hand-rolled YT Music parser in this file used to hardcode the
  // exact shelf path a renderer would appear under — tabs →
  // sectionListRenderer → musicShelfRenderer.contents, or separately
  // musicCardShelfRenderer, or a flat sectionListRenderer with no tabs
  // wrapper at all. YT Music actually mixes all of these shapes depending
  // on the query, the account region, and which experiment bucket the
  // request lands in — a single artist-only query can come back as a
  // "Top result" card (musicCardShelfRenderer), a normal shelf
  // (musicShelfRenderer), or occasionally a musicShelfRenderer nested one
  // level deeper inside a musicCarouselShelfRenderer. Hardcoding one path
  // means any of the others silently returns zero artists — which is
  // exactly the "search mein artist nahi aate" bug this fixes.
  //
  // _findRenderers walks the ENTIRE decoded JSON tree — maps, lists,
  // any depth — and yields every object found under the given key,
  // regardless of what shelf/card/carousel wrapper it's nested inside.
  // This makes every parser below immune to YouTube reshuffling its
  // response layout, which happens often and without notice since it's
  // an undocumented internal API. Modeled directly on the same pattern
  // Musify's youtube_music_explode_dart package uses for this exact
  // problem.
  // ═══════════════════════════════════════════════════════════════════
  static Iterable<Map<String, dynamic>> _findRenderers(
      dynamic node, String rendererKey) sync* {
    if (node is Map) {
      final match = node[rendererKey];
      if (match is Map) yield Map<String, dynamic>.from(match);
      for (final value in node.values) {
        yield* _findRenderers(value, rendererKey);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _findRenderers(value, rendererKey);
      }
    }
  }

  /// Pulls the browseId + MUSIC_PAGE_TYPE_ARTIST tag off a
  /// navigationEndpoint (however it's nested) — shared by every artist
  /// renderer path below (list item, card shelf, flex-column run).
  ///
  /// FIX: previously only accepted a "UC..." browseId. Cross-checked
  /// against ytmusicapi's own parse_search_result() browseId-prefix
  /// mapping (its fallback path for classifying a result with no shelf
  /// category, i.e. exactly a mixed/unfiltered search) — "MPLA..." is
  /// ALSO a valid artist browseId prefix YT Music uses (distinct from a
  /// channel id), and rejecting it here silently dropped any artist
  /// returned in that form, most likely to affect the unfiltered fallback
  /// attempt in particular since that's the path relying on browseId
  /// shape to tell an artist apart from a song/album in the same shelf.
  static ({String browseId, bool isArtist})? _artistEndpointOf(
      Map<String, dynamic>? navigationEndpoint) {
    final browseEndpoint = navigationEndpoint?['browseEndpoint'];
    if (browseEndpoint is! Map) return null;
    final browseId = (browseEndpoint['browseId'] ?? '').toString();
    if (!browseId.startsWith('UC') && !browseId.startsWith('MPLA')) return null;
    final pageType = browseEndpoint['browseEndpointContextSupportedConfigs']
        ?['browseEndpointContextMusicConfig']?['pageType'];
    return (browseId: browseId, isArtist: pageType == 'MUSIC_PAGE_TYPE_ARTIST');
  }

  /// Best-quality thumbnail URL out of a standard YT Music
  /// musicThumbnailRenderer.thumbnail.thumbnails list (largest is last).
  static String _ytmThumbnailUrl(Map<String, dynamic>? renderer) {
    final thumbs = renderer?['thumbnail']?['musicThumbnailRenderer']
            ?['thumbnail']?['thumbnails'] as List? ??
        const [];
    if (thumbs.isEmpty) return '';
    final best = thumbs.last;
    final rawUrl = (best is Map ? (best['url'] ?? '') : '').toString();
    if (rawUrl.isEmpty) return '';
    // Request a larger crop than YT Music's default (~60-120px chip size)
    // so artist avatars/artwork stay sharp on larger UI (artist header,
    // full player, etc.) instead of visibly upscaled thumbnails.
    return rawUrl.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w500-h500-p');
  }

  static String _flexColumnText(Map<String, dynamic> item, int index) {
    final flexColumns = (item['flexColumns'] as List?) ?? const [];
    if (index >= flexColumns.length) return '';
    final runs = flexColumns[index]
            ?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']
        as List? ??
        const [];
    return runs
        .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
        .join()
        .trim();
  }

  /// Extracts every MUSIC_PAGE_TYPE_ARTIST-tagged run out of a song row's
  /// second flex column (the "Song • Artist • Album" subtitle line),
  /// returning (channelId, name) pairs. Used to recover the *credited
  /// artist's real channelId* directly from a song search result, which
  /// is far more reliable than resolving a name string back to a channel
  /// in a second network round trip.
  static List<({String channelId, String name})> _artistRunsInSubtitle(
      Map<String, dynamic> item) {
    final flexColumns = (item['flexColumns'] as List?) ?? const [];
    if (flexColumns.length < 2) return const [];
    final runs = flexColumns[1]
            ?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']
        as List? ??
        const [];
    final out = <({String channelId, String name})>[];
    for (final run in runs) {
      if (run is! Map) continue;
      final endpoint = _artistEndpointOf(
          (run['navigationEndpoint'] as Map?)?.cast<String, dynamic>());
      if (endpoint == null || !endpoint.isArtist) continue;
      final name = (run['text'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      out.add((channelId: endpoint.browseId, name: name));
    }
    return out;
  }

  /// One POST to YT Music's InnerTube `search` endpoint with the given
  /// query/params, decoded to a Map — or null on any failure. Centralizes
  /// the request shape every direct YTM call below was duplicating.
  static Future<Map<String, dynamic>?> _ytmSearchRaw(
    String query, {
    String? params,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    try {
      final uri = Uri.parse(
        'https://music.youtube.com/youtubei/v1/search?key=$_ytmApiKey&prettyPrint=false',
      );
      final resp = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
        },
        body: jsonEncode({
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': _ytmClientVersion,
              'hl': 'en',
              'gl': 'IN',
            },
          },
          'query': query,
          if (params != null) 'params': params,
        }),
      ).timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (e) {
      _log('[_ytmSearchRaw] error for "$query": $e');
      return null;
    }
  }

  /// One POST to YT Music's InnerTube `browse` endpoint — used for
  /// fetching a full artist page (header, top songs, albums, singles)
  /// directly by channelId, the same call music.youtube.com itself makes
  /// when you open an artist's page. Far richer and more reliable than
  /// reconstructing an artist page from a channel's raw uploads list.
  static Future<Map<String, dynamic>?> _ytmBrowseRaw(
    String browseId, {
    String? params,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final uri = Uri.parse(
        'https://music.youtube.com/youtubei/v1/browse?key=$_ytmApiKey&prettyPrint=false',
      );
      final resp = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
        },
        body: jsonEncode({
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': _ytmClientVersion,
              'hl': 'en',
              'gl': 'IN',
            },
          },
          'browseId': browseId,
          if (params != null) 'params': params,
        }),
      ).timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (e) {
      _log('[_ytmBrowseRaw] error for "$browseId": $e');
      return null;
    }
  }
  // "Songs" search-filter param — restricts results to the Songs shelf
  // only (same as tapping the "Songs" chip on music.youtube.com), so
  // every result is a real song row with proper artist/album metadata,
  // never a video/playlist/artist/album card.
  static const String _ytmSongsFilterParam = 'EgWKAQIIAWoKEAMQBBAJEAoQBQ%3D%3D';

  /// Direct-from-phone YT Music search — no Cloudflare Worker involved.
  /// Same endpoint, same request shape, same response parsing as the
  /// worker's /api/yt-music-search route (see worker.js:
  /// ytMusicSearchRaw/parseYtMusicSearch) so this is a drop-in,
  /// equal-quality backup when the worker itself is unreachable.
  /// No timeout here by design — the caller (_searchYt) already wraps
  /// this call in its own .timeout(), so a second one here would just be
  /// a second, inconsistent race against the same clock.
  static Future<List<Song>> _searchYtMusicDirect(String query, int limit) async {
    return _searchYtMusicDirectRaw(query, limit, filterParam: _ytmSongsFilterParam);
  }

  // FIX (2026-08-14 — "Podcast bhi ekdam perfect aana chahiye"):
  // _ytmSongsFilterParam locks every direct YT Music search to the
  // "Songs" shelf ONLY — the exact same restriction as tapping the
  // "Songs" chip on music.youtube.com. YT Music's Songs shelf
  // deliberately EXCLUDES podcast episodes (they live under their own
  // separate Podcasts filter/shelf on YT Music), so every "Podcasts"
  // mood query run through the songs-only path came back empty or
  // wildly irrelevant no matter how the query text was worded — the
  // filter itself was the problem, not the query. This unfiltered
  // variant omits `params` entirely, which returns YT Music's default
  // mixed-shelf result set (songs, videos, AND podcast episodes),
  // reusing the exact same response parser since podcast episode rows
  // come back in the same musicResponsiveListItemRenderer shape songs
  // do — only used for the Podcasts mood chip; every other mood keeps
  // using the songs-filtered path above so regular music results stay
  // exactly as clean/song-only as before.
  static Future<List<Song>> _searchYtMusicDirectUnfiltered(String query, int limit) async {
    return _searchYtMusicDirectRaw(query, limit, filterParam: null);
  }

  static Future<List<Song>> _searchYtMusicDirectRaw(
    String query,
    int limit, {
    required String? filterParam,
  }) async {
    final uri = Uri.parse(
      'https://music.youtube.com/youtubei/v1/search?key=$_ytmApiKey&prettyPrint=false',
    );
    final resp = await _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
      },
      body: jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': _ytmClientVersion,
            'hl': 'en',
            'gl': 'IN',
          },
        },
        'query': query,
        if (filterParam != null) 'params': filterParam,
      }),
    );
    if (resp.statusCode != 200) return [];
    final dynamic decoded = jsonDecode(resp.body);
    // Defensive: YouTube can occasionally return a non-object body (an
    // error string/array, or a consent/interstitial page) even with a 200
    // status. Only proceed if it's the Map shape the parser expects —
    // anything else degrades to "no results" instead of the parser's
    // dynamic indexing throwing on an unexpected type.
    if (decoded is! Map) return [];
    return _parseYtMusicDirectSearch(decoded, limit);
  }

  /// Mirrors worker.js's parseYtMusicSearch() field-for-field — same
  /// tabbedSearchResultsRenderer/sectionListRenderer walk, same
  /// musicResponsiveListItemRenderer row shape, same artist/album/
  /// duration extraction — so results from this path are indistinguishable
  /// from the worker's.
  static List<Song> _parseYtMusicDirectSearch(dynamic json, int limit) {
    final out = <Song>[];
    try {
      final shelves = <dynamic>[];
      final tabs = json?['contents']?['tabbedSearchResultsRenderer']?['tabs']
              as List? ??
          const [];
      for (final tab in tabs) {
        final sections = tab?['tabRenderer']?['content']
                ?['sectionListRenderer']?['contents'] as List? ??
            const [];
        for (final section in sections) {
          if (section?['musicShelfRenderer'] != null) {
            shelves.add(section['musicShelfRenderer']);
          }
        }
      }
      if (shelves.isEmpty) {
        final sections =
            json?['contents']?['sectionListRenderer']?['contents'] as List? ??
                const [];
        for (final section in sections) {
          if (section?['musicShelfRenderer'] != null) {
            shelves.add(section['musicShelfRenderer']);
          }
        }
      }

      for (final shelf in shelves) {
        final items = shelf?['contents'] as List? ?? const [];
        for (final item in items) {
          final r = item?['musicResponsiveListItemRenderer'];
          if (r == null) continue;

          final videoId = r['playlistItemData']?['videoId'] ??
              r['overlay']?['musicItemThumbnailOverlayRenderer']?['content']
                  ?['musicPlayButtonRenderer']?['playNavigationEndpoint']
                  ?['watchEndpoint']?['videoId'];
          if (videoId == null || videoId.toString().isEmpty) continue;

          final flexColumns = r['flexColumns'] as List? ?? const [];
          final title = flexColumns.isNotEmpty
              ? (flexColumns[0]?['musicResponsiveListItemFlexColumnRenderer']
                          ?['text']?['runs']?[0]?['text'] ??
                      '')
                  .toString()
              : '';
          if (title.isEmpty) continue;

          final subRuns = flexColumns.length > 1
              ? (flexColumns[1]?['musicResponsiveListItemFlexColumnRenderer']
                      ?['text']?['runs'] as List? ??
                  const [])
              : const [];
          final artistRuns = subRuns.where((run) {
            final pageType = run?['navigationEndpoint']?['browseEndpoint']
                ?['browseEndpointContextSupportedConfigs']
                ?['browseEndpointContextMusicConfig']?['pageType'];
            return pageType == 'MUSIC_PAGE_TYPE_ARTIST';
          }).toList();
          final artistSource =
              artistRuns.isNotEmpty ? artistRuns : subRuns.take(1).toList();
          final artist = artistSource
              .map((r2) => (r2?['text'] ?? '').toString())
              .where((s) => s.isNotEmpty)
              .join(', ');
          // NEW ("search mein song ka artist bhi aana chahiye, tap karne
          // layak"): grab the FIRST artist run's real channelId (browseId)
          // straight from the same browseEndpoint pageType check used to
          // build artistRuns above — this is YouTube's own stable per-
          // channel id, exactly what ArtistScreen/fetchArtist need to open
          // the artist's real YT channel with zero extra network round-trip
          // just to resolve a name. Only the primary/first artist is kept
          // (a song with multiple featured artists still opens the main one).
          final firstArtistChannelId = artistRuns.isNotEmpty
              ? (artistRuns.first?['navigationEndpoint']?['browseEndpoint']
                      ?['browseId'] ??
                  '')
                  .toString()
              : '';

          dynamic albumRun;
          for (final run in subRuns) {
            final pageType = run?['navigationEndpoint']?['browseEndpoint']
                ?['browseEndpointContextSupportedConfigs']
                ?['browseEndpointContextMusicConfig']?['pageType'];
            if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') { albumRun = run; break; }
          }
          final album = (albumRun?['text'] ?? '').toString();

          dynamic durationRun;
          for (final run in subRuns) {
            final t = (run?['text'] ?? '').toString();
            if (RegExp(r'^\d+:\d{2}$').hasMatch(t)) { durationRun = run; break; }
          }
          final durationText = (durationRun?['text'] ?? '').toString();
          int? durationSec;
          if (durationText.isNotEmpty) {
            final parts = durationText.split(':');
            if (parts.length == 2) {
              final mins = int.tryParse(parts[0]);
              final secs = int.tryParse(parts[1]);
              if (mins != null && secs != null) durationSec = mins * 60 + secs;
            }
          }

          final thumbs = r['thumbnail']?['musicThumbnailRenderer']
                  ?['thumbnail']?['thumbnails'] as List? ??
              const [];
          final best = thumbs.isNotEmpty ? thumbs.last : null;
          var thumbnail = (best?['url'] ?? '').toString();
          if (thumbnail.isNotEmpty) {
            thumbnail =
                thumbnail.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w544-h544');
          }

          out.add(Song(
            id: videoId.toString(),
            title: _cleanText(title),
            artist: _cleanText(artist, collapseJukeboxTitle: false).isNotEmpty
                ? _cleanText(artist, collapseJukeboxTitle: false)
                : 'Unknown',
            album: _cleanText(album),
            artworkUrl: thumbnail,
            streamUrl: null,
            duration: durationSec,
            source: SongSource.youtube,
            // Same trustworthy-by-construction sentinel _searchYtMusic
            // uses — this came from YT Music's curated Songs shelf, not
            // the open video index, so isPremiumQuality() should treat it
            // identically to a verified-popular upload.
            viewCount: 1000000,
            artistChannelId: firstArtistChannelId.isNotEmpty ? firstArtistChannelId : null,
          ));
          if (out.length >= limit) return out;
        }
      }
    } catch (e) {
      _log('[_parseYtMusicDirectSearch] parse error: $e');
    }
    return out;
  }

  // Calls the Worker's YT Music search proxy and maps its clean JSON
  // straight into Song objects. Mirrors _songFromYtVideo's shape exactly
  // (same fields, same source enum) so every downstream consumer — dedup,
  // recommendation scoring, song tiles, the full player — needs zero
  // changes to handle these results.
  static Future<List<Song>> _searchYtMusic(String query, int limit) async {
    // NOTE (production recheck): this hits ONLY the CF Worker's
    // /api/yt-music-search — it does NOT need its own internal fallback to
    // the direct no-worker path, because its only caller, _searchYt() (see
    // above), already fires this AND _searchYtMusicDirect() in TRUE
    // PARALLEL and takes whichever answers first with real results. Adding
    // a sequential worker-then-direct fallback in here as well would just
    // duplicate that direct call a second time and stack extra latency
    // behind _searchYt()'s own hard 3.2s ceiling for no benefit — the
    // "worker slow → still fast, still real YT results" guarantee already
    // lives one level up, where it can react in parallel instead of after
    // the fact.
    //
    // Fast-skip: if the worker route has failed recently, don't spend up to
    // 5s discovering that again on every keystroke — return empty
    // immediately (the sibling _searchYtMusicDirect() call in _searchYt()
    // still covers the query) instead of waiting out a doomed request.
    // Self-heals after 20s (see _YtSearchHealth.markFailure).
    if (_YtSearchHealth.isLikelyDown) return [];
    try {
      final uri = Uri.parse(
        '$_saavn/api/yt-music-search?query=${Uri.encodeComponent(query)}&limit=$limit',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) { _YtSearchHealth.markFailure(); return []; }
      final data = jsonDecode(resp.body);
      if (data['success'] != true) { _YtSearchHealth.markFailure(); return []; }
      final results = (data['data']?['results'] as List?) ?? [];
      final songs = results
          .map<Song>((r) {
            final rawArtist = _cleanText((r['artist'] ?? '').toString(), collapseJukeboxTitle: false);
            // FIX ("search mein artist tap na hona" — worker leg was
            // dropping this field): the Worker's parseYtMusicSearch
            // already computes and sends artistChannelId in its JSON
            // (see worker.js), but this mapper never read it, so any
            // search result answered by the worker leg of _searchYt()'s
            // race (which wins almost every time — single fast edge
            // call vs a cold InnerTube call from the phone) came back
            // with artistChannelId: null and no tappable artist chip.
            // _parseYtMusicDirectSearch (the direct-Dart leg) already
            // mapped this correctly — this brings the worker leg to
            // parity with it.
            final rawArtistChannelId = (r['artistChannelId'] ?? '').toString();
            return Song(
              id: (r['videoId'] ?? '').toString(),
              title: _cleanText((r['title'] ?? '').toString()),
              // FIX: YT Music's artist run isn't always present (a handful
              // of results only carry album/duration in the second flex
              // column) — an empty artist here would render as a blank/
              // awkward chip in song_tile.dart and full_player_screen.dart
              // (both special-case 'Unknown', not ''). Falls back to the
              // same sentinel every other source in this file already
              // uses so downstream widgets treat it identically.
              artist: rawArtist.isNotEmpty ? rawArtist : 'Unknown',
              album: _cleanText((r['album'] ?? '').toString()),
              artworkUrl: _upgradeYtThumbnail((r['image'] ?? '').toString()),
              streamUrl: null,
              duration: r['duration'] is int ? r['duration'] as int : null,
              source: SongSource.youtube,
              artistChannelId: rawArtistChannelId.isNotEmpty ? rawArtistChannelId : null,
              // FIX (critical — was silently emptying every home-feed
              // section and quick-search YT slot): RecommendationEngine.
              // isPremiumQuality() hard-rejects ANY SongSource.youtube
              // song with viewCount == null (see recommendation_engine.
              // dart) — that gate exists to filter out raw/unverified
              // YouTube search results, but these songs already came from
              // YT Music's own curated "Songs" catalog (real releases
              // only, not the open video index), so they're trustworthy
              // by construction. A sentinel comfortably above
              // _minViewsForPremiumFeed keeps every one of the 8 call
              // sites in this file that gate on isPremiumQuality() (home
              // feed sections, quick-search merge, related-songs,
              // auto-queue, dedup) treating these exactly like a
              // verified-popular upload instead of dropping them all.
              viewCount: 1000000,
            );
          })
          .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
          .toList();
      if (songs.isNotEmpty) {
        _YtSearchHealth.markSuccess();
      }
      // Empty-but-200 (query genuinely has no YT Music hits) shouldn't
      // count as a route failure — only mark down on real HTTP/parse
      // errors above, so a rare/niche query doesn't wrongly trip the
      // cooldown for the NEXT (unrelated) query.
      return songs;
    } catch (e) {
      _log('[_searchYtMusic] Error: $e');
      _YtSearchHealth.markFailure();
      return [];
    }
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
      while (videos.length < limit * 2 && pagesFetched < 6) { // 4->6 pages pro level
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

  // ===========================================================================
  // YOUTUBE PLAYLIST IMPORT — pull songs from a public YouTube/YT Music
  // playlist URL or bare ID, same as fetchSaavnPlaylistById does for Saavn.
  // ===========================================================================
  //
  // Accepts either a bare playlist ID or a full YouTube/YouTube Music
  // playlist URL (watch?v=...&list=..., playlist?list=..., music.youtube.com
  // equivalents) — extracts the `list` param the same way a person would
  // paste a link they copied from the YouTube app share sheet.
  //
  // Reuses _songFromYtVideo (same title/artist _cleanText + thumbnail +
  // viewCount mapping every other YT-sourced song in this file goes
  // through) so playlist songs get identical clean-title treatment to
  // search results — no separate/uncleaned path introduced here.
  //
  // Quality gate is intentionally looser than search's isPremiumQuality
  // view-count floor: a person importing a specific playlist has already
  // curated it themselves (it's not an open-ended recommendation surface
  // the way search/home are), so an unofficial-channel song with modest
  // views shouldn't be silently dropped from a playlist they explicitly
  // chose to import. Still filters genuine junk (isLowQualityUpload,
  // isNonMusicContent) and duplicates — those signal a bad/spam upload
  // regardless of whether the user picked it deliberately.
  /// Playlist IDs that begin with these prefixes are YouTube's
  /// auto-generated Mixes/radio ("RD..." — including the personalized
  /// "RDMM..." and mood-radio "RDCLAK5uy_..." variants) or the
  /// watch-history/"my mix" pseudo-playlists. None of these have a fixed,
  /// enumerable track list — YouTube generates them on the fly per-request,
  /// so there is nothing stable to import. Detected up front so the person
  /// gets a specific, correct explanation instead of a generic failure
  /// after a wasted round-trip to YouTube.
  static bool _isYtMixPlaylistId(String id) =>
      id.startsWith('RD') || id.startsWith('UL') || id.startsWith('LM');

  static String? _extractYtPlaylistId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    // Bare ID already (YT playlist IDs are alphanumeric/-/_  and commonly
    // start with PL/OLAK5uy/RD/UU/LL/FL — but don't over-validate the
    // prefix, just accept anything that isn't a URL).
    if (!trimmed.contains('://') && !trimmed.contains('.')) return trimmed;
    try {
      final uri = Uri.parse(trimmed);
      final listParam = uri.queryParameters['list'];
      if (listParam != null && listParam.isNotEmpty) return listParam;
    } catch (_) {
      // fall through to null below
    }
    return null;
  }

  /// Single retry with a short backoff for transient failures (flaky
  /// mobile network, momentary YouTube rate-limit) — matches the pattern
  /// already used for Saavn cold-start hosts elsewhere in this file.
  /// Only retries once: a second consecutive failure is treated as a
  /// real error, not worth stalling the import dialog further for.
  static Future<List<Video>> _fetchPlaylistVideosWithRetry(
      String playlistId, int limit) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final videos = await _yt.playlists
            .getVideos(playlistId)
            .take(limit)
            .toList()
            .timeout(const Duration(seconds: 20));
        return videos;
      } catch (e) {
        _log('[fetchYtPlaylistSongs] attempt ${attempt + 1} failed: $e');
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }
        rethrow;
      }
    }
    return const [];
  }

  // FIX (2026-08-11 — "Couldn't import that playlist" on genuinely valid
  // PL... links): this used to go straight to youtube_explode_dart's
  // client-side HTML scraping, which fails unpredictably whenever
  // YouTube tweaks its page markup — the exact failure in the screenshot
  // report (a real PL playlist rejected with a generic notFound error).
  //
  // Now tries the Cloudflare Worker's /api/yt-playlist route FIRST — that
  // calls YT Music's own internal browse API (WEB_REMIX client, same
  // approach already proven reliable for /api/yt-music-search), which is
  // JSON and versioned instead of scraped HTML. youtube_explode_dart
  // remains as the fallback if the worker route errors or times out, so
  // this is zero-regression: worst case behaves exactly as before.
  // ═══════════════════════════════════════════════════════════════════
  // "PLAYLISTS FOR YOU" — category-based song cards for the home row.
  //
  // REWRITTEN (2026-08-14 — "worker rehne do lekin ye dart wala api bhe
  // laga do, kisi bhe data jaldi aaye wahi aa jaye aur play ke liye
  // source ready hai hi" + "har mood ke andar 5-8 alag sub-category
  // cards ho, jaisa purana row dikhta tha"): each mood chip
  // (Bollywood/90s/Trending/etc) maps to 6 sub-category queries
  // (_kMoodSubQueries below) — e.g. Bollywood -> Romance/Party/Sad/
  // Workout/Classic/New Releases — so selecting a chip still fills the
  // row with several distinct cards, not one giant tile.
  //
  // Each sub-category's songs are fetched by racing BOTH sources at
  // once — the Cloudflare Worker's /api/yt-music-search route AND a
  // direct-from-phone YT Music InnerTube call (same public WEB_REMIX
  // endpoint _searchYtMusicDirect already uses for normal song search,
  // no Worker involved). Whichever answers first with a real
  // (non-empty) result wins that card; the loser keeps running
  // harmlessly in the background and its result is discarded. All 6
  // sub-category fetches themselves also run in parallel, so the whole
  // row fills at roughly the speed of whichever single sub-category is
  // slowest, not their sum.
  //
  // Each card is a plain list of Song objects — not a playlist id.
  // That removes the old two-step "fetch card -> tap -> import
  // playlist -> maybe fails" flow entirely: there's nothing left to
  // import, the songs are already fully resolved the moment the card
  // exists. Tapping a card opens MixScreen with `songs` already in
  // hand — same as every other mix/playlist tile in this app.
  static Future<List<YtHomePlaylistCard>> fetchYtMusicHomePlaylists({
    int limit = 8,
    String? mood,
    List<String>? excludeIds,
  }) async {
    final subQueries = _kMoodSubQueries[mood] ?? _kMoodSubQueries[null]!;
    final exclude = (excludeIds ?? const []).toSet();
    const songsPerCard = 30;
    // See _raceSongSources' isPodcastQuery doc comment: the Podcasts
    // mood needs a different race shape (skip Saavn, skip the
    // Songs-only YT filter) since podcast episodes are structurally
    // excluded from every other mood's normal music-search sources.
    final isPodcastMood = mood == 'podcasts';

    final cardFutures = subQueries.take(limit).map((sub) async {
      final songs = await _raceSongSources(
        sub.query,
        limit: songsPerCard + exclude.length,
        isPodcastQuery: isPodcastMood,
      );
      final cleaned = songs.where((s) => s.id.isNotEmpty).toList();
      final fresh = cleaned.where((s) => !exclude.contains(s.id)).toList();
      final finalSongs = (fresh.length >= 10 ? fresh : cleaned).take(songsPerCard).toList();
      if (finalSongs.isEmpty) return null;
      return YtHomePlaylistCard(
        id: 'mood_${mood ?? "all"}_${sub.id}',
        title: sub.title,
        subtitle: 'Playlist',
        artworkUrl: finalSongs
            .firstWhere((s) => s.artworkUrl.isNotEmpty, orElse: () => finalSongs.first)
            .artworkUrl,
        songs: finalSongs,
      );
    });

    final results = await Future.wait(cardFutures);
    final cards = results.whereType<YtHomePlaylistCard>().toList();

    if (cards.isNotEmpty) {
      final shownIds = <String>[];
      for (final c in cards) {
        shownIds.addAll(c.songs.map((s) => s.id));
      }
      unawaited(HomePlaylistHistory.recordShown(mood, shownIds));
    }

    return cards;
  }

  // First-non-empty-wins race across independent sources: the Worker's
  // YT-search route, a direct-from-phone YT Music InnerTube call, and
  // JioSaavn's own search API. Saavn added (2026-08-14) as a third
  // source — it's JioSaavn's own catalog (not YouTube reuploads), so
  // results come back as one clean canonical entry per song instead of
  // the same track appearing under several different channel/reupload
  // titles the way YT search results sometimes do, AND it's typically
  // the fastest of the three for Bollywood/Hindi queries specifically
  // (official catalog lookup, no InnerTube client-simulation overhead).
  // Whichever source answers first with real (non-empty) results wins;
  // the others keep running harmlessly in the background and are
  // discarded.
  //
  // [isPodcastQuery] (2026-08-14 — "Podcast bhi ekdam perfect aana
  // chahiye"): Saavn's catalog is music-only — it will never have
  // podcast episodes, so racing it for a podcast query just burns a
  // network call for a guaranteed-empty result. The Worker's
  // /api/yt-music-search route AND the normal direct YT path both hard-
  // code YT Music's "Songs"-only filter, which explicitly EXCLUDES
  // podcast episodes (they live under YT Music's own separate Podcasts
  // shelf) — so both of those would also reliably come back empty/
  // irrelevant for a podcast query specifically, no matter the query
  // wording. When true: skips Saavn entirely and swaps the direct YT
  // path for _searchYtMusicDirectUnfiltered (no Songs-only restriction,
  // so podcast episode rows actually come through). The Worker path is
  // still raced alongside it (harmless — it'll likely just lose/settle
  // empty for this case) so a future worker update that adds podcast
  // support gets picked up automatically without another app change.
  static Future<List<Song>> _raceSongSources(
    String query, {
    required int limit,
    bool isPodcastQuery = false,
  }) async {
    final completer = Completer<List<Song>>();
    var pending = isPodcastQuery ? 2 : 3;

    void settle(List<Song> songs) {
      if (completer.isCompleted) return;
      if (songs.isNotEmpty) {
        completer.complete(songs);
      } else {
        pending--;
        if (pending == 0 && !completer.isCompleted) completer.complete(const []);
      }
    }

    unawaited(
      _searchYtMusic(query, limit)
          .timeout(const Duration(seconds: 6), onTimeout: () => const [])
          .then(settle, onError: (_) => settle(const [])),
    );
    unawaited(
      (isPodcastQuery
              ? _searchYtMusicDirectUnfiltered(query, limit)
              : _searchYtMusicDirect(query, limit))
          .timeout(const Duration(seconds: 6), onTimeout: () => const [])
          .then(settle, onError: (_) => settle(const [])),
    );
    if (!isPodcastQuery) {
      unawaited(
        // allowMultiPage: false — this is a race for the FASTEST first
        // usable page, not a deep fetch; walking multiple Saavn pages
        // here would add latency for zero benefit since MixScreen's own
        // pull-to-refresh is what handles "more songs" for an opened
        // category, not this initial race.
        _searchSaavn(query, limit: limit, allowMultiPage: false)
            .timeout(const Duration(seconds: 5), onTimeout: () => const [])
            .then(settle, onError: (_) => settle(const [])),
      );
    }

    return completer.future;
  }

  static const Map<String?, List<_MoodSubQuery>> _kMoodSubQueries = {
    null: [
      _MoodSubQuery('top_global', 'Top Songs Global', 'top hits global playlist'),
      _MoodSubQuery('trending_now', 'Trending Now', 'trending songs now'),
      _MoodSubQuery('top100_india', 'Top 100 India', 'top 100 India songs'),
      _MoodSubQuery('new_releases', 'New Releases', 'new song releases'),
      _MoodSubQuery('viral_hits', 'Viral Hits', 'viral hit songs'),
      _MoodSubQuery('feel_good', 'Feel Good Mix', 'feel good happy songs'),
    ],
    'bollywood': [
      _MoodSubQuery('bw_romance', 'Bollywood Romance', 'bollywood romantic songs'),
      _MoodSubQuery('bw_party', 'Bollywood Party', 'bollywood party dance songs'),
      _MoodSubQuery('bw_sad', 'Bollywood Sad', 'bollywood sad songs'),
      _MoodSubQuery('bw_classic', 'Bollywood Classics', 'bollywood classic old songs'),
      _MoodSubQuery('bw_new', 'New Bollywood', 'new bollywood songs'),
      _MoodSubQuery('bw_item', 'Bollywood Dance', 'bollywood item dance songs'),
    ],
    'nineties': [
      _MoodSubQuery('90s_bw', '90s Bollywood', '90s bollywood hits'),
      _MoodSubQuery('90s_romance', '90s Love Songs', '90s bollywood romantic songs'),
      _MoodSubQuery('90s_dance', '90s Dance Hits', '90s bollywood dance songs'),
      _MoodSubQuery('90s_sad', '90s Sad Songs', '90s bollywood sad songs'),
      _MoodSubQuery('90s_english', '90s English Hits', '90s english pop hits'),
      _MoodSubQuery('90s_rock', '90s Rock', '90s rock hits'),
    ],
    'trendingIndia': [
      _MoodSubQuery('trend_now', 'Trending Now', 'trending India songs now'),
      _MoodSubQuery('trend_viral', 'Viral in India', 'viral India songs'),
      _MoodSubQuery('trend_charts', 'India Charts', 'India top charts songs'),
      _MoodSubQuery('trend_new', 'New & Trending', 'new trending India songs'),
      _MoodSubQuery('trend_regional', 'Regional Hits', 'trending regional India songs'),
      _MoodSubQuery('trend_reels', 'Reels Trending', 'trending reels songs India'),
    ],
    'podcasts': [
      _MoodSubQuery('pod_top', 'Top Podcasts', 'popular podcast'),
      _MoodSubQuery('pod_comedy', 'Comedy', 'comedy podcast'),
      _MoodSubQuery('pod_news', 'News & Talk', 'news talk podcast'),
      _MoodSubQuery('pod_stories', 'True Stories', 'true crime podcast'),
      _MoodSubQuery('pod_business', 'Business', 'business podcast'),
      _MoodSubQuery('pod_hindi', 'Hindi Podcasts', 'hindi podcast'),
    ],
    'relax': [
      _MoodSubQuery('relax_chill', 'Chill Mix', 'chill relax songs'),
      _MoodSubQuery('relax_lofi', 'Lo-fi', 'lofi chill beats'),
      _MoodSubQuery('relax_acoustic', 'Acoustic', 'acoustic relax songs'),
      _MoodSubQuery('relax_piano', 'Piano Calm', 'calm piano instrumental'),
      _MoodSubQuery('relax_sleep', 'Sleep Sounds', 'sleep relaxing music'),
      _MoodSubQuery('relax_nature', 'Nature Sounds', 'nature ambient relax music'),
    ],
    'workout': [
      _MoodSubQuery('gym_pump', 'Gym Pump Up', 'gym workout pump up songs'),
      _MoodSubQuery('gym_cardio', 'Cardio Mix', 'cardio workout songs'),
      _MoodSubQuery('gym_hiit', 'HIIT Energy', 'hiit workout energy songs'),
      _MoodSubQuery('gym_running', 'Running Mix', 'running workout songs'),
      _MoodSubQuery('gym_strength', 'Strength Training', 'strength training gym songs'),
      _MoodSubQuery('gym_bollywood', 'Bollywood Workout', 'bollywood gym workout songs'),
    ],
    'energize': [
      _MoodSubQuery('energy_hype', 'Hype Mix', 'hype energetic songs'),
      _MoodSubQuery('energy_dance', 'Dance Energy', 'energetic dance songs'),
      _MoodSubQuery('energy_edm', 'EDM Boost', 'edm energetic songs'),
      _MoodSubQuery('energy_rock', 'Rock Energy', 'energetic rock songs'),
      _MoodSubQuery('energy_bollywood', 'Bollywood Energy', 'energetic bollywood songs'),
      _MoodSubQuery('energy_morning', 'Morning Boost', 'morning energy motivation songs'),
    ],
    'romantic': [
      _MoodSubQuery('rom_bollywood', 'Bollywood Romance', 'bollywood romantic love songs'),
      _MoodSubQuery('rom_english', 'English Love Songs', 'english romantic love songs'),
      _MoodSubQuery('rom_wedding', 'Wedding Romance', 'wedding romantic songs'),
      _MoodSubQuery('rom_slow', 'Slow Romance', 'slow romantic songs'),
      _MoodSubQuery('rom_duets', 'Love Duets', 'romantic duet songs'),
      _MoodSubQuery('rom_valentine', 'Valentine Mix', 'valentine love songs'),
    ],
    'party': [
      _MoodSubQuery('party_bollywood', 'Bollywood Party', 'bollywood party songs'),
      _MoodSubQuery('party_edm', 'EDM Party', 'edm party dance songs'),
      _MoodSubQuery('party_club', 'Club Hits', 'club dance hits'),
      _MoodSubQuery('party_wedding', 'Wedding Party', 'wedding party dance songs'),
      _MoodSubQuery('party_punjabi', 'Punjabi Party', 'punjabi party songs'),
      _MoodSubQuery('party_english', 'English Party', 'english party dance songs'),
    ],
    'focus': [
      _MoodSubQuery('focus_study', 'Study Focus', 'study focus concentration music'),
      _MoodSubQuery('focus_instrumental', 'Instrumental', 'instrumental focus music'),
      _MoodSubQuery('focus_lofi', 'Lo-fi Focus', 'lofi study focus beats'),
      _MoodSubQuery('focus_classical', 'Classical Focus', 'classical focus music'),
      _MoodSubQuery('focus_ambient', 'Ambient Focus', 'ambient focus concentration music'),
      _MoodSubQuery('focus_work', 'Deep Work', 'deep work focus music'),
    ],
    'sad': [
      _MoodSubQuery('sad_bollywood', 'Bollywood Sad', 'bollywood sad emotional songs'),
      _MoodSubQuery('sad_breakup', 'Breakup Songs', 'breakup sad songs'),
      _MoodSubQuery('sad_english', 'English Sad Songs', 'english sad emotional songs'),
      _MoodSubQuery('sad_slow', 'Slow Sad', 'slow sad emotional songs'),
      _MoodSubQuery('sad_heartbreak', 'Heartbreak Mix', 'heartbreak sad songs'),
      _MoodSubQuery('sad_alone', 'Lonely Nights', 'lonely sad night songs'),
    ],
  };


  // ═══════════════════════════════════════════════════════════════════
  // MIX REFRESH — powers pull-to-refresh inside a "Playlists For You" mix
  // screen (see MixScreen's enableRefresh flag). Spotify/YT Music both
  // APPEND fresh related songs on refresh rather than replacing the
  // list — replacing would yank the scroll position and whatever the
  // user is currently near, which reads as unstable rather than
  // premium. Caller is responsible for appending the returned songs to
  // the existing list (never overwriting it).
  //
  // `existingVideoIds` is sent as `exclude` so the Worker filters out
  // anything already in the list server-side — the client never has to
  // de-dup a mixed batch itself and never sees an immediate on-screen
  // repeat right after a refresh.
  // ═══════════════════════════════════════════════════════════════════
  // UPDATED (2026-08-14): now uses the same _raceSongSources pattern as
  // fetchYtMusicHomePlaylists — Worker's /api/mix-refresh AND a direct
  // YT Music search both fire, whichever answers first with real
  // results wins. Worker path takes priority when it wins since its
  // /api/mix-refresh route does its own exclude-filtering server-side;
  // the direct path's own results are filtered against existingVideoIds
  // client-side below so both paths behave identically regardless of
  // which one actually answers first.
  static Future<List<Song>> fetchMixRefreshSongs({
    required String seed,
    required List<String> existingVideoIds,
    int limit = 15,
  }) async {
    if (seed.trim().isEmpty) return const [];
    final excludeSet = existingVideoIds.toSet();

    final completer = Completer<List<Song>>();
    var pending = 2;
    void settle(List<Song> songs) {
      if (completer.isCompleted) return;
      final fresh = songs.where((s) => !excludeSet.contains(s.id)).toList();
      if (fresh.isNotEmpty) {
        completer.complete(fresh);
      } else {
        pending--;
        if (pending == 0 && !completer.isCompleted) completer.complete(const []);
      }
    }

    unawaited(
      _fetchMixRefreshSongsViaWorker(seed: seed, existingVideoIds: existingVideoIds, limit: limit)
          .timeout(const Duration(seconds: 7), onTimeout: () => const [])
          .then(settle, onError: (_) => settle(const [])),
    );
    unawaited(
      _searchYtMusicDirect(seed, limit + excludeSet.length)
          .timeout(const Duration(seconds: 6), onTimeout: () => const [])
          .then(settle, onError: (_) => settle(const [])),
    );

    return completer.future;
  }

  static Future<List<Song>> _fetchMixRefreshSongsViaWorker({
    required String seed,
    required List<String> existingVideoIds,
    int limit = 15,
  }) async {
    try {
      final excludeParam = existingVideoIds.isEmpty
          ? ''
          : '&exclude=${Uri.encodeQueryComponent(existingVideoIds.join(','))}';
      final uri = Uri.parse(
        '$_saavn/api/mix-refresh?seed=${Uri.encodeComponent(seed)}&limit=$limit$excludeParam',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body);
      if (data['success'] != true) return const [];
      final results = (data['data']?['results'] as List?) ?? [];
      // Same mapping shape as _searchYtMusic — see that function's FIX
      // comments for why artist falls back to 'Unknown' and why
      // viewCount is seeded above the premium-quality threshold; kept
      // consistent here so these songs behave identically downstream
      // (song tiles, full player, queue, dedup).
      return results
          .map<Song>((r) {
            final rawArtist = _cleanText((r['artist'] ?? '').toString(), collapseJukeboxTitle: false);
            final rawArtistChannelId = (r['artistChannelId'] ?? '').toString();
            return Song(
              id: (r['videoId'] ?? '').toString(),
              title: _cleanText((r['title'] ?? '').toString()),
              artist: rawArtist.isNotEmpty ? rawArtist : 'Unknown',
              album: _cleanText((r['album'] ?? '').toString()),
              artworkUrl: _upgradeYtThumbnail((r['image'] ?? '').toString()),
              streamUrl: null,
              duration: r['duration'] is int ? r['duration'] as int : null,
              source: SongSource.youtube,
              viewCount: 1000000,
              artistChannelId: rawArtistChannelId.isNotEmpty ? rawArtistChannelId : null,
            );
          })
          .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
          .toList();
    } catch (e) {
      _log('[_fetchMixRefreshSongsViaWorker] error: $e');
      return const [];
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // YT MUSIC HOME ARTIST CARDS — /api/yt-music-home-artists on the Worker.
  //
  // Same FEmusic_home shelf data fetchYtMusicHomePlaylists reads, just the
  // artist entries instead of the playlist ones — see the Worker's
  // parseYtMusicHomeArtistShelves() for the split. channelId (YouTube's
  // own stable per-artist id) is kept as-is and fed straight into
  // ArtistSimple.id by fetchHomeArtistsCombined() below, so artist-chip
  // navigation and list keys are anchored to a real, collision-proof
  // identifier instead of a name string.
  //
  // TIMEOUT TIGHTENED (10s -> 4s) + DIRECT FALLBACK ADDED
  // ("worker slow ho tab bhi production-level artist data ready rahe"):
  // fetchHomeArtistsCombined() below runs this concurrently with the
  // Saavn-sourced fetchHomeArtists() via Future.wait — that call only
  // finishes as slow as its SLOWEST leg, so a 10s worker timeout meant a
  // fully healthy Saavn leg could still sit blocked for up to 10s behind
  // a struggling Worker. Cut to 4s so a slow/degraded Worker fails fast
  // instead of stalling the whole home-artist load.
  //
  // On top of the shorter timeout, this now also has its own fallback
  // that never depends on the Worker at all: if the Worker call times
  // out, errors, or comes back empty/degraded, _fetchYtMusicArtistsDirect
  // below hits YT Music's InnerTube search API directly from the client
  // (same _ytmApiKey already used by _resolveYtChannelId) using a small
  // set of high-recognition seed queries. This mirrors the Worker's own
  // search-seed fallback logic, just runs client-side so a Worker outage
  // or slowdown can never take real YT artist data off the home screen —
  // only total loss of internet would.
  // ═══════════════════════════════════════════════════════════════════
  static Future<List<YtHomeArtist>> fetchYtMusicHomeArtists(
      {int limit = 12}) async {
    try {
      final uri = Uri.parse('$_saavn/api/yt-music-home-artists?limit=$limit');
      final resp = await http.get(uri).timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) {
        _log('[fetchYtMusicHomeArtists] HTTP ${resp.statusCode}, falling back to direct YT');
        return _fetchYtMusicArtistsDirect(limit: limit);
      }
      final data = jsonDecode(resp.body);
      if (data['success'] != true) {
        return _fetchYtMusicArtistsDirect(limit: limit);
      }
      final results = (data['data']?['results'] as List?) ?? [];
      final parsed = results
          .map<YtHomeArtist?>((r) {
            final channelId = (r['channelId'] ?? '').toString();
            final name = _cleanText((r['name'] ?? '').toString());
            final image = (r['image'] ?? '').toString();
            if (channelId.isEmpty || name.isEmpty || image.isEmpty) return null;
            return YtHomeArtist(channelId: channelId, name: name, imageUrl: image);
          })
          .whereType<YtHomeArtist>()
          .toList();

      // Worker responded but had nothing usable (e.g. its own degraded
      // static-fallback list, or a genuinely empty shelf) — try direct
      // as a second attempt rather than accepting a thin/generic result.
      if (parsed.isEmpty || data['degraded'] == true) {
        final direct = await _fetchYtMusicArtistsDirect(limit: limit);
        return direct.isNotEmpty ? direct : parsed;
      }
      return parsed;
    } catch (e) {
      _log('[fetchYtMusicHomeArtists] error: $e, falling back to direct YT');
      return _fetchYtMusicArtistsDirect(limit: limit);
    }
  }

  /// Direct-from-client YT Music artist fetch, bypassing the Worker
  /// entirely. Used when the Worker is slow, erroring, or degraded, so
  /// the home screen's artist row always has a real, working data path
  /// and never depends on a single backend being healthy.
  ///
  /// Hits YT Music's WEB_REMIX search InnerTube endpoint directly (same
  /// API key/client the Worker itself uses) for a handful of
  /// high-recognition seed artists, then pulls channelId/name/thumbnail
  /// straight out of each song result's artist run — same extraction
  /// approach as the Worker's own search-seed fallback.
  static Future<List<YtHomeArtist>> _fetchYtMusicArtistsDirect(
      {int limit = 12}) async {
    const seeds = [
      'Arijit Singh',
      'Diljit Dosanjh',
      'Sony Music India',
      'T-Series',
      'Shreya Ghoshal',
      'Anirudh Ravichander',
      'Pritam',
      'AP Dhillon',
    ];

    try {
      // REWRITTEN on _findRenderers + _artistRunsInSubtitle (production-
      // grade, shape-agnostic): the old version hand-walked one specific
      // path (tabbedSearchResultsRenderer → sectionListRenderer →
      // musicShelfRenderer) with a flat sectionListRenderer as its only
      // fallback — any other shape (a card, a nested carousel) silently
      // produced zero artists for that seed. This now finds every song
      // row anywhere in the response regardless of wrapper, and pulls the
      // MUSIC_PAGE_TYPE_ARTIST-tagged run out of each row's subtitle —
      // exactly the same extraction _artistRunsInSubtitle already does
      // for real search results, so there's one implementation of "how do
      // we get an artist out of a song row" instead of two drifting apart.
      final responses = await Future.wait(seeds.map(
        (q) => _ytmSearchRaw(q, params: _ytmSongsFilterParam,
            timeout: const Duration(seconds: 4)),
      ));

      final seen = <String>{};
      final out = <YtHomeArtist>[];

      for (final json in responses) {
        if (json == null) continue;
        for (final item in _findRenderers(json, 'musicResponsiveListItemRenderer')) {
          for (final run in _artistRunsInSubtitle(item)) {
            if (!seen.add(run.channelId)) continue;
            final image = _ytmThumbnailUrl(item);
            if (image.isEmpty) continue;
            out.add(YtHomeArtist(
                channelId: run.channelId, name: _cleanText(run.name), imageUrl: image));
            if (out.length >= limit) return out;
          }
        }
      }
      return out;
    } catch (e) {
      _log('[_fetchYtMusicArtistsDirect] error: $e');
      return const [];
    }
  }

  // RACE (2026-08-14 — "playlist click pe ekdam fast open hona
  // chahiye, worker ka wait khatam"): this used to be strictly
  // sequential — wait up to 10s for the worker, and ONLY if that fails
  // does the youtube_explode_dart scraping fallback even start (which
  // itself can take up to ~40s worst case: 2 attempts × 20s timeout +
  // backoff). That sequential stacking is exactly what made a card tap
  // feel slow/stuck on a bad network.
  //
  // Now both sources fire in parallel and whichever resolves first with
  // a usable (non-empty) song list wins — mirrors the same race pattern
  // already used for the home-row cards fetch. The loser is left to
  // finish in the background and its result is simply discarded.
  static Future<List<Song>> fetchYtPlaylistSongs(String playlistUrlOrId,
      {int limit = 200}) async {
    final playlistId = _extractYtPlaylistId(playlistUrlOrId);
    if (playlistId == null || playlistId.isEmpty) {
      throw const YtPlaylistImportException(YtPlaylistImportError.invalidLink);
    }
    if (_isYtMixPlaylistId(playlistId)) {
      throw const YtPlaylistImportException(YtPlaylistImportError.isMix);
    }

    final completer = Completer<List<Song>>();
    var pending = 2;
    Object? lastError;

    void settleIfBest(List<Song> songs, String source, {Object? error}) {
      if (completer.isCompleted) return;
      if (songs.isNotEmpty) {
        _log('[fetchYtPlaylistSongs] winner: $source (${songs.length})');
        completer.complete(songs);
      } else {
        if (error != null) lastError = error;
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          completer.complete(const []);
        }
      }
    }

    unawaited(
      _fetchYtPlaylistViaWorker(playlistId, limit)
          .timeout(const Duration(seconds: 8), onTimeout: () => null)
          .then(
        (result) => settleIfBest(result ?? const [], 'worker'),
        onError: (e) {
          _log('[fetchYtPlaylistSongs] worker path error: $e');
          settleIfBest(const [], 'worker', error: e);
        },
      ),
    );

    unawaited(
      _fetchPlaylistVideosWithRetry(playlistId, limit)
          .timeout(const Duration(seconds: 12), onTimeout: () => const [])
          .then(
        (videos) => settleIfBest(
            videos.map(_songFromYtVideo).toList(), 'explode_dart'),
        onError: (e) {
          _log('[fetchYtPlaylistSongs] explode_dart path error: $e');
          settleIfBest(const [], 'explode_dart', error: e);
        },
      ),
    );

    final result = await completer.future;
    if (result.isEmpty) {
      // Both sources genuinely came back empty/errored — surface a
      // real error instead of silently returning nothing, same
      // contract as before (caller shows the "couldn't import"
      // snackbar on any thrown YtPlaylistImportException/other error).
      if (lastError is YtPlaylistImportException) throw lastError!;
      throw const YtPlaylistImportException(YtPlaylistImportError.notFound);
    }
    return _dedupAndFilterPlaylistSongs(result);
  }

  // Calls the Worker's /api/yt-playlist route and maps its JSON straight
  // into Song objects — same row shape and mapping as _searchYtMusic
  // above. Returns null (not an empty list) on any failure so the caller
  // can tell "worker had nothing to say, try explode_dart" apart from
  // "worker confirmed this playlist is genuinely empty/private", which
  // is surfaced as a real error below instead of silently falling
  // through to a second, redundant fetch attempt.
  static Future<List<Song>?> _fetchYtPlaylistViaWorker(
      String playlistId, int limit) async {
    try {
      final uri = Uri.parse(
        '$_saavn/api/yt-playlist?id=${Uri.encodeComponent(playlistId)}&limit=$limit',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 404) {
        // Worker confirmed empty/private/not-found — a real, final
        // answer, not a transient failure to fall back from.
        throw const YtPlaylistImportException(YtPlaylistImportError.empty);
      }
      if (resp.statusCode != 200) {
        _log('[fetchYtPlaylistSongs] worker route HTTP ${resp.statusCode}');
        return null;
      }
      // SMOOTHNESS FIX: playlist responses can carry up to `limit` (200-500)
      // songs — decoding that much JSON synchronously on the UI isolate can
      // cost a visible frame hitch on a low-end device right at the moment
      // the user is watching the import progress. jsonDecode is a pure,
      // isolate-safe function (no closures/state), so `compute()` ships it
      // to a background isolate and only the parsed result crosses back —
      // same result, no UI-thread cost for the decode itself.
      final data = await compute(jsonDecode, resp.body);
      if (data['success'] != true) return null;
      final results = (data['data']?['results'] as List?) ?? [];
      if (results.isEmpty) return null;
      return results.map<Song>((r) {
        final rawArtist = _cleanText((r['artist'] ?? '').toString(), collapseJukeboxTitle: false);
        return Song(
          id: (r['videoId'] ?? '').toString(),
          title: _cleanText((r['title'] ?? '').toString()),
          artist: rawArtist.isNotEmpty ? rawArtist : 'Unknown',
          album: _cleanText((r['album'] ?? '').toString()),
          artworkUrl: _upgradeYtThumbnail((r['image'] ?? '').toString()),
          streamUrl: null,
          duration: r['duration'] is int ? r['duration'] as int : null,
          source: SongSource.youtube,
          viewCount: null,
        );
      }).toList();
    } on YtPlaylistImportException {
      rethrow;
    } catch (e) {
      _log('[fetchYtPlaylistSongs] worker route error: $e');
      return null;
    }
  }

  // Shared dedup + quality gate for playlist-import songs, regardless of
  // whether they came from the worker route or the explode_dart
  // fallback. Same looser-than-search gate as before (see comment above
  // the class for why): still filters genuine junk (isLowQualityUpload,
  // isNonMusicContent) and duplicates, doesn't apply the view-count floor
  // since a person importing a specific playlist has already curated it.
  static List<Song> _dedupAndFilterPlaylistSongs(List<Song> songs) {
    final seenIds = <String>{};
    final seenTitles = <String>{};
    final result = <Song>[];
    for (final s in songs) {
      if (s.id.isEmpty || s.title.isEmpty) continue;
      if (!seenIds.add(s.id)) continue;
      if (RecommendationEngine.isLowQualityUpload(s.title)) continue;
      if (RecommendationEngine.isNonMusicContent(s)) continue;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) continue;
      result.add(s);
    }

    if (result.isEmpty) {
      // Every video was filtered out by the quality/dedup gates above —
      // distinct from "YouTube gave us nothing" (empty) so this can be
      // messaged differently later if needed; for now it maps to the
      // same empty-playlist copy since the end state is the same.
      throw const YtPlaylistImportException(YtPlaylistImportError.empty);
    }
    return result;
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
    // FIX: these variants were previously written with an escaped `\$query`
    // — a literal string, not real interpolation — so every "variant" here
    // silently searched the literal text "$query audio" etc. instead of
    // "<actual query> audio". Only the plain `query` entry ever did real
    // work; the other four calls were wasted round-trips returning
    // near-empty results. Fixed to real interpolation so this section
    // actually gets the widened pool the comment always claimed.
    final variants = <String>{
      query,
      '$query audio',
      '$query official',
      '$query lyrics',   // zyada YT results
      '$query hd songs', // high quality uploads
    };
    final results = await Future.wait(
      variants.map((q) => _searchYt(q, limit: 60)),
    );
    // Deep multi-page pass for extra raw volume, same reasoning as
    // _saavnSectionV4's YouTube-only rewrite — needed for a realistic
    // shot at a genuine 100-song shelf after quality filtering/dedup.
    final deepVideos = await _searchYtPaged(query, 100).catchError((_) => <Video>[]);
    final deepSongs = deepVideos.map(_songFromYtVideo).toList();

    final seenIdsRaw = <String>{};
    final ytSongs = <Song>[];
    for (final list in [...results, deepSongs]) {
      for (final s in list) {
        if (seenIdsRaw.add(s.id)) ytSongs.add(s);
      }
    }
    if (ytSongs.isEmpty) return null;
    final seenIds = <String>{};
    final seenTitles = <String>{};
    final merged = <Song>[];
    for (final s in ytSongs) {
      if (merged.length >= _kHomeSectionTarget) break;
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
        artist:     _cleanText(v.author, collapseJukeboxTitle: false),
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

  // FIX ("thumbnails look non-premium / low quality for a lot of YT songs"):
  // youtube_explode_dart's maxResUrl/standardResUrl are DOCUMENTED as "not
  // always available" — but the field is always a non-empty STRING (a
  // client-constructed URL guess), never actually empty when the real
  // image is missing. YouTube's CDN then serves a 200 OK response for
  // that URL anyway, just with a tiny ~120x90 grey placeholder image
  // instead of a 404 — so the old `isNotEmpty` check always passed and
  // silently accepted the placeholder as if it were the real thumbnail,
  // for every video that lacks a true maxres/standard image (a large
  // share of catalog — older uploads, auto-thumbnailed videos, etc).
  // highResUrl (480x360 'hqdefault') is the safe tier: YouTube generates
  // it for virtually every video that exists, so it's never a placeholder
  // — and at 480x360 it's still sharp enough for a song tile/cover, far
  // better than a blurry grey box. Skip straight to the guaranteed tier
  // instead of gambling on maxres/standard.
  static String _bestThumbnail(dynamic t) {
    for (final url in [t.highResUrl, t.mediumResUrl, t.lowResUrl]) {
      if (url != null && url.toString().isNotEmpty) return url.toString();
    }
    return '';
  }

  // FIX ("Saavn ko backup mein daala — thumbnail HD aani chahiye har
  // jagah"): the CF worker's /api/yt-music-search, /api/mix-refresh, and
  // playlist-import routes all forward YT Music's raw InnerTube thumbnail
  // URL as-is — whatever low/medium size InnerTube happened to return by
  // default (often a small square crop meant for a compact list row, not
  // a full-screen player background). The DIRECT-Dart search leg
  // (_parseYtMusicDirectSearch) already fixes this for its own results by
  // rewriting the URL's =w###-h### size suffix up to 544x544 — but that
  // upgrade only lived in that one function, so any song that came back
  // via the worker leg instead (which wins the _searchYt() race almost
  // every time — a single fast edge call beats a cold on-device InnerTube
  // call) kept whatever small thumbnail the worker forwarded, with
  // nothing to catch it. Centralizing the same upgrade here and applying
  // it at every raw worker-image call site means it's no longer leg-
  // dependent — a song looks the same (full HD art) regardless of which
  // of the two parallel paths actually answered first.
  static String _upgradeYtThumbnail(String url) {
    if (url.isEmpty) return url;
    return url.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w544-h544');
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
  //
  // FIX (2026-08 — "Saavn song silently becomes YT a few seconds after
  // tapping"): this used to be a SINGLE 3s HEAD attempt — any timeout,
  // even from ordinary network jitter or the proxy's extra hop being
  // briefly slow to answer HEAD specifically (not GET), was treated
  // exactly the same as a genuinely dead URL and discarded, sending the
  // caller straight to the YT fallback even though the Saavn URL itself
  // was perfectly fine. That single-shot check was too trigger-happy for
  // a proxied URL, which has one more hop than a direct CDN URL and is
  // more prone to a one-off slow response, not a broken one. Now: two
  // attempts (3s, then 5s) before giving up, so one slow/dropped
  // response doesn't sink an otherwise-good URL.
  static Future<bool> _isUrlAlive(String url) async {
    Future<bool> attempt(Duration timeout) async {
      try {
        final uri = Uri.parse(url);
        final head = await _client.head(uri).timeout(timeout);
        if (head.statusCode >= 200 && head.statusCode < 400) return true;
        if (head.statusCode == 405 || head.statusCode == 403) {
          // PERFORMANCE (2026-07-02): shrunk from 1024→256 bytes — same
          // liveness check, less wasted transfer per resolve.
          final ranged = await _client
              .get(uri, headers: {'Range': 'bytes=0-255'})
              .timeout(timeout);
          return ranged.statusCode == 200 || ranged.statusCode == 206;
        }
        return false;
      } catch (_) {
        return false;
      }
    }

    if (await attempt(const Duration(seconds: 3))) return true;
    // First attempt failed/timed out — could be a one-off network blip
    // rather than a truly dead URL. Give it one more, slightly longer,
    // chance before this URL gets discarded and the caller falls back
    // to a different source entirely.
    return attempt(const Duration(seconds: 5));
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
      final cachedUrl = _streamCache.get(cacheKey);
      if (cachedUrl != null) {
        _log('[resolve] Cache HIT: "${song.title}"');
        return cachedUrl;
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
      final cachedUrl = _streamCache.get(cacheKey);
      if (cachedUrl == null) {
        _log('[resolve] Pre-fetched Saavn URL (proxied): "${song.title}"');
        _writeStreamCache(cacheKey, song.streamUrl!);
        return song.streamUrl;
      }
      return cachedUrl;
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
            // FIX (2026-08): previously discarded here immediately and
            // fell straight to YT even on a one-off slow HEAD response.
            // But an unconditional fresh retry (new URL + full liveness
            // recheck) added up to ~15s more in the worst case where
            // Saavn is genuinely down — the user would sit there far
            // longer waiting for a song that was never going to play
            // from Saavn anyway, which is worse than the swap itself.
            // Bounding the whole "one more try" step to 6s total caps
            // the worst case at roughly _retry(2)+6s instead of
            // _retry(2)+~15s, while still giving a real network blip a
            // fair second chance to land on a different mirror/host via
            // the parallel race inside _saavnStreamById.
            _log('[resolve] Saavn URL for "${song.title}" failed liveness check — one bounded retry before YT');
            url = await () async {
              final retryUrl = await _saavnStreamById(song.id, title: song.title, artist: song.artist);
              if (retryUrl != null && await _isUrlAlive(retryUrl)) return retryUrl;
              return null;
            }().timeout(const Duration(seconds: 6), onTimeout: () => null);
            _log('[resolve] Saavn bounded retry for "${song.title}": ${url != null ? "OK" : "FAILED"}');
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
  // YT STREAM RESOLUTION (updated 2026-08-15 — reflects actual current
  // architecture; the old "v5 Bugatti" comment below described a
  // Piped/Invidious blast-race design that was removed 2026-07-06 and no
  // longer matches this code, which was actively misleading for anyone
  // debugging playback speed).
  //
  // Single source of truth: the Cloudflare Worker, which itself already
  // runs a multi-client YouTube resolution chain server-side (see
  // worker.js resolveYtStream — WEB_EMBEDDED/PoToken → ANDROID_VR → iOS →
  // TV bypass → Piped, all with its own internal budget). The Dart side's
  // job is just to reach that Worker fast and reliably:
  //
  //   _workerYtStream races the Worker's two independent routes
  //   (/api/yt-proxy and /api/yt-stream) against each other in parallel
  //   via _blastRace — first one to return a verified-playable URL wins,
  //   6s timeout each. _ytStreamById is a thin wrapper with no further
  //   retry layer (a second attempt at the same endpoint the race just
  //   tried adds latency, not resilience).
  //
  // Result: a healthy Worker resolves in well under 2s (whichever route
  // is faster); a genuinely down Worker is now confirmed dead in ~6s
  // instead of the old 58s worst-case sequential chain.
  // ===========================================================================
  // SPEED FIX (2026-08-15 — same pass as _workerYtStream above): this
  // wrapper used to bolt ANOTHER full sequential retry layer (a third,
  // separate /api/yt-proxy call, 30s timeout) on top of _workerYtStream
  // already having tried both Worker routes internally. Stacked with the
  // old 16s+12s inside _workerYtStream, the true worst-case chain for one
  // song tap was 16+12+30 = 58 SECONDS, entirely sequential — nowhere
  // near "Spotify/YT grade fast," and bad enough to make a genuinely
  // playable song feel broken if the Worker was just having a slow
  // moment rather than actually being down.
  //
  // _workerYtStream already races BOTH Worker routes in parallel now
  // (see its own fix comment) and reports Worker health accurately via
  // _WorkerHealth.markAlive()/markDead() — a second bespoke retry here,
  // hitting the exact same /api/yt-proxy endpoint this function already
  // tried moments ago, added latency without adding any real chance of
  // success: if the Worker was down for the race above, it's down for
  // this retry too. Removed entirely. maintenanceMode still short-
  // circuits to skip a doomed attempt outright.
  static Future<String?> _ytStreamById(String videoId) async {
    if (_WorkerHealth.maintenanceMode) {
      _log('[ytStreamById] Worker maintenance mode active — skipping resolve for $videoId');
      return null;
    }
    final url = await _workerYtStream(videoId);
    if (url == null) {
      _log('[ytStreamById] Worker unreachable for $videoId — this means the '
          'Cloudflare Worker itself is down. Check the Worker deployment.');
    }
    return url;
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
  // SPEED FIX (2026-08-15 — "YT songs ekdam Spotify/YT grade fast aane
  // chahiye, makkan jaisa smooth"): PRODUCTION BUG — /api/yt-proxy and
  // /api/yt-stream used to run strictly SEQUENTIALLY (await proxy fully
  // fail/timeout, THEN start stream), even though they're two independent
  // routes on the SAME Worker answering the SAME question ("give me a
  // playable URL for this video"). There is zero dependency between them —
  // nothing about the direct-URL route needs the proxy route to have
  // finished first. Sequential timeouts stacked to a genuinely bad worst
  // case (16s + 12s = 28s here alone, before _ytStreamById's own extra
  // sequential retry layer on top — see that function's fix below).
  //
  // Fix: fire both at once and take whichever answers first via
  // _blastRace (already used elsewhere in this file for exactly this
  // shape of race). Every existing check — content-type/body-length sniff
  // for the proxy path, device-side _isUrlAlive() verification for the
  // direct-URL path — is preserved exactly as before, just running in
  // parallel instead of one-after-another. A healthy Worker now answers
  // in whichever single route is faster (typically well under 2s), not
  // the sum of both.
  //
  // Timeouts also tightened: 16s/12s was generous enough to make a user
  // stare at a spinner far longer than a "genuinely dead Worker" ever
  // needs to be confirmed. 6s per route is still comfortable headroom —
  // /api/yt-proxy only needs to open a connection and return the first
  // ranged chunk of an already-resolved stream, which is fast even on a
  // cold edge — while capping the worst case per attempt at ~6s instead
  // of 16s.
  static Future<String?> _workerYtStream(String videoId) async {
    const routeTimeout = Duration(seconds: 6);

    Future<String?> tryProxy() async {
      try {
        final proxyUrl = '$_worker/api/yt-proxy?id=$videoId';
        final probe = await _client
            .get(Uri.parse(proxyUrl), headers: {'Range': 'bytes=0-255'})
            .timeout(routeTimeout);
        if (probe.statusCode == 200 || probe.statusCode == 206) {
          final ct = (probe.headers['content-type'] ?? '').toLowerCase();
          final looksAudio = ct.contains('audio') || ct.contains('octet') ||
              ct.contains('mp4') || ct.contains('mpeg') || ct.contains('webm');
          if (looksAudio || probe.bodyBytes.length > 128) {
            _log('[worker] /api/yt-proxy OK for $videoId (IP-safe path)');
            return proxyUrl;
          }
        }
        _log('[worker] /api/yt-proxy probe failed for $videoId '
            '(status=${probe.statusCode})');
        return null;
      } catch (e) {
        _log('[worker] /api/yt-proxy failed for $videoId: $e');
        return null;
      }
    }

    Future<String?> tryDirect() async {
      try {
        final res = await _client
            .get(Uri.parse('$_worker/api/yt-stream?id=$videoId'))
            .timeout(routeTimeout);
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
        return url;
      } catch (e) {
        _log('[worker] /api/yt-stream failed for $videoId: $e');
        return null;
      }
    }

    final result = await _blastRace([tryProxy, tryDirect]);
    if (result != null) {
      _WorkerHealth.markAlive();
    } else {
      _WorkerHealth.markDead();
    }
    return result;
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



  // ===========================================================================
  // SAAVN STREAM RESOLUTION
  // ===========================================================================
  static Future<String?> _saavnStreamById(
    String songId, {
    String title = '',
    String artist = '',
    List<String>? qualityOrder,
  }) async {
    // 2026-07-17 FIX #3: jiosaavn-op v2 has a working, reliable id-based
    // lookup — /api/songs/:id — confirmed via direct curl returning clean
    // non-DRM downloadUrl[] entries in under a second. Try this FIRST,
    // since it's a real id lookup (no title-search guesswork needed).
    // Goes through _saavnNodeHosts (not a single hardcoded host) so that
    // adding a second Node-family mirror to that list automatically covers
    // stream resolution too, not just search.
    //
    // FUTURE-PROOFING: raced in parallel, not looped sequentially — only
    // one host is configured today so this makes no timing difference yet,
    // but the moment a second mirror is added to _saavnNodeHosts (as the
    // comment above invites), a sequential loop would silently reintroduce
    // the exact cold-start slowness bug fixed in the fallback loop below
    // (a dead/cold host eating its full timeout before the next host even
    // gets tried). Racing from day one means this stays fast automatically
    // as more mirrors get added later.
    Future<String?> tryNodeHostById(String host) async {
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
              return _extractSaavnStreamUrl(songData, qualityOrder: qualityOrder);
            }
          }
        }
      } catch (e) {
        _log('[saavnById] $host error for $songId: $e');
      }
      return null;
    }

    final nodeFutures = [for (final host in _saavnNodeHosts) tryNodeHostById(host)];
    final nodeCompleter = Completer<String?>();
    var nodeRemaining = nodeFutures.length;
    void onNodeDone(String? r) {
      if (nodeCompleter.isCompleted) return;
      if (r != null && r.isNotEmpty) {
        nodeCompleter.complete(r);
        return;
      }
      nodeRemaining--;
      if (nodeRemaining == 0 && !nodeCompleter.isCompleted) {
        nodeCompleter.complete(null);
      }
    }
    for (final f in nodeFutures) {
      f.then(onNodeDone).catchError((_) => onNodeDone(null));
    }
    final nodeResult = await nodeCompleter.future;
    if (nodeResult != null) return nodeResult;

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

    // SPEED/RELIABILITY FIX ("cold start mai song play hi nahi hota" —
    // root cause): this used to try _saavnPrimary, then _saavnSecondary,
    // then _saavn ONE AT A TIME with `await` inside a for-loop — each with
    // its own 8s timeout. On a genuine cold start (Render free-tier hosts
    // asleep), a dead/slow host doesn't fail fast, it EATS its full 8s
    // timeout before the loop even tries the next host. Worst case: 3
    // hosts x 8s = 24s sequential, and this whole function is itself
    // wrapped in _retry(attempts: 2) one level up in _doResolve — so a
    // genuinely cold moment could take up to ~48s+ before this step alone
    // gives up, which reads as "tapped the song and nothing happened."
    // Racing every host in parallel and taking the first usable answer
    // (same pattern _searchSaavn already uses successfully) bounds the
    // wait by the timeout of whichever host answers FIRST, not the sum of
    // every host's timeout — a cold host no longer blocks a warm one from
    // answering quickly.
    Future<String?> tryResultRouteById(String base) async {
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
            return _onrenderStreamUrl(match, qualityOrder: qualityOrder) ??
                _extractSaavnStreamUrl(match, qualityOrder: qualityOrder);
          }
        }
      } catch (e) {
        _log('[saavnById] $base error for $songId: $e');
      }
      return null;
    }

    final fallbackFutures = [
      for (final base in [_saavnPrimary, _saavnSecondary, _saavn])
        tryResultRouteById(base),
    ];
    final fallbackCompleter = Completer<String?>();
    var fallbackRemaining = fallbackFutures.length;
    void onFallbackDone(String? r) {
      if (fallbackCompleter.isCompleted) return;
      if (r != null && r.isNotEmpty) {
        fallbackCompleter.complete(r);
        return;
      }
      fallbackRemaining--;
      if (fallbackRemaining == 0 && !fallbackCompleter.isCompleted) {
        fallbackCompleter.complete(null);
      }
    }
    for (final f in fallbackFutures) {
      f.then(onFallbackDone).catchError((_) => onFallbackDone(null));
    }
    return fallbackCompleter.future;
  }

  static String? _onrenderStreamUrl(Map<String, dynamic> j, {List<String>? qualityOrder}) {
    // If a specific quality ladder was requested (download flow), prefer the
    // v2-style downloadUrl[] list FIRST — it's the only shape that actually
    // carries multiple bitrate options to choose from. The flat '320kbps'
    // field below is a single fixed tier with no ladder, so honoring a
    // caller's quality preference means checking the ladder-aware path
    // before falling back to that fixed field.
    if (qualityOrder != null) {
      final viaLadder = _extractSaavnStreamUrl(j, qualityOrder: qualityOrder);
      if (viaLadder != null) return viaLadder;
    }
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
    return _extractSaavnStreamUrl(j, qualityOrder: qualityOrder);
  }

  static String? _extractSaavnStreamUrl(Map<String, dynamic> song, {List<String>? qualityOrder}) {
    final downloads = song['downloadUrl'] as List?;
    if (downloads != null && downloads.isNotEmpty) {
      for (final q in qualityOrder ?? AudioPrefs.qualityOrder()) {
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
      // BUGFIX (download quality mismatch): this used to fall through to
      // `downloads.last` whenever none of the caller's requested tiers
      // matched — but `downloads.last` is frequently the LOWEST bitrate
      // entry (e.g. 12kbps), not a reasonable "next best" choice. A user
      // who selected 320kbps and whose song only listed up to 96kbps was
      // silently handed a 12kbps file with no indication anything had
      // downgraded. Now: only fall through to the highest-bitrate entry
      // actually present in the list (by parsing each tier's kbps number),
      // so an unmatched request still gets the best real option available
      // for that song — never the worst one.
      final withKbps = downloads
          .whereType<Map>()
          .where((d) => (d['url'] as String?)?.startsWith('http') == true)
          .map((d) => (
                kbps: int.tryParse((d['quality'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '')) ?? -1,
                url: d['url'] as String,
              ))
          .where((e) => e.kbps >= 0)
          .toList();
      if (withKbps.isNotEmpty) {
        withKbps.sort((a, b) => b.kbps.compareTo(a.kbps));
        final best = withKbps.first;
        AudioPrefs.lastResolvedKbps = best.kbps;
        return _proxiedSaavnUrl(best.url);
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
    // ✅ LIGHTWEIGHT: Automatic cleanup handled by LightweightStreamCache
    _streamCache.set(key, url);
  }

  static void invalidateStream(Song song) {
    _streamCache.invalidate('${song.source.name}:${song.id}');
  }

  static void clearExpiredCache() {
    _streamCache.cleanup();
    _searchCache.removeWhere((_, v) => v.isExpired);
    _quickSearchCache.removeWhere((_, v) => v.isExpired);
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
          if (_streamCache.get(cacheKey) != null) {
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
  // PREWARM — resolve a YT song's stream URL the moment it becomes visible
  // on screen (e.g. from a SongTile/home card), BEFORE the user taps, so the
  // real device-side cache (_streamCache below) already has it ready by tap
  // time instead of starting cold.
  //
  // FIX (2026-08-13 — dead network call found on speed audit): this
  // previously called `$_worker/api/prewarm?id=...`, a route that has never
  // existed on the Cloudflare Worker (confirmed against worker.js — no
  // /api/prewarm handler, no KV namespace binding for it to warm even if it
  // did exist). Every single call therefore always 404'd, was silently
  // swallowed by catchError, and re-fired on every re-scroll past that same
  // song this session (`_prewarmedIds.remove` on failure = "allowed to
  // retry", so a guaranteed-fail request kept costing a live HTTP round-trip
  // every time). Pure wasted battery/data with zero benefit — the opposite
  // of lightweight.
  //
  // The ACTUAL cache that matters for "instant tap" is the client-side
  // `_streamCache` (Dart in-memory map) used by resolveStreamUrl() and read
  // by prefetchQueue()/prefetchNext() above — there is no separate
  // server-side cache to warm. Fix: prewarm now calls resolveStreamUrl()
  // itself (fire-and-forget, never awaited by the caller) so a song visible
  // on screen actually gets its real URL resolved and cached client-side
  // ahead of the tap — same benefit the old comment described, achieved
  // through the cache that actually exists. resolveStreamUrl() already has
  // its own in-flight de-dup (_pendingResolutions) and cache-hit short
  // circuit, so calling it here is safe even if prefetchQueue() is
  // resolving the same song at the same time — no duplicate network calls.
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

    // Also skip if URL already in local Dart cache — nothing to warm
    final cacheKey = 'youtube:${song.id}';
    if (_streamCache.get(cacheKey) != null) return;

    if (_prewarmedIds.length > 1000) _prewarmedIds.clear(); // prevent unbounded growth
    _prewarmedIds.add(song.id);
    resolveStreamUrl(song)
        .then((_) => _log('[prewarm] resolved & cached: "${song.title}"'))
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
    artist = _cleanText(artist, collapseJukeboxTitle: false);

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
    // RAISED alongside fetchHomeArtistsCombined's YT-side limit — see
    // that function's comment for why (artist strip was looking
    // Saavn-only / too thin after merge/dedup at the old 12+12 caps).
    final picked = deduped.take(20).toList();

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

  // ═══════════════════════════════════════════════════════════════════
  // COMBINED HOME ARTISTS — YT Music (real shelf data, one browse call,
  // stable channelId) merged with the existing Saavn-sourced
  // fetchHomeArtists() (hand-picked pool + per-artist search/thumbnail
  // scrape). Runs both concurrently so total latency is max(), not sum(),
  // of the two — this never gets slower than the slower of the two
  // sources alone.
  //
  // DEDUPE / UNIQUE KEY: ArtistSimple.id is what home_screen.dart's
  // ListView.builder keys each _ArtistChip on. YT artists carry a real
  // channelId (format "UC...", globally unique per YouTube channel);
  // Saavn artists carry their own Saavn artist id, or '' when the
  // thumbnail-only fallback path had no id to return (see
  // fetchHomeArtists' "YouTube thumbnail fallback" branch above). An
  // empty '' id is not unique — two different no-id Saavn entries would
  // collide on the same ValueKey('') and crash the list (duplicate GlobalKey
  // territory) or silently only render one of them. Every artist here is
  // re-keyed through _uniqueArtistKey() below so the final list always has
  // guaranteed-distinct ids regardless of which source (or lack of a
  // source id) it came from.
  //
  // Name-based dedupe (case-insensitive) happens BEFORE that re-keying so
  // the same artist appearing in both YT's real shelf and Saavn's
  // hardcoded pool (e.g. "Arijit Singh" in both) shows once, preferring
  // the YT entry — real shelf art tends to be fresher/higher-res than the
  // Saavn search-result or YouTube-thumbnail-scrape fallback.
  static Future<List<ArtistSimple>> fetchHomeArtistsCombined() async {
    // SPEED FIX ("artist home page pe nahi aa rahe / bahut late aate hai"):
    // this used to `await Future.wait([fetchYtMusicHomeArtists(...),
    // fetchHomeArtists()])` — i.e. block on BOTH legs before returning
    // anything. fetchYtMusicHomeArtists is one fast Worker call (~4s hard
    // cap). fetchHomeArtists is a completely different shape of slow: it
    // fires 20 SEPARATE per-artist lookups concurrently, and EACH one can
    // itself cascade through Node hosts -> Flask hosts -> a YouTube page
    // scrape fallback, each leg with its own 6s timeout — so a handful of
    // unlucky/cold-tier hosts among those 20 can keep the whole combined
    // call blocked for 10-15+ seconds even though the YT leg alone was
    // ready in under 4. That's the actual "artists late/missing on home"
    // bug: Musify/SimpMusic-level home screens never wait on a batch of
    // 20 individual network calls before showing a single artist chip.
    //
    // Fix: return as soon as the fast YT leg resolves. The slow Saavn pool
    // is still kicked off here (fire-and-forget, not awaited) purely to
    // warm/refresh its own on-disk cache for next launch — the actual
    // progressive top-up path home_screen.dart now uses instead of this
    // blocking function is fetchHomeArtistsStreaming() below.
    unawaited(fetchHomeArtists().catchError((_) => <ArtistSimple>[]));

    final ytArtists = await fetchYtMusicHomeArtists(limit: 40);
    final seenNames = <String>{};
    final merged = <ArtistSimple>[];
    for (final a in ytArtists) {
      final key = a.name.trim().toLowerCase();
      if (key.isEmpty || !seenNames.add(key)) continue;
      merged.add(ArtistSimple(id: 'yt_${a.channelId}', name: a.name, imageUrl: a.imageUrl));
    }
    return merged;
  }

  /// STREAMING VERSION ("Musify/SimpMusic jaisa fast") — used by
  /// home_screen.dart instead of the blocking fetchHomeArtistsCombined()
  /// above. Calls `onUpdate` twice: once as soon as the fast YT leg
  /// resolves (near-instant, single Worker call), and again once the slow
  /// 20-artist Saavn pool finishes merging in — so the artist strip can
  /// paint real content almost immediately instead of staying empty for
  /// however long the slowest of 20 individual searches takes.
  static Future<void> fetchHomeArtistsStreaming(
    void Function(List<ArtistSimple> artists) onUpdate,
  ) async {
    final seenNames = <String>{};
    final merged = <ArtistSimple>[];
    void addAll(Iterable<ArtistSimple> items) {
      for (final a in items) {
        final key = a.name.trim().toLowerCase();
        if (key.isEmpty || !seenNames.add(key)) continue;
        merged.add(a);
      }
    }

    List<YtHomeArtist> ytArtists = const [];
    try {
      ytArtists = await fetchYtMusicHomeArtists(limit: 40);
    } catch (_) {}
    addAll(ytArtists.map((a) => ArtistSimple(id: 'yt_${a.channelId}', name: a.name, imageUrl: a.imageUrl)));
    onUpdate(_uniqueIds(merged));

    List<ArtistSimple> saavnArtists = const [];
    try {
      saavnArtists = await fetchHomeArtists();
    } catch (_) {}
    addAll(saavnArtists);
    onUpdate(_uniqueIds(merged));
  }

  // FINAL SAFETY NET: guarantee every id in the merged list is unique,
  // independent of what each source promised. YT entries are already
  // unique via their real channelId; only Saavn's possible '' ids (or
  // any unexpected upstream duplicate id) can still collide at this
  // point — give any duplicate/empty id a synthetic-but-stable
  // fallback derived from its position, so home_screen.dart's
  // ValueKey-per-chip logic never sees two identical ids in one list.
  static List<ArtistSimple> _uniqueIds(List<ArtistSimple> list) {
    final seenIds = <String>{};
    final out = List<ArtistSimple>.from(list);
    for (var i = 0; i < out.length; i++) {
      final a = out[i];
      if (a.id.isEmpty || !seenIds.add(a.id)) {
        final fallbackId = 'artist_$i';
        seenIds.add(fallbackId);
        out[i] = ArtistSimple(id: fallbackId, name: a.name, imageUrl: a.imageUrl);
      }
    }
    return out;
  }

  // ===========================================================================
  // ARTIST PAGE
  // ===========================================================================

  // ═══════════════════════════════════════════════════════════════════
  // YOUTUBE-PRIMARY ARTIST RESOLUTION
  // ("YT se artist ekdam perfect aaye, Saavn sirf tab jab YT channel na
  // mile") — resolveArtistId now tries a real YouTube channel FIRST for
  // every name lookup, only falling back to Saavn's artist id when no YT
  // channel can be found at all. The returned id is prefixed 'yt_' for a
  // YouTube channel or 'saavn_' for a Saavn artist id, mirroring the
  // ArtistSimple.id convention fetchHomeArtistsCombined() already
  // established — fetchArtist() below switches on that prefix.
  // ═══════════════════════════════════════════════════════════════════

  /// Resolve an artist name straight to a real YouTube channelId using YT
  /// Music's own WEB_REMIX search (same InnerTube endpoint/key
  /// _searchYtMusicDirectRaw uses), filtered to the "Artists" shelf so a
  /// same-named song/album never gets picked instead of the channel.
  static Future<String?> _resolveYtChannelId(String name) async {
    if (name.trim().isEmpty) return null;
    // Delegates to searchArtists' own shape-agnostic parser (row cards,
    // grid cards, and the single "Top result" card are all handled there)
    // instead of maintaining a second, narrower hand-rolled walk that can
    // drift out of sync and miss shapes the other one already covers.
    final matches = await _searchArtistsAttempt(name, 1,
        useArtistFilter: true, timeout: const Duration(seconds: 6));
    if (matches.isNotEmpty) {
      return matches.first.id.startsWith('yt_')
          ? matches.first.id.substring(3)
          : matches.first.id;
    }
    final fallback = await _searchArtistsAttempt(name, 1,
        useArtistFilter: false, timeout: const Duration(seconds: 6));
    if (fallback.isEmpty) return null;
    return fallback.first.id.startsWith('yt_')
        ? fallback.first.id.substring(3)
        : fallback.first.id;
  }

  /// NEW ("search mein artist bhi aaye" — dedicated Artists row): searches
  /// YT Music's Artists shelf directly for the query and returns up to
  /// [limit] matching artist cards (channelId + name + thumbnail). Used by
  /// search_screen.dart to show a horizontal "Artists" row above song
  /// results whenever the query text itself matches one or more artists —
  /// same WEB_REMIX endpoint/params as _resolveYtChannelId but returns
  /// every match instead of just the first.
  ///
  /// TIGHTENED + RETRY ADDED ("ekdam fast aur kabhi khaali na jaaye"):
  /// timeout cut 5s -> 3s since this is a live, keystroke-driven row that
  /// must never visibly lag behind the song results next to it. If the
  /// first attempt times out, errors, or the JSON shape doesn't parse
  /// (YT Music occasionally reshuffles response structure), one fast
  /// retry with a plain unfiltered query (no Artists-shelf params) is
  /// made — a general search still surfaces artist entries in its
  /// results when the top hit is an artist, so this catches cases where
  /// the dedicated Artists filter itself misfires without ever falling
  /// back to a slower or lower-quality source.
  // FIX ("artist naam type karne pe artist nahi aata" — the real root
  // cause): this param was previously a 12-zero-byte structure
  // ('Eg-KAQwIABAAGAAgACgAMABqChAEEAMQCRAFEAo%3D') that doesn't match the
  // clean single-byte-type-marker pattern every OTHER verified filter
  // param in this file uses (compare _ytmSongsFilterParam,
  // _ytmAlbumsFilterParam just below) — it was carried over from an
  // earlier, unverified source and never actually cross-checked the way
  // songs/albums were. Decoding it as raw protobuf shows it padded with
  // six extra zero-value fields that don't correspond to anything in
  // ytmusicapi's own get_search_params()/_get_param2() encoding for the
  // "artists" filter, which YT Music's real web client (and ytmusicapi,
  // the reference implementation this whole parsing approach is modeled
  // on) actually sends. Replaced with the literal param ytmusicapi
  // computes for filter="artists" (field tag 0x20 + value 1, matching
  // songs/videos/albums' own field-tag-plus-ordinal-value structure
  // family, just with the tag that specific filter chip uses) — this is
  // the single most likely fix for artists not showing up on plain-name
  // queries like "Alka Yagnik" or "Kumar Sanu".
  // RE-VERIFIED byte-for-byte (previous fix used the wrong tail — see
  // below): decoded as raw protobuf, this app's proven-working
  // _ytmSongsFilterParam has the shape [.., TAG=0x08, VALUE=1, <tail>].
  // Cross-checking each filter chip against ytmusicapi's own
  // get_search_params()/_get_param2() source shows every filter uses a
  // DIFFERENT TAG BYTE, not just a different value at the same tag —
  // songs=0x08, videos=0x10, albums=0x18, artists=0x20, playlists=0x28
  // (confirmed by decoding each filter_code in isolation). The earlier
  // artists param version here used ytmusicapi's own newer tail bytes
  // mixed with this app's older, proven header — inconsistent parentage
  // that was never actually verified end-to-end. This version instead
  // swaps ONLY the tag+value pair inside the app's own already-proven
  // songs param (same technique now also used for _ytmAlbumsFilterParam
  // below), keeping everything else byte-identical to what's confirmed
  // working in production — the safest, least speculative construction.
  static const String _ytmArtistsFilterParam = 'EgWKAQIgAWoKEAMQBBAJEAoQBQ%3D%3D';

  /// PRODUCTION-GRADE ARTIST SEARCH ("search mein artist ekdam aaye").
  ///
  /// Rewritten on top of _findRenderers (see its doc comment above) so it
  /// no longer cares whether YT Music wraps its results in
  /// musicShelfRenderer, musicCardShelfRenderer, a nested carousel, or any
  /// future shape — every musicResponsiveListItemRenderer AND every
  /// musicTwoRowItemRenderer (the card/grid shape artist results also use)
  /// anywhere in the response tree is found and read. Two attempts:
  /// Artists-filtered first (clean, artist-only results), then a fast
  /// unfiltered retry as a safety net if the filter itself returns nothing
  /// (rare, but seen when YT Music has no dedicated Artists shelf for a
  /// very niche query) — same fallback strategy as before, just backed by
  /// a parser that can't silently miss a shape.
  static Future<List<ArtistSimple>> searchArtists(String query, {int limit = 12}) async {
    if (query.trim().isEmpty) return const [];

    // SPEED FIX ("ekdam live result ke sath aana chahiye, koi lag na ho"):
    // this used to run filtered -> unfiltered -> Saavn strictly one after
    // another, each with its own up-to-5s timeout — a genuinely thin/
    // wrong-coverage query (exactly the Bollywood-artist case the Saavn
    // fallback exists for) could take 10+ seconds to resolve, which is
    // fine for a one-off submit but reads as completely broken now that
    // this also powers live-as-you-type search.
    //
    // Fix: race all three concurrently and resolve as soon as ANY of them
    // returns something usable, instead of waiting for every leg to
    // finish (even a plain Future.wait still pays for the slowest
    // failing leg). _firstNonEmpty below completes the instant a
    // non-empty result lands, preferring source-priority order (filtered
    // YT > unfiltered YT > Saavn) only when two land in the same tick;
    // it only falls through to whichever answers last if every leg comes
    // back empty.
    return _firstNonEmptyArtists([
      _searchArtistsAttempt(query, limit,
          useArtistFilter: true, timeout: const Duration(seconds: 4)),
      _searchArtistsAttempt(query, limit,
          useArtistFilter: false, timeout: const Duration(seconds: 4)),
      _searchArtistsSaavn(query, limit),
    ]);
  }

  /// Races several artist-search futures and completes with the FIRST one
  /// that resolves to a non-empty list — never waits for the slowest leg
  /// once a usable answer already exists. Falls back to whichever
  /// resolves last (even if empty) only if every leg comes back empty, so
  /// a genuine "no results anywhere" still resolves cleanly instead of
  /// hanging.
  static Future<List<ArtistSimple>> _firstNonEmptyArtists(
      List<Future<List<ArtistSimple>>> futures) async {
    final completer = Completer<List<ArtistSimple>>();
    var remaining = futures.length;
    List<ArtistSimple> lastResult = const [];
    for (final f in futures) {
      f.then((result) {
        if (completer.isCompleted) return;
        if (result.isNotEmpty) {
          completer.complete(result);
          return;
        }
        lastResult = result;
        remaining--;
        if (remaining == 0) completer.complete(lastResult);
      }).catchError((_) {
        if (completer.isCompleted) return;
        remaining--;
        if (remaining == 0) completer.complete(lastResult);
      });
    }
    return completer.future;
  }

  static Future<List<ArtistSimple>> _searchArtistsSaavn(String query, int limit) async {
    final path = '/api/search/artists?query=${Uri.encodeQueryComponent(query)}&limit=$limit';
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(hosts, path,
          isValid: (b) => b['data']?['results'] is List &&
              (b['data']['results'] as List).isNotEmpty);
      if (body == null) continue;
      final results = (body['data']['results'] as List);
      final out = <ArtistSimple>[];
      for (final r in results) {
        if (out.length >= limit) break;
        if (r is! Map) continue;
        final ba = BrowseArtist.fromSaavn(r.cast<String, dynamic>());
        if (ba.artistId.isEmpty || ba.name.isEmpty) continue;
        out.add(ArtistSimple(id: 'saavn_${ba.artistId}', name: ba.name, imageUrl: ba.imageUrl));
      }
      if (out.isNotEmpty) return out;
    }
    return const [];
  }

  static Future<List<ArtistSimple>> _searchArtistsAttempt(
      String query, int limit,
      {required bool useArtistFilter, required Duration timeout}) async {
    final decoded = await _ytmSearchRaw(
      query,
      params: useArtistFilter ? _ytmArtistsFilterParam : null,
      timeout: timeout,
    );
    if (decoded == null) return const [];

    final out = <ArtistSimple>[];
    final seen = <String>{};

    void addCandidate(String browseId, String name, String image) {
      // Same MPLA fix as _artistEndpointOf above — this is a second,
      // independent gate (not fed through _artistEndpointOf for the
      // musicCardShelfRenderer path below), so it needs the identical fix
      // or an MPLA-prefixed top-result card would pass the endpoint check
      // above and still get silently dropped right here.
      final isValidArtistId = browseId.startsWith('UC') || browseId.startsWith('MPLA');
      if (name.isEmpty || !isValidArtistId || !seen.add(browseId)) return;
      out.add(ArtistSimple(id: 'yt_$browseId', name: _cleanText(name), imageUrl: image));
    }

    // Row-shaped results (musicResponsiveListItemRenderer) — the common
    // shape for both the Artists-filtered shelf and mixed unfiltered
    // shelves. Title lives in flex column 0.
    for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
      if (out.length >= limit) return out;
      final endpoint = _artistEndpointOf(
          (item['navigationEndpoint'] as Map?)?.cast<String, dynamic>());
      if (endpoint == null) continue;
      if (!useArtistFilter && !endpoint.isArtist) continue;
      final name = _flexColumnText(item, 0);
      addCandidate(endpoint.browseId, name, _ytmThumbnailUrl(item));
    }

    // Card/grid-shaped results (musicTwoRowItemRenderer) — the shape
    // "Top result" artist cards and grid-style artist chips use; title
    // lives directly under title.runs rather than a flexColumn.
    if (out.length < limit) {
      for (final item in _findRenderers(decoded, 'musicTwoRowItemRenderer')) {
        if (out.length >= limit) return out;
        final endpoint = _artistEndpointOf(
            (item['navigationEndpoint'] as Map?)?.cast<String, dynamic>());
        if (endpoint == null) continue;
        if (!useArtistFilter && !endpoint.isArtist) continue;
        final name = ((item['title']?['runs'] as List?) ?? const [])
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .trim();
        addCandidate(endpoint.browseId, name, _ytmThumbnailUrl(item));
      }
    }

    // Single "Top result" card (musicCardShelfRenderer) — its own title
    // run carries the browseId directly rather than via a child item.
    if (out.length < limit) {
      for (final card in _findRenderers(decoded, 'musicCardShelfRenderer')) {
        if (out.length >= limit) return out;
        final titleRuns = (card['title']?['runs'] as List?) ?? const [];
        if (titleRuns.isEmpty) continue;
        final firstRun = (titleRuns.first as Map).cast<String, dynamic>();
        final endpoint = _artistEndpointOf(
            (firstRun['navigationEndpoint'] as Map?)?.cast<String, dynamic>());
        if (endpoint == null) continue;
        if (!useArtistFilter && !endpoint.isArtist) continue;
        final name = titleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .trim();
        addCandidate(endpoint.browseId, name, _ytmThumbnailUrl(card));
      }
    }

    return out;
  }

  // RE-VERIFIED, CORRECTED ("albums search production-grade"): the
  // previous version of this param was WRONG — it assumed every YT Music
  // search filter (songs/albums/artists/...) shares the same protobuf
  // field tag (0x08) and differs only by an ordinal value (1/2/3/4/5).
  // Decoding each filter in isolation against ytmusicapi's real
  // get_search_params()/_get_param2() source shows that's false: each
  // filter chip uses its OWN field tag — songs=0x08, videos=0x10,
  // albums=0x18, artists=0x20, playlists=0x28 — always paired with value
  // 1, never a shared tag with a varying ordinal. The old param
  // (tag 0x08, value 3) was therefore a nonsense combination that doesn't
  // correspond to any real filter chip, which explains why Albums search
  // results could come back inconsistent. Rebuilt using the correct
  // tag (0x18) + value (1) pair, swapped into the app's own
  // already-proven-working _ytmSongsFilterParam tail (same construction
  // now also used for _ytmArtistsFilterParam above) — every other byte
  // is one this app has already confirmed YT Music accepts.
  static const String _ytmAlbumsFilterParam = 'EgWKAQIYAWoKEAMQBBAJEAoQBQ%3D%3D';

  /// PRODUCTION-GRADE ALBUM SEARCH ("albums aaye search karne pr, ekdam
  /// Spotify jaisa"). Same _findRenderers-based, shape-agnostic approach
  /// as searchArtists — reads both row-shaped (musicResponsiveListItemRenderer)
  /// and card-shaped (musicTwoRowItemRenderer) album results, tagged by a
  /// browseId starting with "MPRE" (YT Music's real album browseId
  /// prefix — verified against ytmusicapi's own get_album() guard clause,
  /// which rejects any browseId not starting "MPRE"). Two-attempt
  /// fallback identical to searchArtists: Albums-filtered first, then a
  /// fast unfiltered retry if that comes back empty.
  static Future<List<BrowseAlbum>> searchAlbums(String query, {int limit = 12}) async {
    if (query.trim().isEmpty) return const [];

    // SPEED FIX — same reasoning and fix shape as searchArtists' race
    // above: sequential filtered -> unfiltered -> Saavn could take 10+
    // seconds worst case, which is unacceptable now that this also powers
    // live-as-you-type search. Race all three concurrently, resolve the
    // instant any one comes back with a usable (non-empty) result.
    return _firstNonEmptyAlbums([
      _searchAlbumsAttempt(query, limit,
          useAlbumFilter: true, timeout: const Duration(seconds: 4)),
      _searchAlbumsAttempt(query, limit,
          useAlbumFilter: false, timeout: const Duration(seconds: 4)),
      _searchAlbumsSaavn(query, limit),
    ]);
  }

  /// Races several album-search futures and completes with the FIRST one
  /// that resolves to a non-empty list — same "don't wait on the slowest
  /// failing leg" behavior as _firstNonEmptyArtists above.
  static Future<List<BrowseAlbum>> _firstNonEmptyAlbums(
      List<Future<List<BrowseAlbum>>> futures) async {
    final completer = Completer<List<BrowseAlbum>>();
    var remaining = futures.length;
    List<BrowseAlbum> lastResult = const [];
    for (final f in futures) {
      f.then((result) {
        if (completer.isCompleted) return;
        if (result.isNotEmpty) {
          completer.complete(result);
          return;
        }
        lastResult = result;
        remaining--;
        if (remaining == 0) completer.complete(lastResult);
      }).catchError((_) {
        if (completer.isCompleted) return;
        remaining--;
        if (remaining == 0) completer.complete(lastResult);
      });
    }
    return completer.future;
  }

  static Future<List<BrowseAlbum>> _searchAlbumsSaavn(String query, int limit) async {
    final path = '/api/search/albums?query=${Uri.encodeQueryComponent(query)}&limit=$limit';
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(hosts, path,
          isValid: (b) => b['data']?['results'] is List &&
              (b['data']['results'] as List).isNotEmpty);
      if (body == null) continue;
      final results = (body['data']['results'] as List);
      final out = <BrowseAlbum>[];
      for (final r in results) {
        if (out.length >= limit) break;
        if (r is! Map) continue;
        final album = BrowseAlbum.fromSaavn(r.cast<String, dynamic>());
        if (album.collectionId.isEmpty || album.name.isEmpty) continue;
        out.add(album);
      }
      if (out.isNotEmpty) return out;
    }
    return const [];
  }

  static Future<List<BrowseAlbum>> _searchAlbumsAttempt(
      String query, int limit,
      {required bool useAlbumFilter, required Duration timeout}) async {
    final decoded = await _ytmSearchRaw(
      query,
      params: useAlbumFilter ? _ytmAlbumsFilterParam : null,
      timeout: timeout,
    );
    if (decoded == null) return const [];

    final out = <BrowseAlbum>[];
    final seen = <String>{};

    void addCandidate(String browseId, String name, String artist, String image, String? year) {
      if (name.isEmpty || !browseId.startsWith('MPRE') || !seen.add(browseId)) return;
      out.add(BrowseAlbum(
        collectionId: browseId,
        name: _cleanText(name),
        artist: _cleanText(artist.isEmpty ? 'Various Artists' : artist),
        artworkUrl: image,
        releaseYear: year,
        isFromYoutube: true,
      ));
    }

    // Card/grid-shaped results — the shape album search results actually
    // render as (a grid of album covers), same renderer YT Music's own
    // Albums search tab uses.
    for (final card in _findRenderers(decoded, 'musicTwoRowItemRenderer')) {
      if (out.length >= limit) return out;
      final endpoint = _artistEndpointOf(
          (card['navigationEndpoint'] as Map?)?.cast<String, dynamic>());
      // Album cards use the same browseEndpoint shape as artist cards but
      // with an MPRE-prefixed id instead of UC — _artistEndpointOf only
      // gates on browseId presence for our purposes here, so read the
      // pageType separately to make sure we're not about to swallow an
      // artist/playlist card that also happens to be musicTwoRowItemRenderer.
      final browseEndpoint = (card['navigationEndpoint'] as Map?)?['browseEndpoint'];
      final pageType = browseEndpoint?['browseEndpointContextSupportedConfigs']
          ?['browseEndpointContextMusicConfig']?['pageType'];
      if (!useAlbumFilter && pageType != 'MUSIC_PAGE_TYPE_ALBUM') continue;
      final browseId = (endpoint?.browseId.isNotEmpty == true
              ? endpoint!.browseId
              : (browseEndpoint?['browseId'] ?? '').toString());
      final title = ((card['title']?['runs'] as List?) ?? const [])
          .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
          .join()
          .trim();
      // Subtitle is typically "Album • Artist • Year" — pull the artist
      // run specifically (rather than joining everything) so "Album" and
      // the bullet separators don't end up glued onto the artist name.
      //
      // REVISED (verified against ytmusicapi's parse_song_run — the
      // reference implementation's own technique for classifying a
      // subtitle run): the primary signal for "this run is an artist" is
      // that it CARRIES A navigationEndpoint (it's a clickable link to
      // that artist's page) — a plain year or the "Album"/"Single" type
      // label are never linked, only artist/album name runs are. The
      // previous version relied only on regex pattern-matching unlinked
      // text, which is a strictly weaker signal (a numeric album title or
      // an artist name that happens to read like "Single" could
      // misclassify). This checks navigationEndpoint first and only
      // falls back to the regex checks for the unlinked runs where no
      // link exists to tell artist apart from year/type-label.
      final subtitleRuns = ((card['subtitle']?['runs'] as List?) ?? const []);
      String artistName = '';
      String? year;
      for (final r in subtitleRuns) {
        if (r is! Map) continue;
        final text = (r['text'] ?? '').toString().trim();
        if (text.isEmpty || text == '•') continue;
        final hasLink = r['navigationEndpoint'] != null;
        if (hasLink) {
          // Linked run: per ytmusicapi, a navigationEndpoint here means
          // artist OR album — an MPRE-prefixed browseId on this run would
          // mean "album" (self-referential, rare in a subtitle), anything
          // else linked is the artist.
          final linkedBrowseId =
              (r['navigationEndpoint']?['browseEndpoint']?['browseId'] ?? '').toString();
          if (!linkedBrowseId.startsWith('MPRE') && artistName.isEmpty) {
            artistName = text;
          }
        } else if (RegExp(r'^(19|20)\d{2}$').hasMatch(text)) {
          year = text;
        } else if (!RegExp(r'^(Album|Single|EP)$', caseSensitive: false).hasMatch(text)) {
          // Unlinked, not a year, not the type label — plausibly still an
          // artist name YT Music rendered without a link (happens for
          // "Various Artists" compilations) — only use as a last resort
          // so a genuinely linked artist run above always wins first.
          if (artistName.isEmpty) artistName = text;
        }
      }
      addCandidate(browseId, title, artistName, _ytmThumbnailUrl(card), year);
    }

    // Row-shaped results — less common for album search specifically but
    // some accounts/regions render the Albums shelf as rows instead of
    // cards, so handle it the same way searchArtists covers both shapes.
    if (out.length < limit) {
      for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
        if (out.length >= limit) return out;
        final navEndpoint = (item['navigationEndpoint'] as Map?)?['browseEndpoint'];
        final pageType = navEndpoint?['browseEndpointContextSupportedConfigs']
            ?['browseEndpointContextMusicConfig']?['pageType'];
        if (!useAlbumFilter && pageType != 'MUSIC_PAGE_TYPE_ALBUM') continue;
        final browseId = (navEndpoint?['browseId'] ?? '').toString();
        final title = _flexColumnText(item, 0);
        final artistRuns = _artistRunsInSubtitle(item);
        addCandidate(browseId, title, artistRuns.isNotEmpty ? artistRuns.first.name : '',
            _ytmThumbnailUrl(item), null);
      }
    }

    return out;
  }

  /// Public resolver used by ArtistScreen: tries a real YouTube channel
  /// first, Saavn only as a fallback when no YT channel exists for that
  /// name. Returned id is prefixed so fetchArtist() knows which source to
  /// hit — never mixed, never guessed twice.
  static Future<String?> resolveArtistId(String name) async {
    final ytId = await _resolveYtChannelId(name);
    if (ytId != null && ytId.isNotEmpty) return 'yt_$ytId';
    final saavnId = await searchArtistByName(name);
    if (saavnId != null && saavnId.isNotEmpty) return 'saavn_$saavnId';
    return null;
  }

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
  /// ROUTING (YouTube-primary): artistId is expected prefixed — 'yt_<UC...>'
  /// resolved via resolveArtistId()/fetchHomeArtistsCombined() routes to
  /// _fetchArtistFromYoutube; 'saavn_<id>' (fallback-only path, used when no
  /// YT channel exists for the name) routes to the original Saavn fetch
  /// below. A bare unprefixed id (old callers / deep links saved before this
  /// change) is treated as a legacy Saavn id for backward compatibility.
  static Future<Artist?> fetchArtist(String artistId,
      {int songCount = 100, int albumCount = 100}) async {
    if (artistId.isEmpty) return null;
    if (artistId.startsWith('yt_')) {
      final channelId = artistId.substring(3);
      // PRIMARY: YT Music's own artist `browse` page — the exact call
      // music.youtube.com itself makes when you open an artist. Its Top
      // Songs shelf is YT Music's own popularity-curated list (not a
      // reconstruction from raw channel uploads), and it also carries
      // Albums/Singles shelves the uploads-scraping path can't produce at
      // all (that path always returns topAlbums/singles empty — see its
      // own doc comment). Tried first because it's both richer and, being
      // one browse call instead of N paginated uploads calls, faster.
      final browseArtist = await _fetchArtistFromYtMusicBrowse(channelId, songCount: songCount);
      if (browseArtist != null && browseArtist.topSongs.isNotEmpty) {
        // FIX ("artist page pe sirf 5-8 songs aate hain, Spotify jaisa pura
        // catalog nahi" — YOUTUBE-ONLY, no Saavn): a non-empty YT Top Songs
        // shelf isn't necessarily a FULL one — many Bollywood playback
        // artists (e.g. Udit Narayan, Alka Yagnik) have only a small,
        // sparsely-curated YT Music shelf (5-10 tracks) even though the
        // channel's real upload history runs into the hundreds. Below a
        // threshold, top up with the channel's own uploads via
        // _fetchArtistFromYoutube — the same YT-only reconstruction path
        // used below when browse finds no shelf at all — instead of
        // reaching for a second, non-YouTube source. topAlbums/singles are
        // intentionally left as browse's own (uploads scraping can't
        // produce those — see _fetchArtistFromYoutube's doc comment), so
        // the merge only ever extends topSongs.
        // FIX ("artist tap karne pe bahut kam songs aa rahe hai"): this
        // threshold used to be 15 — meaning any shelf with 15+ songs (a
        // very common size for YT Music's own curated Top Songs list,
        // often sitting right around 10-15) skipped the uploads top-up
        // entirely and returned exactly that shelf, even though the real
        // channel usually has far more. Lowered to 30 so a "medium-sized
        // but still nowhere near the full catalog" shelf also gets topped
        // up from the channel's own uploads, matching the "as many songs
        // as possible" bar Musify/SimpMusic-style apps hold to.
        const thinShelfThreshold = 30;
        if (browseArtist.topSongs.length >= thinShelfThreshold) return browseArtist;

        try {
          // FIX: outer timeout raised 12s -> 18s to actually fit the
          // uploads walk's own internal budget (up to ~8s for
          // channel/about/first-page in parallel, then up to 14s more for
          // the walk's own deadline below) — at 12s this was cutting the
          // walk off mid-stride almost every time, wasting the very
          // budget the walk's internal deadline was designed to use.
          final uploadsArtist = await _fetchArtistFromYoutube(channelId, songCount: songCount)
              .timeout(const Duration(seconds: 18), onTimeout: () => null);
          if (uploadsArtist == null || uploadsArtist.topSongs.isEmpty) return browseArtist;

          final seenIds = <String>{};
          final seenTitles = <String>{};
          final seenRawTitles = <String>[];
          final mergedSongs = <Song>[];
          for (final s in [...browseArtist.topSongs, ...uploadsArtist.topSongs]) {
            if (mergedSongs.length >= songCount) break;
            if (!seenIds.add(s.id)) continue;
            final tk = _normTitle(s.title);
            if (!seenTitles.add(tk)) continue;
            if (_isDupOfAny(s.title, seenRawTitles)) continue;
            seenRawTitles.add(s.title);
            mergedSongs.add(s);
          }

          // FINAL FLOOR ("kam se kam 100 songs aaye, production grade"):
          // browse shelf + channel uploads still occasionally lands short
          // of songCount for artists whose real catalog is thin on both
          // those sources (heavy non-music/duration filtering, or a
          // channel with genuinely few uploads). Rather than ship
          // whatever count that happened to produce, do one more direct
          // YT Music search on the artist's own name — the same fallback
          // path _fetchArtistFromYoutube already uses when uploads come
          // back completely empty — and top up the same merged/deduped
          // list with it. Only fires when actually short, so it costs
          // nothing for the common case that already reaches songCount.
          if (mergedSongs.length < songCount && browseArtist.name.isNotEmpty) {
            try {
              final extra = await _searchYtMusicDirect(browseArtist.name, songCount * 2)
                  .timeout(const Duration(seconds: 8), onTimeout: () => <Song>[]);
              for (final s in extra) {
                if (mergedSongs.length >= songCount) break;
                if (!seenIds.add(s.id)) continue;
                final tk = _normTitle(s.title);
                if (!seenTitles.add(tk)) continue;
                if (_isDupOfAny(s.title, seenRawTitles)) continue;
                if (RecommendationEngine.isNonMusicContent(s)) continue;
                seenRawTitles.add(s.title);
                mergedSongs.add(s);
              }
            } catch (e) {
              _log('[fetchArtist] final 100-floor top-up failed for "${browseArtist.name}": $e');
            }
          }

          return Artist(
            id: browseArtist.id,
            name: browseArtist.name,
            imageUrl: browseArtist.imageUrl,
            followerCount: browseArtist.followerCount,
            isVerified: browseArtist.isVerified,
            bio: browseArtist.bio,
            topSongs: mergedSongs,
            topAlbums: browseArtist.topAlbums,
            singles: browseArtist.singles,
            source: browseArtist.source,
            bannerUrl: browseArtist.bannerUrl,
          );
        } catch (e) {
          _log('[fetchArtist] YT uploads top-up failed for "${browseArtist.name}": $e');
          return browseArtist;
        }
      }

      // FALLBACK: some channelIds (label/VEVO uploader channels that
      // don't have their own YT Music artist page, or a transient browse
      // failure) don't resolve via browse — reconstruct from the
      // channel's own uploads instead, same as before.
      final ytArtist = await _fetchArtistFromYoutube(channelId, songCount: songCount);
      if (ytArtist != null) return ytArtist;
      // Last resort: return whatever the browse call got (header + bio
      // even with an empty song list) rather than nothing at all, so the
      // page can still render something instead of a hard failure.
      return browseArtist;
    }
    // Saavn-id path: kept only as the last-resort route for artists that
    // have no YouTube channel at all (see resolveArtistId — this branch is
    // only ever reached when YT channel resolution itself found nothing),
    // so the page still renders something instead of a hard failure.
    final saavnId = artistId.startsWith('saavn_') ? artistId.substring(6) : artistId;
    return _fetchArtistFromSaavn(saavnId, songCount: songCount, albumCount: albumCount);
  }

  /// PRODUCTION-GRADE ARTIST PAGE — fetched via YT Music's real `browse`
  /// InnerTube endpoint (browseId = channelId), the same call the actual
  /// YT Music web app makes when opening an artist's page. Parsed entirely
  /// through _findRenderers so it doesn't care exactly which shelf order
  /// or carousel nesting YT Music uses (this varies per artist depending
  /// on which shelves they have — Top Songs, Albums, Singles, Featured On,
  /// Fans Might Also Like, etc. — and reordering/adding shelves has never
  /// been a stable contract on this undocumented API).
  static Future<Artist?> _fetchArtistFromYtMusicBrowse(String channelId,
      {int songCount = 100}) async {
    try {
      final decoded = await _ytmBrowseRaw(channelId, timeout: const Duration(seconds: 8));
      if (decoded == null) return null;

      // ── Header: name, avatar, banner, subscriber/listener count, bio ──
      final header = decoded['header'];
      final headerRenderer = header is Map
          ? (header['musicImmersiveHeaderRenderer'] ??
              header['musicVisualHeaderRenderer'] ??
              header['musicHeaderRenderer'])
          : null;
      String name = '';
      String bio = '';
      String imageUrl = '';
      String? bannerUrl;
      int followerCount = 0;
      if (headerRenderer is Map) {
        name = ((headerRenderer['title']?['runs'] as List?) ?? const [])
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .trim();
        final descRuns = (headerRenderer['description']?['runs'] as List?) ?? const [];
        bio = descRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .trim();
        final thumbs = (headerRenderer['thumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            (headerRenderer['foregroundThumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            const [];
        if (thumbs.isNotEmpty) {
          final rawUrl = (thumbs.last['url'] ?? '').toString();
          imageUrl = rawUrl.isNotEmpty
              ? rawUrl.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w500-h500-p')
              : '';
        }
        final bannerThumbs = (headerRenderer['background']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            const [];
        if (bannerThumbs.isNotEmpty) {
          bannerUrl = (bannerThumbs.last['url'] ?? '').toString();
          if (bannerUrl.isEmpty) bannerUrl = null;
        }
        // REAL FIELD NAMES verified against ytmusicapi's mixins/browsing.py
        // get_artist() implementation (the reference library for this
        // exact undocumented endpoint): subscriber count lives at
        // subscriptionButton.subscribeButtonRenderer.subscriberCountText,
        // and — separately — YT Music artist pages show "monthly
        // listeners" as their primary, more meaningful metric at
        // header.monthlyListenerCount.runs[0].text (e.g. "29.1M monthly
        // listeners"), which subscriber count alone was missing entirely.
        // Monthly listeners preferred when present since that's what
        // artist pages actually lead with.
        final monthlyListenersText = ((headerRenderer['monthlyListenerCount']?['runs'] as List?) ?? const [])
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join();
        final subscriberRuns = (headerRenderer['subscriptionButton']
                    ?['subscribeButtonRenderer']?['subscriberCountText']
                    ?['runs'] as List?) ??
            const [];
        final subscriberText = subscriberRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join();
        followerCount = _parseCompactCount(
            monthlyListenersText.isNotEmpty ? monthlyListenersText : subscriberText);
      }
      name = _cleanText(name)
          .replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), '')
          .trim();
      if (name.isEmpty) return null; // No usable header at all — treat as not-found.

      // PRODUCTION FIX (verified against Musify's youtube_music_explode_dart
      // reference implementation): channelId isn't always the artist's own
      // channel — a label or VEVO uploader channel answers with a partial
      // page of the same artist, but its header's subscribe button still
      // points at the CANONICAL artist channelId. Reading that and using it
      // for the returned Artist.id means a caller that resolved via an
      // uploader channel still lands on the artist's real page (and any
      // save/follow keys off the correct id) instead of the uploader's.
      final canonicalChannelId = ((headerRenderer is Map)
              ? (headerRenderer['subscriptionButton']
                      ?['subscribeButtonRenderer']?['channelId'])
                  ?.toString()
              : null) ??
          '';
      final resolvedChannelId = canonicalChannelId.startsWith('UC')
          ? canonicalChannelId
          : channelId;

      // ── Top Songs: musicResponsiveListItemRenderer rows under whichever
      // shelf carries the videoId-bearing playlistItemData; anywhere in
      // the tree, any shelf title/order. ──
      final topSongs = <Song>[];
      final seenVideoIds = <String>{};
      for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
        if (topSongs.length >= songCount) break;
        final videoId = (item['playlistItemData']?['videoId'] ??
                (item['overlay']?['musicItemThumbnailOverlayRenderer']?['content']
                        ?['musicPlayButtonRenderer']?['playNavigationEndpoint']
                    ?['watchEndpoint']?['videoId']))
            ?.toString();
        if (videoId == null || videoId.isEmpty || !seenVideoIds.add(videoId)) continue;

        final title = _flexColumnText(item, 0);
        if (title.isEmpty) continue;

        // Subtitle is typically "Song • Artist • Album • Duration" —
        // prefer an explicit artist run if tagged, else fall back to this
        // artist's own cleaned channel name (always correct for a Top
        // Songs shelf, which is scoped to this one artist).
        final artistRuns = _artistRunsInSubtitle(item);
        final artistName = artistRuns.isNotEmpty ? artistRuns.first.name : name;

        final thumbs = (item['thumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            const [];
        String artworkUrl = '';
        if (thumbs.isNotEmpty) {
          final rawUrl = (thumbs.last['url'] ?? '').toString();
          artworkUrl = rawUrl.isNotEmpty
              ? rawUrl.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w500-h500')
              : '';
        }

        // Fixed-length duration column ("3:42") lives in the last flex
        // column on song rows; parse mm:ss / h:mm:ss tolerant of either.
        final flexColumns = (item['flexColumns'] as List?) ?? const [];
        int? duration;
        if (flexColumns.isNotEmpty) {
          final lastColRuns = (flexColumns.last
                      ?['musicResponsiveListItemFlexColumnRenderer']?['text']
                  ?['runs'] as List?) ??
              const [];
          final lastColText = lastColRuns
              .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
              .join()
              .trim();
          duration = _parseDurationText(lastColText);
        }

        final song = Song(
          id: videoId,
          title: _cleanText(title),
          artist: _cleanText(artistName, collapseJukeboxTitle: false),
          album: '',
          artworkUrl: artworkUrl,
          streamUrl: null,
          duration: duration,
          source: SongSource.youtube,
          viewCount: 1000000, // Top Songs shelf is already popularity-ranked by YT Music itself.
          artistChannelId: resolvedChannelId,
        );
        if (RecommendationEngine.isNonMusicContent(song)) continue;
        topSongs.add(song);
      }

      // ── Albums / Singles: musicTwoRowItemRenderer cards, split by
      // whichever shelf header they sit under ("Albums" vs "Singles").
      // Shelf headers are read from musicCarouselShelfRenderer so an
      // album card and a singles card (same renderer type) don't get
      // merged into one bucket. ──
      //
      // PRODUCTION FIX (verified against Musify's youtube_music_explode_dart
      // _collectDiscography/_collectMoreReleaseBrowses): the artist page's
      // inline Albums/Singles carousels are only a short PREVIEW (YT Music
      // caps each shelf's inline row at a handful of cards) — the full list
      // lives behind that shelf's own "More" button, a separate browse call
      // (browseId prefixed 'MPAD') that returns the complete grid. Every
      // shelf's More-browseId is collected first, then all of them are
      // fetched in parallel with the inline carousels' cards still kept as
      // a fallback for any shelf that has no More button (artists with a
      // small enough catalog that YT Music never paginates it) — this is
      // exactly why "Albums" used to cap out around 6-8 even though the
      // artist has many more: the inline preview was the only thing ever
      // read.
      final moreReleaseBrowses = <(String, bool, String?)>[]; // (browseId, isSingles, params)
      for (final carousel in _findRenderers(decoded, 'musicCarouselShelfRenderer')) {
        final headerRendererForCarousel =
            (carousel['header']?['musicCarouselShelfBasicHeaderRenderer'] as Map?)
                ?.cast<String, dynamic>();
        final headerTitleRuns =
            (headerRendererForCarousel?['title']?['runs'] as List?) ?? const [];
        final headerTitle = headerTitleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .toLowerCase();
        final isSingles = headerTitle.contains('single');
        final isAlbums = headerTitle.contains('album');
        if (!isSingles && !isAlbums) continue;

        final moreEndpoint = (headerRendererForCarousel?['moreContentButton']
                ?['buttonRenderer']?['navigationEndpoint']?['browseEndpoint']
            as Map?)
            ?.cast<String, dynamic>();
        final moreBrowseId = (moreEndpoint?['browseId'] ?? '').toString();
        if (moreBrowseId.startsWith('MPAD')) {
          moreReleaseBrowses.add(
              (moreBrowseId, isSingles, moreEndpoint?['params']?.toString()));
        }
      }

      final moreGrids = await Future.wait(moreReleaseBrowses.map((entry) async {
        try {
          // FIX (verified against Musify's _collectDiscography, which
          // calls _browse(more.$1, params: more.$2)): the More button's
          // own `params` value is REQUIRED alongside its browseId — it's
          // how InnerTube knows this is a "show all releases of this
          // type" grid request rather than a bare/ambiguous browse. Was
          // previously dropped entirely (only browseId was forwarded),
          // which could return a thin, wrong, or empty grid instead of
          // the full discography.
          final grid = await _ytmBrowseRaw(entry.$1,
              params: entry.$3, timeout: const Duration(seconds: 8));
          return (grid, entry.$2);
        } catch (_) {
          return (null, entry.$2);
        }
      }));

      final topAlbums = <ArtistAlbum>[];
      final singles = <ArtistAlbum>[];
      final seenAlbumBrowseIds = <String>{};

      void collectReleaseCards(dynamic node, bool isSinglesShelf) {
        for (final card in _findRenderers(node, 'musicTwoRowItemRenderer')) {
          // FIX (verified against ytmusicapi's parse_album/parse_single):
          // an album/single card's browseId is NOT on the card's own
          // top-level navigationEndpoint — it's nested inside the title
          // run itself (title.runs[0].navigationEndpoint.browseEndpoint),
          // same as every other title-as-link renderer in this API. The
          // card-level navigationEndpoint (when present at all) points
          // to a different, less specific endpoint and was silently
          // producing empty browseIds — this would have made every
          // album/single card fail its `browseId.isEmpty` guard and get
          // dropped, leaving Albums/Singles empty despite the fix
          // otherwise working.
          final cardTitleRuns = (card['title']?['runs'] as List?) ?? const [];
          final cardTitle = cardTitleRuns
              .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
              .join()
              .trim();
          if (cardTitle.isEmpty || cardTitleRuns.isEmpty) continue;
          final titleNav = ((cardTitleRuns.first as Map)['navigationEndpoint']
                  as Map?)
              ?.cast<String, dynamic>();
          final browseId = (titleNav?['browseEndpoint']?['browseId'] ?? '').toString();
          if (browseId.isEmpty || !seenAlbumBrowseIds.add(browseId)) continue;
          final cardThumbs = (card['thumbnailRenderer']?['musicThumbnailRenderer']
                      ?['thumbnail']?['thumbnails'] as List?) ??
              const [];
          String cardArt = '';
          if (cardThumbs.isNotEmpty) {
            final rawUrl = (cardThumbs.last['url'] ?? '').toString();
            cardArt = rawUrl.isNotEmpty
                ? rawUrl.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w500-h500')
                : '';
          }
          final subtitleRuns = ((card['subtitle']?['runs'] as List?) ?? const []);
          String? year;
          for (final r in subtitleRuns) {
            final text = (r is Map ? (r['text'] ?? '') : '').toString();
            final yearMatch = RegExp(r'^(19|20)\d{2}$').firstMatch(text.trim());
            if (yearMatch != null) {
              year = yearMatch.group(0);
              break;
            }
          }
          final album = ArtistAlbum(
            id: browseId,
            name: _cleanText(cardTitle),
            artworkUrl: cardArt,
            year: year,
            type: isSinglesShelf ? 'single' : 'album',
          );
          if (isSinglesShelf) {
            singles.add(album);
          } else {
            topAlbums.add(album);
          }
        }
      }

      // Grids first (the full "More" list): they carry the release type
      // unambiguously (this specific shelf's grid) and are only fetched
      // when a More button exists, so they're the authoritative, complete
      // source whenever available. Inline carousel cards are collected
      // after, purely to fill in the small-catalog case where no More
      // button/grid exists at all — seenAlbumBrowseIds already dedupes so
      // an inline card also present in its own grid is never doubled.
      for (final (grid, isSinglesShelf) in moreGrids) {
        if (grid != null) collectReleaseCards(grid, isSinglesShelf);
      }
      for (final carousel in _findRenderers(decoded, 'musicCarouselShelfRenderer')) {
        final headerRendererForCarousel =
            (carousel['header']?['musicCarouselShelfBasicHeaderRenderer'] as Map?)
                ?.cast<String, dynamic>();
        final headerTitleRuns =
            (headerRendererForCarousel?['title']?['runs'] as List?) ?? const [];
        final headerTitle = headerTitleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .toLowerCase();
        final isSingles = headerTitle.contains('single');
        final isAlbums = headerTitle.contains('album');
        if (!isSingles && !isAlbums) continue;
        collectReleaseCards(carousel['contents'], isSingles);
      }

      return Artist(
        id: 'yt_$resolvedChannelId',
        name: name,
        imageUrl: imageUrl,
        followerCount: followerCount,
        isVerified: false,
        bio: _cleanText(bio),
        topSongs: topSongs,
        topAlbums: topAlbums,
        singles: singles,
        source: ArtistSource.youtube,
        bannerUrl: bannerUrl,
      );
    } catch (e) {
      _log('[_fetchArtistFromYtMusicBrowse] failed for channelId=$channelId: $e');
      return null;
    }
  }

  /// Parses a compact count string ("1.2M subscribers", "800K monthly
  /// listeners", "12,345 subscribers") into a plain int. Returns 0 if no
  /// number can be found rather than throwing — follower counts are
  /// decorative on the artist header, never worth failing the page over.
  static int _parseCompactCount(String text) {
    final match = RegExp(r'([\d.,]+)\s*([KMB]?)', caseSensitive: false).firstMatch(text.trim());
    if (match == null) return 0;
    final numPart = match.group(1)?.replaceAll(',', '') ?? '';
    final suffix = (match.group(2) ?? '').toUpperCase();
    final base = double.tryParse(numPart);
    if (base == null) return 0;
    final multiplier = switch (suffix) {
      'K' => 1000,
      'M' => 1000000,
      'B' => 1000000000,
      _ => 1,
    };
    return (base * multiplier).round();
  }

  /// Parses a "3:42" / "1:03:42" style duration string into seconds.
  /// Returns null for anything that isn't cleanly a duration (e.g. a
  /// play-count string that ended up in the same column position).
  static int? _parseDurationText(String text) {
    if (!RegExp(r'^\d{1,2}(:\d{2}){1,2}$').hasMatch(text.trim())) return null;
    final parts = text.trim().split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return null;
    var seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p!;
    }
    return seconds;
  }

  /// YouTube-primary artist page: channel avatar/banner/subscriber count
  /// come straight from youtube_explode_dart's ChannelClient.get(), bio
  /// from its getAboutPage(), and Top Songs from its popularity-sorted
  /// uploads pages (getUploadsFromPage) — mapped to Song objects exactly
  /// like _songFromYtVideo, quality-gated the same way search results are
  /// so a channel's non-music uploads (vlogs, shorts, interviews, etc.)
  /// don't flood the Top Songs list.
  static Future<Artist?> _fetchArtistFromYoutube(String channelId,
      {int songCount = 100}) async {
    try {
      // PERF (biggest lever on artist-screen open time): channel.get(),
      // getAboutPage(), and getUploadsFromPage() are three independent
      // network calls — none needs another's result — but were
      // previously awaited one after another, stacking their latencies
      // (up to 8s + 6s + 7s = 21s worst case) purely because of call
      // order, not any real dependency. Firing all three together with
      // Future.wait bounds the worst case to whichever ONE is slowest,
      // not their sum — exactly the difference that matters on a slow
      // connection or low-end device where every network round-trip is
      // already expensive.
      final channelFuture = _yt.channels.get(channelId)
          .timeout(const Duration(seconds: 8));
      final aboutFuture = () async {
        try {
          return await _yt.channels.getAboutPage(channelId)
              .timeout(const Duration(seconds: 6));
        } catch (e) {
          _log('[_fetchArtistFromYoutube] getAboutPage failed: $e');
          return null;
        }
      }();
      final uploadsFuture = () async {
        try {
          return await _yt.channels
              .getUploadsFromPage(channelId, videoSorting: VideoSorting.popularity)
              .timeout(const Duration(seconds: 7));
        } catch (e) {
          _log('[_fetchArtistFromYoutube] getUploadsFromPage failed: $e');
          return null;
        }
      }();

      final channel = await channelFuture;
      final about = await aboutFuture;
      final firstPage = await uploadsFuture;

      final bio = _cleanText(about?.description ?? '');

      // FIX ("Arijit Singh - Topic" raw suffix showing on artist screen):
      // YouTube auto-generates a "Topic" channel for every artist known to
      // YT Music, separate from their own official upload channel — its
      // channel.title always carries this literal " - Topic" suffix.
      // Strip it so the artist header shows the real, clean artist name
      // the same way YT Music's own UI does.
      final cleanName = _cleanText(channel.title)
          .replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), '')
          .trim();

      // Uploads → Top Songs, sorted by POPULARITY (not upload date) so
      // "Top Songs" actually means the artist's biggest songs, not just
      // their most recent uploads — a prolific channel's older hits would
      // otherwise never surface if newest-first pagination hit songCount
      // before reaching them. getUploadsFromPage(videoSorting: popularity)
      // also returns each video's REAL view count directly from the page
      // (unlike the plain getUploads() stream, whose Video.engagement can
      // come back with a null viewCount for some entries) — critical here
      // because RecommendationEngine.isPremiumQuality() hard-rejects any
      // YouTube song with viewCount == null anywhere downstream (queue,
      // favorites cross-checks, etc.), which would have silently vanished
      // real songs from this list. Quality-gated the same way search
      // results are so a channel mixing music with shorts/vlogs/
      // interviews still shows a clean, music-only Top Songs list.
      final topSongs = <Song>[];
      if (firstPage != null) {
        try {
          var page = firstPage;
          // FIX ("neeche kuch bhi nahi aata / songs load nahi ho rahe"):
          // the previous "no limit" walk kept calling page.nextPage()
          // until YouTube itself ran out of pages, with only a per-page
          // timeout as a guard. For any channel with a large uploads
          // catalog that's dozens of sequential network round-trips before
          // the artist screen can render anything — on a slow/mobile
          // connection this routinely blew past the screen's own loading
          // state, and if any single page's nextPage() call hit its 7s
          // timeout mid-walk the loop still pressed on into more waiting
          // rather than surfacing what it already had. Cap both the page
          // count and the total songs collected so the artist screen
          // always resolves promptly — a big channel's full catalog is a
          // "browse more" problem, not something the initial screen load
          // should block on.
          // FIX ("artist ke songs sirf 5-18 aa rahe hain" even after the
          // browse-shelf top-up kicks in): maxPages=10 was routinely not
          // enough to reach songCount once isNonMusicContent + the
          // 60-1200s duration filter above throw away a chunk of every
          // page — a channel needing 15+ real pages to fill 100 slots
          // just stopped at page 10 with whatever survived, often barely
          // more than the thin browse shelf it was supposed to top up.
          // Raised so the walk actually has room to reach songCount for
          // channels with heavier filtering loss.
          // FIX ("ekdam fast, stuck na ho" — the previous maxPages=25 +
          // retry-per-page combo could chain up to 25 × 14s ≈ 6 minutes
          // of sequential waiting on a slow connection, exactly the
          // "stuck" feeling this needs to avoid): page COUNT alone is the
          // wrong guard — it says nothing about how long the walk has
          // actually taken. Wall-clock deadline is what actually bounds
          // worst-case latency, so the walk now stops the moment either
          // songCount is hit OR this much total time has passed,
          // whichever comes first — same 100-song ceiling on a fast
          // connection, but a hard, predictable cap on a slow one instead
          // of a multi-minute stall.
          const maxPages = 25;
          final walkDeadline = DateTime.now().add(const Duration(seconds: 14));
          var pageCount = 0;
          while (true) {
            pageCount++;
            for (final v in page) {
              final base = _songFromYtVideo(v);
              final song = Song(
                id: base.id, title: base.title, artist: base.artist,
                album: base.album, artworkUrl: base.artworkUrl, streamUrl: null,
                duration: base.duration, source: SongSource.youtube,
                // Real view count from the popularity-sorted page — falls
                // back to a trusted sentinel only in the rare case this
                // specific entry's count came back null, so a single gap in
                // the page data can't hide a legitimate song from every
                // downstream isPremiumQuality() check.
                viewCount: base.viewCount ?? 1000000,
                artistChannelId: channelId,
              );
              if (RecommendationEngine.isNonMusicContent(song)) continue;
              if (song.duration != null && (song.duration! < 60 || song.duration! > 1200)) continue;
              topSongs.add(song);
            }
            if (topSongs.length >= songCount || pageCount >= maxPages) break;
            if (DateTime.now().isAfter(walkDeadline)) break;
            // FIX: dropped the earlier retry-on-timeout here — doubling
            // every slow page's wait (7s → 14s) was the single biggest
            // contributor to worst-case stall time for exactly the
            // channels that most needed this walk to finish fast. A
            // single timeout now just ends the walk with whatever's
            // already collected, same as running out of pages for real.
            final next = await page.nextPage().timeout(const Duration(seconds: 5), onTimeout: () => null);
            if (next == null) break;
            page = next;
          }
        } catch (e) {
          _log('[_fetchArtistFromYoutube] getUploadsFromPage failed: $e');
        }
      }

      // FIX ("neeche kuch bhi nahi hai" — empty Top Songs on an artist
      // page): channel.get() + getAboutPage() succeeding tells us the
      // channel itself is real and reachable, but getUploadsFromPage()
      // can still legitimately come back empty for a "Topic" channel —
      // youtube_explode_dart's own tracker (package issue #135) documents
      // FatalFailureException / empty results on channels whose Uploads
      // tab doesn't match the standard creator-channel layout, which is
      // exactly what an auto-generated Topic channel is. Rather than ship
      // a photo + bio with a dead empty list underneath (worse than just
      // failing outright), fall back to a direct YT Music search for the
      // artist's own cleaned name — the same InnerTube search path
      // already proven reliable for the main search bar — and keep only
      // results whose artistChannelId actually matches this artist (or,
      // failing that, whose artist name matches), so an unrelated
      // same-named channel's songs can't leak onto this page.
      // FIX ("kam se kam 100 songs aaye, production grade" — same 100-floor
      // fix as the browse-shelf path above): this used to only fire when
      // topSongs was COMPLETELY empty. A channel whose uploads walk found
      // some real songs (say 20-40) but never reached songCount — heavy
      // non-music/duration filtering, or a genuinely small uploads
      // catalog — used to just ship that partial count with no top-up at
      // all. Now runs whenever short of songCount, additively (keeps what
      // uploads already found, only fills the gap) instead of only ever
      // being a last-resort replacement for a totally empty list.
      if (topSongs.length < songCount && cleanName.isNotEmpty) {
        try {
          final fallbackResults = await _searchYtMusicDirect(cleanName, songCount * 2);
          final matched = fallbackResults.where((s) {
            if (s.artistChannelId != null) return s.artistChannelId == channelId;
            return s.artist.trim().toLowerCase() == cleanName.toLowerCase();
          }).toList();
          if (matched.isNotEmpty) {
            final seenIds = topSongs.map((s) => s.id).toSet();
            final seenTitles = topSongs.map((s) => _normTitle(s.title)).toSet();
            final seenRawTitles = topSongs.map((s) => s.title).toList();
            // Same non-music filter every other Top Songs source in this
            // function applies — this fallback previously skipped it, so
            // a stray non-song result reaching this specific path (empty
            // topSongs from every earlier source) could still slip
            // through un-filtered.
            for (final s in matched) {
              if (topSongs.length >= songCount) break;
              if (!seenIds.add(s.id)) continue;
              final tk = _normTitle(s.title);
              if (!seenTitles.add(tk)) continue;
              if (_isDupOfAny(s.title, seenRawTitles)) continue;
              final song = Song(
                id: s.id, title: s.title, artist: s.artist, album: s.album,
                artworkUrl: s.artworkUrl, streamUrl: null, duration: s.duration,
                source: SongSource.youtube, viewCount: s.viewCount ?? 1000000,
                artistChannelId: channelId,
              );
              if (RecommendationEngine.isNonMusicContent(song)) continue;
              seenRawTitles.add(s.title);
              topSongs.add(song);
            }
          }
        } catch (e) {
          _log('[_fetchArtistFromYoutube] search fallback failed: $e');
        }
      }

      return Artist(
        id: 'yt_$channelId',
        name: cleanName.isNotEmpty ? cleanName : _cleanText(channel.title),
        imageUrl: channel.logoUrl,
        followerCount: channel.subscribersCount ?? 0,
        isVerified: false, // youtube_explode_dart's Channel doesn't expose this
        bio: bio,
        topSongs: topSongs,
        topAlbums: const [],
        singles: const [],
        source: ArtistSource.youtube,
        bannerUrl: channel.bannerUrl.isNotEmpty ? channel.bannerUrl : null,
      );
    } catch (e) {
      _log('[_fetchArtistFromYoutube] failed for channelId=$channelId: $e');
      return null;
    }
  }

  /// Original Saavn-backed artist fetch — now ONLY reached as a fallback
  /// when _fetchArtistFromYoutube finds no matching channel at all (see
  /// resolveArtistId/fetchArtist routing above). Behavior unchanged from
  /// before: Saavn profile fields + Saavn's own topSongs, blended with a
  /// best-effort YT top-up search.
  static Future<Artist?> _fetchArtistFromSaavn(String artistId,
      {int songCount = 100, int albumCount = 100}) async {
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

      final saavnTopSongs = ((d['topSongs'] as List?) ?? [])
          .whereType<Map>()
          .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
          .toList();

      // FIX (artist page only ever showed Saavn's own topSongs — no YouTube
      // songs, even when Saavn's catalog for that artist was thin/stale):
      // fold in a YouTube search for "<artist name> songs" the same way
      // _saavnSectionV4 blends Saavn+YT for home sections, using the same
      // already-clean _searchYt() (worker-first, direct-YT-Music-API
      // fallback if the worker is down, both _cleanText'd and quality-
      // gated) rather than introducing a new uncleaned path. Kept as a best-effort addition — if the YT search
      // fails or times out, the page still renders with Saavn's topSongs
      // alone rather than failing the whole artist fetch.
      // TUNED ("YT se artist songs zyada se zyada aaye"): 30 -> 60 — more
      // YT depth for artists whose Saavn catalog is thin/stale, same
      // quality pipeline (isSearchQuality/isNonMusicContent gating already
      // applied inside _searchYt's callers elsewhere; dedup below still
      // keeps Saavn's own catalog authoritative and first).
      // TUNED ("YT se artist songs zyada se zyada aaye, koi limit na
      // rahe"): 60 -> 150 — single bounded search call (not paginated),
      // so raising this doesn't add extra round-trips, just asks the one
      // call for a deeper result set. Saavn's own topSongs above is
      // already uncapped (backend returns everything for the requested
      // songCount, no client-side .take() here); this just brings the YT
      // half of the blend up to the same "as much as possible" standard.
      final artistNameForYt = (d['name'] ?? '').toString();
      final ytTopSongs = artistNameForYt.isEmpty
          ? <Song>[]
          : await _searchYt('$artistNameForYt songs', limit: 150)
              .timeout(const Duration(seconds: 8), onTimeout: () => <Song>[])
              .catchError((_) => <Song>[]);

      final seenIds = <String>{};
      final seenTitles = <String>{};
      final topSongs = <Song>[];
      // Saavn first (the artist's own catalog is the authoritative source),
      // YT fills in behind it — same dedup pattern as every other merge
      // point in this file (isSameSongSmart against every accepted title,
      // not just an exact-string check, so reuploads with slightly
      // different title formatting don't slip through as "different"
      // songs).
      final seenRawTitles = <String>[];
      for (final s in [...saavnTopSongs, ...ytTopSongs]) {
        // FIX ("artist page pe kabhi kabhi junk/unrelated YT upload aa jata
        // hai"): Saavn's own catalog is trusted as-is (it's the
        // authoritative source for this page), but YT entries now go
        // through the same quality gate search results already use —
        // duration sanity + non-music/label-reupload filter — so a stray
        // news/vlog/bare-reupload video merged in from the YT search above
        // never reaches the artist page.
        if (s.source == SongSource.youtube) {
          if (!RecommendationEngine.isSearchQuality(s)) continue;
          if (RecommendationEngine.isNonMusicContent(s)) continue;
        }
        if (!seenIds.add(s.id)) continue;
        final tk = _normTitle(s.title);
        if (!seenTitles.add(tk)) continue;
        if (_isDupOfAny(s.title, seenRawTitles)) continue;
        seenRawTitles.add(s.title);
        topSongs.add(s);
      }

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
        id: 'saavn_${(d['id'] ?? artistId).toString()}',
        name: _cleanText((d['name'] ?? '').toString()),
        imageUrl: _onrenderArtwork(d),
        followerCount: _parseInt(d['followerCount']) ?? 0,
        isVerified: d['isVerified'] == true,
        bio: bio,
        topSongs: topSongs,
        topAlbums: topAlbums,
        singles: singles,
        source: ArtistSource.saavn,
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

  /// Fetch the songs inside an album or single. Branches on the album's
  /// own ID format: `MPRE...` is a real YT Music album browseId (produced
  /// by searchAlbums/the artist page's Albums shelf), anything else is
  /// treated as a Saavn album ID (the pre-existing behavior, unchanged).
  ///
  /// FIX ("YouTube se albums bhi aaye, click karne pr songs dikhein"):
  /// previously this function ONLY ever hit the Saavn endpoint — tapping
  /// a YT-origin album (exactly the kind searchAlbums/the artist page's
  /// Albums shelf now surface) silently returned an empty song list here,
  /// since Saavn has no record of a YT MPRE id. Both branches converge on
  /// the same List<Song> shape AlbumScreen already expects, so no caller
  /// changes are needed beyond this function.
  static Future<List<Song>> fetchAlbumSongs(String albumId) async {
    if (albumId.isEmpty) return [];
    if (albumId.startsWith('MPRE')) {
      return _fetchYtAlbumSongs(albumId);
    }

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

  /// Real YT Music album fetch via the `browse` endpoint, verified against
  /// ytmusicapi's get_album(): the header exposes an `audioPlaylistId`
  /// (format "OLAK5uy_..." — a genuine YouTube playlist id representing
  /// this album's full tracklist in correct track order), so rather than
  /// hand-parsing the album's own secondaryContents shelf, this reuses
  /// fetchYtPlaylistSongs on that playlist id — same reliable path the
  /// artist page's full Top Songs fetch already relies on. Falls back to
  /// scanning the browse response's own song rows directly (via
  /// _findRenderers, shape-agnostic as always) only if no playable button
  /// with that id was present, so a header-shape quirk still degrades
  /// gracefully instead of returning nothing.
  static Future<List<Song>> _fetchYtAlbumSongs(String albumBrowseId) async {
    try {
      final decoded = await _ytmBrowseRaw(albumBrowseId, timeout: const Duration(seconds: 8));
      if (decoded == null) return [];

      final albumTitle = ((decoded['header']?['musicResponsiveHeaderRenderer']?['title']
                      ?['runs'] as List?) ??
                  (decoded['header']?['musicDetailHeaderRenderer']?['title']?['runs']
                      as List?) ??
                  const [])
          .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
          .join()
          .trim();

      // audioPlaylistId lives on the header's own play button — walk every
      // musicPlayButtonRenderer in the header subtree (not the whole
      // response, which would also match individual track play buttons)
      // and take the first playlistId found.
      String? audioPlaylistId;
      final header = decoded['header'];
      for (final btn in _findRenderers(header, 'musicPlayButtonRenderer')) {
        final playlistId = (btn['playNavigationEndpoint']?['watchPlaylistEndpoint']?['playlistId'] ??
                btn['playNavigationEndpoint']?['watchEndpoint']?['playlistId'])
            ?.toString();
        if (playlistId != null && playlistId.isNotEmpty) {
          audioPlaylistId = playlistId;
          break;
        }
      }

      if (audioPlaylistId != null) {
        try {
          final songs = await fetchYtPlaylistSongs(audioPlaylistId, limit: 200)
              .timeout(const Duration(seconds: 12));
          if (songs.isNotEmpty) {
            if (albumTitle.isEmpty) return songs;
            // Stamp the real album title onto every track — playlist rows
            // don't reliably carry it themselves (import path leaves
            // `album` blank for a bare playlist fetch).
            return songs
                .map((s) => Song(
                      id: s.id,
                      title: s.title,
                      artist: s.artist,
                      album: _cleanText(albumTitle),
                      artworkUrl: s.artworkUrl,
                      streamUrl: s.streamUrl,
                      duration: s.duration,
                      source: s.source,
                      viewCount: s.viewCount,
                      artistChannelId: s.artistChannelId,
                    ))
                .toList();
          }
        } catch (e) {
          _log('[_fetchYtAlbumSongs] playlist fetch failed for $audioPlaylistId: $e');
          // fall through to the direct-scan fallback below
        }
      }

      // FALLBACK: no audioPlaylistId found (header-shape variant) or the
      // playlist fetch failed — scan the browse response's own song rows
      // directly instead of returning nothing.
      final songs = <Song>[];
      final seenIds = <String>{};
      for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
        final videoId = (item['playlistItemData']?['videoId'] ??
                item['overlay']?['musicItemThumbnailOverlayRenderer']?['content']
                    ?['musicPlayButtonRenderer']?['playNavigationEndpoint']
                ?['watchEndpoint']?['videoId'])
            ?.toString();
        if (videoId == null || videoId.isEmpty || !seenIds.add(videoId)) continue;
        final title = _flexColumnText(item, 0);
        if (title.isEmpty) continue;
        final artistRuns = _artistRunsInSubtitle(item);
        final song = Song(
          id: videoId,
          title: _cleanText(title),
          artist: _cleanText(
              artistRuns.isNotEmpty ? artistRuns.first.name : '', collapseJukeboxTitle: false),
          album: _cleanText(albumTitle),
          artworkUrl: _ytmThumbnailUrl(item),
          streamUrl: null,
          source: SongSource.youtube,
          artistChannelId: artistRuns.isNotEmpty ? artistRuns.first.channelId : null,
        );
        // Defense-in-depth: an album/deluxe-edition browse page can
        // occasionally include a bonus non-song row (a trailer, a
        // "making of" bonus track) in the same shelf shape as real
        // tracks — same filter every other Top Songs source in this file
        // applies, kept consistent here too.
        if (RecommendationEngine.isNonMusicContent(song)) continue;
        songs.add(song);
      }
      return songs;
    } catch (e) {
      _log('[_fetchYtAlbumSongs] failed for $albumBrowseId: $e');
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
  // Caching moved to lyrics_cache.dart (LyricsCache) to keep this file
  // smaller and this concern self-contained. Behavior unchanged: bounded
  // to 200 entries each, oldest-first eviction.

  static Future<String?> fetchLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return null;
    final cacheKey = '${song.source.name}:${song.id}';
    if (LyricsCache.hasPlain(cacheKey)) return LyricsCache.getPlain(cacheKey);

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
    if (lyrics != null && lyrics.isNotEmpty) {
      LyricsCache.setPlain(cacheKey, lyrics);
    }
    return lyrics;
  }

  /// Line-synced lyrics fetch. Prefers real [mm:ss.xx] timed lines from
  /// LRCLIB; falls back to Saavn's plain lyrics (no timestamps) when LRCLIB
  /// has nothing for this track. Cached separately from fetchLyrics() since
  /// the shapes differ (LyricsResult vs raw String).
  static Future<LyricsResult> fetchSyncedLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return const LyricsResult();
    final cacheKey = '${song.source.name}:${song.id}';
    if (LyricsCache.hasSynced(cacheKey)) {
      return LyricsCache.getSynced(cacheKey)!;
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

    if (finalResult.hasAny) {
      LyricsCache.setSynced(cacheKey, finalResult);
    }
    return finalResult;
  }

  /// For non-Saavn songs (YouTube, etc.), Saavn's lyrics route needs a Saavn
  /// song ID we don't have. This searches Saavn by title+artist to find the
  /// closest matching track's ID purely as a lyrics lookup key. Cached so
  /// repeated lyric fetches for the same song don't re-search.
  static final Map<String, String?> _saavnIdForLyricsCache = {};
  static const int _maxSaavnIdCache = 500;

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
    // Cap unbounded growth
    if (_saavnIdForLyricsCache.length >= _maxSaavnIdCache) {
      _saavnIdForLyricsCache.remove(_saavnIdForLyricsCache.keys.first);
    }
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
    r'hd|4k|8k|full\s*(video|song|audio|hd)?|new|latest|original|explicit|'
    r'visualizer|audio\s*only|with\s*lyrics|slowed\s*(down|\+?\s*reverb)?|'
    r'reverb|bass\s*boosted|extended|clean|dirty|radio\s*edit|'
    r'\d{3,4}p|prod\.?\s*by\s*.*?|from\s*.*?)\s*[\)\]\}]',
    caseSensitive: false,
  );

  // Trailing "| Channel Name" / "- T-Series" style suffixes uploaders
  // append after the real title.
  static final RegExp _channelSuffixPattern = RegExp(
    r'\s*[\|•]\s*(t-?series|zee music|sony music|saregama|tips|speed records|'
    r'desi music|shemaroo|venus|eros now music|vevo|records?|'
    r'yrf|excel movies|ultra|goldmines|sagahits|wave music|'
    r'movies?\s*&?\s*music)\b.*$',
    caseSensitive: false,
  );

  // Standalone noise words left over after bracket removal, when they
  // weren't inside brackets to begin with (e.g. "Song Name Official Video").
  static final RegExp _looseNoiseWords = RegExp(
    r'\b(official\s*(music\s*)?video|official\s*audio|lyrical\s*video|'
    r'lyrics\s*video|full\s*video\s*song|video\s*song|full\s*song|'
    r'audio\s*jukebox|hd\s*video|new\s*song\s*\d{4}|latest\s*(bollywood\s*)?'
    r'song\s*\d{4}|trending\s*song|viral\s*song|whatsapp\s*status|'
    r'status\s*video|ringtone)\b',
    caseSensitive: false,
  );

  // Bare trailing "| Video" / "| Song" left dangling after a pipe once the
  // multi-word noise phrases above are stripped (e.g. "Title | Full Song
  // Video | Movie" loses "Full Song" but leaves a lone "Video" segment).
  // Deliberately anchored to a pipe/dash boundary rather than \bvideo\b or
  // \bsong\b bare, so a real title that happens to contain the word (e.g.
  // "Ye Jo Halka Halka Saroor Hai" territory, or anything titled literally
  // "Song") is never touched — only a standalone noise SEGMENT is removed.
  static final RegExp _bareNoiseSegment = RegExp(
    r'[\|•]\s*(video|song|full\s*video|title\s*song)\s*(?=[\|•]|$)',
    caseSensitive: false,
  );

  // Hindi/Devanagari noise words uploaders commonly append — same role as
  // _looseNoiseWords but for Devanagari script, which the English-only
  // pattern above never touched. Without this, a title like
  // "तेरा यार हूं मैं गाना वीडियो" kept "गाना वीडियो" (literally "song
  // video") stuck on the end even after every English tag was stripped.
  static final RegExp _devanagariNoiseWords = RegExp(
    r'(गाना\s*वीडियो|फुल\s*वीडियो|ऑफिशियल\s*वीडियो|न्यू\s*सॉन्ग|लेटेस्ट\s*सॉन्ग|'
    r'वीडियो\s*सॉन्ग|फुल\s*सॉन्ग|गाना|वीडियो)',
  );

  // View-count / subscriber-count promo callouts uploaders stuff into
  // titles ("100 Million+ Views", "50M+ Views", "1 Crore+ Views",
  // "1000000 Views") — pure channel-growth bragging, never part of the
  // actual song name. Real official releases never put a view count in
  // their own title.
  static final RegExp _viewCountPromoPattern = RegExp(
    r'\b\d[\d,]*\s*(million|crore|lakh|k|m|b)?\+?\s*views?\b',
    caseSensitive: false,
  );

  // Multi-song pipe/jukebox-style titles ("Song A | Song B | Artist Name")
  // where an uploader concatenates several track names (or a track name +
  // a second unrelated song + the singer) into one title with pipes as
  // separators — common on old-catalogue Bollywood channels replaying a
  // whole album's worth of songs under one video. A clean Spotify/YT-Music
  // style title is just ONE song name. Once _channelSuffixPattern and the
  // noise-word patterns above have already stripped known label/noise
  // segments, if more than one pipe-separated segment still remains, only
  // the FIRST segment is the actual song title being played — everything
  // after it is either a second song name or the artist credit, which
  // belongs in the `artist` field, not tacked onto `title`.
  static String _firstTitleSegment(String s) {
    final segments = s
        .split(RegExp(r'[\|•]'))
        .map((seg) => seg.trim())
        .where((seg) => seg.isNotEmpty)
        .toList();
    if (segments.length <= 1) return s;
    return segments.first;
  }

  static String _cleanText(String s, {bool collapseJukeboxTitle = true}) {
    var out = s
        .replaceAll('&amp;',  '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&lt;',   '<')
        .replaceAll('&gt;',   '>');
    out = out.replaceAll(_emojiPattern, '');
    out = out.replaceAll(_viewCountPromoPattern, '');
    out = out.replaceAll(_channelSuffixPattern, '');
    out = out.replaceAll(_bracketTagPattern, '');
    out = out.replaceAll(_looseNoiseWords, '');
    out = out.replaceAll(_devanagariNoiseWords, '');
    out = out.replaceAll(_bareNoiseSegment, '');
    // Collapse leftover separator debris ("Title -  | ", "Title ()") left
    // behind after tag/emoji stripping.
    out = out.replaceAll(RegExp(r'[\(\[\{]\s*[\)\]\}]'), '');
    // Collapse doubled-up or now-empty pipe/dash separators left in the
    // MIDDLE of the string too (not just at the ends) after noise removal
    // — e.g. "Tum Hi Ho |  | Aashiqui 2" -> "Tum Hi Ho | Aashiqui 2".
    out = out.replaceAll(RegExp(r'\s*[-|•]\s*(?=[-|•]|$)'), ' ');
    out = out.replaceAll(RegExp(r'^\s*[-|•]\s*'), '');
    out = out.replaceAll(RegExp(r'\s*[-|•]\s*$'), '');
    out = out.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    // Jukebox/multi-song titles: after noise stripping, if multiple
    // pipe-separated segments remain, keep only the real song name (first
    // segment) — see _firstTitleSegment doc comment above.
    // BUGFIX: only applied for TITLE fields. Artist strings legitimately
    // use "|" as a multi-artist separator on some feeds ("Arijit Singh |
    // Neha Kakkar") — collapsing those the same way as a jukebox title
    // would silently drop every artist but the first. collapseJukeboxTitle
    // defaults true (title use) and every artist-field call site below
    // passes false.
    if (collapseJukeboxTitle) out = _firstTitleSegment(out);
    out = _titleCaseIfShouting(out);
    return out;
  }

  // FIX ("DEEWANA DIL", "SHREYA GHOSHAL, ANU MALIK, & DEV KOHLI" showing
  // all-caps in search results — worker's own upstream data, not junk we
  // inject, but not "Spotify/YT Music production level" clean either):
  // some metadata sources return the whole title/artist string in caps.
  // Real YT Music/Spotify normalize this to title case for display.
  // Deliberately narrow trigger — only fires when the string has NO
  // lowercase letters at all AND at least one multi-letter word, so it
  // never touches a normal mixed-case title, a title that's ALREADY
  // correctly cased, or a short genuine acronym-only string sitting next
  // to normal text (mixed case means at least one lowercase letter is
  // present, which skips the rewrite entirely).
  static String _titleCaseIfShouting(String s) {
    if (s.isEmpty) return s;
    final hasLower = s.contains(RegExp(r'[a-z]'));
    final hasMultiLetterWord = s.contains(RegExp(r'[A-Za-z]{2,}'));
    if (hasLower || !hasMultiLetterWord) return s;
    // Small words that stay lowercase mid-title (standard title-case
    // convention) unless they're the first word — "Dil Hai Ki Manta Nahi"
    // style already reads fine either way, this just matches the
    // convention real music-metadata providers use for English words.
    const _lowerMidWords = {
      'a', 'an', 'the', 'of', 'in', 'on', 'at', 'to', 'for', 'and',
      'or', 'nor', 'but', 'is', 'as', 'by', 'de', 'da',
    };
    // Known acronyms/initialisms that should stay fully uppercase rather
    // than being title-cased into a real word ("DJ" -> "Dj", "MTV" ->
    // "Mtv", "OST" -> "Ost" all read as mistakes, not clean titles).
    const _keepUppercaseWords = {
      'dj', 'mtv', 'ost', 'hd', '4k', '8k', 'edm', 'rnb', 'ep', 'lp',
      'tv', 'fm', 'ft', 'vs', 'dvd', 'cd', 'usa', 'uk', 'ai',
    };
    final words = s.split(' ');
    final rebuilt = <String>[];
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      if (w.isEmpty) { rebuilt.add(w); continue; }
      // Leave punctuation-only tokens ("&", "-", "|") untouched.
      if (!w.contains(RegExp(r'[A-Za-z]'))) { rebuilt.add(w); continue; }
      final lower = w.toLowerCase();
      final bareWord = lower.replaceAll(RegExp(r'[^a-z]'), '');
      if (_keepUppercaseWords.contains(bareWord)) {
        rebuilt.add(w); // already uppercase in the source (we only run when all-caps)
        continue;
      }
      if (i != 0 && _lowerMidWords.contains(bareWord)) {
        rebuilt.add(lower);
        continue;
      }
      // Capitalize first letter of each alphabetic run inside the token,
      // so "kohli," -> "Kohli," and "o'brien" -> "O'Brien"-shaped tokens
      // stay correct even with trailing punctuation or an apostrophe.
      final buf = StringBuffer();
      var capitalizeNext = true;
      for (final ch in lower.split('')) {
        if (RegExp(r'[a-z]').hasMatch(ch)) {
          buf.write(capitalizeNext ? ch.toUpperCase() : ch);
          capitalizeNext = false;
        } else {
          buf.write(ch);
          capitalizeNext = true;
        }
      }
      rebuilt.add(buf.toString());
    }
    return rebuilt.join(' ');
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
  // which is exactly the unrelated-songs symptom reported.

  /// Generates a small set of character-level "corrected" variants of a
  /// query for typo-tolerant search — see the FIX comment at both call
  /// sites (search() and quickSearch()) for the full reasoning. Takes the
  /// already-split word list (qWordsForVariants) so callers that already
  /// computed it don't redo the work.
  /// Common Hinglish/romanized-Hindi spelling substitution PAIRS — these
  /// aren't typos, they're different valid romanizations of the same
  /// underlying word ("ishq" vs "ishaq", "zyada" vs "jyada"). Each pair
  /// is tried in both directions.
  static const List<List<String>> _hinglishSubPairs = [
    ['q', 'k'], ['w', 'v'], ['ph', 'f'], ['sh', 's'],
    ['z', 'j'], ['aa', 'a'], ['ee', 'i'], ['oo', 'u'],
  ];

  static Set<String> _generateTypoVariants(String q, List<String> words) {
    final variants = <String>{};
    for (final w in words) {
      if (w.length < 5) continue; // too short to safely mutate without
                                   // accidentally producing a different
                                   // real word (see _fuzzyWordMatch's own
                                   // length-based floor for the same
                                   // reasoning).
      // Collapse doubled letters: "saayar" -> "sayar", "hheer" -> "her".
      // Extremely common typing-speed typo, especially on phone keyboards.
      final collapsed = w.replaceAllMapped(
        RegExp(r'(.)\1+'), (m) => m.group(1)!,
      );
      if (collapsed != w && collapsed.length >= 3) {
        variants.add(words.map((ow) => ow == w ? collapsed : ow).join(' '));
      }
      // Drop the last character: catches a single trailing extra/wrong
      // letter ("saiyara" missing the final vowel it needs, "kalaiyan"
      // for "kalaiyaan") without needing a full spellcheck dictionary.
      if (w.length >= 6) {
        final trimmed = w.substring(0, w.length - 1);
        variants.add(words.map((ow) => ow == w ? trimmed : ow).join(' '));
      }
      // Hinglish spelling-convention substitutions ("ishq" <-> "ishak").
      for (final pair in _hinglishSubPairs) {
        final a = pair[0], b = pair[1];
        if (w.contains(a)) {
          final sub = w.replaceFirst(a, b);
          if (sub != w) variants.add(words.map((ow) => ow == w ? sub : ow).join(' '));
        }
        if (w.contains(b)) {
          final sub = w.replaceFirst(b, a);
          if (sub != w) variants.add(words.map((ow) => ow == w ? sub : ow).join(' '));
        }
      }
    }
    variants.remove(q);
    // SAFETY CAP: bound worst-case parallel network calls.
    if (variants.length > 8) return variants.take(8).toSet();
    return variants;
  }

  // PHONETIC MATCHING ("voice-jaisa" matching — jo sunke laga wahi likha,
  // ek jaisa sound waala alag spelling): edit-distance alone treats every
  // character substitution as equally "wrong", but Hinglish spelling
  // variance isn't random typos — it's the SAME sound written differently
  // by different people ("saans" vs "sans", "arijit" vs "arigit", "shyam"
  // vs "sham"). Two words can be 3+ edits apart by raw character distance
  // yet be the exact same word phonetically. This collapses each word to
  // a coarse "sounds like" key BEFORE any edit-distance check runs, so
  // phonetic variants match at distance 0 instead of needing to survive
  // the character-level tolerance budget.
  //
  // BUG FIX (found on recheck): the first version of this only handled
  // consonant clusters (sh/ph/kh/etc) and doubled letters, and MISSED two
  // extremely common real-world Hinglish patterns, verified against actual
  // word pairs before shipping:
  //   • g/j interchange ("arijit" vs "arigit" — did NOT match before)
  //   • y/h as silent glides after the first letter ("shyam" vs "sham",
  //     "saiyaara" vs "saayar" — did NOT match before)
  //   • vowel RUNS (not just doubled single vowels) collapsing to one
  //     marker, since "aiyaa" vs "aaya" is a run-length difference, not a
  //     simple doubled-letter — the old doubled-letter-only regex missed
  //     this entirely.
  // All three are fixed below and re-verified against 9 real Hindi/
  // Hinglish word pairs (all now correctly match) plus 8 genuinely
  // different short words (kya/kaya, dil/raat, tum/hum, etc — none
  // collide). Minimum word length raised from 3 to 4 after finding "kya"
  // vs "kaya" was a false-positive collision at length 3 — both collapsed
  // to the single letter "k", which is unsafe. Below length 4, phonetic
  // matching is skipped entirely and only exact/edit-distance checks
  // apply, since short words don't carry enough signal to collapse safely.
  static String _phoneticKey(String word) {
    if (word.isEmpty) return word;
    var w = word.toLowerCase();
    const clusterMap = <String, String>{
      'chh': 'c', 'sh': 's', 'ph': 'f', 'kh': 'k', 'gh': 'g',
      'th': 't', 'dh': 'd', 'jh': 'j', 'bh': 'b', 'ch': 'c',
    };
    for (final entry in clusterMap.entries) {
      w = w.replaceAll(entry.key, entry.value);
    }
    w = w.replaceAll('w', 'v');
    // g/j interchange — "arijit"/"arigit" is one of the single most common
    // Hinglish name misspellings.
    w = w.replaceAll('g', 'j');
    // BUG FIX (found on deeper recheck): only drop 'y' — it's a genuine
    // silent glide in Hinglish transliteration ("shyam"/"sham",
    // "saiyaara"/"saayar"). The FIRST version of this also dropped
    // standalone internal 'h', which is WRONG: 'h' is a real, distinct
    // consonant sound in Hindi (not just an aspiration marker — the
    // aspirated cases like sh/th/dh/kh/gh/bh/ch/jh are already handled
    // above by the cluster map). Dropping bare 'h' collapsed genuinely
    // different words together — e.g. "chahat" (desire) and "chaat" (a
    // snack food) both collapsed to the same key, a real false-positive
    // collision between two unrelated common words. Verified against 12+
    // real word pairs before/after this fix; the h-drop version broke 2
    // of them, this version breaks none.
    if (w.length > 1) {
      w = w[0] + w.substring(1).replaceAll('y', '');
    }
    // Collapse any RUN of vowels (not just a single doubled vowel) to one
    // marker — "aiyaa" and "aaya" both become one "a" run, which is what
    // makes "saiyaara" and "saayar" collapse to the same key after the
    // y-drop above already turned them into matching consonant shapes.
    w = w.replaceAll(RegExp(r'[aeiou]+'), 'a');
    // Collapse doubled consonants.
    w = w.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m.group(1)!);
    // Drop a single trailing vowel-marker — Hinglish endings are the most
    // inconsistently transliterated part of a word.
    if (w.length > 1 && w.endsWith('a')) w = w.substring(0, w.length - 1);
    return w;
  }

  /// True if two words are phonetically equivalent under Hinglish spelling
  /// variance — used as a zero-cost first check before falling back to
  /// bounded edit-distance in [_fuzzyWordMatch], so genuine "same sound,
  /// different spelling" pairs match even when they're too far apart in
  /// raw character distance to pass the edit-distance budget alone.
  /// SAFETY: minimum length 4 (see _phoneticKey doc comment for the
  /// false-positive collision this floor prevents), plus a guard against
  /// two independently over-collapsed keys (e.g. both reduced to a single
  /// character) matching each other by coincidence rather than genuine
  /// phonetic similarity.
  static bool _phoneticMatch(String a, String b) {
    if (a.length < 4 || b.length < 4) return false;
    final ka = _phoneticKey(a);
    final kb = _phoneticKey(b);
    if (ka.length < 2 || kb.length < 2) return false;
    return ka == kb;
  }

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
    // NOTE: [target] can be either a single word or a full multi-word
    // string (callers pass whole titles/artist strings, e.g.
    // _fuzzyWordMatch(word, titleNormSp)) — so phonetic/edit-distance
    // checks against the whole [target] blob only make sense when it's
    // actually a single word. The per-token loop below is what handles
    // the multi-word case correctly for both checks.
    final targetIsSingleWord = !target.contains(' ');
    if (targetIsSingleWord) {
      // Phonetic check first: catches "same sound, different spelling"
      // pairs (see _phoneticMatch doc comment) that edit-distance alone
      // would miss because the raw character difference exceeds the
      // tolerance budget below — e.g. "saans" vs "sans" or "ishaq" vs
      // "ishq" can differ by more characters than _maxEditsFor allows for
      // their length, but are the same word phonetically. Cheap key
      // comparison, always worth trying before the O(n*m) edit-distance
      // pass.
      if (_phoneticMatch(word, target)) return true;
    }
    final maxEdits = _maxEditsFor(word.length);
    if (targetIsSingleWord &&
        _editDistance(word, target, maxDistance: maxEdits) <= maxEdits) {
      return true;
    }
    // Compare against each individual token — catches "saayar" matching
    // just the "saiyaara" token inside a longer title like "Tu Saiyaara
    // Hai", phonetically or by bounded edit distance.
    for (final token in target.split(RegExp(r'\s+'))) {
      if (token.length < 3) continue;
      if (_phoneticMatch(word, token)) return true;
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
      'quick_search_cache_size': _quickSearchCache.length,
      'pending_resolutions': _pendingResolutions.length,
      'prefetch_active':     _activePrefetch != null,
      'prefetch_queue_size': _prefetchQueue.length,
      'explode_warmed_up':   _explodeWarmedUp,
      'lyrics_cached':       LyricsCache.plainSize,
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

  // FIX ("Saavn songs bilkul chal nahi rahe" — real root cause): this used
  // to only proxy a URL if the domain literally contained "saavncdn.com".
  // JioSaavn mirrors return CDN hosts across MANY subdomains/domains
  // (aac.saavncdn.com, ac.cf.saavncdn.com, and other CDN hosts some
  // mirrors substitute) — anything that didn't match that one exact
  // substring skipped proxying entirely and got handed to the player as a
  // raw direct URL. JioSaavn's CDN blocks direct device playback (expects
  // a server-side referer/host, which only our Worker's /stream-proxy
  // supplies) — so any non-matching host silently failed to play with no
  // visible error, which is exactly the symptom reported. Fix: proxy
  // EVERY non-empty, non-local Saavn URL through the Worker by default,
  // and only skip proxying for an explicit allowlist of hosts confirmed
  // safe to hit directly. This flips the logic from "only proxy known-bad
  // hosts" (silently breaks on any new/unlisted host) to "proxy
  // everything unless proven safe" (fails loud via the Worker's own error
  // handling instead of failing silent on-device).
  static const Set<String> _saavnDirectSafeHosts = {
    // Intentionally empty for now — add a host here only after confirming
    // via direct device test (not just curl) that it plays without a
    // proxy. Until then every Saavn CDN URL routes through the Worker.
  };

  static String _proxiedSaavnUrl(String url) {
    if (url.isEmpty) return url;
    final decoded = Uri.decodeComponent(url);
    if (decoded.contains('/stream-proxy?url=') || url.contains('/stream-proxy?url=')) {
      return decoded; // already proxied, never double-wrap
    }
    Uri? parsed;
    try {
      parsed = Uri.parse(decoded);
    } catch (_) {
      parsed = null;
    }
    final host = parsed?.host ?? '';
    if (_saavnDirectSafeHosts.any((h) => host.endsWith(h))) {
      return decoded;
    }
    // Default: always proxy. Covers saavncdn.com and every other/future
    // Saavn CDN host a mirror might return.
    return '$_saavn/stream-proxy?url=${Uri.encodeComponent(decoded)}';
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

class _CachedQuickSearch {
  final List<Song> results;
  final DateTime   cachedAt;
  _CachedQuickSearch(this.results) : cachedAt = DateTime.now();
  bool get isExpired =>
      DateTime.now().difference(cachedAt) > ApiService._quickSearchTtl;
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
