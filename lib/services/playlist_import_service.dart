// =============================================================================
// FILE: lib/services/playlist_import_service.dart
// PROJECT: Astra Music
// DESCRIPTION: One entry point for importing an outside playlist by link.
//
//   YouTube / YouTube Music  -> tracks come straight from YouTube, already
//                               playable (see ApiService.fetchYtPlaylistSongs)
//   Spotify (playlist/album) -> Spotify only gives us title + artist + length,
//                               so every track is MATCHED to a playable song
//                               (YouTube Music first, JioSaavn as backup).
//
// WRONG-SONG POLICY: a Spotify track is only accepted when title, artist AND
// duration all agree with the candidate (see TrackMatcher.score). Anything
// that doesn't clear the bar is reported back as "not found" instead of being
// silently replaced by a remix / live / cover / karaoke upload.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HandshakeException;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:http/http.dart' as http;

import '../models/song.dart';
import 'api_service.dart';

// ── Public types ─────────────────────────────────────────────────────────────

enum PlaylistImportSource { youtube, spotify }

enum PlaylistImportError {
  /// Text isn't a link/ID we understand at all.
  invalidLink,

  /// A Spotify link, but not a playlist/album (track, artist, podcast...).
  unsupportedLink,

  /// YouTube Mix / radio / Liked Music — no fixed track list.
  isMix,

  /// Private, deleted or non-existent playlist.
  notFound,

  /// Playlist exists but has no tracks.
  empty,

  /// No internet / timeout.
  network,

  /// Spotify list was read, but not a single track could be matched safely.
  noMatches,

  /// Anything else (e.g. Spotify changed its page format).
  failed,
}

class PlaylistImportException implements Exception {
  final PlaylistImportError reason;
  const PlaylistImportException(this.reason);
  @override
  String toString() => 'PlaylistImportException($reason)';
}

/// Thrown when the caller cancelled via [ImportCancelToken].
class PlaylistImportCancelled implements Exception {
  const PlaylistImportCancelled();
}

class ImportCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

enum PlaylistImportPhase { reading, matching }

class PlaylistImportProgress {
  final PlaylistImportPhase phase;
  final int done;
  final int total;
  const PlaylistImportProgress({
    required this.phase,
    this.done = 0,
    this.total = 0,
  });
}

/// A track as described by Spotify (not yet playable in Astra).
class SpotifyTrackRef {
  final String title;
  final List<String> artists;
  final int? durationSec;
  const SpotifyTrackRef({
    required this.title,
    required this.artists,
    this.durationSec,
  });

  String get artistLine => artists.join(', ');
}

class PlaylistImportResult {
  final PlaylistImportSource source;
  final String name;

  /// Playable songs, in the original playlist order, de-duplicated.
  final List<Song> songs;

  /// Spotify tracks we refused to guess (empty for YouTube imports).
  final List<SpotifyTrackRef> unmatched;

  /// Number of tracks the source playlist listed (Spotify) or fetched (YT).
  final int totalTracks;

  /// True when the source may have more tracks than we could read
  /// (Spotify's public share page only exposes the first 100).
  final bool possiblyTruncated;

  const PlaylistImportResult({
    required this.source,
    required this.name,
    required this.songs,
    this.unmatched = const [],
    required this.totalTracks,
    this.possiblyTruncated = false,
  });
}

// ── Service ──────────────────────────────────────────────────────────────────

class PlaylistImportService {
  PlaylistImportService._();

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// How many Spotify tracks are matched at the same time. Low enough not to
  /// hammer the search backends (and trip their health breakers), high enough
  /// that a 100-song playlist finishes in well under a minute.
  static const int _matchConcurrency = 4;

  // Spotify's embed page lists at most this many tracks.
  static const int _spotifyEmbedCap = 100;

  static final RegExp _spotifyRefRe = RegExp(
    r'(playlist|album|track|artist|show|episode)[/:]([A-Za-z0-9]{22})',
    caseSensitive: false,
  );

  static final RegExp _spotifyPageRefRe = RegExp(
    r'open\.spotify\.com/(?:intl-[a-zA-Z-]+/)?(?:embed/)?(playlist|album)/([A-Za-z0-9]{22})',
    caseSensitive: false,
  );

  // ── Link handling ─────────────────────────────────────────────────────────

  /// Pulls the first link (or spotify: URI) out of whatever was pasted —
  /// people often paste "Check this out https://open.spotify.com/..." with
  /// share text around it.
  static String extractCandidate(String raw) {
    final text = raw.trim();
    final uri = RegExp(
      r'spotify:(?:playlist|album|track|artist|show|episode):[A-Za-z0-9]{22}',
      caseSensitive: false,
    ).firstMatch(text);
    if (uri != null) return uri.group(0)!;
    final url = RegExp(
      r'(?:https?://|www\.)[^\s<>"\x27]+',
      caseSensitive: false,
    ).firstMatch(text);
    if (url != null) {
      return url.group(0)!.replaceAll(RegExp(r'[)\]\.,;!?]+$'), '');
    }
    return text;
  }

  static bool _looksSpotify(String s) {
    final l = s.toLowerCase();
    return l.contains('spotify.com') ||
        l.contains('spotify.link') ||
        l.startsWith('spotify:');
  }

  /// Which service a pasted link belongs to. null = not recognisable (yet).
  static PlaylistImportSource? detect(String input) {
    final c = extractCandidate(input);
    if (c.isEmpty) return null;
    if (_looksSpotify(c)) return PlaylistImportSource.spotify;
    final l = c.toLowerCase();
    if (l.contains('youtube.com') ||
        l.contains('youtu.be') ||
        l.contains('list=')) {
      return PlaylistImportSource.youtube;
    }
    // Bare playlist ID pasted on its own.
    if (RegExp(r'^[A-Za-z0-9_-]{13,64}$').hasMatch(c) &&
        (c.startsWith('PL') || c.startsWith('OLAK') || c.startsWith('UU'))) {
      return PlaylistImportSource.youtube;
    }
    return null;
  }

  // ── Main entry ────────────────────────────────────────────────────────────

  static Future<PlaylistImportResult> importFromLink(
    String input, {
    void Function(PlaylistImportProgress progress)? onProgress,
    ImportCancelToken? cancel,
  }) async {
    final candidate = extractCandidate(input);
    if (candidate.isEmpty) {
      throw const PlaylistImportException(PlaylistImportError.invalidLink);
    }
    onProgress?.call(
        const PlaylistImportProgress(phase: PlaylistImportPhase.reading));

    if (_looksSpotify(candidate)) {
      return _importSpotify(candidate, onProgress, cancel);
    }
    return _importYoutube(candidate, cancel);
  }

  // ── YouTube ───────────────────────────────────────────────────────────────

  static Future<PlaylistImportResult> _importYoutube(
      String candidate, ImportCancelToken? cancel) async {
    final titleFuture = ApiService.fetchYtPlaylistTitle(candidate);
    List<Song> songs;
    try {
      songs = await ApiService.fetchYtPlaylistSongs(candidate, limit: 1000);
    } on YtPlaylistImportException catch (e) {
      throw PlaylistImportException(switch (e.reason) {
        YtPlaylistImportError.invalidLink => PlaylistImportError.invalidLink,
        YtPlaylistImportError.isMix => PlaylistImportError.isMix,
        YtPlaylistImportError.network => PlaylistImportError.network,
        YtPlaylistImportError.empty ||
        YtPlaylistImportError.notFound =>
          PlaylistImportError.notFound,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[PlaylistImport] youtube error: $e');
      throw PlaylistImportException(_isNetworkError(e)
          ? PlaylistImportError.network
          : PlaylistImportError.failed);
    }
    if (cancel?.isCancelled ?? false) throw const PlaylistImportCancelled();
    if (songs.isEmpty) {
      throw const PlaylistImportException(PlaylistImportError.empty);
    }
    final title = await titleFuture;
    return PlaylistImportResult(
      source: PlaylistImportSource.youtube,
      name: (title ?? '').trim(),
      songs: songs,
      totalTracks: songs.length,
    );
  }

  // ── Spotify ───────────────────────────────────────────────────────────────

  static Future<PlaylistImportResult> _importSpotify(
    String candidate,
    void Function(PlaylistImportProgress progress)? onProgress,
    ImportCancelToken? cancel,
  ) async {
    final ref = await _resolveSpotifyRef(candidate);
    if (cancel?.isCancelled ?? false) throw const PlaylistImportCancelled();

    final page = await _fetchSpotifyPage(ref.type, ref.id);
    if (cancel?.isCancelled ?? false) throw const PlaylistImportCancelled();

    final tracks = page.tracks;
    final total = tracks.length;
    onProgress?.call(PlaylistImportProgress(
        phase: PlaylistImportPhase.matching, done: 0, total: total));

    final matched = List<Song?>.filled(total, null);
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        if (cancel?.isCancelled ?? false) return;
        final i = next++;
        if (i >= total) return;
        try {
          matched[i] = await _matchTrack(tracks[i]);
        } catch (e) {
          if (kDebugMode) debugPrint('[PlaylistImport] match error: $e');
          matched[i] = null;
        }
        done++;
        onProgress?.call(PlaylistImportProgress(
            phase: PlaylistImportPhase.matching, done: done, total: total));
      }
    }

    await Future.wait(
        List.generate(math.min(_matchConcurrency, total), (_) => worker()));
    if (cancel?.isCancelled ?? false) throw const PlaylistImportCancelled();

    final songs = <Song>[];
    final unmatched = <SpotifyTrackRef>[];
    final seen = <String>{};
    for (var i = 0; i < total; i++) {
      final s = matched[i];
      if (s == null) {
        unmatched.add(tracks[i]);
      } else if (seen.add(s.id)) {
        songs.add(s);
      }
      // else: same song matched twice (duplicate in the source playlist) —
      // quietly keep the first, it isn't a failure.
    }

    if (songs.isEmpty) {
      throw const PlaylistImportException(PlaylistImportError.noMatches);
    }

    return PlaylistImportResult(
      source: PlaylistImportSource.spotify,
      name: page.name,
      songs: songs,
      unmatched: unmatched,
      totalTracks: total,
      possiblyTruncated: page.possiblyTruncated,
    );
  }

  /// Turns whatever Spotify link/URI was pasted into (type, id). Follows
  /// short links (spotify.link / spotify.app.link) to find the real target.
  static Future<_SpotifyRef> _resolveSpotifyRef(String candidate) async {
    _SpotifyRef? fromText(String text, {bool strict = false}) {
      final m = (strict ? _spotifyPageRefRe : _spotifyRefRe).firstMatch(text);
      if (m == null) return null;
      final type = m.group(1)!.toLowerCase();
      if (type != 'playlist' && type != 'album') {
        throw const PlaylistImportException(PlaylistImportError.unsupportedLink);
      }
      return _SpotifyRef(type, m.group(2)!);
    }

    final direct = fromText(candidate);
    if (direct != null) return direct;

    // Short link / unknown spotify URL: follow redirects and look again.
    final l = candidate.toLowerCase();
    if (l.startsWith('spotify:')) {
      throw const PlaylistImportException(PlaylistImportError.invalidLink);
    }
    try {
      final url = candidate.toLowerCase().startsWith('http')
          ? candidate
          : 'https://$candidate';
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': _userAgent,
        'Accept-Language': 'en-US,en;q=0.9',
      }).timeout(const Duration(seconds: 12));
      final finalUrl = resp.request?.url.toString() ?? url;
      final fromUrl = fromText(finalUrl);
      if (fromUrl != null) return fromUrl;
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final fromBody = fromText(body, strict: true);
      if (fromBody != null) return fromBody;
    } on PlaylistImportException {
      rethrow;
    } catch (e) {
      if (_isNetworkError(e)) {
        throw const PlaylistImportException(PlaylistImportError.network);
      }
    }
    throw const PlaylistImportException(PlaylistImportError.invalidLink);
  }

  /// Reads the track list from Spotify's public embed page (no login, no API
  /// key). Two URL variants x two attempts each, so one hiccup never fails an
  /// import.
  static Future<_SpotifyPage> _fetchSpotifyPage(String type, String id) async {
    final urls = [
      'https://open.spotify.com/embed/$type/$id',
      'https://open.spotify.com/embed/$type/$id?utm_source=generator',
    ];
    PlaylistImportError failure = PlaylistImportError.failed;
    for (final url in urls) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final resp = await http.get(Uri.parse(url), headers: {
            'User-Agent': _userAgent,
            'Accept': 'text/html,application/xhtml+xml',
            'Accept-Language': 'en-US,en;q=0.9',
          }).timeout(const Duration(seconds: 15));
          if (resp.statusCode == 404 || resp.statusCode == 403) {
            // Private or non-existent. Trying again won't change that.
            throw const PlaylistImportException(PlaylistImportError.notFound);
          }
          if (resp.statusCode != 200) {
            failure = PlaylistImportError.failed;
            await Future.delayed(const Duration(milliseconds: 500));
            continue;
          }
          final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
          final page = _parseSpotifyEmbed(html);
          if (page == null) {
            failure = PlaylistImportError.failed;
          } else if (page.tracks.isEmpty) {
            failure = PlaylistImportError.empty;
          } else {
            return page;
          }
        } on PlaylistImportException {
          rethrow;
        } catch (e) {
          if (kDebugMode) debugPrint('[PlaylistImport] spotify fetch: $e');
          failure = _isNetworkError(e)
              ? PlaylistImportError.network
              : PlaylistImportError.failed;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    throw PlaylistImportException(failure);
  }

  static _SpotifyPage? _parseSpotifyEmbed(String html) {
    final m = RegExp(
      r'<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>',
      dotAll: true,
    ).firstMatch(html);
    if (m == null) return null;

    dynamic data;
    try {
      data = jsonDecode(m.group(1)!);
    } catch (_) {
      return null;
    }

    Map? entity;
    dynamic cursor = data;
    for (final key in const ['props', 'pageProps', 'state', 'data', 'entity']) {
      cursor = cursor is Map ? cursor[key] : null;
    }
    if (cursor is Map && cursor['trackList'] is List) {
      entity = cursor;
    } else {
      entity = _findEntityWithTrackList(data, 0);
    }
    if (entity == null) return null;

    final list = entity['trackList'] as List;
    final tracks = <SpotifyTrackRef>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final uri = (raw['uri'] ?? '').toString();
      // Skip podcast episodes etc. that can sit inside a playlist.
      if (uri.isNotEmpty && !uri.contains(':track:')) continue;
      final title = _cleanSpotifyText((raw['title'] ?? '').toString());
      if (title.isEmpty) continue;
      final subtitle = _cleanSpotifyText((raw['subtitle'] ?? '').toString());
      final artists = subtitle
          .split(RegExp(r'\s*,\s*'))
          .map((a) => a.trim())
          .where((a) => a.isNotEmpty)
          .toList();
      final d = raw['duration'];
      final ms = d is num ? d.toInt() : int.tryParse((d ?? '').toString());
      tracks.add(SpotifyTrackRef(
        title: title,
        artists: artists,
        durationSec: (ms != null && ms > 0) ? (ms / 1000).round() : null,
      ));
    }

    final name = _cleanSpotifyText(
        (entity['name'] ?? entity['title'] ?? '').toString());
    return _SpotifyPage(
      name: name,
      tracks: tracks,
      possiblyTruncated: list.length >= _spotifyEmbedCap,
    );
  }

  static Map? _findEntityWithTrackList(dynamic node, int depth) {
    if (depth > 12) return null;
    if (node is Map) {
      if (node['trackList'] is List) return node;
      for (final v in node.values) {
        final r = _findEntityWithTrackList(v, depth + 1);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findEntityWithTrackList(v, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  static String _cleanSpotifyText(String s) => s
      .replaceAll(' ', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();

  // ── Matching ──────────────────────────────────────────────────────────────

  static Future<Song?> _matchTrack(SpotifyTrackRef t) async {
    final cleanTitle = TrackMatcher.cleanForSearch(t.title);
    if (cleanTitle.isEmpty) return null;
    final primary = t.artists.isNotEmpty ? t.artists.first : '';
    final q1 = '$cleanTitle $primary'.trim();

    Song? best;
    var bestScore = -1.0;
    void consider(List<Song> results) {
      for (final s in results) {
        if (s.id.isEmpty) continue;
        final sc = TrackMatcher.score(t, s);
        if (sc > bestScore) {
          bestScore = sc;
          best = s;
        }
      }
    }

    consider(await _searchYt(q1));

    if (bestScore < 0.9 && t.artists.length > 1) {
      final q2 = '$cleanTitle ${t.artists.take(2).join(' ')}'.trim();
      if (q2 != q1) consider(await _searchYt(q2));
    }

    if (bestScore < 0.85) {
      consider(await _searchSaavn(q1));
    }

    return bestScore >= TrackMatcher.acceptScore ? best : null;
  }

  static Future<List<Song>> _searchYt(String q) async {
    for (var i = 0; i < 2; i++) {
      try {
        final r = await ApiService.searchYtRaw(q, limit: 10)
            .timeout(const Duration(seconds: 14));
        if (r.isNotEmpty) return r;
      } catch (_) {}
      if (i == 0) await Future.delayed(const Duration(milliseconds: 500));
    }
    return const [];
  }

  static Future<List<Song>> _searchSaavn(String q) async {
    try {
      return await ApiService.searchSaavnRaw(q, limit: 10)
          .timeout(const Duration(seconds: 14));
    } catch (_) {
      return const [];
    }
  }

  static bool _isNetworkError(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is HandshakeException ||
      e is http.ClientException;
}

class _SpotifyRef {
  final String type; // 'playlist' | 'album'
  final String id;
  const _SpotifyRef(this.type, this.id);
}

class _SpotifyPage {
  final String name;
  final List<SpotifyTrackRef> tracks;
  final bool possiblyTruncated;
  const _SpotifyPage({
    required this.name,
    required this.tracks,
    required this.possiblyTruncated,
  });
}

// ── Track matcher ────────────────────────────────────────────────────────────

/// Decides whether a search result really is the Spotify track.
///
/// score() returns -1 for "definitely not", otherwise 0..1:
///   0.50 * title similarity   (token Dice, after stripping feat./From "..."/
///                              remaster noise)
///   0.30 * artist agreement   (lead artist, or any credited artist)
///   +0.20 .. -0.30 duration   (<=3s apart is a near-certain match)
///   -0.35 per version word    (live, remix, cover, karaoke, slowed...) the
///                              candidate has and the original doesn't
class TrackMatcher {
  TrackMatcher._();

  static const double acceptScore = 0.68;

  static const Set<String> _versionWords = {
    'live',
    'remix',
    'cover',
    'karaoke',
    'instrumental',
    'slowed',
    'reverb',
    'sped',
    'speed',
    'acoustic',
    'lofi',
    'mashup',
    '8d',
    'unplugged',
    'reprise',
    'demo',
    'rework',
    'bootleg',
    'nightcore',
    'tribute',
    'ringtone',
  };

  static final RegExp _featParen = RegExp(
      r'[\(\[]\s*(?:feat|ft|featuring|with|prod)\b[^\)\]]*[\)\]]',
      caseSensitive: false);
  static final RegExp _featTail =
      RegExp(r'\s+(?:feat|ft|featuring)\.?\s+.*$', caseSensitive: false);
  static final RegExp _fromParen =
      RegExp(r'[\(\[]\s*from\s+[^\)\]]*[\)\]]', caseSensitive: false);
  static final RegExp _fromTail =
      RegExp(r'\s*[-–—]\s*from\s+.*$', caseSensitive: false);
  static final RegExp _noiseTail = RegExp(
      r'\s*[-–—]\s*(?:\d{4}\s+)?(?:remaster(?:ed)?|re-?master(?:ed)?|single version|radio edit|album version|mono|stereo|deluxe|bonus track)\b.*$',
      caseSensitive: false);
  static final RegExp _noiseParen = RegExp(
      r'[\(\[]\s*(?:\d{4}\s+)?(?:remaster(?:ed)?|re-?master(?:ed)?|single version|radio edit|album version|mono|stereo|deluxe|bonus track|official(?: music)? (?:video|audio)|lyric video|lyrics?|audio|video)[^\)\]]*[\)\]]',
      caseSensitive: false);

  static final RegExp _splitRe =
      RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);

  // Letters from scripts other than Latin — used to spot "तुम ही हो" vs
  // "Tum Hi Ho" style mismatches between Spotify and the matched catalogue.
  static final RegExp _nonLatinRe = RegExp(
      r'[Ͱ-ϿЀ-ӿ؀-ۿऀ-෿฀-๿぀-ヿ㐀-鿿가-힯]');

  static const Map<String, String> _fold = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o', 'ō': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
    'ç': 'c', 'č': 'c', 'ñ': 'n', 'ß': 'ss', 'ý': 'y', 'ÿ': 'y',
    'š': 's', 'ž': 'z', 'ł': 'l',
  };

  static final RegExp _singleLetterRe = RegExp(r'^\p{L}$', unicode: true);
  static final RegExp _combiningRe = RegExp(r'[\u0300-\u036f]');

  static bool _nonLatin(String s) => _nonLatinRe.hasMatch(s);

  /// Title with feat./"From ..."/remaster noise removed (but NOT version
  /// words like Live/Remix — those must still count against a candidate).
  static String clean(String s) {
    var t = s.replaceAll('&amp;', '&').replaceAll('&quot;', '"');
    t = t
        .replaceAll(_featParen, '')
        .replaceAll(_fromParen, '')
        .replaceAll(_noiseParen, '')
        .replaceAll(_fromTail, '')
        .replaceAll(_noiseTail, '')
        .replaceAll(_featTail, '');
    return t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  /// What we type into the search box.
  static String cleanForSearch(String title) {
    final c = clean(title);
    return c.isEmpty ? title.trim() : c;
  }

  static List<String> _tokens(String s) {
    final lower = s.toLowerCase();
    final folded = StringBuffer();
    for (final r in lower.runes) {
      final ch = String.fromCharCode(r);
      folded.write(_fold[ch] ?? ch);
    }
    final raw = <String>[];
    for (final w in folded.toString().replaceAll(_combiningRe, '').split(_splitRe)) {
      if (w.isEmpty || w == 'the' || w == 'and') continue;
      raw.add(w);
    }
    // "A. R. Rahman" -> [ar, rahman]: glue runs of single-letter tokens so
    // initials compare equal to their joined spelling.
    final out = <String>[];
    final run = StringBuffer();
    void flush() {
      if (run.isNotEmpty) {
        out.add(run.toString());
        run.clear();
      }
    }

    for (final w in raw) {
      if (w.runes.length == 1 && _singleLetterRe.hasMatch(w)) {
        run.write(w);
      } else {
        flush();
        out.add(w);
      }
    }
    flush();
    return out;
  }

  /// -1 = reject, otherwise 0..1 confidence.
  static double score(SpotifyTrackRef q, Song c) {
    final qTitleTokens = _tokens(clean(q.title));
    var cTitleTokens = _tokens(clean(c.title));
    if (qTitleTokens.isEmpty || cTitleTokens.isEmpty) return -1;

    final qArtistTokens = <String>{};
    for (final a in q.artists) {
      qArtistTokens.addAll(_tokens(a));
    }

    // YouTube-style "Song - Artist" titles: ignore artist words the original
    // title doesn't contain.
    final qTitleSet = qTitleTokens.toSet();
    cTitleTokens = cTitleTokens
        .where((t) => qTitleSet.contains(t) || !qArtistTokens.contains(t))
        .toList();
    if (cTitleTokens.isEmpty) return -1;

    int? dur;
    if (q.durationSec != null && c.duration != null && c.duration! > 0) {
      dur = (q.durationSec! - c.duration!).abs();
    }

    // ── title ──
    double titleSim;
    if (_nonLatin(q.title) != _nonLatin(c.title)) {
      // Different scripts can't be compared token-by-token; only trust it when
      // the length matches to within 3s (artist is still checked below).
      titleSim = (dur != null && dur <= 3) ? 0.85 : 0.0;
    } else {
      final qs = qTitleTokens.toSet();
      final cs = cTitleTokens.toSet();
      final inter = qs.intersection(cs).length;
      titleSim = (2.0 * inter) / (qs.length + cs.length);
    }
    if (titleSim < 0.6) return -1;

    // ── artist ──
    final cArtistPool = <String>{..._tokens(c.artist), ..._tokens(c.title)};
    double artistScore = 0;
    if (q.artists.isEmpty) {
      artistScore = 0.5;
    } else {
      final primary = _tokens(q.artists.first);
      if (primary.isNotEmpty && primary.every(cArtistPool.contains)) {
        artistScore = 1.0;
      } else {
        for (final a in q.artists.skip(1)) {
          final at = _tokens(a);
          if (at.isNotEmpty && at.every(cArtistPool.contains)) {
            artistScore = 0.8;
            break;
          }
        }
        if (artistScore == 0 && primary.length > 1) {
          final hits = primary.where(cArtistPool.contains).length;
          if (hits * 2 >= primary.length) artistScore = 0.5;
        }
      }
      if (artistScore == 0 &&
          _nonLatin(q.artists.join(' ')) != _nonLatin(c.artist) &&
          dur != null &&
          dur <= 3) {
        artistScore = 0.8;
      }
    }
    if (artistScore == 0) return -1;

    // ── duration ──
    double durAdj = 0;
    if (dur != null) {
      if (dur <= 3) {
        durAdj = 0.2;
      } else if (dur <= 7) {
        durAdj = 0.12;
      } else if (dur <= 15) {
        durAdj = 0.04;
      } else if (dur <= 30) {
        durAdj = -0.1;
      } else {
        durAdj = -0.3;
      }
    }

    // ── version words (live / remix / cover / ...) ──
    final qRaw = _tokens(q.title).toSet();
    final cRaw = _tokens(c.title).toSet();
    var penalty = 0.0;
    for (final w in _versionWords) {
      final inC = cRaw.contains(w);
      final inQ = qRaw.contains(w);
      if (inC && !inQ) {
        penalty += 0.35;
      } else if (inQ && !inC) {
        penalty += 0.25;
      }
    }
    penalty = math.min(penalty, 0.7);

    return 0.5 * titleSim + 0.3 * artistScore + durAdj - penalty;
  }
}
