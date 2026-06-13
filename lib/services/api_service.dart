import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/song.dart';

// ═══════════════════════════════════════════════════════════════════════════════
//  CACHE ENTRY
// ═══════════════════════════════════════════════════════════════════════════════
class _CacheEntry<T> {
  final T value;
  final DateTime expiresAt;
  _CacheEntry(this.value, Duration ttl) : expiresAt = DateTime.now().add(ttl);
  bool get isValid => DateTime.now().isBefore(expiresAt);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  CACHE STORE
// ═══════════════════════════════════════════════════════════════════════════════
class _Cache {
  static final _streams = <String, _CacheEntry<String>>{};
  static final _meta    = <String, _CacheEntry<List<Song>>>{};
  static final _lyrics  = <String, _CacheEntry<String>>{};
  static final _artwork = <String, _CacheEntry<String>>{};
  static final _home    = <String, _CacheEntry<List<SongSection>>>{};

  static const _streamTtl = Duration(hours: 5);
  static const _metaTtl   = Duration(minutes: 30);
  static const _lyricsTtl = Duration(hours: 24);
  static const _artTtl    = Duration(hours: 1);
  static const _homeTtl   = Duration(minutes: 15);

  static String? getStream(String id) {
    final e = _streams[id];
    if (e != null && e.isValid) return e.value;
    _streams.remove(id);
    return null;
  }
  static void setStream(String id, String url) =>
      _streams[id] = _CacheEntry(url, _streamTtl);
  static void invalidateStream(String id) => _streams.remove(id);

  static List<Song>? getMeta(String key) {
    final e = _meta[key];
    if (e != null && e.isValid) return e.value;
    _meta.remove(key);
    return null;
  }
  static void setMeta(String key, List<Song> songs) =>
      _meta[key] = _CacheEntry(songs, _metaTtl);

  static String? getLyrics(String key) {
    final e = _lyrics[key];
    if (e != null && e.isValid) return e.value;
    _lyrics.remove(key);
    return null;
  }
  static void setLyrics(String key, String text) =>
      _lyrics[key] = _CacheEntry(text, _lyricsTtl);

  static String? getArtwork(String id) {
    final e = _artwork[id];
    if (e != null && e.isValid) return e.value;
    _artwork.remove(id);
    return null;
  }
  static void setArtwork(String id, String url) =>
      _artwork[id] = _CacheEntry(url, _artTtl);

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
//  HOST HEALTH TRACKER
// ═══════════════════════════════════════════════════════════════════════════════
class _HostHealth {
  int success = 0;
  int failure = 0;
  DateTime? lastFailure;

  double get score {
    final total = success + failure;
    if (total == 0) return 1.0;
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
//  FAILURE ANALYTICS
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
    if (_log.length > 500) _log.removeAt(0);
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
//  PLAYBACK PERSISTENCE
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
class ApiService {
  ApiService._();

  static final _client = http.Client();

  // ─── InnerTube constants ────────────────────────────────────────────────────
  static const _ytKey   = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-KOEQ9cGuw';
  static const _workerBase = 'https://aurum-stream.sharmashivam9109.workers.dev';
  static const _ytMusic = 'https://music.youtube.com/youtubei/v1';
  static const _ytBase  = 'https://www.youtube.com/youtubei/v1';

  static const Map<String, String> _ytmHeaders = {
    'Content-Type'   : 'application/json',
    'User-Agent'     : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Origin'         : 'https://music.youtube.com',
    'Referer'        : 'https://music.youtube.com/',
    'X-Goog-Api-Key' : _ytKey,
  };

  // YT clients tried in order — most reliable first
  static const _ytClients = [
    {
      'context': {
        'client': {
          'clientName':        'ANDROID_MUSIC',
          'clientVersion':     '8.13.50',
          'androidSdkVersion': 30,
          'hl': 'en', 'gl': 'IN',
          'userAgent':
              'com.google.android.apps.youtube.music/8.13.50 (Linux; U; Android 11) gzip',
        }
      },
      'base': _ytBase,
    },
    {
      'context': {
        'client': {
          'clientName':    'IOS_MUSIC',
          'clientVersion': '8.13',
          'deviceMake':    'Apple',
          'deviceModel':   'iPhone16,2',
          'osName':        'iPhone',
          'osVersion':     '17.5.1.21F90',
          'hl': 'en', 'gl': 'IN',
        }
      },
      'base': _ytBase,
    },
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
    {
      'context': {
        'client': {
          'clientName':    'WEB',
          'clientVersion': '2.20260120.01.00',
          'hl': 'en', 'gl': 'IN',
        }
      },
      'base': _ytBase,
    },
  ];

  static const _ctxWebRemix = {
    'client': {
      'clientName':    'WEB_REMIX',
      'clientVersion': '1.20260121.03.00',
      'hl': 'en', 'gl': 'IN',
    }
  };

  // ─── Invidious instances for YT stream fallback ─────────────────────────────
  // Tried in order; health tracked per-instance
  static final _invidiousInstances = [
    'https://invidious.io.lol',
    'https://yt.cdaut.de',
    'https://invidious.nerdvpn.de',
    'https://inv.nadeko.net',
    'https://invidious.privacyredirect.com',
  ];
  static final _invHealth = <String, _HostHealth>{};

  // ─── JioSaavn — primary working host ────────────────────────────────────────
  static const _jiosavanBase = 'https://jiosavan.onrender.com';

  // Legacy Saavn hosts — kept as last-resort fallback
  static final _saavnHosts = [
    'https://saavn.dev/api',
    'https://saavn-api-sigma.vercel.app/api',
    'https://jiosaavn-api-privatecvc2.vercel.app',
  ];
  static final _hostHealth = <String, _HostHealth>{};

  // ─── LRCLib ─────────────────────────────────────────────────────────────────
  static const _lrcLibBase = 'https://lrclib.net/api';

  // ─── Prefetch tracker ────────────────────────────────────────────────────────
  static final _prefetchInFlight = <String>{};

  static final _ytIdRx = RegExp(r'^[A-Za-z0-9_\-]{11}$');

  // ══════════════════════════════════════════════════════════════════════════════
  //  PUBLIC INTERFACE
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<List<SongSection>> fetchHome() async {
    const key = 'home_feed';
    final cached = _Cache.getHome(key);
    if (cached != null) return cached;

    final ytSections = await _ytHomeFeed();
    if (ytSections.isNotEmpty) {
      // Prefetch stream URLs for first 3 songs of first section in background
      _prefetchSectionStreams(ytSections);
      _Cache.setHome(key, ytSections);
      return ytSections;
    }
    final saavnSections = await _saavnHomeSections();
    if (saavnSections.isNotEmpty) {
      _Cache.setHome(key, saavnSections);
    }
    return saavnSections;
  }

  static Future<List<Song>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final cacheKey = 'search:${_norm(q)}';
    final cached = _Cache.getMeta(cacheKey);
    if (cached != null) {
      // Prefetch top 3 stream URLs in background on cache hit too
      _prefetchTopStreams(cached);
      return cached;
    }

    // Run YT search and jiosavan search in parallel for speed
    final results = await Future.wait([
      _ytSearch(q),
      _jiosavanSearch(q),
    ]);

    final ytResults    = results[0];
    final saavnResults = results[1];

    // YT results first (better metadata), saavn fills gaps
    // If YT returned enough, skip merging saavn to keep list clean
    List<Song> merged;
    if (ytResults.length >= 5) {
      merged = _dedup([...ytResults, ...saavnResults]);
    } else {
      // YT failed or thin — saavn primary
      merged = _dedup([...saavnResults, ...ytResults]);
    }

    if (merged.isNotEmpty) {
      _Cache.setMeta(cacheKey, merged);
      // Prefetch top 3 stream URLs immediately in background
      _prefetchTopStreams(merged);
    }
    return merged;
  }

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

  /// Resolve stream URL. Cache first — instant if pre-fetched.
  static Future<String?> resolveStreamUrl(Song song, {bool forceRefresh = false}) async {
    if (song.isLocal) return song.localPath;

    if (!forceRefresh) {
      final cached = _Cache.getStream(song.id);
      if (cached != null) return cached; // instant return
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

  static Future<String?> refreshStreamUrl(Song song) =>
      resolveStreamUrl(song, forceRefresh: true);

  /// Prefetch next track's stream URL at 80% of current track.
  static void prefetchNext(Song song) {
    if (_prefetchInFlight.contains(song.id)) return;
    _prefetchInFlight.add(song.id);
    Future.microtask(() async {
      try {
        if (_Cache.getStream(song.id) == null) {
          await resolveStreamUrl(song);
        }
        if (song.artworkUrl.isNotEmpty) {
          _Cache.setArtwork(song.id, song.artworkUrl);
        }
      } finally {
        _prefetchInFlight.remove(song.id);
      }
    });
  }

  static Future<String?> fetchLyrics(Song song) async {
    final key = 'lyrics:${song.id}';
    final cached = _Cache.getLyrics(key);
    if (cached != null) return cached;

    if (!_ytIdRx.hasMatch(song.id)) {
      final saavnLyrics = await _saavnLyrics(song.id);
      if (saavnLyrics != null && saavnLyrics.trim().isNotEmpty) {
        _Cache.setLyrics(key, saavnLyrics);
        return saavnLyrics;
      }
    }

    final lrcLyrics = await _lrcLibLyrics(song.title, song.artist);
    if (lrcLyrics != null && lrcLyrics.trim().isNotEmpty) {
      _Cache.setLyrics(key, lrcLyrics);
      return lrcLyrics;
    }

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

  // ── Internal: prefetch top N stream URLs in background ──────────────────────
  static void _prefetchTopStreams(List<Song> songs) {
    final top = songs.take(3).toList();
    for (final song in top) {
      if (_prefetchInFlight.contains(song.id)) continue;
      if (_Cache.getStream(song.id) != null) continue;
      _prefetchInFlight.add(song.id);
      Future.microtask(() async {
        try {
          await resolveStreamUrl(song);
        } finally {
          _prefetchInFlight.remove(song.id);
        }
      });
    }
  }

  static void _prefetchSectionStreams(List<SongSection> sections) {
    if (sections.isEmpty) return;
    _prefetchTopStreams(sections.first.songs);
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
  //  YOUTUBE — STREAM RESOLUTION
  //  Order: InnerTube clients → Invidious instances
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<String?> _ytStreamUrl(String videoId) async {
    // 1. Cloudflare Worker
    try {
      final res = await _client.get(Uri.parse(_workerBase + '/api/yt-stream?id=' + videoId)).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['success'] == true && data['url'] != null) return data['url'] as String;
      }
    } catch (_) {}
    // 2. InnerTube fallback
    for (final clientCfg in _ytClients) {
      final url = await _ytStreamFromClient(videoId, clientCfg);
      if (url != null) return url;
    }

    // 2. InnerTube failed — try Invidious instances
    FailureAnalytics.record('yt_innertube_failed', detail: videoId);
    final invUrl = await _invidiousStreamUrl(videoId);
    if (invUrl != null) return invUrl;

    FailureAnalytics.record('yt_all_failed', detail: videoId);
    return null;
  }

  static Future<String?> _ytStreamFromClient(
    String videoId,
    Map<String, dynamic> cfg,
  ) async {
    final base       = cfg['base'] as String;
    final context    = cfg['context'] as Map<String, dynamic>;
    final clientName = (context['client'] as Map)['clientName'] as String;

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'User-Agent':
          'com.google.android.apps.youtube.music/8.13.50 (Linux; U; Android 11) gzip',
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
      maxRetries: 1,
      tag: 'yt[$clientName]',
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
  //  INVIDIOUS — YT stream fallback
  //  Uses health tracking — best instance first
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<String?> _invidiousStreamUrl(String videoId) async {
    final instances = _rankedInvidious();
    for (final base in instances) {
      if (_invHealth[base]?.isBlacklisted == true) continue;
      try {
        final res = await _client
            .get(
              Uri.parse('$base/api/v1/videos/$videoId'),
              headers: {'User-Agent': 'Mozilla/5.0'},
            )
            .timeout(const Duration(seconds: 7));

        if (res.statusCode != 200) {
          _recordInvFailure(base);
          continue;
        }

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final formats = data['adaptiveFormats'] as List? ?? [];

        // Audio only — no video
        final audioFormats = formats
            .whereType<Map>()
            .where((f) {
              final type = (f['type'] as String? ?? '');
              final url  = (f['url'] as String? ?? '');
              return (type.contains('audio/mp4') || type.contains('audio/webm'))
                  && url.startsWith('http');
            })
            .toList()
          ..sort((a, b) =>
              ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));

        if (audioFormats.isNotEmpty) {
          _recordInvSuccess(base);
          return audioFormats.first['url'] as String;
        }

        // Fallback: formatStreams (combined, audio+video — audio still plays)
        final fmtStreams = data['formatStreams'] as List? ?? [];
        for (final f in fmtStreams.reversed) {
          final url = (f['url'] as String? ?? '');
          if (url.startsWith('http')) {
            _recordInvSuccess(base);
            return url;
          }
        }

        _recordInvFailure(base);
      } catch (_) {
        _recordInvFailure(base);
        FailureAnalytics.record('invidious_error', detail: base);
      }
    }
    return null;
  }

  static List<String> _rankedInvidious() {
    final list = List<String>.from(_invidiousInstances);
    list.sort((a, b) {
      final sa = _invHealth[a]?.score ?? 1.0;
      final sb = _invHealth[b]?.score ?? 1.0;
      return sb.compareTo(sa);
    });
    return list;
  }

  static void _recordInvSuccess(String host) =>
      (_invHealth[host] ??= _HostHealth()).success++;

  static void _recordInvFailure(String host) {
    final h = (_invHealth[host] ??= _HostHealth());
    h.failure++;
    h.lastFailure = DateTime.now();
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  JIOSAAVN — PRIMARY SAAVN SOURCE
  //  jiosavan.onrender.com — flat array, media_url directly playable
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<List<SongSection>> _saavnHomeSections() async {
    const queries = [
      ('🔥 Trending Now',   'trending hindi songs 2025'),
      ('🎬 Bollywood Hits', 'bollywood hits 2025'),
      ('🎵 Top Charts',     'hindi top charts'),
    ];
    final sections = <SongSection>[];
    for (final (label, q) in queries) {
      List<Song> songs = await _jiosavanSearch(q, limit: 15);
      if (songs.isEmpty) songs = await _saavnSearch(q, limit: 15);
      if (songs.isNotEmpty) sections.add(SongSection(title: label, songs: songs));
    }
    return sections;
  }

  static Future<List<Song>> _jiosavanSearch(String query, {int limit = 20}) async {
    try {
      final uri = Uri.parse('$_jiosavanBase/result/').replace(
        queryParameters: {'query': query, 'limit': '$limit'},
      );
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        FailureAnalytics.record('jiosavan_error', detail: '${res.statusCode}');
        return [];
      }
      final raw = jsonDecode(res.body);
      final List items = raw is List ? raw : [];
      final songs = <Song>[];
      for (final item in items) {
        if (item is! Map<String, dynamic>) continue;
        final id    = (item['id'] ?? '').toString().trim();
        final title = _dec((item['song'] ?? item['title'] ?? '').toString().trim());
        if (id.isEmpty || title.isEmpty) continue;

        final artist  = _dec((item['singers'] ?? item['primary_artists'] ?? 'Unknown Artist').toString().trim());
        final album   = _dec((item['album'] ?? '').toString().trim());
        final artUrl  = (item['image'] ?? '').toString().trim();
        final dur     = _parseInt(item['duration']);
        final lang    = item['language']?.toString();
        final year    = item['year']?.toString();

        // Pre-cache stream URL — no separate resolve call needed
        final mediaUrl = (item['media_url'] ?? '').toString().trim();
        if (mediaUrl.startsWith('http')) {
          _Cache.setStream(id, mediaUrl);
        }

        if (artUrl.isNotEmpty) _Cache.setArtwork(id, artUrl);

        songs.add(Song(
          id: id,
          title: title,
          artist: artist.isEmpty ? 'Unknown Artist' : artist,
          album: album,
          artworkUrl: artUrl,
          duration: dur,
          language: lang,
          year: year,
        ));
      }
      return songs;
    } catch (e) {
      FailureAnalytics.record('jiosavan_search_error', detail: e.toString());
      return [];
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  JIOSAAVN LEGACY HOSTS — last resort fallback
  // ══════════════════════════════════════════════════════════════════════════════

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
    // For jiosavan songs — stream URL already in cache from search
    final cached = _Cache.getStream(songId);
    if (cached != null) return cached;

    // Legacy hosts fallback
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
  //  LYRICS
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
      final synced = data['syncedLyrics'] as String?;
      if (synced != null && synced.trim().isNotEmpty) return synced.trim();
      final plain = data['plainLyrics'] as String?;
      return plain?.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _ytDescriptionLyrics(String videoId) async {
    try {
      final data = await _post(
        '$_ytBase/next?key=$_ytKey',
        headers: _ytmHeaders,
        body: {'context': _ctxWebRemix, 'videoId': videoId},
        timeout: const Duration(seconds: 8),
      );
      if (data == null) return null;
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
      return sb.compareTo(sa);
    });
    return hosts;
  }

  static void _recordHostSuccess(String host) =>
      (_hostHealth[host] ??= _HostHealth()).success++;

  static void _recordHostFailure(String host) {
    final h = (_hostHealth[host] ??= _HostHealth());
    h.failure++;
    h.lastFailure = DateTime.now();
  }

  static Map<String, double> get hostHealthScores => {
    for (final h in _saavnHosts) h: _hostHealth[h]?.score ?? 1.0,
  };

  static void onNetworkRestored() {
    for (final h in _hostHealth.values) {
      h.lastFailure = null;
    }
    for (final h in _invHealth.values) {
      h.lastFailure = null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  HTTP HELPERS
  // ══════════════════════════════════════════════════════════════════════════════

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

  static Future<Map<String, dynamic>?> _retryPost(
    String url, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required Duration timeout,
    int maxRetries = 2,
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
        if (res.statusCode >= 400 && res.statusCode < 500) {
          FailureAnalytics.record('http_4xx', detail: '$tag:${res.statusCode}');
          return null;
        }
        FailureAnalytics.record('http_5xx_retry', detail: '$tag:${res.statusCode}:attempt$attempt');
      } catch (e) {
        FailureAnalytics.record('network_error', detail: '$tag:attempt$attempt');
      }

      attempt++;
      if (attempt <= maxRetries) {
        final delay = Duration(milliseconds: 200 * pow(2, attempt - 1).toInt());
        await Future.delayed(delay);
      }
    }
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  DEDUP + HELPERS
  // ══════════════════════════════════════════════════════════════════════════════

  static List<Song> _dedup(List<Song> songs) {
    final seen = <String>{};
    final out  = <Song>[];
    for (final s in songs) {
      final key = '${_norm(s.title)}_${_norm(s.artist.split(',').first)}';
      if (seen.add(key)) out.add(s);
    }
    return out;
  }

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

  static String _bestThumb(List thumbs, {bool preferHigh = true}) {
    if (preferHigh) {
      for (final t in thumbs.reversed) {
        final url = (t['url'] as String? ?? '').trim();
        if (url.isNotEmpty) return url;
      }
    } else {
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
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)));

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  // ══════════════════════════════════════════════════════════════════════════════
  //  DEBUG
  // ══════════════════════════════════════════════════════════════════════════════

  static Future<String> debugYtSearch() async {
    final buf = StringBuffer();
    try {
      buf.writeln('--- YT SEARCH ---');
      final uri = Uri.parse('$_ytMusic/search?key=$_ytKey');
      final res = await _client.post(
        uri,
        headers: _ytmHeaders,
        body: jsonEncode({
          'context': _ctxWebRemix,
          'query': 'arijit singh',
          'params': 'Eg-KAQwIARAAGAAgACgAMABqChAEEAMQCRAFEAo=',
        }),
      ).timeout(const Duration(seconds: 10));
      buf.writeln('Status: ${res.statusCode}');
      buf.writeln('Body length: ${res.body.length}');
      if (res.statusCode == 200) {
        final data   = jsonDecode(res.body) as Map<String, dynamic>;
        final parsed = _parseSearchResults(data);
        buf.writeln('Parsed songs: ${parsed.length}');
        if (parsed.isNotEmpty) {
          buf.writeln('First: ${parsed.first.title} - ${parsed.first.artist} (id=${parsed.first.id})');
        }
      }

      buf.writeln('\n--- YT STREAM TEST (InnerTube) ---');
      final streamUrl = await _ytStreamFromClient('dQw4w9WgXcQ', _ytClients[0]);
      buf.writeln('InnerTube stream: ${streamUrl != null ? "OK" : "FAILED"}');

      buf.writeln('\n--- INVIDIOUS STREAM TEST ---');
      final invUrl = await _invidiousStreamUrl('dQw4w9WgXcQ');
      buf.writeln('Invidious stream: ${invUrl != null ? "OK" : "FAILED"}');
      if (invUrl != null) buf.writeln('URL: ${invUrl.substring(0, invUrl.length > 60 ? 60 : invUrl.length)}...');

      buf.writeln('\n--- JIOSAVAN TEST ---');
      final saavnSongs = await _jiosavanSearch('arijit singh', limit: 3);
      buf.writeln('Jiosavan results: ${saavnSongs.length}');
      if (saavnSongs.isNotEmpty) {
        buf.writeln('First: ${saavnSongs.first.title}');
        buf.writeln('Stream cached: ${_Cache.getStream(saavnSongs.first.id) != null}');
      }

      buf.writeln('\n--- INVIDIOUS HEALTH ---');
      for (final inst in _invidiousInstances) {
        final h = _invHealth[inst];
        buf.writeln('$inst → score: ${h?.score.toStringAsFixed(2) ?? "1.00"}');
      }

      buf.writeln('\n--- FAILURE LOG ---');
      for (final entry in FailureAnalytics.recentLog.take(15)) {
        buf.writeln(entry.toString());
      }
    } catch (e, st) {
      buf.writeln('EXCEPTION: $e');
      buf.writeln(st.toString().split('\n').take(5).join('\n'));
    }
    return buf.toString();
  }
}
