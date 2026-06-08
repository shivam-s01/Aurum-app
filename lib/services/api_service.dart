import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/song.dart';

class ApiService {
  static const String _base = 'https://aurum-stream.sharmashivam9109.workers.dev';
  static final _client = http.Client();

  static Future<List<SongSection>> fetchHome() async {
    final sections = <SongSection>[];
    
    try {
      // Fetch trending / default songs
      final res = await _client.get(Uri.parse('$_base/api/songs')).timeout(
        const Duration(seconds: 15),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final songs = _parseSongs(data);
        if (songs.isNotEmpty) {
          sections.add(SongSection(title: '🔥 Trending Now', songs: songs));
        }
      }
    } catch (_) {}

    // Fetch saavn charts
    final categories = [
      {'key': 'bollywood', 'label': '🎬 Bollywood Hits'},
      {'key': 'hindi', 'label': '🎵 Hindi Top Charts'},
      {'key': 'pop', 'label': '💿 Pop Picks'},
    ];

    for (final cat in categories) {
      try {
        final res = await _client.get(
          Uri.parse('$_base/api/saavn?query=${cat['key']}&limit=15'),
        ).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final songs = _parseSongs(data);
          if (songs.isNotEmpty) {
            sections.add(SongSection(title: cat['label']!, songs: songs));
          }
        }
      } catch (_) {}
    }

    return sections;
  }

  static Future<List<Song>> search(String query) async {
    try {
      final res = await _client.get(
        Uri.parse('$_base/api/search?q=${Uri.encodeQueryComponent(query)}'),
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return _parseSongs(data);
      }
    } catch (_) {}
    return [];
  }

  static Future<List<String>> suggest(String query) async {
    try {
      final res = await _client.get(
        Uri.parse('$_base/api/suggest?q=${Uri.encodeQueryComponent(query)}'),
      ).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is List) return data.map((e) => e.toString()).toList();
        if (data['suggestions'] is List) {
          return (data['suggestions'] as List).map((e) => e.toString()).toList();
        }
      }
    } catch (_) {}
    return [];
  }

  static Future<String?> resolveStreamUrl(Song song) async {
    if (song.streamUrl != null && song.streamUrl!.isNotEmpty) {
      return song.streamUrl;
    }
    try {
      final res = await _client.get(
        Uri.parse('$_base/api/play?id=${song.id}'),
      ).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final url = data['stream_url'] ?? data['url'] ?? data['media_url'];
        if (url != null && url.toString().isNotEmpty) {
          // If relative, prepend /api/stream
          if (!url.toString().startsWith('http')) {
            return '$_base/api/stream?id=${song.id}';
          }
          return url.toString();
        }
      }
    } catch (_) {}
    // Fallback to stream endpoint
    return '$_base/api/stream?id=${song.id}';
  }

  static List<Song> _parseSongs(dynamic data) {
    List<dynamic> raw = [];
    if (data is List) {
      raw = data;
    } else if (data is Map) {
      raw = data['results'] ??
          data['songs'] ??
          data['data']?['results'] ??
          data['data'] ??
          [];
    }
    return raw
        .whereType<Map<String, dynamic>>()
        .map((j) => Song.fromJson(j))
        .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
        .toList();
  }
}
