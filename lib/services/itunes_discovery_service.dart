// =============================================================================
// FILE: lib/services/itunes_discovery_service.dart
//
// ISOLATED, REMOVABLE MODULE — iTunes Search API used ONLY for enriched
// discovery data (Home + Search screens): title, artist, album, high-res
// artwork, year, genre. NEVER used for playback.
//
// Why isolated: to remove this feature entirely later, you only need to:
//   1. Delete this file.
//   2. Remove the two call sites that reference ItunesDiscoveryService
//      (marked with "ITUNES DISCOVERY" comments in home_screen.dart /
//      search_screen.dart or wherever it's wired in).
// Nothing else in the app touches this file — Saavn/YT search, playback,
// and Shorts (itunes_shorts_api.dart, a separate file) are all untouched.
//
// PLAYBACK SAFETY: every Song returned here has streamUrl=null and id=''.
// api_service.dart's resolveStreamUrl() treats an empty id + null
// streamUrl as "not yet resolved" and always falls through to its normal
// Saavn-by-title-search → YT-by-title-search chain (see _doResolve in
// api_service.dart). So tapping an iTunes-discovered song plays it from
// Saavn or YouTube exactly like any other song — iTunes audio/preview is
// never reached.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/song.dart';

class ItunesDiscoveryService {
  ItunesDiscoveryService._();

  static const _base = 'https://itunes.apple.com/search';
  static const _timeout = Duration(seconds: 8);
  static final http.Client _client = http.Client();

  /// Rich-metadata search for the Search screen. Same query the user
  /// typed goes to iTunes; results carry proper artist/album/high-res
  /// artwork but are NOT playable as-is (see file header).
  static Future<List<Song>> search(String query, {int limit = 25}) async {
    if (query.trim().isEmpty) return [];
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {
        'term': query,
        'media': 'music',
        'entity': 'song',
        'limit': '$limit',
      });
      final res = await _client.get(uri).timeout(_timeout);
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final results = data is Map ? (data['results'] ?? []) : [];
      if (results is! List) return [];
      return results
          .whereType<Map<String, dynamic>>()
          .map(_toDiscoverySong)
          .where((s) => s.title.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Rich-metadata rows for a Home section, seeded by an artist/genre
  /// term (e.g. "Arijit Singh", "Bollywood", "Punjabi Hits").
  static Future<List<Song>> fetchByTerm(String term, {int limit = 15}) async {
    return search(term, limit: limit);
  }

  // key: category query -> next offset to fetch from. Module-level so it
  // survives across screen rebuilds within the app session — each
  // pull-to-refresh / "See All" open advances further into iTunes'
  // result set instead of re-fetching the same top slice every time.
  static final Map<String, int> _categoryOffsets = {};

  /// Fetches up to [limit] songs for a category/playlist query (e.g. "90s
  /// bollywood hit songs", "english rock songs classic"). Each call
  /// advances an internal offset for that exact query string, so repeated
  /// calls (pull-to-refresh, reopening "See All", app restart within the
  /// same session) return a DIFFERENT slice of iTunes' results instead of
  /// the same songs every time. Call [resetCategoryRotation] to force
  /// starting over from offset 0 for a given query.
  static Future<List<Song>> fetchCategory(
    String query, {
    int limit = 80,
  }) async {
    if (query.trim().isEmpty) return [];
    final offset = _categoryOffsets[query] ?? 0;
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {
        'term': query,
        'media': 'music',
        'entity': 'song',
        'limit': '$limit',
        'offset': '$offset',
      });
      final res = await _client.get(uri).timeout(_timeout);
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final results = data is Map ? (data['results'] ?? []) : [];
      if (results is! List || results.isEmpty) {
        // Ran off the end of iTunes' result set for this query — wrap
        // back to the start next time instead of returning empty forever.
        _categoryOffsets[query] = 0;
        // One retry from offset 0 so this call still returns songs now.
        if (offset != 0) return fetchCategory(query, limit: limit);
        return [];
      }
      // Advance the offset for next time. iTunes Search caps out well
      // before infinite scroll territory, so once we've moved far enough
      // that a full page likely won't come back, wrap to 0 next call.
      _categoryOffsets[query] = results.length < limit ? 0 : offset + limit;
      return results
          .whereType<Map<String, dynamic>>()
          .map(_toDiscoverySong)
          .where((s) => s.title.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Resets the rotation for [query] back to the start — useful if you
  /// want a specific "restart from top" action rather than continuing
  /// to advance through the catalog.
  static void resetCategoryRotation(String query) {
    _categoryOffsets.remove(query);
  }

  /// Converts a raw iTunes result into a Song with playback fields
  /// deliberately blanked out — see file header PLAYBACK SAFETY note.
  static Song _toDiscoverySong(Map<String, dynamic> j) {
    final song = Song.fromJson(j); // Song.fromJson already understands
                                    // iTunes' trackId/trackName/artistName/
                                    // artworkUrl100 shape (see models/song.dart)
    return Song(
      id: '',                 // force resolveStreamUrl() into title-search path
      title: song.title,
      artist: song.artist,
      album: song.album,
      artworkUrl: song.artworkUrl,
      streamUrl: null,        // never let an iTunes preview URL leak into playback
      duration: song.duration,
      language: song.language,
      year: song.year,
      source: SongSource.saavn, // resolves via Saavn-first chain, same as any search result
    );
  }

  static void dispose() => _client.close();
}
