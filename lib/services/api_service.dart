import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/song.dart';

/// Sources:
///   Search  → JioSaavn + YouTube (Piped) combined results
///   Home    → JioSaavn trending sections + YouTube trending
///   Stream  → JioSaavn 320kbps → Piped YouTube fallback
class ApiService {
  static final _client = http.Client();

  static const _saavn = 'https://jiosavan.onrender.com';
  static const _piped = 'https://pipedapi.kavin.rocks';

  // ═══════════════════════════════════════════════════════════
  //  HOME
  // ═══════════════════════════════════════════════════════════

  static Future<List<SongSection>> fetchHome() async {
    final results = await Future.wait([
      _saavnSection('trending hindi songs', '🔥 Trending Now'),
      _saavnSection('bollywood hits', '🎬 Bollywood Hits'),
      _saavnSection('hindi top charts', '🎵 Hindi Top Charts'),
      _pipedSection('top english songs 2024', '🎧 YouTube Picks'),
    ]);
    return results.whereType<SongSection>().toList();
  }

  static Future<SongSection?> _saavnSection(String query, String label) async {
    final songs = await _searchSaavn(query, limit: 15);
    if (songs.isNotEmpty) return SongSection(title: label, songs: songs);
    return null;
  }

  static Future<SongSection?> _pipedSection(String query, String label) async {
    final songs = await _searchPiped(query, limit: 15);
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
      _searchPiped(query, limit: 15),
    ]);

    final saavnResults = both[0];
    final pipedResults = both[1];

    // Merge: interleave so both sources visible (Saavn first, then YT)
    // De-duplicate by title+artist similarity
    final merged = <Song>[...saavnResults];
    final existingTitles = saavnResults
        .map((s) => _normalise(s.title))
        .toSet();

    for (final yt in pipedResults) {
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

  // ── Piped (YouTube) search ────────────────────────────────

  static Future<List<Song>> _searchPiped(String query, {int limit = 15}) async {
    try {
      final url = Uri.parse(
        '$_piped/search?q=${Uri.encodeQueryComponent(query)}&filter=music_songs',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final items = (data['items'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .where((j) => j['url'] != null && j['type'] != 'playlist')
            .take(limit)
            .toList();
        return items.map(_songFromPiped).where((s) => s.id.isNotEmpty).toList();
      }
    } catch (_) {}
    return [];
  }

  // ═══════════════════════════════════════════════════════════
  //  SUGGESTIONS
  // ═══════════════════════════════════════════════════════════

  static Future<List<String>> suggest(String query) async {
    // Run both in parallel, merge unique suggestions
    final both = await Future.wait([
      _suggestSaavn(query),
      _suggestPiped(query),
    ]);
    final seen = <String>{};
    final merged = <String>[];
    for (final list in both) {
      for (final s in list) {
        if (seen.add(s.toLowerCase())) merged.add(s);
        if (merged.length >= 8) break;
      }
      if (merged.length >= 8) break;
    }
    return merged;
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

  static Future<List<String>> _suggestPiped(String query) async {
    try {
      final url = Uri.parse(
        '$_piped/search?q=${Uri.encodeQueryComponent(query)}&filter=music_songs',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final items = data['items'] as List? ?? [];
        return items
            .whereType<Map<String, dynamic>>()
            .where((j) => j['title'] != null)
            .map((j) => _cleanText(j['title'].toString()))
            .where((s) => s.isNotEmpty)
            .take(4)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  // ═══════════════════════════════════════════════════════════
  //  STREAM URL RESOLUTION
  //  Priority: JioSaavn 320kbps → Piped YouTube fallback
  // ═══════════════════════════════════════════════════════════

  static Future<String?> resolveStreamUrl(Song song) async {
    if (song.isLocal) return song.localPath;

    // If song came from YouTube (id looks like YT video id, no saavn stream)
    final isYtSong = _isYouTubeId(song.id);

    // 1. Pre-fetched streamUrl use karo (Saavn search sets this)
    if (song.streamUrl != null && song.streamUrl!.startsWith('http')) {
      return song.streamUrl;
    }

    if (!isYtSong && song.id.isNotEmpty) {
      final url = await _saavnStreamById(song.id);
      if (url != null) return url;
      return _pipedStreamBySearch('${song.title} ${song.artist}');
    }

    if (isYtSong) {
      return _pipedStreamByVideoId(song.id);
    }
    return null;
  }

  /// YouTube video IDs are 11 chars, alphanumeric + - _
  static bool _isYouTubeId(String id) =>
      RegExp(r'^[A-Za-z0-9_\-]{11}$').hasMatch(id);

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

  // ── Piped stream ──────────────────────────────────────────

  static Future<String?> _pipedStreamByVideoId(String videoId) async {
    try {
      final res = await _client
          .get(Uri.parse('$_piped/streams/$videoId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        return _bestAudioFromPipedStreams(jsonDecode(res.body));
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _pipedStreamBySearch(String query) async {
    try {
      final searchRes = await _client
          .get(Uri.parse('$_piped/search?q=${Uri.encodeQueryComponent(query)}&filter=music_songs'))
          .timeout(const Duration(seconds: 8));
      if (searchRes.statusCode != 200) return null;

      final items = (jsonDecode(searchRes.body)['items'] as List? ?? []);
      final first = items.whereType<Map<String, dynamic>>().firstWhere(
            (i) => i['url'] != null,
            orElse: () => {},
          );
      if (first.isEmpty) return null;

      final videoId = (first['url'] as String).replaceAll('/watch?v=', '');
      return _pipedStreamByVideoId(videoId);
    } catch (_) {}
    return null;
  }

  static String? _bestAudioFromPipedStreams(dynamic data) {
    final audioStreams = data['audioStreams'] as List? ?? [];
    if (audioStreams.isEmpty) return null;
    audioStreams.sort((a, b) =>
        ((b['bitrate'] ?? 0) as int).compareTo((a['bitrate'] ?? 0) as int));
    final url = audioStreams.first['url'] as String?;
    return (url != null && url.startsWith('http')) ? url : null;
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

  static Song _songFromPiped(Map<String, dynamic> j) {
    final url = (j['url'] ?? '').toString();
    // Extract 11-char video ID from /watch?v=XXXXXXXXXXX
    final videoId = url.contains('?v=') ? url.split('?v=').last : url;
    return Song(
      id: videoId,
      title: _cleanText((j['title'] ?? 'Unknown').toString()),
      artist: _cleanText((j['uploaderName'] ?? 'Unknown').toString()),
      album: '',
      artworkUrl: (j['thumbnail'] ?? '').toString(),
      streamUrl: null, // always resolved fresh on play
      duration: j['duration'] as int?,
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
    if (_isYouTubeId(song.id)) return null; // YT songs have no Saavn lyrics
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
    buf.writeln('▶ Testing Piped stream for YT id: $testId');
    try {
      final url = await _pipedStreamByVideoId(testId);
      if (url != null) {
        buf.writeln('✅ Piped stream OK');
        buf.writeln('   URL: ${url.substring(0, url.length.clamp(0, 80))}...');
      } else {
        buf.writeln('❌ Piped stream returned null');
      }
    } catch (e) {
      buf.writeln('❌ Piped stream error: $e');
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
