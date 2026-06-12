import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/song.dart';

// ═══════════════════════════════════════════════════════════════════════════════
//  CACHE ENTRY — generic TTL wrapper
// ═══════════════════════════════════════════════════════════════════════════════
class _CacheEntry<T> {
  final T value;
  final DateTime expiresAt;
  _CacheEntry(this.value, Duration ttl) : expiresAt = DateTime.now().add(ttl);
  bool get isValid => DateTime.now().isBefore(expiresAt);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  IN-MEMORY CACHE STORE
// ═══════════════════════════════════════════════════════════════════════════════
class _Cache {
  // Stream URLs expire in 5 h (YouTube URLs are valid ~6 h)
  static final _streams  = <String, _CacheEntry<String>>{};
  // Metadata & search results: 30 min
  static final _meta     = <String, _CacheEntry<List<Song>>>{};
  // Lyrics: 24 h
  static final _lyrics   = <String, _CacheEntry<String>>{};
  // Artwork URLs: 1 h
  static final _artwork  = <String, _CacheEntry<String>>{};
  // Home feed: 15 min
  static final _home     = <String, _CacheEntry<List<SongSection>>>{};

  static const _streamTtl = Duration(hours: 5);
  static const _metaTtl   = Duration(minutes: 30);
  static const _lyricsTtl = Duration(hours: 24);
  static const _artTtl    = Duration(hours: 1);
  static const _homeTtl   = Duration(minutes: 15);

  // ── Stream URL ──────────────────────────────────────────────────────────────
  static String? getStream(String id) {
    final e = _streams[id];
    if (e != null && e.isValid) return e.value;
    _streams.remove(id);
    return null;
  }
  static void setStream(String id, String url) =>
      _streams[id] = _CacheEntry(url, _streamTtl);
  static void invalidateStream(String id) => _streams.remove(id);

  // ── Search / metadata ───────────────────────────────────────────────────────
  static List<Song>? getMeta(String key) {
    final e = _meta[key];
    if (e != null && e.isValid) return e.value;
    _meta.remove(key);
    return null;
  }
  static void setMeta(String key, List<Song> songs) =>
      _meta[key] = _CacheEntry(songs, _metaTtl);

  // ── Lyrics ──────────────────────────────────────────────────────────────────
  static String? getLyrics(String key) {
    final e = _lyrics[key];
    if (e != null && e.isValid) return e.value;
    _lyrics.remove(key);
    return null;
  }
  static void setLyrics(String key, String text) =>
      _lyrics[key] = _CacheEntry(text, _lyricsTtl);

  // ── Artwork ─────────────────────────────────────────────────────────────────
  static String? getArtwork(String id) {
    final e = _artwork[id];
    if (e != null && e.isValid) return e.value;
    _artwork.remove(id);
    return null;
  }
  static void setArtwork(String id, String url) =>
      _artwork[id] = _CacheEntry(url, _artTtl);

  // ── Home feed ────────────────────────────────────────────────────────────────
  static List<SongSection>? getHome(String key) {
    final e = _home[key];
    if (e != null && e.isValid) return e.value;
    _home.remove(key);
    return null;
  }
  static void setHome(String key, List<SongSection> sections) =>
      _home[key] = _CacheEntry(sections, _homeTtl);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HOST HEALTH TRACKER — ranks Saavn hosts by success rate
// ═══════════════════════════════════════════════════════════════════════════════
class _HostHealth {
  int success = 0;
  int failure = 0;
  DateTime? lastFailure;

  double get score {
    final total = success + failure;
    if (total == 0) return 1.0;
    // Penalise recent failures harder
    final recencyPenalty = (lastFailure != null &&
            DateTime.now().difference(lastFailure!).inMinutes < 5)
        ? 0.3
        : 0.0;
    return (success / total) - recencyPenalty;
  }

  bool get isBlacklisted =>
      failure > 5 &&
      lastFailure != null &&
      DateTime.now().difference(lastFailure!).inMinutes < 2;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  FAILURE ANALYTICS  (in-memory counters — extend to persist if needed)
// ═══════════════════════════════════════════════════════════════════════════════
class FailureAnalytics {
  static final Map<String, int> _counts = {};
  static final List<Map<String, dynamic>> _log = [];

  static void record(String event, {String? detail}) {
    _counts[event] = (_counts[event] ?? 0) + 1;
    _log.add({
      'event': event,
      'detail': detail,
      'time': DateTime.now().toIso8601String(),
    });
    if (_log.length > 500) _log.removeAt(0); // rolling window
  }

  static Map<String, int> get counts => Map.unmodifiable(_counts);
  static List<Map<String, dynamic>> get recentLog =>
      List.unmodifiable(_log.reversed.take(50).toList());

  static void reset() {
    _counts.clear();
    _log.clear();
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  QUEUE / PLAYBACK PERSISTENCE  (lightweight in-memory store)
//  Drop-in: swap _PersistenceStore impl with SharedPreferences/Hive anytime.
// ═══════════════════════════════════════════════════════════════════════════════
class PlaybackPersistence {
  static List<Song> _queue = [];
  static int _index = 0;
  static int _positionMs = 0;

  static void saveQueue(List<Song> queue, int index, int positionMs) {
    _queue = List.from(queue);
    _index = index;
    _positionMs = positionMs;
  }

  static ({List<Song> queue, int index, int positionMs}) restoreQueue() =>
      (queue: List.from(_queue), index: _index, positionMs: _positionMs);

  static bool get hasPersistedQueue => _queue.isNotEmpty;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MAIN SERVICE
// ═══════════════════════════════════════════════════════════════════════════════

/// Production-grade YouTube Music InnerTube + JioSaavn fallback service.
/// Features: multi-client YT fallback, retry + exponential backoff,
/// per-layer caching, host health ranking, lyrics (Saavn + LRCLib),
/// smart prefetch, stream URL refresh, failure analytics.
class ApiService {
  ApiService._();

  static final _client = http.Client();

  // ─── InnerTube constants ────────────────────────────────────────────────────
  static const _ytKey   = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-KOEQ9cGuw';
  static const _ytMusic = 'https://music.youtube.com/youtubei/v1';
  static const _ytBase  = 'https://www.youtube.com/youtubei/v1';

  static const Map<String, String> _ytmHeaders = {
    'Content-Type'    : 'application/json',
    'User-Agent'      : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Origin'          : 'https://music.youtube.com',
    'Referer'         : 'https://music.youtube.com/',
    'X-Goog-Api-Key'  : _ytKey,
  };

  // Multiple YT clients — tried in order until one returns a playable stream
  static const _ytClients = [
    // Best: direct unsigned URLs
    {
      'context': {
        'client': {
          'clientName':        'ANDROID_MUSIC',
          'clientVersion':     '7.27.52',
          'androidSdkVersion': 30,
          'hl': 'en', 'gl': 'IN',
          'userAgent':
              'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 11) gzip',
        }
      },
      'base': _ytBase,
    },
    // Fallback 1: iOS Music client
    {
      'context': {
        'client': {
          'clientName':    'IOS_MUSIC',
          'clientVersion': '6.21',
          'deviceMake':    'Apple',
          'deviceModel':   'iPhone16,2',
          'osName':        'iPhone',
          'osVersion':     '17.5.1.21F90',
          'hl': 'en', 'gl': 'IN',
        }
      },
      'base': _ytBase,
    },
    // Fallback 2: TVHTML5 — rarely blocked
    {
      'context': {
        'client': {
          'clientName':    'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
          'clientVersion': '2.0',
          'hl': 'en', 'gl': 'IN',
        }
      },
      'base': _ytBase,
    },
    // Fallback 3: Web
    {
      'context': {
        'client': {
          'clientName':    'WEB',
          'clientVersion': '2.20240726.00.00',
          'hl': 'en', 'gl': 'IN',
        }
      },
      'base': _ytBase,
    },
  ];

  static const _ctxWebRemix = {
    'client': {
      'clientName':    'WEB_REMIX',
      'clientVersion': '1.20240724.00.00',
      'hl': 'en', 'gl': 'IN',
    }
  };

  // ─── JioSaavn hosts ─────────────────────────────────────────────────────────
  static final _saavnHosts = [
    'https://saavn.dev/api',
    'https://saavn-api-sigma.vercel.app/api',
    'https://jiosaavn-api-privatecvc2.vercel.app',
  ];
  static final _hostHealth = <String, _HostHealth>{};

  // ─── LRCLib (synced lyrics) ──────────────────────────────────────────────────
  static const _lrcLibBase = 'https://lrclib.net/api';

  // ─── Prefetch tracker ────────────────────────────────────────────────────────
  static final _prefetchInFlight = <String>{};

  static final _ytIdRx = RegExp(r'^[A-Za-z0-9_\-]{11}$');

  // ══════════════════════════════════════════════════════════════════════════════
  //  PUBLIC INTERFACE
  // ══════════════════════════════════════════════════════════════════════════════

  /// Home feed. Returns cached result if fresh.
  static Future<List<SongSection>> fetchHome() async {
    const key = 'home_feed';
    final cached = _Cache.getHome(key);
    if (cached != null) return cached;

    final ytSections = await _ytHomeFeed();
    if (ytSections.isNotEmpty) {
      _Cache.setHome(key, ytSections);
      return ytSections;
    }
    final saavnSections = await _saavnHomeSections();
    if (saavnSections.isNotEmpty) _Cache.setHome(key, saavnSections);
    return saavnSections;
  }

  /// Search with cache + dedup + Saavn fallback.
  static Future<List<Song>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final cacheKey = 'search:${_norm(q)}';
    final cached = _Cache.getMeta(cacheKey);
    if (cached != null) return cached;

    final ytResults = await _ytSearch(q);
    List<Song> saavnResults = [];
    if (ytResults.length < 3) {
      saavnResults = await _saavnSearch(q);
    }

    final merged = _dedup([...ytResults, ...saavnResults]);
    if (merged.isNotEmpty) _Cache.setMeta(cacheKey, merged);
    return merged;
  }

  /// Auto-complete suggestions with 3s timeout.
  static Future<List<String>> suggest(String query) async {
    final q = query.trim();
    if (q.length < 2) return [];
    try {
      final res = await _post(
        '$_ytMusic/music/get_search_suggestions?key=$_ytKey',
        headers: _ytmHeaders,
        body: {'context': _ctxWebRemix, 'input': q},
        timeout: const Duration(seconds: 3),
      );
      if (res == null) return [];
      final outer = res['contents'] as List? ?? [];
      final out   = <String>[];
      for (final c in outer) {
        final items = _path(c, ['searchSuggestionsSectionRenderer', 'contents'])
            as List? ?? [];
        for (final item in items) {
          final runs = _path(item,
              ['searchSuggestionRenderer', 'suggestion', 'runs']) as List? ?? [];
          final text = runs.map((r) => r['text'] ?? '').join('').trim();
          if (text.isNotEmpty) out.add(text);
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Resolve stream URL. Returns cached URL if still valid; otherwise re-fetches.
  static Future<String?> resolveStreamUrl(Song song, {bool forceRefresh = false}) async {
    if (song.isLocal) return song.localPath;

    if (!forceRefresh) {
      final cached = _Cache.getStream(song.id);
      if (cached != null) return cached;
    }

    String? url;
    if (_ytIdRx.hasMatch(song.id)) {
      url = await _ytStreamUrl(song.id);
    } else {
      url = await _saavnStreamUrl(song.id);
    }

    if (url != null) {
      _Cache.setStream(song.id, url);
    } else {
      FailureAnalytics.record('stream_resolve_failed', detail: song.id);
    }
    return url;
  }

  /// Refresh a stream URL that may have expired (call before resuming after bg).
  static Future<String?> refreshStreamUrl(Song song) =>
      resolveStreamUrl(song, forceRefresh: true);

  /// Prefetch stream URL + artwork for the next track (non-blocking).
  static void prefetchNext(Song song) {
    if (_prefetchInFlight.contains(song.id)) return;
    _prefetchInFlight.add(song.id);
    Future.microtask(() async {
      try {
        // Stream URL
        if (_Cache.getStream(song.id) == null) {
          await resolveStreamUrl(song);
        }
        // Artwork
        if (song.artworkUrl.isNotEmpty) {
          _Cache.setArtwork(song.id, song.artworkUrl);
        }
      } finally {
        _prefetchInFlight.remove(song.id);
      }
    });
  }

  /// Fetch lyrics — tries Saavn → LRCLib → YouTube description in order.
  static Future<String?> fetchLyrics(Song song) async {
    final key = 'lyrics:${song.id}';
    final cached = _Cache.getLyrics(key);
    if (cached != null) return cached;

    // 1. JioSaavn (only for Saavn IDs)
    if (!_ytIdRx.hasMatch(song.id)) {
      final saavnLyrics = await _saavnLyrics(song.id);
      if (saavnLyrics != null && saavnLyrics.trim().isNotEmpty) {
        _Cache.setLyrics(key, saavnLyrics);
        return saavnLyrics;
      }
    }

    // 2. LRCLib — synced/plain lyrics, free, no key needed
    final lrcLyrics = await _lrcLibLyrics(song.title, song.artist);
    if (lrcLyrics != null && lrcLyrics.trim().isNotEmpty) {
      _Cache.setLyrics(key, lrcLyrics);
      return lrcLyrics;
    }

    // 3. YouTube description scrape (best-effort, often has lyrics)
    if (_ytIdRx.hasMatch(song.id)) {
      final ytLyrics = await _ytDescriptionLyrics(song.id);
      if (ytLyrics != null && ytLyrics.trim().isNotEmpty) {
        _Cache.setLyrics(key, ytLyrics);
        return ytLyrics;
      }
    }

    FailureAnalytics.record('lyrics_not_found', detail: '${song.title} – ${song.artist}');
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  YOUTUBE — HOME FEED
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<List<SongSection>> _ytHomeFeed() async {
    final data = await _post(
      '$_ytMusic/browse?key=$_ytKey',
      headers: _ytmHeaders,
      body: {'context': _ctxWebRemix, 'browseId': 'FEmusic_home'},
      timeout: const Duration(seconds: 12),
    );
    if (data == null) return [];
    return _parseHomeFeed(data);
  }

  static List<SongSection> _parseHomeFeed(Map<String, dynamic> data) {
    final tabs = _path(data,
        ['contents', 'singleColumnBrowseResultsRenderer', 'tabs']) as List? ?? [];
    if (tabs.isEmpty) return [];

    final contents = _path(tabs[0],
        ['tabRenderer', 'content', 'sectionListRenderer', 'contents'])
        as List? ?? [];

    final sections = <SongSection>[];
    for (final c in contents) {
      final carousel = c['musicCarouselShelfRenderer'] as Map?;
      if (carousel == null) continue;

      final title = _path(carousel, [
        'header', 'musicCarouselShelfBasicHeaderRenderer',
        'title', 'runs', 0, 'text',
      ]) as String? ?? 'Featured';

      final items = carousel['contents'] as List? ?? [];
      final songs = <Song>[];
      for (final item in items) {
        final song = _parseTwoRowItem(item['musicTwoRowItemRenderer'])
            ?? _parseResponsiveItem(item['musicResponsiveListItemRenderer']);
        if (song != null) songs.add(song);
      }
      if (songs.isNotEmpty) {
        sections.add(SongSection(title: _dec(title), songs: songs));
      }
    }
    return sections;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  YOUTUBE — SEARCH
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<List<Song>> _ytSearch(String query) async {
    final data = await _post(
      '$_ytMusic/search?key=$_ytKey',
      headers: _ytmHeaders,
      body: {
        'context': _ctxWebRemix,
        'query'  : query,
        'params' : 'Eg-KAQwIARAAGAAgACgAMABqChAEEAMQCRAFEAo=',
      },
      timeout: const Duration(seconds: 10),
    );
    if (data == null) return [];
    return _parseSearchResults(data);
  }

  static List<Song> _parseSearchResults(Map<String, dynamic> data) {
    final tabs = _path(data,
        ['contents', 'tabbedSearchResultsRenderer', 'tabs']) as List? ?? [];
    if (tabs.isEmpty) return [];

    final sections = _path(tabs[0],
        ['tabRenderer', 'content', 'sectionListRenderer', 'contents'])
        as List? ?? [];

    final songs = <Song>[];
    for (final s in sections) {
      final shelf = s['musicShelfRenderer'] as Map?;
      if (shelf == null) continue;
      for (final item in (shelf['contents'] as List? ?? [])) {
        final song = _parseResponsiveItem(item['musicResponsiveListItemRenderer']);
        if (song != null) songs.add(song);
      }
    }
    return songs;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  YOUTUBE — PARSERS
  // ══════════════════════════════════════════════════════════════════════════════

  static Song? _parseTwoRowItem(dynamic r) {
    if (r == null) return null;
    try {
      final videoId =
          _path(r, ['navigationEndpoint', 'watchEndpoint', 'videoId']) as String?
          ?? _path(r, [
               'overlay', 'musicItemThumbnailOverlayRenderer', 'content',
               'musicPlayButtonRenderer', 'playNavigationEndpoint',
               'watchEndpoint', 'videoId']) as String?;
      if (videoId == null || videoId.isEmpty) return null;

      final title = (_path(r, ['title', 'runs', 0, 'text']) as String? ?? '').trim();
      if (title.isEmpty) return null;

      final subtitleRuns = _path(r, ['subtitle', 'runs']) as List? ?? [];
      final artist = subtitleRuns.isNotEmpty
          ? (subtitleRuns[0]['text'] as String? ?? 'Unknown Artist').trim()
          : 'Unknown Artist';

      final thumbs = _path(r, [
        'thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails',
      ]) as List? ?? [];
      final artUrl = _bestThumb(thumbs, preferHigh: false);
      if (artUrl.isNotEmpty) _Cache.setArtwork(videoId, artUrl);

      return Song(
        id: videoId, title: _dec(title), artist: _dec(artist),
        album: '', artworkUrl: artUrl,
      );
    } catch (_) { return null; }
  }

  static Song? _parseResponsiveItem(dynamic r) {
    if (r == null) return null;
    try {
      final videoId =
          _path(r, ['playlistItemData', 'videoId']) as String?
          ?? _path(r, [
               'flexColumns', 0,
               'musicResponsiveListItemFlexColumnRenderer',
               'text', 'runs', 0,
               'navigationEndpoint', 'watchEndpoint', 'videoId']) as String?
          ?? _path(r, [
               'overlay', 'musicItemThumbnailOverlayRenderer', 'content',
               'musicPlayButtonRenderer', 'playNavigationEndpoint',
               'watchEndpoint', 'videoId']) as String?;
      if (videoId == null || videoId.isEmpty) return null;

      final flexCols = r['flexColumns'] as List? ?? [];
      final title = (_path(
        flexCols.isNotEmpty ? flexCols[0] : null,
        ['musicResponsiveListItemFlexColumnRenderer', 'text', 'runs', 0, 'text'],
      ) as String? ?? '').trim();
      if (title.isEmpty) return null;

      String artist = 'Unknown Artist';
      if (flexCols.length > 1) {
        final runs = _path(flexCols[1], [
          'musicResponsiveListItemFlexColumnRenderer', 'text', 'runs',
        ]) as List? ?? [];
        if (runs.isNotEmpty) {
          artist = (runs[0]['text'] as String? ?? '').trim();
          if (artist.isEmpty) artist = 'Unknown Artist';
        }
      }

      final thumbs = _path(r, [
        'thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails',
      ]) as List? ?? [];

      int? dur;
      final fixedCols = r['fixedColumns'] as List? ?? [];
      if (fixedCols.isNotEmpty) {
        dur = _parseDurText(_path(fixedCols[0], [
          'musicResponsiveListItemFixedColumnRenderer',
          'text', 'runs', 0, 'text',
        ]) as String?);
      }

      final artUrl = _bestThumb(thumbs, preferHigh: false);
      if (artUrl.isNotEmpty) _Cache.setArtwork(videoId, artUrl);

      return Song(
        id: videoId, title: _dec(title), artist: _dec(artist),
        album: '', artworkUrl: artUrl, duration: dur,
      );
    } catch (_) { return null; }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  YOUTUBE — STREAM  (multi-client fallback with retry)
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<String?> _ytStreamUrl(String videoId) async {
    for (final clientCfg in _ytClients) {
      final url = await _ytStreamFromClient(videoId, clientCfg);
      if (url != null) return url;
    }
    FailureAnalytics.record('yt_all_clients_failed', detail: videoId);
    return null;
  }

  static Future<String?> _ytStreamFromClient(
    String videoId,
    Map<String, dynamic> cfg,
  ) async {
    final base    = cfg['base'] as String;
    final context = cfg['context'] as Map<String, dynamic>;
    final clientName = (context['client'] as Map)['clientName'] as String;

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'User-Agent':
          'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 11) gzip',
    };

    final body = {
      'context'       : context,
      'videoId'       : videoId,
      'contentCheckOk': true,
      'racyCheckOk'   : true,
    };

    final data = await _retryPost(
      '$base/player?key=$_ytKey',
      headers: headers,
      body: body,
      timeout: const Duration(seconds: 8),
      maxRetries: 2,
      tag: 'yt_stream[$clientName]',
    );
    if (data == null) return null;

    final status = _path(data, ['playabilityStatus', 'status']) as String? ?? '';
    if (status == 'UNPLAYABLE' || status == 'LOGIN_REQUIRED') {
      FailureAnalytics.record('yt_unplayable', detail: '$videoId/$clientName');
      return null;
    }

    final formats = _path(data, ['streamingData', 'adaptiveFormats']) as List? ?? [];

    // Prefer audio/mp4, highest bitrate
    final audioMp4 = formats
        .whereType<Map>()
        .where((f) =>
            (f['mimeType'] as String? ?? '').contains('audio/mp4') &&
            f['url'] != null)
        .toList()
      ..sort((a, b) =>
          ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
    if (audioMp4.isNotEmpty) return audioMp4.first['url'] as String;

    // Any audio fallback
    final anyAudio = formats
        .whereType<Map>()
        .where((f) => f['audioQuality'] != null && f['url'] != null)
        .toList()
      ..sort((a, b) =>
          ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
    return anyAudio.isNotEmpty ? anyAudio.first['url'] as String : null;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  JIOSAAVN — SEARCH + STREAM
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<List<SongSection>> _saavnHomeSections() async {
    const queries = [
      ('🔥 Trending Now',   'trending hindi songs'),
      ('🎬 Bollywood Hits', 'bollywood hits 2024'),
      ('🎵 Top Charts',     'hindi top charts'),
    ];
    final sections = <SongSection>[];
    for (final (label, q) in queries) {
      final songs = await _saavnSearch(q, limit: 15);
      if (songs.isNotEmpty) sections.add(SongSection(title: label, songs: songs));
    }
    return sections;
  }

  static Future<List<Song>> _saavnSearch(String query, {int limit = 20}) async {
    final hosts = _rankedHosts();
    for (final host in hosts) {
      if (_hostHealth[host]?.isBlacklisted == true) continue;
      try {
        final uri = Uri.parse('$host/search/songs').replace(
          queryParameters: {'query': query, 'page': '1', 'limit': '$limit'},
        );
        final res = await _client.get(uri).timeout(const Duration(seconds: 6));
        if (res.statusCode != 200) {
          _recordHostFailure(host);
          continue;
        }
        _recordHostSuccess(host);
        final data    = jsonDecode(res.body) as Map<String, dynamic>;
        final results = (data['data']?['results'] ?? data['data']) as List?;
        if (results == null || results.isEmpty) continue;
        return results
            .whereType<Map<String, dynamic>>()
            .map(_parseSaavnSong)
            .whereType<Song>()
            .toList();
      } catch (e) {
        _recordHostFailure(host);
        FailureAnalytics.record('saavn_search_error', detail: host);
      }
    }
    return [];
  }

  static Future<String?> _saavnStreamUrl(String songId) async {
    final hosts = _rankedHosts();
    for (final host in hosts) {
      if (_hostHealth[host]?.isBlacklisted == true) continue;
      try {
        final res = await _client
            .get(Uri.parse('$host/songs/$songId'))
            .timeout(const Duration(seconds: 6));
        if (res.statusCode != 200) { _recordHostFailure(host); continue; }
        _recordHostSuccess(host);

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final raw  = data['data'];
        final Map<String, dynamic>? songMap = raw is List && raw.isNotEmpty
            ? raw[0] as Map<String, dynamic>
            : raw is Map ? raw as Map<String, dynamic> : null;
        if (songMap == null) continue;

        final urls = songMap['downloadUrl'] as List? ?? [];
        for (final q in ['320kbps', '160kbps', '96kbps', '48kbps']) {
          final m = urls.firstWhere(
            (u) => u['quality'] == q &&
                (u['url'] as String?)?.startsWith('http') == true,
            orElse: () => null,
          );
          if (m != null) return m['url'] as String;
        }
        if (urls.isNotEmpty) {
          final fb = urls.last['url'] as String?;
          if (fb != null && fb.startsWith('http')) return fb;
        }
      } catch (_) {
        _recordHostFailure(host);
      }
    }
    FailureAnalytics.record('saavn_stream_failed', detail: songId);
    return null;
  }

  static Song? _parseSaavnSong(Map<String, dynamic> j) {
    try {
      final id    = (j['id'] ?? '').toString();
      final title = (j['name'] ?? j['title'] ?? '').toString().trim();
      if (id.isEmpty || title.isEmpty) return null;

      final primary = j['artists']?['primary'] as List? ?? [];
      final artist  = primary.isNotEmpty
          ? primary.map((a) => (a['name'] ?? '').toString())
              .where((s) => s.isNotEmpty).join(', ')
          : (j['primaryArtists'] ?? j['singers'] ?? 'Unknown Artist').toString();

      final album  = (j['album']?['name'] ?? '').toString();
      final images = j['image'] as List? ?? [];
      final thumb  = images.isNotEmpty
          ? (images.last['url'] ?? images.last['link'] ?? '').toString()
          : '';
      if (thumb.isNotEmpty) _Cache.setArtwork(id, thumb);

      return Song(
        id: id, title: _dec(title),
        artist: _dec(artist.isEmpty ? 'Unknown Artist' : artist),
        album: _dec(album), artworkUrl: thumb,
        duration: _parseInt(j['duration']),
        language: j['language']?.toString(), year: j['year']?.toString(),
      );
    } catch (_) { return null; }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  LYRICS — JIOSAAVN
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<String?> _saavnLyrics(String songId) async {
    final hosts = _rankedHosts();
    for (final host in hosts) {
      try {
        final res = await _client
            .get(Uri.parse('$host/songs/$songId/lyrics'))
            .timeout(const Duration(seconds: 6));
        if (res.statusCode != 200) { _recordHostFailure(host); continue; }
        _recordHostSuccess(host);
        final data   = jsonDecode(res.body) as Map<String, dynamic>;
        final lyrics = data['data']?['lyrics'] as String?
            ?? data['lyrics'] as String?;
        if (lyrics != null && lyrics.trim().isNotEmpty) {
          return _dec(lyrics.trim());
        }
      } catch (_) { _recordHostFailure(host); }
    }
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  LYRICS — LRCLib (synced LRC format, free, no API key)
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<String?> _lrcLibLyrics(String title, String artist) async {
    try {
      final uri = Uri.parse('$_lrcLibBase/get').replace(queryParameters: {
        'track_name' : title,
        'artist_name': artist,
      });
      final res = await _client.get(uri, headers: {
        'User-Agent': 'MusicApp/1.0 (contact@example.com)',
      }).timeout(const Duration(seconds: 6));

      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      // Prefer synced (LRC) lyrics; fall back to plain text
      final synced = data['syncedLyrics'] as String?;
      if (synced != null && synced.trim().isNotEmpty) return synced.trim();
      final plain = data['plainLyrics'] as String?;
      return plain?.trim();
    } catch (_) {
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  LYRICS — YOUTUBE DESCRIPTION SCRAPE (best-effort)
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<String?> _ytDescriptionLyrics(String videoId) async {
    try {
      // Use next endpoint to get description
      final data = await _post(
        '$_ytBase/next?key=$_ytKey',
        headers: _ytmHeaders,
        body: {'context': _ctxWebRemix, 'videoId': videoId},
        timeout: const Duration(seconds: 8),
      );
      if (data == null) return null;

      // Description path in next response
      final desc = _path(data, [
        'contents', 'singleColumnMusicWatchNextResultsRenderer',
        'tabbedRenderer', 'watchNextTabbedResultsRenderer',
        'tabs', 0, 'tabRenderer', 'content', 'musicQueueRenderer',
        'content', 'playlistPanelRenderer',
      ]);
      // This path varies; extract any long text block heuristically
      final raw = jsonEncode(data);
      final rx  = RegExp(r'"description"\s*:\s*\{"runs"\s*:\s*\[\{"text"\s*:\s*"([^"]{200,})"');
      final match = rx.firstMatch(raw);
      if (match != null) {
        final text = match.group(1)?.replaceAll(r'\n', '\n') ?? '';
        if (text.isNotEmpty) return _dec(text);
      }
      return null;
    } catch (_) { return null; }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  HOST HEALTH HELPERS
  // ══════════════════════════════════════════════════════════════════════════════

  static List<String> _rankedHosts() {
    final hosts = List<String>.from(_saavnHosts);
    hosts.sort((a, b) {
      final sa = _hostHealth[a]?.score ?? 1.0;
      final sb = _hostHealth[b]?.score ?? 1.0;
      return sb.compareTo(sa); // highest score first
    });
    return hosts;
  }

  static void _recordHostSuccess(String host) {
    (_hostHealth[host] ??= _HostHealth()).success++;
  }

  static void _recordHostFailure(String host) {
    final h = (_hostHealth[host] ??= _HostHealth());
    h.failure++;
    h.lastFailure = DateTime.now();
  }

  /// Expose host health scores for debugging / UI display.
  static Map<String, double> get hostHealthScores => {
    for (final h in _saavnHosts) h: _hostHealth[h]?.score ?? 1.0,
  };

  // ══════════════════════════════════════════════════════════════════════════════
  //  NETWORK RECOVERY — call when connectivity is restored
  // ══════════════════════════════════════════════════════════════════════════════

  /// Call this from a ConnectivityListener when network comes back online.
  /// Clears blacklisted host penalties so the next request retries all hosts.
  static void onNetworkRestored() {
    for (final h in _hostHealth.values) {
      h.lastFailure = null; // unblacklist all
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  HTTP HELPERS — retry + exponential backoff
  // ══════════════════════════════════════════════════════════════════════════════

  /// Single POST with timeout — returns decoded JSON or null.
  static Future<Map<String, dynamic>?> _post(
    String url, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async {
    try {
      final res = await _client
          .post(Uri.parse(url), headers: headers, body: jsonEncode(body))
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// POST with exponential backoff retry.
  /// Retries on network errors and 5xx. Does NOT retry on 4xx (client error).
  static Future<Map<String, dynamic>?> _retryPost(
    String url, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required Duration timeout,
    int maxRetries = 3,
    String tag = '',
  }) async {
    int attempt = 0;
    while (attempt <= maxRetries) {
      try {
        final res = await _client
            .post(Uri.parse(url), headers: headers, body: jsonEncode(body))
            .timeout(timeout);

        if (res.statusCode == 200) {
          return jsonDecode(res.body) as Map<String, dynamic>;
        }

        // Don't retry client errors
        if (res.statusCode >= 400 && res.statusCode < 500) {
          FailureAnalytics.record('http_4xx', detail: '$tag:${res.statusCode}');
          return null;
        }

        // Server error — retry
        FailureAnalytics.record('http_5xx_retry', detail: '$tag:${res.statusCode}:attempt$attempt');
      } catch (e) {
        FailureAnalytics.record('network_error', detail: '$tag:attempt$attempt');
      }

      attempt++;
      if (attempt <= maxRetries) {
        // Exponential backoff: 200ms, 400ms, 800ms …
        final delay = Duration(milliseconds: 200 * pow(2, attempt - 1).toInt());
        await Future.delayed(delay);
      }
    }
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  DEDUPLICATION  (improved: title + artist normalization)
  // ══════════════════════════════════════════════════════════════════════════════

  static List<Song> _dedup(List<Song> songs) {
    final seen  = <String>{};
    final out   = <Song>[];
    for (final s in songs) {
      // Key: normalised title + first artist word — catches "Tum Hi Ho (Official)" dups
      final key = '${_norm(s.title)}_${_norm(s.artist.split(',').first)}';
      if (seen.add(key)) out.add(s);
    }
    return out;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ══════════════════════════════════════════════════════════════════════════════

  static dynamic _path(dynamic node, List<dynamic> keys) {
    for (final k in keys) {
      if (node == null) return null;
      if (k is String && node is Map)  { node = node[k]; continue; }
      if (k is int    && node is List) {
        node = k < node.length ? node[k] : null; continue;
      }
      return null;
    }
    return node;
  }

  /// [preferHigh]: true = now-playing screen, false = list view (medium thumb)
  static String _bestThumb(List thumbs, {bool preferHigh = true}) {
    if (preferHigh) {
      for (final t in thumbs.reversed) {
        final url = (t['url'] as String? ?? '').trim();
        if (url.isNotEmpty) return url;
      }
    } else {
      // Pick middle-resolution thumbnail for list views
      final mid = thumbs.length > 1 ? thumbs[thumbs.length ~/ 2] : (thumbs.isNotEmpty ? thumbs.last : null);
      if (mid != null) {
        final url = (mid['url'] as String? ?? '').trim();
        if (url.isNotEmpty) return url;
      }
    }
    return '';
  }

  static int? _parseDurText(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    final parts = s.trim().split(':');
    try {
      if (parts.length == 2) return int.parse(parts[0]) * 60 + int.parse(parts[1]);
      if (parts.length == 3) {
        return int.parse(parts[0]) * 3600 +
            int.parse(parts[1]) * 60 + int.parse(parts[2]);
      }
    } catch (_) {}
    return null;
  }

  static int? _parseInt(dynamic d) {
    if (d == null) return null;
    if (d is int) return d;
    if (d is String) return int.tryParse(d);
    return null;
  }

  /// Extended HTML entity decoder
  static String _dec(String s) => s
      .replaceAll('&amp;',   '&')
      .replaceAll('&quot;',  '"')
      .replaceAll('&#039;',  "'")
      .replaceAll('&#39;',   "'")
      .replaceAll('&lt;',    '<')
      .replaceAll('&gt;',    '>')
      .replaceAll('&nbsp;',  ' ')
      .replaceAll('&hellip;','…')
      .replaceAll('&mdash;', '—')
      .replaceAll('&ndash;', '–')
      .replaceAll(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)));

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}
