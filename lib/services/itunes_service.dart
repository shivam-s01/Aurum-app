// =============================================================================
// FILE: lib/services/itunes_service.dart
// PROJECT: Aurum Music
//
// ITUNES_INTEGRATION — Metadata only. No streaming, no preview.
//
// What this does:
//   - Search iTunes for songs, artists, albums (titles + artwork only)
//   - Returns ItunesTrack / ItunesAlbum / ItunesArtist objects
//   - On tap, caller resolves stream via existing ApiService (Saavn/YT)
//
// To REMOVE this integration:
//   1. Delete this file
//   2. In search_screen.dart — remove the "Browse" tab and _BrowseTab widget
//   3. That's it. Nothing else touches iTunes.
//
// API: iTunes Search API — free, no key needed.
// Docs: https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI
// =============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;

// ─── Models ──────────────────────────────────────────────────────────────────

class ItunesTrack {
  final String  trackId;
  final String  title;
  final String  artist;
  final String  album;
  final String  artworkUrl;
  final int?    durationMs;

  const ItunesTrack({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.artworkUrl,
    this.durationMs,
  });

  /// Search query to resolve this track via Saavn/YT
  String get resolveQuery => '$title $artist';

  factory ItunesTrack.fromJson(Map<String, dynamic> j) => ItunesTrack(
    trackId:    j['trackId']?.toString() ?? '',
    title:      _clean(j['trackName']?.toString() ?? 'Unknown'),
    artist:     _clean(j['artistName']?.toString() ?? 'Unknown'),
    album:      _clean(j['collectionName']?.toString() ?? ''),
    artworkUrl: _hqArtwork(j['artworkUrl100']?.toString() ?? ''),
    durationMs: j['trackTimeMillis'] as int?,
  );
}

class ItunesAlbum {
  final String collectionId;
  final String name;
  final String artist;
  final String artworkUrl;
  final int?   trackCount;
  final String? releaseYear;

  const ItunesAlbum({
    required this.collectionId,
    required this.name,
    required this.artist,
    required this.artworkUrl,
    this.trackCount,
    this.releaseYear,
  });

  factory ItunesAlbum.fromJson(Map<String, dynamic> j) => ItunesAlbum(
    collectionId: j['collectionId']?.toString() ?? '',
    name:         _clean(j['collectionName']?.toString() ?? 'Unknown'),
    artist:       _clean(j['artistName']?.toString() ?? 'Unknown'),
    artworkUrl:   _hqArtwork(j['artworkUrl100']?.toString() ?? ''),
    trackCount:   j['trackCount'] as int?,
    releaseYear:  j['releaseDate']?.toString().substring(0, 4),
  );
}

class ItunesArtist {
  final String artistId;
  final String name;
  final String? genre;

  const ItunesArtist({
    required this.artistId,
    required this.name,
    this.genre,
  });

  factory ItunesArtist.fromJson(Map<String, dynamic> j) => ItunesArtist(
    artistId: j['artistId']?.toString() ?? '',
    name:     _clean(j['artistName']?.toString() ?? 'Unknown'),
    genre:    j['primaryGenreName']?.toString(),
  );
}

// ─── Service ─────────────────────────────────────────────────────────────────

class ItunesService {
  static final _client = http.Client();
  static const _base   = 'https://itunes.apple.com';

  // Search tracks, albums, artists in one call — returns all three lists.
  static Future<ItunesSearchResult> search(String query) async {
    if (query.trim().isEmpty) return ItunesSearchResult.empty();

    final encoded = Uri.encodeQueryComponent(query.trim());

    // Fire tracks + artists + albums in parallel
    final results = await Future.wait([
      _fetch('$_base/search?term=$encoded&entity=song&limit=25'),
      _fetch('$_base/search?term=$encoded&entity=album&limit=10'),
      _fetch('$_base/search?term=$encoded&entity=musicArtist&limit=8'),
    ]);

    final tracks  = <ItunesTrack>[];
    final albums  = <ItunesAlbum>[];
    final artists = <ItunesArtist>[];

    for (final item in _parseResults(results[0])) {
      if (item['wrapperType'] == 'track' && item['kind'] == 'song') {
        tracks.add(ItunesTrack.fromJson(item));
      }
    }
    for (final item in _parseResults(results[1])) {
      if (item['wrapperType'] == 'collection') {
        albums.add(ItunesAlbum.fromJson(item));
      }
    }
    for (final item in _parseResults(results[2])) {
      if (item['wrapperType'] == 'artist') {
        artists.add(ItunesArtist.fromJson(item));
      }
    }

    return ItunesSearchResult(tracks: tracks, albums: albums, artists: artists);
  }

  // Fetch all tracks in an album by collectionId
  static Future<List<ItunesTrack>> albumTracks(String collectionId) async {
    final data = await _fetch(
      '$_base/lookup?id=$collectionId&entity=song&limit=50',
    );
    return _parseResults(data)
        .where((j) => j['wrapperType'] == 'track' && j['kind'] == 'song')
        .map(ItunesTrack.fromJson)
        .toList();
  }

  // Fetch top songs by artist (via search)
  static Future<List<ItunesTrack>> artistTopSongs(String artistName) async {
    final encoded = Uri.encodeQueryComponent(artistName);
    final data = await _fetch(
      '$_base/search?term=$encoded&entity=song&attribute=artistTerm&limit=20',
    );
    return _parseResults(data)
        .where((j) => j['wrapperType'] == 'track' && j['kind'] == 'song')
        .map(ItunesTrack.fromJson)
        .toList();
  }

  // ── Internals ───────────────────────────────────────────────

  static Future<String> _fetch(String url) async {
    try {
      final res = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
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

  static String _hqArtwork(String url) {
    if (url.isEmpty) return '';
    return url
        .replaceAll('100x100bb', '600x600bb')
        .replaceAll('100x100', '600x600');
  }

  static String _clean(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  static void dispose() => _client.close();
}

class ItunesSearchResult {
  final List<ItunesTrack>  tracks;
  final List<ItunesAlbum>  albums;
  final List<ItunesArtist> artists;

  const ItunesSearchResult({
    required this.tracks,
    required this.albums,
    required this.artists,
  });

  factory ItunesSearchResult.empty() => const ItunesSearchResult(
    tracks: [], albums: [], artists: [],
  );

  bool get isEmpty => tracks.isEmpty && albums.isEmpty && artists.isEmpty;
}
