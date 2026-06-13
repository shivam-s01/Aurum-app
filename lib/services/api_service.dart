import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/song.dart';

/// Sources:
///   Search  → JioSaavn + YouTube (youtube_explode_dart, client-side) combined results
///   Home    → JioSaavn trending sections + YouTube trending
///   Stream  → JioSaavn 320kbps → YouTube audio (resolved on-device via youtube_explode_dart)
class ApiService {
  static final _client = http.Client();
  static final _yt = YoutubeExplode();

  static const _saavn = 'https://jiosavan.onrender.com';

  // ─────────────────────────────────────────────────────────
  //  STREAM URL CACHE
  //  Avoids re-resolving the same song's stream repeatedly.
  //  YouTube URLs expire (~6hrs), Saavn URLs are longer-lived
  //  but we cache both with a conservative TTL.
  // ─────────────────────────────────────────────────────────
  static final Map<String, _CachedStream> _streamCache = {};
  static const _streamTtl = Duration(minutes: 50);

  // ═══════════════════════════════════════════════════════════
  //  HOME
  // ═══════════════════════════════════════════════════════════

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

  // ═══════════════════════════════════════════════════════════
  //  SEARCH — JioSaavn + YouTube combined
  // ═══════════════════════════════════════════════════════════

  static Future<List<Song>> search(String query) async {
    // Run both in parallel
    final both = await Future.wait([
      _searchSaavn(query, limit: 20),
      _searchYt(query, limit: 15),
    ]);

    final saavnResults = both[0];
    final ytResults = both[1];

    // Merge: interleave so both sources visible (Saavn first, then YT)
    // De-duplicate by title+artist similarity
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

  static String _normalise(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').substring(
            0,
            s.length > 20 ? 20 : s.length,
          );

  // ── JioSaavn search ───────────────────────────────────────

  static Future<List<Song>> _searchSaavn(String query, {int limit = 20}) async {
    try {
      final url = Uri.parse(
        '$_saavn/result/?query=${Uri.encodeQueryComponent(query)}&limit=$limit',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        // onrender returns a List directly
        final results = data is List ? data : (data['data']?['results'] ?? data['data'] ?? []);
        if (results is List && results.isNotEmpty) {
          return results
              .whereType<Map<String, dynamic>>()
              .take(limit)
              .map(_songFromSaavn)
              .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
              .toList();
        }
      }
    } catch (_) {}
    return [];
  }

  // ── YouTube search (client-side via youtube_explode_dart) ──

  static Future<List<Song>> _searchYt(String query, {int limit = 15}) async {
    try {
      final results = await _yt.search.search(query).timeout(const Duration(seconds: 6));
      return results
          .whereType<Video>()
          .take(limit)
          .map(_songFromYtVideo)
          .where((s) => s.id.isNotEmpty)
          .toList();
    } catch (_) {}
    return [];
  }

  static Song _songFromYtVideo(Video v) {
    // Pick the highest-resolution thumbnail available
    final thumb = v.thumbnails.maxResUrl.isNotEmpty
        ? v.thumbnails.maxResUrl
        : v.thumbnails.highResUrl;
    return Song(
      id: v.id.value,
      title: _cleanText(v.title),
      artist: _cleanText(v.author),
      album: '',
      artworkUrl: thumb,
      streamUrl: null, // resolved fresh on play
      duration: v.duration?.inSeconds,
      source: SongSource.youtube,
    );
  }

  // ═══════════════════════════════════════════════════════════
  //  SUGGESTIONS
  // ═══════════════════════════════════════════════════════════

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
              .map((j) => _cleanText((j['song'] ?? j['name'] ?? j['title'] ?? '').toString()))
              .where((s) => s.isNotEmpty)
              .take(5)
              .toList();
        }
      }
    } catch (_) {}
    return [];
  }

  // ═══════════════════════════════════════════════════════════
  //  STREAM URL RESOLUTION
  //  Priority: cache → JioSaavn 320kbps → YouTube fallback
  //  Cached, retried, and source-aware (no ID guessing).
  // ═══════════════════════════════════════════════════════════

  static Future<String?> resolveStreamUrl(Song song, {bool forceRefresh = false}) async {
    if (song.isLocal) return song.localPath;

    final cacheKey = '${song.source.name}:${song.id}';

    // 1. Cache hit — return instantly if not expired
    if (!forceRefresh) {
      final cached = _streamCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        return cached.url;
      }
    }

    // 2. Pre-fetched streamUrl from search results (Saavn sets this)
    if (!forceRefresh && song.streamUrl != null && song.streamUrl!.startsWith('http')) {
      _streamCache[cacheKey] = _CachedStream(song.streamUrl!);
      return song.streamUrl;
    }

    String? url;

    // 3. Source-aware resolution (no ID-pattern guessing)
    switch (song.source) {
      case SongSource.youtube:
        url = await _retry(() => _ytStreamByVideoId(song.id));
        url ??= await _retry(() => _ytStreamBySearch('${song.title} ${song.artist}'));
        break;

      case SongSource.saavn:
        if (song.id.isNotEmpty) {
          url = await _retry(() => _saavnStreamById(song.id));
        }
        url ??= await _retry(() => _ytStreamBySearch('${song.title} ${song.artist}'));
        break;

      case SongSource.local:
        return song.localPath;
    }

    if (url != null) {
      _streamCache[cacheKey] = _CachedStream(url);
    }
    return url;
  }

  /// Retry a resolver up to 2 times with a short delay — handles transient
  /// network blips without giving up on the first failure.
  static Future<String?> _retry(Future<String?> Function() fn, {int attempts = 2}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final result = await fn();
        if (result != null && result.isNotEmpty) return result;
      } catch (_) {}
      if (i < attempts - 1) await Future.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }

  /// Call this when a song fails to play (e.g. 403/expired URL) — clears the
  /// cached stream so the next attempt re-resolves fresh.
  static void invalidateStream(Song song) {
    _streamCache.remove('${song.source.name}:${song.id}');
  }

  // ── JioSaavn stream ───────────────────────────────────────

  static Future<String?> _saavnStreamById(String songId) async {
    try {
      // onrender: /song/?id=SONGID
      final res = await _client
          .get(Uri.parse('$_saavn/song/?id=$songId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        // onrender returns list or single object
        final Map<String, dynamic>? songData = data is List && data.isNotEmpty
            ? data[0] as Map<String, dynamic>?
            : (data is Map ? data as Map<String, dynamic> : null);
        if (songData != null) {
          final url = _onrenderStreamUrl(songData) ?? _extractSaavnStreamUrl(songData);
          return url;
        }
      }
    } catch (_) {}
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
      if ((last['url'] as String?)?.startsWith('http') == true) return last['url'] as String;
    }
    final mediaUrl = song['media_url'] ?? song['streamUrl'];
    if (mediaUrl is String && mediaUrl.startsWith('http')) return mediaUrl;
    return null;
  }

  // ── YouTube stream (client-side via youtube_explode_dart) ──

  static Future<String?> _ytStreamByVideoId(String videoId) async {
    try {
      final manifest = await _yt.videos.streamsClient
          .getManifest(VideoId(videoId))
          .timeout(const Duration(seconds: 12));
      if (manifest.audioOnly.isEmpty) return null;
      final best = manifest.audioOnly.withHighestBitrate();
      return best.url.toString();
    } catch (_) {}
    return null;
  }

  static Future<String?> _ytStreamBySearch(String query) async {
    try {
      final results = await _yt.search.search(query).timeout(const Duration(seconds: 12));
      final videos = results.whereType<Video>().toList();
      if (videos.isEmpty) return null;
      return _ytStreamByVideoId(videos.first.id.value);
    } catch (_) {}
    return null;
  }

  // ═══════════════════════════════════════════════════════════
  //  SONG PARSERS
  // ═══════════════════════════════════════════════════════════

  static Song _songFromSaavn(Map<String, dynamic> j) {
    // onrender keys: song, primary_artists, singers, image, albumid, id, 320kbps, duration, language, year
    final title = _cleanText((j['song'] ?? j['name'] ?? j['title'] ?? 'Unknown').toString());
    final artist = _cleanText((j['primary_artists'] ?? j['singers'] ?? j['artist'] ?? 'Unknown').toString());
    final album = _cleanText((j['album'] ?? '').toString());
    final artwork = _onrenderArtwork(j);
    final streamUrl = _onrenderStreamUrl(j);
    return Song(
      id: (j['id'] ?? '').toString(),
      title: title,
      artist: artist.isEmpty ? 'Unknown Artist' : artist,
      album: album,
      artworkUrl: artwork,
      streamUrl: streamUrl,
      duration: _parseInt(j['duration']),
      language: j['language']?.toString() ?? 'hindi', // onrender songs are Saavn = always set
      year: j['year']?.toString(),
    );
  }


  // ═══════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════

  static String _saavnArtists(Map<String, dynamic> j) {
    final primary = j['artists']?['primary'];
    if (primary is List && primary.isNotEmpty) {
      return primary
          .map((a) => a['name'] ?? '')
          .where((n) => n.toString().isNotEmpty)
          .join(', ');
    }
    return (j['primary_artists'] ?? j['primaryArtists'] ?? j['singers'] ?? 'Unknown').toString();
  }

  static String _saavnArtwork(Map<String, dynamic> j) {
    final images = j['image'];
    if (images is List && images.isNotEmpty) {
      for (final img in images.reversed) {
        final link = (img['url'] ?? img['link'] ?? '').toString();
        if (link.isNotEmpty) return link;
      }
    }
    final raw = (j['artwork'] ?? j['thumbnail'] ?? '').toString();
    return raw.replaceAll('150x150', '500x500').replaceAll('50x50', '500x500');
  }

  // onrender-specific helpers
  static String _onrenderArtwork(Map<String, dynamic> j) {
    // onrender: image field is a direct URL string
    final img = (j['image'] ?? '').toString();
    if (img.startsWith('http')) {
      return img
          .replaceAll('150x150', '500x500')
          .replaceAll('50x50', '500x500');
    }
    return '';
  }

  static String? _onrenderStreamUrl(Map<String, dynamic> j) {
    // onrender: 320kbps field has the stream URL directly
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

  // ═══════════════════════════════════════════════════════════
  //  NETWORK / PREFETCH / LYRICS / DEBUG
  // ═══════════════════════════════════════════════════════════

  /// Called when network is restored (e.g. after audio interruption).
  /// No-op here — stream URLs are re-fetched on demand.
  static void onNetworkRestored() {}

  /// Pre-resolve next track's stream URL so playback is instant.
  static void prefetchNext(Song song) {
    if (song.isLocal) return;
    // Fire-and-forget — ignore result, just warm the streamUrl
    Future.microtask(() async {
      try {
        await resolveStreamUrl(song);
      } catch (_) {}
    });
  }

  /// Fetch lyrics for a song via JioSaavn API.
  static Future<String?> fetchLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return null;
    if (song.source != SongSource.saavn) return null; // YT/local songs have no Saavn lyrics
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

  /// Debug helper — tests YouTube stream resolution and returns a report.
  static Future<String> debugYtSearch() async {
    final buf = StringBuffer();
    const testId = 'dQw4w9WgXcQ'; // Rick Astley — reliable test video
    buf.writeln('=== Aurum Debug Report ===');
    buf.writeln('Time: ${DateTime.now()}');
    buf.writeln('');
    buf.writeln('▶ Testing YouTube stream for id: $testId');
    try {
      final url = await _ytStreamByVideoId(testId);
      if (url != null) {
        buf.writeln('✅ YouTube stream OK');
        buf.writeln('   URL: ${url.substring(0, url.length.clamp(0, 80))}...');
      } else {
        buf.writeln('❌ YouTube stream returned null');
      }
    } catch (e) {
      buf.writeln('❌ YouTube stream error: $e');
    }
    buf.writeln('');
    buf.writeln('▶ Testing Saavn search...');
    try {
      final songs = await _searchSaavn('arijit singh', limit: 1);
      if (songs.isNotEmpty) {
        buf.writeln('✅ Saavn search OK — "${songs.first.title}"');
        buf.writeln('   streamUrl: ${songs.first.streamUrl != null ? "present" : "null"}');
      } else {
        buf.writeln('❌ Saavn search returned 0 results');
      }
    } catch (e) {
      buf.writeln('❌ Saavn search error: $e');
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
