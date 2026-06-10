import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/song.dart';

class ApiService {
  static const String _base = 'https://aurum-stream.sharmashivam9109.workers.dev';
  static final _client = http.Client();

  static Future<List<SongSection>> fetchHome() async {
    final results = await Future.wait([
      _fetchTrending(),
      _fetchSaavn('bollywood', '🎬 Bollywood Hits'),
      _fetchSaavn('hindi', '🎵 Hindi Top Charts'),
      _fetchSaavn('pop', '💿 Pop Picks'),
    ]);
    return results.whereType<SongSection>().toList();
  }

  static Future<SongSection?> _fetchTrending() async {
    try {
      final res = await _client.get(Uri.parse('$_base/api/songs')).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final songs = _parseSongs(jsonDecode(res.body));
        if (songs.isNotEmpty) return SongSection(title: '🔥 Trending Now', songs: songs);
      }
    } catch (_) {}
    return null;
  }

  static Future<SongSection?> _fetchSaavn(String key, String label) async {
    try {
      final res = await _client.get(Uri.parse('$_base/api/saavn?query=$key&limit=15')).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final songs = _parseSongs(jsonDecode(res.body));
        if (songs.isNotEmpty) return SongSection(title: label, songs: songs);
      }
    } catch (_) {}
    return null;
  }

  static Future<List<Song>> search(String query) async {
    try {
      final res = await _client.get(Uri.parse('$_base/api/search?q=${Uri.encodeQueryComponent(query)}')).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return _parseSongs(jsonDecode(res.body));
    } catch (_) {}
    return [];
  }

  static Future<List<String>> suggest(String query) async {
    try {
      final res = await _client.get(Uri.parse('$_base/api/suggest?q=${Uri.encodeQueryComponent(query)}')).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is List) return data.map((e) => e.toString()).toList();
        if (data['suggestions'] is List) return (data['suggestions'] as List).map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<String?> resolveStreamUrl(Song song) async {
    if (song.streamUrl != null && song.streamUrl!.isNotEmpty) {
      final s = song.streamUrl!;
      if (s.startsWith('http')) return s;
      return '$_base$s';
    }
    final title = Uri.encodeQueryComponent(song.title);
    final artist = Uri.encodeQueryComponent(song.artist);
    return '$_base/api/play?title=$title&artist=$artist';
  }

  static List<Song> _parseSongs(dynamic data) {
    List<dynamic> raw = [];
    if (data is List) raw = data;
    else if (data is Map) raw = data['results'] ?? data['songs'] ?? data['data']?['results'] ?? data['data'] ?? [];
    return raw.whereType<Map<String, dynamic>>().map((j) => Song.fromJson(j)).where((s) => s.id.isNotEmpty && s.title.isNotEmpty).toList();
  }
}
