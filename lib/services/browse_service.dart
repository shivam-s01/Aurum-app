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
    // This backend returns a flat schema: image is a plain URL string,
    // artist is a plain "primary_artists"/"singers" string — not the
    // nested {artists: {primary: [...]}} shape some other Saavn wrappers use.
    final rawImage = j['image'];
    final artwork = _hqArtwork(
      rawImage is List
          ? ((rawImage.lastWhere((e) => e is Map, orElse: () => {}) as Map)['url'] ?? '').toString()
          : (rawImage ?? '').toString(),
    );
    final durationSec = int.tryParse(j['duration']?.toString() ?? '');
    return BrowseTrack(
      trackId:    (j['id'] ?? j['song_id'] ?? '').toString(),
      title:      _clean((j['song'] ?? j['name'] ?? j['title'] ?? 'Unknown').toString()),
      artist:     _clean((j['primary_artists'] ?? j['singers'] ?? j['artist'] ?? 'Unknown').toString()),
      album:      _clean((j['album'] ?? '').toString()),
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
  // The old backend (jiosavan.onrender.com) is permanently suspended —
  // free-tier quota exhausted. This was the entire reason Browse showed
  // nothing. Pointed at the same live backend api_service.dart uses.
  static const _base = 'https://jiosaavn-op-gits.onrender.com';

  static Future<BrowseSearchResult> search(String query) async {
    if (query.trim().isEmpty) return BrowseSearchResult.empty();

    final encoded = Uri.encodeQueryComponent(query.trim());

    // Only the song-search endpoint is confirmed to exist on this backend.
    // Dedicated /search/albums and /search/artists endpoints aren't part
    // of this API's flat schema, so we derive albums/artists from the
    // song results themselves instead of hitting endpoints that 404.
    final body = await _fetch('$_base/result/?query=$encoded&limit=30');
    final rawTracks = _parseList(body);

    final tracks  = <BrowseTrack>[];
    for (final j in rawTracks) {
      try { tracks.add(BrowseTrack.fromSaavn(j)); } catch (_) {}
    }

    // Derive a lightweight "Albums" and "Artists" view from the track
    // results so Browse still feels rich without needing extra endpoints.
    final albums  = _deriveAlbums(rawTracks);
    final artists = _deriveArtists(rawTracks);

    return BrowseSearchResult(tracks: tracks, albums: albums, artists: artists);
  }

  // Group track results by album name to fake an "Albums" row.
  static List<BrowseAlbum> _deriveAlbums(List<Map<String, dynamic>> raw) {
    final seen = <String, BrowseAlbum>{};
    for (final j in raw) {
      final albumName = (j['album'] ?? '').toString().trim();
      if (albumName.isEmpty || seen.containsKey(albumName)) continue;
      try {
        final artwork = _hqArtwork((j['image'] ?? '').toString());
        seen[albumName] = BrowseAlbum(
          collectionId: albumName, // used as a search key, not a real ID
          name: _clean(albumName),
          artist: _clean((j['primary_artists'] ?? j['singers'] ?? 'Unknown').toString()),
          artworkUrl: artwork,
          releaseYear: j['year']?.toString(),
        );
      } catch (_) {}
      if (seen.length >= 10) break;
    }
    return seen.values.toList();
  }

  // Group track results by primary artist to fake an "Artists" row.
  static List<BrowseArtist> _deriveArtists(List<Map<String, dynamic>> raw) {
    final seen = <String>{};
    final artists = <BrowseArtist>[];
    for (final j in raw) {
      final name = (j['primary_artists'] ?? j['singers'] ?? '').toString().trim();
      if (name.isEmpty || seen.contains(name)) continue;
      seen.add(name);
      artists.add(BrowseArtist(artistId: name, name: _clean(name)));
      if (artists.length >= 8) break;
    }
    return artists;
  }

  // Fetch tracks for a derived "album" — re-searches by album name since
  // this backend has no dedicated /albums?id= endpoint.
  static Future<List<BrowseTrack>> albumTracks(String collectionId) async {
    final encoded = Uri.encodeQueryComponent(collectionId.trim());
    final body = await _fetch('$_base/result/?query=$encoded&limit=25');
    final tracks = <BrowseTrack>[];
    for (final j in _parseList(body)) {
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
          // 9s — matches api_service.dart's Saavn timeout to absorb
          // Render free-tier cold starts instead of failing early.
          .timeout(const Duration(seconds: 9));
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
