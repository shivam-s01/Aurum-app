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
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

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
  final bool   isFromYoutube;

  const BrowseTrack({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.artworkUrl,
    this.durationMs,
    this.isFromYoutube = false,
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
  final bool   isFromYoutube;

  const BrowseAlbum({
    required this.collectionId,
    required this.name,
    required this.artist,
    required this.artworkUrl,
    this.trackCount,
    this.releaseYear,
    this.isFromYoutube = false,
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
  final String  imageUrl;
  final bool    isFromYoutube;

  const BrowseArtist({
    required this.artistId,
    required this.name,
    this.genre,
    this.imageUrl = '',
    this.isFromYoutube = false,
  });

  factory BrowseArtist.fromSaavn(Map<String, dynamic> j) {
    final rawImage = j['image'];
    final artwork = _hqArtwork(
      rawImage is List
          ? ((rawImage.lastWhere((e) => e is Map, orElse: () => {}) as Map)['url']
                  ?? (rawImage.lastWhere((e) => e is Map, orElse: () => {}) as Map)['link']
                  ?? '').toString()
          : (rawImage ?? '').toString(),
    );
    return BrowseArtist(
      artistId: (j['id'] ?? '').toString(),
      name:     _clean((j['name'] ?? j['title'] ?? 'Unknown').toString()),
      genre:    null,
      imageUrl: artwork,
    );
  }

  BrowseArtist copyWith({String? imageUrl, bool? isFromYoutube}) => BrowseArtist(
    artistId: artistId,
    name: name,
    genre: genre,
    imageUrl: imageUrl ?? this.imageUrl,
    isFromYoutube: isFromYoutube ?? this.isFromYoutube,
  );
}

// ─── Service ─────────────────────────────────────────────────────────────────

class BrowseService {
  static final _client = http.Client();
  // The old backend (jiosaavn-op-gits.onrender.com) was suspended by
  // Render for exceeding free-tier monthly usage hours. Migrated to the
  // same repo's Vercel deployment (jiosavan-three) — serverless functions
  // don't sleep/get suspended for usage-hours the way Render's free web
  // services do, so this should hold up better long-term.
  static const _base = 'https://jiosavan-three.vercel.app';

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
    var albums  = _deriveAlbums(rawTracks);
    var artists = _deriveArtists(rawTracks);

    // PATCH: real artist photos. Saavn's dedicated artist-search endpoint
    // returns a proper display picture — swap that in for each derived
    // artist (limit concurrency so this stays fast). Falls back to a
    // YouTube channel thumbnail if Saavn has nothing for that name.
    if (artists.isNotEmpty) {
      artists = await Future.wait(artists.map(_withArtistPhoto));
    }

    // PATCH: if Saavn gave us nothing at all for albums/artists (common for
    // niche or misspelled queries), fill the section from YouTube instead
    // of leaving it blank — a search results screen with an empty "Artists"
    // row reads as broken, not as "no results".
    if (artists.isEmpty && query.trim().isNotEmpty) {
      artists = await _ytArtistFallback(query.trim());
    }
    if (albums.isEmpty && query.trim().isNotEmpty) {
      albums = await _ytAlbumFallback(query.trim());
    }

    return BrowseSearchResult(tracks: tracks, albums: albums, artists: artists);
  }

  // Look up a real artist photo from Saavn's artist-search endpoint by name.
  // Keeps everything else about the derived artist (id, name) unchanged —
  // only the image gets patched in. Falls back to a YouTube thumbnail.
  static Future<BrowseArtist> _withArtistPhoto(BrowseArtist artist) async {
    if (artist.imageUrl.isNotEmpty) return artist;
    try {
      final uri = Uri.parse('$_base/api/search/artists')
          .replace(queryParameters: {'query': artist.name, 'limit': '1'});
      final res = await _client.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final results = data['data']?['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final r = results.first as Map<String, dynamic>;
          final imageList = r['image'];
          final url = _hqArtwork(
            imageList is List
                ? ((imageList.lastWhere((e) => e is Map, orElse: () => {}) as Map)['url']
                        ?? (imageList.lastWhere((e) => e is Map, orElse: () => {}) as Map)['link']
                        ?? '').toString()
                : (imageList ?? '').toString(),
          );
          if (url.isNotEmpty) return artist.copyWith(imageUrl: url);
        }
      }
    } catch (_) {}
    // Saavn had nothing — patch in a YouTube channel/video thumbnail.
    final ytThumb = await _ytThumbnailFor('${artist.name} singer');
    if (ytThumb.isNotEmpty) return artist.copyWith(imageUrl: ytThumb);
    return artist;
  }

  // Full YouTube-sourced fallback when Saavn returns zero artists for the
  // query — derives a small artist row from YT's top video results so the
  // section never reads as empty/broken. Uses youtube_explode_dart (the
  // same library the rest of the app already relies on for YT playback)
  // instead of scraping raw search-page HTML, which is far more fragile
  // and prone to silently returning nothing if YouTube tweaks its markup.
  static Future<List<BrowseArtist>> _ytArtistFallback(String query) async {
    try {
      final ytClient = yt.YoutubeExplode();
      final results = await ytClient.search.search('$query song')
          .then((list) => list.toList())
          .timeout(const Duration(seconds: 8), onTimeout: () => <yt.Video>[]);
      ytClient.close();
      final seen = <String>{};
      final out = <BrowseArtist>[];
      for (final v in results) {
        final channel = v.author.trim();
        if (channel.isEmpty || !_isRealArtist(channel) || seen.contains(channel.toLowerCase())) continue;
        seen.add(channel.toLowerCase());
        final thumb = v.thumbnails.mediumResUrl.isNotEmpty
            ? v.thumbnails.mediumResUrl
            : (v.thumbnails.standardResUrl);
        out.add(BrowseArtist(artistId: channel, name: _clean(channel), imageUrl: thumb, isFromYoutube: true));
        if (out.length >= 8) break;
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // Full YouTube-sourced fallback for albums when Saavn has none — groups
  // top video results loosely so the row still shows something playable.
  static Future<List<BrowseAlbum>> _ytAlbumFallback(String query) async {
    try {
      final ytClient = yt.YoutubeExplode();
      final results = await ytClient.search.search('$query song')
          .then((list) => list.toList())
          .timeout(const Duration(seconds: 8), onTimeout: () => <yt.Video>[]);
      ytClient.close();
      final out = <BrowseAlbum>[];
      for (final v in results.take(6)) {
        final thumb = v.thumbnails.mediumResUrl.isNotEmpty
            ? v.thumbnails.mediumResUrl
            : v.thumbnails.standardResUrl;
        out.add(BrowseAlbum(
          collectionId: v.id.value, // real YT video id — used directly for playback
          name: _clean(v.title),
          artist: _clean(v.author),
          artworkUrl: thumb,
          isFromYoutube: true,
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // Real, guaranteed-playable tracks for a YouTube-sourced artist/album —
  // searches YouTube directly and returns tracks whose trackId is an
  // actual YT video id, so tapping one plays immediately via the app's
  // existing YouTube resolve path instead of round-tripping through a
  // Saavn text search that may match nothing for a channel/video name.
  static Future<List<BrowseTrack>> _ytTracksFor(String query) async {
    try {
      final ytClient = yt.YoutubeExplode();
      final results = await ytClient.search.search(query)
          .then((list) => list.toList())
          .timeout(const Duration(seconds: 8), onTimeout: () => <yt.Video>[]);
      ytClient.close();
      return results.take(25).map((v) {
        final thumb = v.thumbnails.mediumResUrl.isNotEmpty
            ? v.thumbnails.mediumResUrl
            : v.thumbnails.standardResUrl;
        return BrowseTrack(
          trackId: v.id.value,
          title: _clean(v.title),
          artist: _clean(v.author),
          album: '',
          artworkUrl: thumb,
          durationMs: v.duration?.inMilliseconds,
          isFromYoutube: true,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // Best-effort single YouTube thumbnail for a query — used as the last
  // resort for an individual artist photo.
  static Future<String> _ytThumbnailFor(String query) async {
    try {
      final uri = Uri.parse('https://www.youtube.com/results')
          .replace(queryParameters: {'search_query': query});
      final res = await _client
          .get(uri, headers: {'User-Agent': 'Mozilla/5.0'})
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final match = RegExp(r'"videoId":"([a-zA-Z0-9_-]{11})"').firstMatch(res.body);
        if (match != null) {
          return 'https://i.ytimg.com/vi/${match.group(1)}/mqdefault.jpg';
        }
      }
    } catch (_) {}
    return '';
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

  // Known music-label / channel / playlist names that show up in Saavn's
  // "primary_artists" field but are NOT actual singers — filtering these
  // out was the reason tapping an "artist" like "T-Series" or "90's Gaane"
  // opened an empty track list: BrowseService.artistTopSongs() searched
  // Saavn for that literal string, which matches nothing since it's a
  // label name, not a singer anyone actually recorded under.
  static const _labelBlacklist = {
    't-series', 'tips official', 'tips', 'zee music company', 'zee music',
    'sony music', 'sony music entertainment', 'saregama', 'venus',
    'venus music', 'eros now music', 'speed records', 'white hill music',
    'desi music factory', 'jjust music', 'times music', 'universal music',
    '90\'s gaane', 'bollywood hits', 'filmi gaane', 'various artists',
    'unknown', 'unknown artist',
  };

  static bool _isRealArtist(String name) {
    final lower = name.toLowerCase().trim();
    if (lower.isEmpty) return false;
    if (_labelBlacklist.contains(lower)) return false;
    // Catch label-ish patterns not in the explicit list above (e.g.
    // "XYZ Records", "XYZ Music Company") without needing to enumerate
    // every label that exists.
    if (lower.contains('music company') || lower.contains('records')) return false;
    return true;
  }

  // Group track results by primary artist to fake an "Artists" row.
  // Splits combined "A, B" credits into individual real singers and
  // drops label/channel names so every chip is tappable and actually
  // resolves to a track list.
  static List<BrowseArtist> _deriveArtists(List<Map<String, dynamic>> raw) {
    final seen = <String>{};
    final artists = <BrowseArtist>[];
    for (final j in raw) {
      final rawName = (j['primary_artists'] ?? j['singers'] ?? '').toString().trim();
      if (rawName.isEmpty) continue;
      for (final single in rawName.split(',')) {
        final name = single.trim();
        if (name.isEmpty || !_isRealArtist(name) || seen.contains(name.toLowerCase())) continue;
        seen.add(name.toLowerCase());
        artists.add(BrowseArtist(artistId: name, name: _clean(name)));
        if (artists.length >= 8) break;
      }
      if (artists.length >= 8) break;
    }
    return artists;
  }

  // Fetch tracks for a derived "album" — re-searches by album name since
  // this backend has no dedicated /albums?id= endpoint.
  //
  // FIX: when the album card itself came from the YouTube fallback (Saavn
  // had nothing for the query), its "name" is a YT video title, not a real
  // Saavn album — searching Saavn for that text matched nothing and the
  // track list opened empty. isFromYoutube routes straight to a YouTube
  // search instead, so tapping a YT-sourced card always plays something.
  static Future<List<BrowseTrack>> albumTracks(String collectionId, {bool isFromYoutube = false}) async {
    if (isFromYoutube) return _ytTracksFor(collectionId);
    final encoded = Uri.encodeQueryComponent(collectionId.trim());
    final body = await _fetch('$_base/result/?query=$encoded&limit=25');
    final tracks = <BrowseTrack>[];
    for (final j in _parseList(body)) {
      try { tracks.add(BrowseTrack.fromSaavn(j)); } catch (_) {}
    }
    // Saavn search matched nothing (common for a niche/misspelled album) —
    // fall back to YouTube rather than showing an empty track list.
    if (tracks.isEmpty) return _ytTracksFor(collectionId);
    return tracks;
  }

  // Fetch top songs for an artist. Same YouTube-routing fix as albumTracks:
  // a YT-sourced artist chip holds a channel/byline name that won't match
  // anything on Saavn, so isFromYoutube (or an empty Saavn result) sends
  // the query straight to YouTube for guaranteed-playable results.
  static Future<List<BrowseTrack>> artistTopSongs(String artistName, {bool isFromYoutube = false}) async {
    if (isFromYoutube) return _ytTracksFor('$artistName songs');
    final encoded = Uri.encodeQueryComponent(artistName.trim());
    final body = await _fetch('$_base/result/?query=$encoded&limit=25');
    final tracks = <BrowseTrack>[];
    for (final j in _parseList(body)) {
      try { tracks.add(BrowseTrack.fromSaavn(j)); } catch (_) {}
    }
    if (tracks.isEmpty) return _ytTracksFor('$artistName songs');
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
