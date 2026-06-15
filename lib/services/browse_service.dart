// =============================================================================
// FILE: lib/services/browse_service.dart
// PROJECT: Aurum Music
//
// BROWSE_INTEGRATION — Metadata only. No streaming, no preview.
//
// What this does:
//   - Search for songs, artists, albums (titles + artwork only)
//   - Returns BrowseTrack / BrowseAlbum / BrowseArtist objects
//   - On tap, caller resolves stream via existing ApiService (Saavn/YT)
//
// To REMOVE this integration:
//   1. Delete this file
//   2. In search_screen.dart — remove the "Browse" tab and _BrowseTab widget
//   3. That's it. Nothing else touches this service.
//
// API: Apple Music Search API — free, no key needed.
// Docs: https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI
// =============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;

// ─── Top-level helpers (accessible by all classes in this file) ──────────────

String _clean(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#039;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

String _hqArtwork(String url) {
  if (url.isEmpty) return '';
  return url
      .replaceAll('100x100bb', '600x600bb')
      .replaceAll('100x100', '600x600');
}

// ─── Models ──────────────────────────────────────────────────────────────────

class BrowseTrack {
  final String  trackId;
  final String  title;
  final String  artist;
  final String  album;
  final String  artworkUrl;
  final int?    durationMs;

  const BrowseTrack({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.artworkUrl,
    this.durationMs,
  });

  /// Search query to resolve this track via Saavn/YT
  String get resolveQuery => '$title $artist';

  factory BrowseTrack.fromJson(Map<String, dynamic> j) => BrowseTrack(
    trackId:    j['trackId']?.toString() ?? '',
    title:      _clean(j['trackName']?.toString() ?? 'Unknown'),
    artist:     _clean(j['artistName']?.toString() ?? 'Unknown'),
    album:      _clean(j['collectionName']?.toString() ?? ''),
    artworkUrl: _hqArtwork(j['artworkUrl100']?.toString() ?? ''),
    durationMs: j['trackTimeMillis'] as int?,
  );
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

  factory BrowseAlbum.fromJson(Map<String, dynamic> j) => BrowseAlbum(
    collectionId: j['collectionId']?.toString() ?? '',
    name:         _clean(j['collectionName']?.toString() ?? 'Unknown'),
    artist:       _clean(j['artistName']?.toString() ?? 'Unknown'),
    artworkUrl:   _hqArtwork(j['artworkUrl100']?.toString() ?? ''),
    trackCount:   j['trackCount'] as int?,
    releaseYear:  j['releaseDate']?.toString().substring(0, 4),
  );
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

  factory BrowseArtist.fromJson(Map<String, dynamic> j) => BrowseArtist(
    artistId: j['artistId']?.toString() ?? '',
    name:     _clean(j['artistName']?.toString() ?? 'Unknown'),
    genre:    j['primaryGenreName']?.toString(),
  );
}

// ─── Service ─────────────────────────────────────────────────────────────────

class BrowseService {
  static final _client = http.Client();
  static const _base   = 'https://itunes.apple.com';

  // Search tracks, albums, artists in one call — returns all three lists.
  static Future<BrowseSearchResult> search(String query) async {
    if (query.trim().isEmpty) return BrowseSearchResult.empty();

    final encoded = Uri.encodeQueryComponent(query.trim());

    // Fire tracks + artists + albums in parallel
    final results = await Future.wait([
      _fetch('$_base/search?term=$encoded&entity=song&limit=25'),
      _fetch('$_base/search?term=$encoded&entity=album&limit=10'),
      _fetch('$_base/search?term=$encoded&entity=musicArtist&limit=8'),
    ]);

    final tracks  = <BrowseTrack>[];
    final albums  = <BrowseAlbum>[];
    final artists = <BrowseArtist>[];

    for (final j in _parseResults(results[0])) {
      try { tracks.add(BrowseTrack.fromJson(j)); } catch (_) {}
    }
    for (final j in _parseResults(results[1])) {
      try { albums.add(BrowseAlbum.fromJson(j)); } catch (_) {}
    }
    for (final j in _parseResults(results[2])) {
      try { artists.add(BrowseArtist.fromJson(j)); } catch (_) {}
    }

    return BrowseSearchResult(tracks: tracks, albums: albums, artists: artists);
  }

  static Future<String> _fetch(String url) async {
    try {
      final res = await _client.get(Uri.parse(url)).timeout(
        const Duration(seconds: 8),
      );
      if (res.statusCode == 200) return res.body;
    } catch (_) {}
    return '{}';
  }

  static List<Map<String, dynamic>> _parseResults(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final results = data['results'] as List?;
      if (results != null) {
        return results.whereType<Map<String, dynamic>>().toList();
      }
    } catch (_) {}
    return [];
  }


  // Fetch tracks for a specific album by collectionId
  static Future<List<BrowseTrack>> albumTracks(String collectionId) async {
    final body = await _fetch(
      'https://itunes.apple.com/lookup?id=$collectionId&entity=song&limit=50',
    );
    final results = _parseResults(body);
    final tracks = <BrowseTrack>[];
    for (final j in results) {
      // lookup returns the album itself as first result (wrapperType=collection)
      if (j['wrapperType'] == 'track') {
        try { tracks.add(BrowseTrack.fromJson(j)); } catch (_) {}
      }
    }
    return tracks;
  }

  // Fetch top songs for an artist by name
  static Future<List<BrowseTrack>> artistTopSongs(String artistName) async {
    final encoded = Uri.encodeQueryComponent(artistName.trim());
    final body = await _fetch(
      'https://itunes.apple.com/search?term=$encoded&entity=song&limit=25',
    );
    final results = _parseResults(body);
    final tracks = <BrowseTrack>[];
    for (final j in results) {
      try { tracks.add(BrowseTrack.fromJson(j)); } catch (_) {}
    }
    return tracks;
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

