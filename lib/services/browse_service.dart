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

/// True if a Browse Saavn result actually relates to what was typed —
/// same word-overlap + typo-tolerance idea as api_service.dart's search
/// scoring, kept local/simple since Browse doesn't need full relevance
/// scoring, just a "not obviously unrelated" floor.
bool _looksRelevant(String title, String query) {
  if (title.isEmpty || query.isEmpty) return false;
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), '');
  final t = norm(title);
  final q = norm(query);
  if (t == q || t.contains(q) || q.contains(t)) return true;

  final qWords = q.split(RegExp(r'\s+')).where((w) => w.length > 2).toList();
  if (qWords.isEmpty) return true; // too short a query to filter safely
  var matched = 0;
  for (final w in qWords) {
    if (t.contains(w)) {
      matched++;
      continue;
    }
    // Bounded edit-distance typo tolerance — same reasoning as
    // ApiService._fuzzyWordMatch: a genuine misspelling ("saayar" for
    // "saiyaara") shouldn't make an otherwise-correct result look
    // unrelated just because it doesn't substring-match exactly.
    final tTokens = t.split(' ');
    for (final tok in tTokens) {
      if (tok.length < 3) continue;
      final maxEdits = w.length <= 4 ? 1 : (w.length <= 7 ? 2 : 3);
      if ((w.length - tok.length).abs() > maxEdits) continue;
      if (_editDistanceAtMost(w, tok, maxEdits)) { matched++; break; }
    }
  }
  return (matched / qWords.length) >= 0.5;
}

bool _editDistanceAtMost(String a, String b, int maxDistance) {
  if (a == b) return true;
  final la = a.length, lb = b.length;
  if ((la - lb).abs() > maxDistance) return false;
  var prev = List<int>.generate(lb + 1, (j) => j);
  for (var i = 1; i <= la; i++) {
    final cur = List<int>.filled(lb + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= lb; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].reduce((v, e) => v < e ? v : e);
    }
    prev = cur;
  }
  return prev[lb] <= maxDistance;
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

    // FIX (Browse tab showing unrelated tracks for loose/typo'd queries):
    // Browse's track list previously took every Saavn result verbatim with
    // no relevance check at all — the Search tab already learned this
    // lesson (a backend's own loose full-text match can return genuinely
    // unrelated songs for a misspelled or partial query) and applies a
    // lightweight relevance floor; Browse had no equivalent, so the same
    // "typo query returns random songs" symptom could show up here too.
    // This mirrors that same word/phrase-overlap floor, just without
    // needing ApiService's private scorer — kept local and simple since
    // Browse doesn't need the full mood/session-aware scoring, only "is
    // this actually related to what was typed".
    final relevantRawTracks = rawTracks.where((j) {
      final title = (j['song'] ?? j['name'] ?? j['title'] ?? '').toString();
      return _looksRelevant(title, query.trim());
    }).toList();
    // If the relevance filter left nothing (very short/ambiguous query,
    // or every result happened to score low), fall back to the unfiltered
    // list rather than showing an empty Browse tab.
    final effectiveRawTracks = relevantRawTracks.isNotEmpty ? relevantRawTracks : rawTracks;

    final tracks  = <BrowseTrack>[];
    for (final j in effectiveRawTracks) {
      try { tracks.add(BrowseTrack.fromSaavn(j)); } catch (_) {}
    }

    // Derive a lightweight "Albums" and "Artists" view from the (already
    // relevance-filtered) track results so Browse still feels rich without
    // needing extra endpoints.
    var albums  = _deriveAlbums(effectiveRawTracks);
    var artists = _deriveArtists(effectiveRawTracks);

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

  // Full YouTube-sourced fallback for albums when Saavn has none — groups
  // top video results loosely so the row still shows something playable.
  //
  // FIX ("Albums" row showing junk/duplicate results): this used to take
  // YouTube's raw top-6 results with zero filtering — no view-count/quality
  // gate (unlike every other YouTube-sourced surface in the app: search,
  // up-next, home feed all apply RecommendationEngine.isPremiumQuality /
  // isLowQualityUpload) and no duplicate detection, so 2-3 re-uploads of
  // the exact same song could easily eat multiple slots in a 6-card row,
  // and low-view junk uploads (status videos, wedding uploads, etc.) could
  // fill the rest. Fetching a wider pool and filtering/deduping down to the
  // requested count brings this row up to the same premium bar the rest of
  // the app already holds YouTube content to.
  static Future<List<BrowseAlbum>> _ytAlbumFallback(String query, {int count = 6}) async {
    final ytClient = yt.YoutubeExplode();
    try {
      final results = await ytClient.search.search('$query song')
          .then((list) => list.toList())
          .timeout(const Duration(seconds: 8), onTimeout: () => <yt.Video>[]);

      final out = <BrowseAlbum>[];
      final acceptedTitles = <String>[];
      for (final v in results) {
        if (out.length >= count) break;
        if (!_isBrowseQuality(v)) continue;
        if (RecommendationEngine.isInherentVariant(v.title)) continue;
        var isDup = false;
        for (final seen in acceptedTitles) {
          if (RecommendationEngine.isSameSongSmart(v.title, seen)) { isDup = true; break; }
        }
        if (isDup) continue;
        acceptedTitles.add(v.title);
        final thumb = _bestYtThumbnail(v.thumbnails);
        out.add(BrowseAlbum(
          collectionId: v.id.value, // real YT video id — used directly for playback
          name: _clean(v.title),
          artist: _clean(v.author),
          artworkUrl: thumb,
          isFromYoutube: true,
        ));
      }

      // Quality/dedup filtering left the row short (thin catalog for a
      // niche query) — backfill from the same pool ignoring the view-count
      // floor (but still respecting dedup) rather than showing fewer cards
      // than the user would expect from a normal Browse row.
      if (out.isEmpty) {
        final acceptedFallback = <String>[];
        for (final v in results) {
          if (out.length >= count) break;
          var isDup = false;
          for (final seen in acceptedFallback) {
            if (RecommendationEngine.isSameSongSmart(v.title, seen)) { isDup = true; break; }
          }
          if (isDup) continue;
          acceptedFallback.add(v.title);
          final thumb = _bestYtThumbnail(v.thumbnails);
          out.add(BrowseAlbum(
            collectionId: v.id.value,
            name: _clean(v.title),
            artist: _clean(v.author),
            artworkUrl: thumb,
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

  // Group track results by album name to fake an "Albums" row.
  //
  // FIX (Albums row showing duplicate cards / missing genuine variety):
  // dedup was keyed on the raw albumName string, case-sensitively. The
  // same backend often returns the same album with inconsistent casing
  // across different track entries (e.g. "Saajan" on one song, "SAAJAN"
  // on another from the same OST) — those produced two separate cards
  // for the same album, eating a slot that could have gone to a genuinely
  // different album, and made the row look broken/repetitive. Dedup key
  // is now case-normalized while the original casing is still used for
  // display.
  static List<BrowseAlbum> _deriveAlbums(List<Map<String, dynamic>> raw) {
    final seen = <String, BrowseAlbum>{};
    for (final j in raw) {
      final albumName = (j['album'] ?? '').toString().trim();
      if (albumName.isEmpty) continue;
      final key = albumName.toLowerCase();
      if (seen.containsKey(key)) continue;
      try {
        final artwork = _hqArtwork((j['image'] ?? '').toString());
        seen[key] = BrowseAlbum(
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
