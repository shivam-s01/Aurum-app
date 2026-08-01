// =============================================================================
// FILE: lib/services/browse_service.dart
// PROJECT: Aurum Music
//
// BROWSE — Powered by YouTube. Search tab owns Saavn; Browse is the
// YouTube-catalogue side (channels, live versions, remixes, regional/indie
// uploads, full discographies-as-playlists), held to the same premium
// quality bar (view-count floor, official-channel priority, smart dedup)
// as every other YT-sourced surface in the app.
//
// What this does:
//   - Search YouTube for songs, albums (grouped by channel), artists
//   - Returns BrowseTrack / BrowseAlbum / BrowseArtist objects
//   - On tap, caller resolves stream via existing ApiService (YT path)
//
// To REMOVE this integration:
//   1. Delete this file
//   2. In search_screen.dart — remove the "Browse" tab and _BrowseTab widget
//   3. That's it. Nothing else touches Browse.
// =============================================================================

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import 'recommendation_engine.dart';

// ─── Top-level helpers ───────────────────────────────────────────────────────

// View counts below this are treated as unproven/low-quality uploads and
// excluded from Browse's YouTube-sourced album/artist fallback rows — same
// threshold and reasoning RecommendationEngine.isPremiumQuality already
// applies elsewhere in the app (search, up-next, home feed). Browse's YT
// fallback previously had NO quality gate at all: it took whatever YouTube's
// search returned in raw order, so a handful of low-view junk uploads (or,
// worse, several re-uploads of the exact same song) could easily fill an
// entire "Albums"/"Artists" row — a visibly un-premium result for a feature
// meant to feel like a real catalog browse, not a raw video search.
const int _kMinViewsForBrowse = 100000;

// Safe view-count accessor — youtube_explode_dart's Video.engagement can
// throw/come back empty for videos with hidden or unavailable engagement
// stats; never let that crash a whole fallback fetch over one bad video.
int? _safeViewCount(yt.Video v) {
  try {
    return v.engagement.viewCount;
  } catch (_) {
    return null;
  }
}

/// True if a raw YouTube search result is worth surfacing in a premium
/// Browse row: has a real, sane view count AND doesn't look like a
/// low-quality/junk upload by title. Mirrors the same bar the rest of the
/// app already holds search/up-next/home-feed YouTube content to.
bool _isBrowseQuality(yt.Video v) {
  final views = _safeViewCount(v);
  if (views == null || views < _kMinViewsForBrowse) return false;
  if (RecommendationEngine.isLowQualityUpload(v.title)) return false;
  return true;
}

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

// BUGFIX: full-player artwork looked visibly low-res for YouTube-sourced
// tracks. The three call sites below previously went straight to
// v.thumbnails.mediumResUrl (a ~320x180 tier) with standardResUrl as their
// only fallback — never touching maxResUrl (1280x720, the actual highest
// tier YouTube offers) or highResUrl (480x360) at all. maxResUrl is
// documented as "not always available" for some videos, which is exactly
// why a fallback chain exists — but the chain needs to try the BEST
// options first and only fall back to worse ones when they're genuinely
// missing, not skip straight past them. This tries every tier from
// highest to lowest and only returns a lower one if every better tier is
// actually empty for that video.
String _bestYtThumbnail(yt.ThumbnailSet thumbnails) {
  if (thumbnails.maxResUrl.isNotEmpty) return thumbnails.maxResUrl;
  if (thumbnails.standardResUrl.isNotEmpty) return thumbnails.standardResUrl;
  if (thumbnails.highResUrl.isNotEmpty) return thumbnails.highResUrl;
  if (thumbnails.mediumResUrl.isNotEmpty) return thumbnails.mediumResUrl;
  return thumbnails.lowResUrl;
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
    // FIX (same bug as _deriveAlbums below): j['album'] is a nested
    // {id, name} object on most Saavn endpoints, not a plain string.
    final albumField = j['album'];
    final albumStr = albumField is Map
        ? (albumField['name'] ?? '').toString()
        : (albumField ?? '').toString();
    return BrowseTrack(
      trackId:    (j['id'] ?? j['song_id'] ?? '').toString(),
      title:      _clean((j['song'] ?? j['name'] ?? j['title'] ?? 'Unknown').toString()),
      artist:     _clean((j['primary_artists'] ?? j['singers'] ?? j['artist'] ?? 'Unknown').toString()),
      album:      _clean(albumStr),
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

  static Future<BrowseSearchResult> search(String query) async {
    if (query.trim().isEmpty) return BrowseSearchResult.empty();
    final q = query.trim();

    // BROWSE IS 100% YOUTUBE — no Saavn calls anywhere in this tab anymore.
    // Search tab already owns "proper Saavn songs, fast"; Browse's whole
    // purpose is the complementary side: YouTube's much deeper catalogue
    // (channels, live versions, remixes, regional/indie uploads, full
    // albums-as-playlists) with the same premium quality bar (view-count
    // floor + official-channel priority + smart dedup) the old YT-fallback
    // paths already used elsewhere in this file — just applied everywhere
    // in Browse now, not only when Saavn came up short.
    final tracksFuture  = _ytTracksFor(q);
    final albumsFuture  = _ytAlbumFallback(q);
    final artistsFuture = _ytArtistFallback(q);

    final results = await Future.wait([tracksFuture, albumsFuture, artistsFuture]);
    final tracks  = results[0] as List<BrowseTrack>;
    var albums    = results[1] as List<BrowseAlbum>;
    var artists   = results[2] as List<BrowseArtist>;

    // Real artist photos: try a quick YT-channel-thumbnail patch for any
    // artist chip missing one (should be rare since _ytArtistFallback
    // already sets imageUrl from the anchoring video's thumbnail, but kept
    // as a safety net).
    if (artists.isNotEmpty) {
      artists = await Future.wait(artists.map(_withArtistPhoto));
    }

    // PREMIUM FEATURE ("search karte hi seedha playlist dikhna chahiye"):
    // if the query strongly matches one of the derived YT albums — the
    // user typed a movie/OST/album/channel name, not just a loose keyword
    // — pre-fetch that album's full track list right here and attach it
    // to the result, so the UI can show the complete playlist the instant
    // search results land, without waiting for a tap first. Tap-to-open
    // (_openAlbum in search_screen.dart -> albumTracks below) is untouched
    // and still works identically for every other album in the list.
    // Deliberately gated on a STRONG match since this fires an extra
    // network round-trip: a weak/partial match would pay that cost on
    // every search for no real benefit.
    BrowseAlbum? topAlbum;
    List<BrowseTrack> topAlbumTracks = const [];
    if (albums.isNotEmpty) {
      String norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9\s]'), '');
      final qNorm = norm(q);
      for (final a in albums) {
        final aNorm = norm(a.name);
        if (aNorm.isEmpty || qNorm.isEmpty) continue;
        final isStrongMatch = aNorm == qNorm || aNorm.startsWith(qNorm) || qNorm.startsWith(aNorm);
        if (isStrongMatch) {
          topAlbum = a;
          break;
        }
      }
      if (topAlbum != null) {
        try {
          topAlbumTracks = await albumTracks(topAlbum.collectionId, isFromYoutube: true)
              .timeout(const Duration(seconds: 6), onTimeout: () => <BrowseTrack>[]);
        } catch (_) {
          topAlbumTracks = const [];
        }
      }
    }

    return BrowseSearchResult(
      tracks: tracks,
      albums: albums,
      artists: artists,
      topAlbum: topAlbumTracks.isNotEmpty ? topAlbum : null,
      topAlbumTracks: topAlbumTracks,
    );
  }

  // Patches in a display photo for an artist chip that doesn't already
  // have one (rare — _ytArtistFallback normally sets this from the
  // anchoring video's thumbnail already). YouTube-only, matching the rest
  // of Browse.
  static Future<BrowseArtist> _withArtistPhoto(BrowseArtist artist) async {
    if (artist.imageUrl.isNotEmpty) return artist;
    final ytThumb = await _ytThumbnailFor('${artist.name} singer');
    if (ytThumb.isNotEmpty) return artist.copyWith(imageUrl: ytThumb);
    return artist;
  }

  // YouTube-sourced artist row — derives a small artist chip list from YT's
  // top video results grouped by channel/author. Uses youtube_explode_dart
  // (the same library the rest of the app already relies on for YT
  // playback) instead of scraping raw search-page HTML, which is far more
  // fragile and prone to silently returning nothing if YouTube tweaks its
  // markup.
  static Future<List<BrowseArtist>> _ytArtistFallback(String query) async {
    // FIX (YoutubeExplode client leak): close() previously only ran on the
    // success path, right after search() returned. If search() itself threw
    // (network error, backend hiccup, timeout at the http layer under the
    // youtube_explode_dart timeout) execution jumped straight to `catch`
    // and ytClient.close() was skipped — leaking the underlying http client
    // every time a fallback search failed. try/finally guarantees close()
    // runs regardless of how the try block exits.
    final ytClient = yt.YoutubeExplode();
    try {
      final results = await ytClient.search.search('$query song')
          .then((list) => list.toList())
          .timeout(const Duration(seconds: 8), onTimeout: () => <yt.Video>[]);
      final seen = <String>{};
      final out = <BrowseArtist>[];
      for (final v in results) {
        final channel = v.author.trim();
        if (channel.isEmpty || !_isRealArtist(channel) || seen.contains(channel.toLowerCase())) continue;
        seen.add(channel.toLowerCase());
        final thumb = _bestYtThumbnail(v.thumbnails);
        out.add(BrowseArtist(artistId: channel, name: _clean(channel), imageUrl: thumb, isFromYoutube: true));
        if (out.length >= 8) break;
      }
      return out;
    } catch (_) {
      return [];
    } finally {
      ytClient.close();
    }
  }

  // YouTube-sourced "Albums" row for Browse.
  //
  // PREMIUM REDESIGN ("ekdam pro level ka albums chahiye"): the previous
  // version turned each individual top-ranked VIDEO into its own "Album"
  // card — that's not really an album, it's one song wearing an album
  // label, and worse, tapping it searched YouTube using the raw VIDEO ID
  // as a text query (collectionId was set to v.id.value), which returns
  // garbage/unrelated results since a video id means nothing as search
  // text. A real premium "Albums" row should represent an artist/channel's
  // body of work, not a single video.
  //
  // Fix: search once, then GROUP results by their uploading channel
  // (official music-label channels prioritized — same _officialChannelMarkers
  // list api_service.dart's YouTube search already uses to rank official
  // uploads above random reuploads). Each accepted channel becomes ONE
  // album card, using its highest-quality song as the card's artwork/
  // title, with collectionId set to the CHANNEL NAME (not a video id) —
  // so tapping the card resolves via _ytTracksFor('$channelName songs'),
  // giving a real multi-track list from that channel instead of one
  // video's worth of "album".
  static const List<String> _officialAlbumChannelMarkers = [
    't-series', 'zee music', 'sony music', 'saregama', 'tips official',
    'tips music', 'speed records', 'desi music factory', 'shemaroo',
    'venus', 'eros now music', 'yrf', 'jjust music', 'white hill music',
    'times music', 'muzik one', 'goldmines', 'ultra music', 'divo',
    'universal music', 'sony music south', 'aditya music', 'lahari music',
    'think music', 'zee music south', 'wave music', 'atlantic records',
    'republic records', 'columbia records', 'interscope', 'def jam',
  ];

  static bool _isOfficialAlbumChannel(String channelName) {
    final c = channelName.toLowerCase();
    return _officialAlbumChannelMarkers.any((m) => c.contains(m));
  }

  static Future<List<BrowseAlbum>> _ytAlbumFallback(String query, {int count = 6}) async {
    final ytClient = yt.YoutubeExplode();
    try {
      final results = await ytClient.search.search('$query song')
          .then((list) => list.toList())
          .timeout(const Duration(seconds: 8), onTimeout: () => <yt.Video>[]);

      // Reject junk/variant titles and apply the quality floor FIRST,
      // then group survivors by channel — so a channel's "album" card is
      // always built from its best qualifying upload, never a low-view or
      // junk-titled one even if that's all a niche channel had.
      final qualified = results.where((v) =>
          _isBrowseQuality(v) && !RecommendationEngine.isInherentVariant(v.title)).toList();

      // Group by channel (case-insensitive), keeping first-seen order so
      // the channel whose song ranked highest in YT's own relevance order
      // still anchors that channel's position in the output row.
      final channelOrder = <String>[];
      final channelBest = <String, yt.Video>{};
      final channelTitles = <String, List<String>>{};
      for (final v in qualified) {
        final channel = v.author.trim();
        if (channel.isEmpty) continue;
        final key = channel.toLowerCase();
        // De-dupe within a channel using the same smart-title comparison
        // used everywhere else, so a channel that re-uploaded the same
        // song 3x under slightly different titles doesn't look "richer"
        // than it is when we later derive a track count.
        final titlesSoFar = channelTitles.putIfAbsent(key, () => []);
        var isDupWithinChannel = false;
        for (final seen in titlesSoFar) {
          if (RecommendationEngine.isSameSongSmart(v.title, seen)) { isDupWithinChannel = true; break; }
        }
        if (isDupWithinChannel) continue;
        titlesSoFar.add(v.title);
        if (!channelBest.containsKey(key)) {
          channelOrder.add(key);
          channelBest[key] = v;
        }
      }

      // Official label/publisher channels first (a T-Series or Zee Music
      // "album" card is exactly what a premium browse row should lead
      // with), independent channels after — same tie-break used for
      // individual YT search results elsewhere in the app.
      channelOrder.sort((a, b) {
        final aOfficial = _isOfficialAlbumChannel(a) ? 0 : 1;
        final bOfficial = _isOfficialAlbumChannel(b) ? 0 : 1;
        return aOfficial.compareTo(bOfficial);
      });

      final out = <BrowseAlbum>[];
      for (final key in channelOrder) {
        if (out.length >= count) break;
        final v = channelBest[key]!;
        final thumb = _bestYtThumbnail(v.thumbnails);
        final trackCount = channelTitles[key]?.length;
        out.add(BrowseAlbum(
          // Channel name, not a video id — this is what makes tapping the
          // card actually work (see albumTracks below): it's used as a
          // real search query ('$channelName songs'), not a meaningless
          // video-id string.
          collectionId: v.author.trim(),
          name: _clean(v.title),
          artist: _clean(v.author),
          artworkUrl: thumb,
          trackCount: trackCount,
          isFromYoutube: true,
        ));
      }

      // Quality/dedup filtering left the row short (thin catalog for a
      // niche query) — backfill from the RAW pool (ignoring the view-count
      // floor, but still respecting per-channel dedup and still grouping
      // by channel) rather than showing fewer cards than the user would
      // expect from a normal Browse row.
      if (out.isEmpty) {
        final fallbackChannelOrder = <String>[];
        final fallbackChannelBest = <String, yt.Video>{};
        final fallbackChannelTitles = <String, List<String>>{};
        for (final v in results) {
          final channel = v.author.trim();
          if (channel.isEmpty) continue;
          final key = channel.toLowerCase();
          final titlesSoFar = fallbackChannelTitles.putIfAbsent(key, () => []);
          var isDupWithinChannel = false;
          for (final seen in titlesSoFar) {
            if (RecommendationEngine.isSameSongSmart(v.title, seen)) { isDupWithinChannel = true; break; }
          }
          if (isDupWithinChannel) continue;
          titlesSoFar.add(v.title);
          if (!fallbackChannelBest.containsKey(key)) {
            fallbackChannelOrder.add(key);
            fallbackChannelBest[key] = v;
          }
        }
        for (final key in fallbackChannelOrder) {
          if (out.length >= count) break;
          final v = fallbackChannelBest[key]!;
          final thumb = _bestYtThumbnail(v.thumbnails);
          out.add(BrowseAlbum(
            collectionId: v.author.trim(),
            name: _clean(v.title),
            artist: _clean(v.author),
            artworkUrl: thumb,
            trackCount: fallbackChannelTitles[key]?.length,
            isFromYoutube: true,
          ));
        }
      }
      return out;
    } catch (_) {
      return [];
    } finally {
      ytClient.close();
    }
  }

  // Real, guaranteed-playable tracks for a YouTube-sourced artist/album —
  // searches YouTube directly and returns tracks whose trackId is an
  // actual YT video id, so tapping one plays immediately via the app's
  // existing YouTube resolve path instead of round-tripping through a
  // Saavn text search that may match nothing for a channel/video name.
  static Future<List<BrowseTrack>> _ytTracksFor(String query) async {
    final ytClient = yt.YoutubeExplode();
    try {
      final results = await ytClient.search.search(query)
          .then((list) => list.toList())
          .timeout(const Duration(seconds: 8), onTimeout: () => <yt.Video>[]);

      // FIX (junk/duplicate tracks inside an opened album or artist page):
      // same gap as _ytAlbumFallback — raw YT search order, no view-count
      // quality gate, no duplicate detection. Applying the same filter here
      // means tapping into a YT-sourced album/artist shows a clean, deduped
      // track list instead of several copies of the same reupload plus
      // whatever low-view junk happened to rank in the raw search.
      final accepted = <yt.Video>[];
      final acceptedTitles = <String>[];
      for (final v in results) {
        if (accepted.length >= 25) break;
        if (!_isBrowseQuality(v)) continue;
        var isDup = false;
        for (final seen in acceptedTitles) {
          if (RecommendationEngine.isSameSongSmart(v.title, seen)) { isDup = true; break; }
        }
        if (isDup) continue;
        acceptedTitles.add(v.title);
        accepted.add(v);
      }
      // Thin/niche query — quality floor left nothing. Backfill ignoring
      // the view-count gate (still deduped) rather than an empty list.
      if (accepted.isEmpty) {
        final acceptedFallback = <String>[];
        for (final v in results) {
          if (accepted.length >= 25) break;
          var isDup = false;
          for (final seen in acceptedFallback) {
            if (RecommendationEngine.isSameSongSmart(v.title, seen)) { isDup = true; break; }
          }
          if (isDup) continue;
          acceptedFallback.add(v.title);
          accepted.add(v);
        }
      }

      return accepted.map((v) {
        final thumb = _bestYtThumbnail(v.thumbnails);
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
    } finally {
      ytClient.close();
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
          // BUGFIX: same mqdefault -> hqdefault upgrade as api_service.dart's
          // artist thumbnail fallback — hqdefault is guaranteed to exist,
          // maxresdefault isn't, and there's no ThumbnailSet here to fall
          // back through since this is a raw HTML scrape.
          return 'https://i.ytimg.com/vi/${match.group(1)}/hqdefault.jpg';
        }
      }
    } catch (_) {}
    return '';
  }

  // Known music-label / channel / playlist names that show up as a YT
  // channel/author name but are NOT actual singers — filtering these out
  // is why _ytArtistFallback below skips them when building artist chips.
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

  // Fetch tracks for a Browse album card — always YouTube now, since every
  // album in Browse is YT-sourced (see search() above). Kept the
  // isFromYoutube param for call-site compatibility with search_screen.dart.
  static Future<List<BrowseTrack>> albumTracks(String collectionId, {bool isFromYoutube = true}) async {
    return _ytTracksFor('$collectionId songs');
  }

  // Fetch top songs for a Browse artist chip — always YouTube now, since
  // every artist in Browse is YT-sourced (see search() above).
  static Future<List<BrowseTrack>> artistTopSongs(String artistName, {bool isFromYoutube = true}) async {
    return _ytTracksFor('$artistName songs');
  }

  static void dispose() => _client.close();
}

class BrowseSearchResult {
  final List<BrowseTrack>  tracks;
  final List<BrowseAlbum>  albums;
  final List<BrowseArtist> artists;
  // PREMIUM FEATURE ("search karte hi seedha playlist dikhna chahiye"):
  // full track list for a strongly query-matched album, pre-fetched by
  // search() above so the UI can render the complete playlist immediately
  // without waiting for a tap. Null/empty when no album matched strongly.
  final BrowseAlbum? topAlbum;
  final List<BrowseTrack> topAlbumTracks;

  const BrowseSearchResult({
    required this.tracks,
    required this.albums,
    required this.artists,
    this.topAlbum,
    this.topAlbumTracks = const [],
  });

  factory BrowseSearchResult.empty() => const BrowseSearchResult(
    tracks: [], albums: [], artists: [],
  );

  bool get isEmpty => tracks.isEmpty && albums.isEmpty && artists.isEmpty;
}
