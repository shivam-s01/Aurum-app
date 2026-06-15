// =============================================================================
// FILE: lib/services/browse_service.dart
// PROJECT: Aurum Music
//
// BROWSE — Powered by JioSaavn. No third-party music APIs.
//
// What this does:
//   - Search Saavn for songs, albums, artists
//   - Returns BrowseTrack / BrowseAlbum / BrowseArtist objects
//   - On tap, caller resolves stream via existing ApiService (Saavn/YT)
//
// To REMOVE this integration:
//   1. Delete this file
//   2. In search_screen.dart — remove the "Browse" tab and _BrowseTab widget
//   3. That's it. Nothing else touches Browse.
// =============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;

// ─── Top-level helpers ───────────────────────────────────────────────────────

String _clean(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#039;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

String _hqArtwork(String url) {
  if (url.isEmpty) return '';
  // Saavn returns 150x150 — upgrade to 500x500
  return url
      .replaceAll('150x150', '500x500')
      .replaceAll('50x50', '500x500');
}

// ─── Models ──────────────────────────────────────────────────────────────────

class BrowseTrack {
  final String trackId;
  final String title;
  final String artist;
  final String album;
  final String artworkUrl;
  final int?   durationMs;

  const BrowseTrack({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.artworkUrl,
    this.durationMs,
  });

  String get resolveQuery => '$title $artist';

  factory BrowseTrack.fromSaavn(Map<String, dynamic> j) {
    final artwork = _hqArtwork(
      (j['image'] is List
          ? (j['image'] as List).lastWhere(
              (e) => e is Map, orElse: () => {})['url'] ?? ''
          : j['image']?.toString() ?? ''),
    );
    final durationSec = int.tryParse(j['duration']?.toString() ?? '');
    return BrowseTrack(
      trackId:    (j['id'] ?? j['song_id'] ?? '').toString(),
      title:      _clean((j['name'] ?? j['title'] ?? j['song'] ?? 'Unknown').toString()),
      artist:     _clean((j['artists']?['primary']?.isNotEmpty == true
                    ? (j['artists']['primary'] as List).map((a) => a['name']).join(', ')
                    : j['primary_artists'] ?? j['singers'] ?? 'Unknown').toString()),
      album:      _clean((j['album']?['name'] ?? j['album'] ?? '').toString()),
      artworkUrl: artwork,
      durationMs: durationSec != null ? durationSec * 1000 : null,
    );
  }
}

class BrowseAlbum {
  final String collectionId;
  final String name;
  final String artist;
  final String artworkUrl;
  final int?   trackCount;
  final String? releaseYear;

  const BrowseAlbum({
    required this.collectionId,
    required this.name,
    required this.artist,
    required this.artworkUrl,
    this.trackCount,
    this.releaseYear,
  });

  factory BrowseAlbum.fromSaavn(Map<String, dynamic> j) {
    final artwork = _hqArtwork(
      (j['image'] is List
          ? (j['image'] as List).lastWhere(
              (e) => e is Map, orElse: () => {})['url'] ?? ''
          : j['image']?.toString() ?? ''),
    );
    return BrowseAlbum(
      collectionId: (j['id'] ?? '').toString(),
      name:         _clean((j['name'] ?? j['title'] ?? 'Unknown').toString()),
      artist:       _clean((j['artists']?['primary']?.isNotEmpty == true
                      ? (j['artists']['primary'] as List).map((a) => a['name']).join(', ')
                      : j['primary_artists'] ?? 'Unknown').toString()),
      artworkUrl:   artwork,
      trackCount:   int.tryParse(j['songCount']?.toString() ?? ''),
      releaseYear:  j['year']?.toString(),
    );
  }
}

class BrowseArtist {
  final String artistId;
  final String name;
  final String? genre;

  const BrowseArtist({
    required this.artistId,
    required this.name,
    this.genre,
  });

  factory BrowseArtist.fromSaavn(Map<String, dynamic> j) => BrowseArtist(
    artistId: (j['id'] ?? '').toString(),
    name:     _clean((j['name'] ?? j['title'] ?? 'Unknown').toString()),
    genre:    null,
  );
}

// ─── Service ─────────────────────────────────────────────────────────────────

class BrowseService {
  static final _client = http.Client();
  static const _base   = 'https://jiosavan.onrender.com';

  static Future<BrowseSearchResult> search(String query) async {
    if (query.trim().isEmpty) return BrowseSearchResult.empty();

    final encoded = Uri.encodeQueryComponent(query.trim());

    final results = await Future.wait([
      _fetch('$_base/result/?query=$encoded&limit=25'),
      _fetch('$_base/search/albums?query=$encoded&limit=10'),
      _fetch('$_base/search/artists?query=$encoded&limit=8'),
    ]);

    final tracks  = <BrowseTrack>[];
    final albums  = <BrowseAlbum>[];
    final artists = <BrowseArtist>[];

    for (final j in _parseList(results[0])) {
      try { tracks.add(BrowseTrack.fromSaavn(j)); } catch (_) {}
    }
    for (final j in _parseList(results[1])) {
      try { albums.add(BrowseAlbum.fromSaavn(j)); } catch (_) {}
    }
    for (final j in _parseList(results[2])) {
      try { artists.add(BrowseArtist.fromSaavn(j)); } catch (_) {}
    }

    return BrowseSearchResult(tracks: tracks, albums: albums, artists: artists);
  }

  // Fetch tracks for a specific album
  static Future<List<BrowseTrack>> albumTracks(String collectionId) async {
    final body = await _fetch('$_base/albums?id=$collectionId');
    final data = _parseBody(body);
    final songs = data['songs'] as List? ?? [];
    final tracks = <BrowseTrack>[];
    for (final j in songs.whereType<Map<String, dynamic>>()) {
      try { tracks.add(BrowseTrack.fromSaavn(j)); } catch (_) {}
    }
    return tracks;
  }

  // Fetch top songs for an artist
  static Future<List<BrowseTrack>> artistTopSongs(String artistName) async {
    final encoded = Uri.encodeQueryComponent(artistName.trim());
    final body = await _fetch('$_base/result/?query=$encoded&limit=25');
    final tracks = <BrowseTrack>[];
    for (final j in _parseList(body)) {
      try { tracks.add(BrowseTrack.fromSaavn(j)); } catch (_) {}
    }
    return tracks;
  }

  static Future<String> _fetch(String url) async {
    try {
      final res = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) return res.body;
    } catch (_) {}
    return '{}';
  }

  static List<Map<String, dynamic>> _parseList(String body) {
    try {
      final data = jsonDecode(body);
      List? list;
      if (data is List) {
        list = data;
      } else if (data is Map) {
        list = data['data']?['results'] as List?
            ?? data['data'] as List?
            ?? data['results'] as List?;
      }
      if (list != null) {
        return list.whereType<Map<String, dynamic>>().toList();
      }
    } catch (_) {}
    return [];
  }

  static Map<String, dynamic> _parseBody(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        return data['data'] as Map<String, dynamic>? ?? data;
      }
    } catch (_) {}
    return {};
  }

  static void dispose() => _client.close();
}

class BrowseSearchResult {
  final List<BrowseTrack>  tracks;
  final List<BrowseAlbum>  albums;
  final List<BrowseArtist> artists;

  const BrowseSearchResult({
    required this.tracks,
    required this.albums,
    required this.artists,
  });

  factory BrowseSearchResult.empty() => const BrowseSearchResult(
    tracks: [], albums: [], artists: [],
  );

  bool get isEmpty => tracks.isEmpty && albums.isEmpty && artists.isEmpty;
}
