import 'dart:convert';
import 'dart:developer' as dev;
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/song.dart';
import '../utils/constants.dart';

/// ═══════════════════════════════════════════════════════════════
///  AURUM API SERVICE  —  production-grade, audited
///
///  Stream resolution priority (all sources):
///    1. Cache hit (50-min TTL) → return immediately
///    2. SongSource.saavn  → Saavn /song/?id= → 320kbps URL
///                           → YT search fallback
///    3. SongSource.youtube → Cloudflare worker /api/yt-stream?id=
///                           → youtube_explode_dart fallback
///                           → YT search fallback
///    4. SongSource.local  → localPath
///
///  Source detection is based SOLELY on song.source enum, which is
///  set at parse time from the origin API response — no ID-regex
///  guessing anywhere.
/// ═══════════════════════════════════════════════════════════════
class ApiService {
  static final _client = http.Client();
  static final _yt = YoutubeExplode();

  // ── Base URLs ──────────────────────────────────────────────────
  static const _saavn  = 'https://jiosavan.onrender.com';
  static const _worker = AppConstants.apiBase; // https://aurum-stream.sharmashivam9109.workers.dev

  // ── Stream cache ───────────────────────────────────────────────
  static final Map<String, _CachedStream> _streamCache = {};
  static const _streamTtl = Duration(minutes: 50);

  // ═══════════════════════════════════════════════════════════════
  //  HOME
  // ═══════════════════════════════════════════════════════════════

  static Future<List<SongSection>> fetchHome() async {
    final results = await Future.wait([
      _saavnSection('trending hindi songs', '🔥 Trending Now'),
      _saavnSection('bollywood hits', '🎬 Bollywood Hits'),
      _saavnSection('hindi top charts', '🎵 Hindi Top Charts'),
      _saavnSection('english pop hits', '🎧 English Hits'),
    ]);
    return results.whereType<SongSection>().toList();
  }

  static Future<SongSection?> _saavnSection(String query, String label) async {
    final songs = await _searchSaavn(query, limit: 15);
    if (songs.isNotEmpty) return SongSection(title: label, songs: songs);
    return null;
  }

  // ═══════════════════════════════════════════════════════════════
  //  SEARCH — JioSaavn + YouTube combined
  // ═══════════════════════════════════════════════════════════════

  static Future<List<Song>> search(String query) async {
    final both = await Future.wait([
      _searchSaavn(query, limit: 20),
      _searchYt(query, limit: 15),
    ]);

    final saavnResults = both[0];
    final ytResults    = both[1];

    final merged = <Song>[...saavnResults];
    final existingTitles = saavnResults
        .map((s) => _normalise(s.title))
        .toSet();

    for (final yt in ytResults) {
      if (!existingTitles.contains(_normalise(yt.title))) {
        merged.add(yt);
      }
    }
    return merged;
  }

  static String _normalise(String s) {
    final clean = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return clean.substring(0, clean.length.clamp(0, 20));
  }

  // ── JioSaavn search ───────────────────────────────────────────

  static Future<List<Song>> _searchSaavn(String query, {int limit = 20}) async {
    try {
      final url = Uri.parse(
        '$_saavn/result/?query=${Uri.encodeQueryComponent(query)}&limit=$limit',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 10));
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
      dev.log('[Aurum] Saavn search error: $e', name: 'ApiService');
    }
    return [];
  }

  // ── YouTube search (client-side via youtube_explode_dart) ──────

  static Future<List<Song>> _searchYt(String query, {int limit = 15}) async {
    try {
      final results = await _yt.search
          .search(query)
          .timeout(const Duration(seconds: 6));
      return results
          .whereType<Video>()
          .take(limit)
          .map(_songFromYtVideo)
          .where((s) => s.id.isNotEmpty)
          .toList();
    } catch (e) {
      dev.log('[Aurum] YT search error: $e', name: 'ApiService');
    }
    return [];
  }

  static Song _songFromYtVideo(Video v) {
    final thumb = v.thumbnails.maxResUrl.isNotEmpty
        ? v.thumbnails.maxResUrl
        : v.thumbnails.highResUrl;
    return Song(
      id: v.id.value,
      title: _cleanText(v.title),
      artist: _cleanText(v.author),
      album: '',
      artworkUrl: thumb,
      streamUrl: null,
      duration: v.duration?.inSeconds,
      source: SongSource.youtube, // ← EXPLICIT, never guessed
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  SUGGESTIONS
  // ═══════════════════════════════════════════════════════════════

  static Future<List<String>> suggest(String query) async {
    final results = await _suggestSaavn(query);
    return results.take(8).toList();
  }

  static Future<List<String>> _suggestSaavn(String query) async {
    try {
      final url = Uri.parse(
        '$_saavn/result/?query=${Uri.encodeQueryComponent(query)}&limit=5',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 5));
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

  // ═══════════════════════════════════════════════════════════════
  //  STREAM URL RESOLUTION  ← THE AUDITED CORE
  //
  //  BUG FIXED: source detection is now 100% based on song.source
  //  enum, which is set at search/parse time. No regex. No guessing.
  //
  //  FLOW:
  //    Step 1 → cache check (return immediately if hit)
  //    Step 2 → local shortcut
  //    Step 3 → switch on song.source (saavn / youtube / local)
  //    Step 4 → cache resolved URL, return
  // ═══════════════════════════════════════════════════════════════

  static Future<String?> resolveStreamUrl(
    Song song, {
    bool forceRefresh = false,
  }) async {
    // ── Step 1: local shortcut ─────────────────────────────────
    if (song.isLocal) {
      dev.log('[Aurum] resolveStreamUrl: local path ${song.localPath}',
          name: 'ApiService');
      return song.localPath;
    }

    final cacheKey = '${song.source.name}:${song.id}';

    // ── Step 2: cache hit ──────────────────────────────────────
    if (!forceRefresh) {
      final cached = _streamCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        dev.log('[Aurum] resolveStreamUrl: cache HIT for ${song.title} '
            '(${song.source.name}:${song.id})',
            name: 'ApiService');
        return cached.url;
      }
    }

    // ── Step 3: pre-fetched streamUrl shortcut (Saavn 320kbps) ─
    // Only trust if the song is explicitly Saavn and the URL looks valid.
    if (!forceRefresh &&
        song.source == SongSource.saavn &&
        song.streamUrl != null &&
        song.streamUrl!.startsWith('http')) {
      dev.log('[Aurum] resolveStreamUrl: using pre-fetched Saavn URL '
          'for "${song.title}"',
          name: 'ApiService');
      _streamCache[cacheKey] = _CachedStream(song.streamUrl!);
      return song.streamUrl;
    }

    dev.log('[Aurum] resolveStreamUrl: resolving "${song.title}" '
        'source=${song.source.name} id=${song.id} forceRefresh=$forceRefresh',
        name: 'ApiService');

    String? url;

    // ── Step 4: source-aware resolution ───────────────────────
    switch (song.source) {

      // ── SAAVN ──────────────────────────────────────────────
      case SongSource.saavn:
        if (song.id.isNotEmpty) {
          url = await _retry(() => _saavnStreamById(song.id));
          dev.log('[Aurum] Saavn stream by ID: ${url != null ? "OK" : "FAILED"}',
              name: 'ApiService');
        }
        if (url == null) {
          dev.log('[Aurum] Saavn stream failed, falling back to YT search '
              'for "${song.title} ${song.artist}"',
              name: 'ApiService');
          url = await _retry(
              () => _ytStreamBySearch('${song.title} ${song.artist}'));
        }
        break;

      // ── YOUTUBE ────────────────────────────────────────────
      //  Priority: Worker → youtube_explode_dart → YT search
      case SongSource.youtube:
        if (song.id.isNotEmpty) {
          // PRIMARY: Cloudflare worker (avoids client-IP Innertube blocks)
          url = await _retry(() => _workerYtStream(song.id));
          dev.log('[Aurum] Worker YT stream for ${song.id}: '
              '${url != null ? "OK" : "FAILED"}',
              name: 'ApiService');

          // FALLBACK 1: youtube_explode_dart direct
          if (url == null) {
            dev.log('[Aurum] Falling back to youtube_explode_dart for ${song.id}',
                name: 'ApiService');
            url = await _retry(() => _ytExplodeStream(song.id));
          }
        }
        // FALLBACK 2: search-based resolution
        if (url == null) {
          dev.log('[Aurum] Falling back to YT search stream for '
              '"${song.title} ${song.artist}"',
              name: 'ApiService');
          url = await _retry(
              () => _ytStreamBySearch('${song.title} ${song.artist}'));
        }
        break;

      case SongSource.local:
        return song.localPath;
    }

    if (url != null) {
      dev.log('[Aurum] resolveStreamUrl: resolved "${song.title}" → '
          '${url.substring(0, url.length.clamp(0, 80))}...',
          name: 'ApiService');
      _streamCache[cacheKey] = _CachedStream(url);
    } else {
      dev.log('[Aurum] resolveStreamUrl: FAILED for "${song.title}" '
          '(${song.source.name}:${song.id})',
          name: 'ApiService');
    }

    return url;
  }

  // ═══════════════════════════════════════════════════════════════
  //  YOUTUBE STREAM METHODS
  // ═══════════════════════════════════════════════════════════════

  /// PRIMARY: Route through Cloudflare worker to avoid client-IP
  /// Innertube bot-detection blocks. The worker calls Innertube
  /// from a trusted server IP, which is exactly what SimpMusic,
  /// InnerTune, and RiMusic do behind their reverse proxies.
  static Future<String?> _workerYtStream(String videoId) async {
    try {
      final uri = Uri.parse('$_worker/api/yt-stream?id=$videoId');
      dev.log('[Aurum] Worker request: $uri', name: 'ApiService');
      final res = await _client
          .get(uri)
          .timeout(const Duration(seconds: 15));
      dev.log('[Aurum] Worker response: status=${res.statusCode} '
          'headers=${res.headers}',
          name: 'ApiService');
      if (res.statusCode == 200) {
        // Worker may return: { "url": "..." } or redirect or raw audio
        final ct = res.headers['content-type'] ?? '';
        if (ct.contains('application/json')) {
          final data = jsonDecode(res.body);
          final url = (data['url'] ?? data['stream_url'] ?? data['audio_url'])
              ?.toString();
          if (url != null && url.startsWith('http')) return url;
          dev.log('[Aurum] Worker JSON body had no URL: ${res.body.substring(0, res.body.length.clamp(0, 200))}',
              name: 'ApiService');
          return null;
        }
        // If worker returns redirect or direct stream URL in body as text
        final body = res.body.trim();
        if (body.startsWith('http')) return body;
      } else {
        dev.log('[Aurum] Worker error body: ${res.body.substring(0, res.body.length.clamp(0, 300))}',
            name: 'ApiService');
      }
    } catch (e) {
      dev.log('[Aurum] Worker request exception: $e', name: 'ApiService');
    }
    return null;
  }

  /// FALLBACK 1: youtube_explode_dart direct Innertube (may hit bot-detection
  /// on residential/mobile IPs — hence worker is primary).
  static Future<String?> _ytExplodeStream(String videoId) async {
    try {
      final manifest = await _yt.videos.streamsClient
          .getManifest(VideoId(videoId))
          .timeout(const Duration(seconds: 12));
      if (manifest.audioOnly.isEmpty) return null;
      final best = manifest.audioOnly.withHighestBitrate();
      return best.url.toString();
    } catch (e) {
      dev.log('[Aurum] youtube_explode_dart error for $videoId: $e',
          name: 'ApiService');
    }
    return null;
  }

  /// FALLBACK 2: search → pick first video → resolve stream.
  static Future<String?> _ytStreamBySearch(String query) async {
    try {
      final results = await _yt.search
          .search(query)
          .timeout(const Duration(seconds: 12));
      final videos = results.whereType<Video>().toList();
      if (videos.isEmpty) return null;
      final id = videos.first.id.value;
      // Try worker first, then explode
      return await _workerYtStream(id) ?? await _ytExplodeStream(id);
    } catch (e) {
      dev.log('[Aurum] YT search stream error: $e', name: 'ApiService');
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════
  //  SAAVN STREAM METHODS
  // ═══════════════════════════════════════════════════════════════

  static Future<String?> _saavnStreamById(String songId) async {
    try {
      final res = await _client
          .get(Uri.parse('$_saavn/song/?id=$songId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final Map<String, dynamic>? songData = data is List && data.isNotEmpty
            ? data[0] as Map<String, dynamic>?
            : (data is Map ? data as Map<String, dynamic> : null);
        if (songData != null) {
          return _onrenderStreamUrl(songData) ?? _extractSaavnStreamUrl(songData);
        }
      }
    } catch (e) {
      dev.log('[Aurum] Saavn stream by ID error: $e', name: 'ApiService');
    }
    return null;
  }

  static String? _extractSaavnStreamUrl(Map<String, dynamic> song) {
    final downloads = song['downloadUrl'] as List?;
    if (downloads != null && downloads.isNotEmpty) {
      for (final q in ['320kbps', '160kbps', '96kbps', '48kbps', '12kbps']) {
        final match = downloads.firstWhere(
          (d) => d['quality'] == q && (d['url'] as String?)?.startsWith('http') == true,
          orElse: () => null,
        );
        if (match != null) return match['url'] as String;
      }
      final last = downloads.last;
      if ((last['url'] as String?)?.startsWith('http') == true) {
        return last['url'] as String;
      }
    }
    final mediaUrl = song['media_url'] ?? song['streamUrl'];
    if (mediaUrl is String && mediaUrl.startsWith('http')) return mediaUrl;
    return null;
  }

  // ═══════════════════════════════════════════════════════════════
  //  RETRY HELPER
  // ═══════════════════════════════════════════════════════════════

  static Future<String?> _retry(
    Future<String?> Function() fn, {
    int attempts = 2,
  }) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final result = await fn();
        if (result != null && result.isNotEmpty) return result;
      } catch (_) {}
      if (i < attempts - 1) {
        await Future.delayed(const Duration(milliseconds: 400));
      }
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════
  //  CACHE MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  static void invalidateStream(Song song) {
    final key = '${song.source.name}:${song.id}';
    _streamCache.remove(key);
    dev.log('[Aurum] Stream cache invalidated for ${song.source.name}:${song.id}',
        name: 'ApiService');
  }

  static void onNetworkRestored() {
    dev.log('[Aurum] Network restored — cache intact, URLs will re-resolve on demand',
        name: 'ApiService');
  }

  static void prefetchNext(Song song) {
    if (song.isLocal) return;
    Future.microtask(() async {
      try {
        await resolveStreamUrl(song);
      } catch (_) {}
    });
  }

  // ═══════════════════════════════════════════════════════════════
  //  SONG PARSERS
  // ═══════════════════════════════════════════════════════════════

  static Song _songFromSaavn(Map<String, dynamic> j) {
    final title  = _cleanText((j['song'] ?? j['name'] ?? j['title'] ?? 'Unknown').toString());
    final artist = _cleanText((j['primary_artists'] ?? j['singers'] ?? j['artist'] ?? 'Unknown').toString());
    final album  = _cleanText((j['album'] ?? '').toString());
    final artwork   = _onrenderArtwork(j);
    final streamUrl = _onrenderStreamUrl(j);
    return Song(
      id: (j['id'] ?? '').toString(),
      title: title,
      artist: artist.isEmpty ? 'Unknown Artist' : artist,
      album: album,
      artworkUrl: artwork,
      streamUrl: streamUrl,
      duration: _parseInt(j['duration']),
      language: j['language']?.toString() ?? 'hindi',
      year: j['year']?.toString(),
      source: SongSource.saavn, // ← ALWAYS explicit, never regex-guessed
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════

  static String _onrenderArtwork(Map<String, dynamic> j) {
    final img = (j['image'] ?? '').toString();
    if (img.startsWith('http')) {
      return img
          .replaceAll('150x150', '500x500')
          .replaceAll('50x50', '500x500');
    }
    return '';
  }

  static String? _onrenderStreamUrl(Map<String, dynamic> j) {
    final url320 = (j['320kbps'] ?? '').toString();
    if (url320.startsWith('http')) return url320;
    final urlMedia = (j['media_url'] ?? '').toString();
    if (urlMedia.startsWith('http')) return urlMedia;
    return null;
  }

  static String _cleanText(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  static int? _parseInt(dynamic d) {
    if (d == null) return null;
    if (d is int) return d;
    if (d is String) return int.tryParse(d);
    return null;
  }

  // ═══════════════════════════════════════════════════════════════
  //  LYRICS
  // ═══════════════════════════════════════════════════════════════

  static Future<String?> fetchLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return null;
    if (song.source != SongSource.saavn) return null;
    try {
      final res = await _client
          .get(Uri.parse('$_saavn/lyrics/?id=${song.id}'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final lyrics = data['data']?['lyrics'] as String?;
        return (lyrics != null && lyrics.isNotEmpty) ? lyrics : null;
      }
    } catch (_) {}
    return null;
  }

  // ═══════════════════════════════════════════════════════════════
  //  DEBUG
  // ═══════════════════════════════════════════════════════════════

  static Future<String> debugPlaybackPath() async {
    final buf = StringBuffer();
    buf.writeln('=== Aurum Playback Path Debug ===');
    buf.writeln('Time: ${DateTime.now()}');
    buf.writeln('Worker base: $_worker');
    buf.writeln('Saavn base:  $_saavn');
    buf.writeln('');

    // ── Test 1: Worker endpoint ──
    buf.writeln('▶ 1. Testing Cloudflare worker /api/yt-stream?id=dQw4w9WgXcQ');
    try {
      final url = await _workerYtStream('dQw4w9WgXcQ');
      if (url != null) {
        buf.writeln('   ✅ Worker OK → ${url.substring(0, url.length.clamp(0, 80))}...');
      } else {
        buf.writeln('   ❌ Worker returned null — check worker logs');
      }
    } catch (e) {
      buf.writeln('   ❌ Worker exception: $e');
    }
    buf.writeln('');

    // ── Test 2: youtube_explode_dart ──
    buf.writeln('▶ 2. Testing youtube_explode_dart for dQw4w9WgXcQ');
    try {
      final url = await _ytExplodeStream('dQw4w9WgXcQ');
      if (url != null) {
        buf.writeln('   ✅ youtube_explode OK');
      } else {
        buf.writeln('   ❌ youtube_explode returned null (possible Innertube block)');
      }
    } catch (e) {
      buf.writeln('   ❌ youtube_explode exception: $e');
    }
    buf.writeln('');

    // ── Test 3: Saavn search ──
    buf.writeln('▶ 3. Testing Saavn search (arijit singh)');
    try {
      final songs = await _searchSaavn('arijit singh', limit: 1);
      if (songs.isNotEmpty) {
        buf.writeln('   ✅ Saavn search OK — "${songs.first.title}"');
        buf.writeln('   source: ${songs.first.source.name}');
        buf.writeln('   streamUrl present: ${songs.first.streamUrl != null}');
      } else {
        buf.writeln('   ❌ Saavn search returned 0 results');
      }
    } catch (e) {
      buf.writeln('   ❌ Saavn search exception: $e');
    }
    buf.writeln('');

    // ── Test 4: Full resolveStreamUrl for a Saavn song ──
    buf.writeln('▶ 4. Testing resolveStreamUrl for a Saavn song');
    try {
      final songs = await _searchSaavn('arijit singh', limit: 1);
      if (songs.isNotEmpty) {
        final url = await resolveStreamUrl(songs.first);
        buf.writeln(url != null
            ? '   ✅ Saavn resolveStreamUrl OK'
            : '   ❌ Saavn resolveStreamUrl returned null');
      }
    } catch (e) {
      buf.writeln('   ❌ Exception: $e');
    }
    buf.writeln('');

    // ── Test 5: Full resolveStreamUrl for a YouTube song ──
    buf.writeln('▶ 5. Testing resolveStreamUrl for a YouTube song (Rick Astley)');
    try {
      final ytSong = Song(
        id: 'dQw4w9WgXcQ',
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        album: '',
        artworkUrl: '',
        source: SongSource.youtube,
      );
      final url = await resolveStreamUrl(ytSong, forceRefresh: true);
      buf.writeln(url != null
          ? '   ✅ YouTube resolveStreamUrl OK'
          : '   ❌ YouTube resolveStreamUrl returned null — BOTH worker and explode failed');
    } catch (e) {
      buf.writeln('   ❌ Exception: $e');
    }

    return buf.toString();
  }
}

/// A resolved stream URL with an expiry timestamp.
class _CachedStream {
  final String url;
  final DateTime _resolvedAt;

  _CachedStream(this.url) : _resolvedAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(_resolvedAt) > ApiService._streamTtl;
}
