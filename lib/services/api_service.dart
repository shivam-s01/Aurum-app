
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io' show HttpClient;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:html/parser.dart' as html_parser;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:async/async.dart';
import 'package:just_audio/just_audio.dart';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../models/artist.dart';
import '../models/lyrics.dart';
import 'browse_service.dart' show BrowseAlbum, BrowseArtist;
import '../utils/constants.dart';
import 'audio_prefs.dart';
import 'recommendation_engine.dart';
import 'music_source.dart';
import 'lightweight_stream_cache.dart';
import 'lyrics_cache.dart';
import 'diagnostic_log_service.dart';

class RealPlaybackResult {
  final bool success;
  final int positionMs;
  final String processingState;
  final String? errorMessage;

  const RealPlaybackResult({
    required this.success,
    required this.positionMs,
    required this.processingState,
    this.errorMessage,
  });
}

const List<String> _kPipedInstances = [
  'https://pipedapi.kavin.rocks',
  'https://piped-api.privacy.com.de',
  'https://api.piped.projectsegfau.lt',
];

const List<String> _kInvidiousInstances = [
  'https://invidious.io.lol',
  'https://inv.nadeko.net',
  'https://invidious.privacydev.net',
];

class _InstanceHealth {
  static final Map<String, DateTime> _deadUntil = {};
  static const Duration _cooldown = Duration(minutes: 5);

  static bool isAlive(String instance) {
    final dead = _deadUntil[instance];
    if (dead == null) return true;
    if (DateTime.now().isAfter(dead)) {
      _deadUntil.remove(instance);
      return true;
    }
    return false;
  }

  static void markDead(String instance) {
    _deadUntil[instance] = DateTime.now().add(_cooldown);
  }

  static void markAlive(String instance) {
    _deadUntil.remove(instance);
  }
}

class _WorkerHealth {
  static DateTime? _deadUntil;
  static int _consecutiveFailures = 0;

  static const List<Duration> _backoffSteps = [
    Duration(seconds: 8),
    Duration(seconds: 20),
    Duration(seconds: 45),
    Duration(seconds: 90),
    Duration(minutes: 2),
  ];

  static bool maintenanceMode = false;

  static bool get isAlive {
    if (maintenanceMode) return false;
    final dead = _deadUntil;
    if (dead == null) return true;
    if (DateTime.now().isAfter(dead)) {
      _deadUntil = null;
      return true;
    }
    return false;
  }

  static void markDead() {
    final stepIndex = _consecutiveFailures.clamp(0, _backoffSteps.length - 1);
    _deadUntil = DateTime.now().add(_backoffSteps[stepIndex]);
    _consecutiveFailures++;
  }

  static void markAlive() {
    _deadUntil = null;
    _consecutiveFailures = 0;
  }
}

class _YtSearchHealth {
  static DateTime? _skipUntil;
  static bool get isLikelyDown {
    final until = _skipUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) { _skipUntil = null; return false; }
    return true;
  }
  static void markFailure() {
    _skipUntil = DateTime.now().add(const Duration(seconds: 20));
  }
  static void markSuccess() { _skipUntil = null; }
}

enum YtPlaylistImportError {

  invalidLink,

  isMix,

  empty,

  notFound,

  network,
}

class YtPlaylistImportException implements Exception {
  final YtPlaylistImportError reason;
  const YtPlaylistImportException(this.reason);
  @override
  String toString() => 'YtPlaylistImportException($reason)';
}

class _MoodSubQuery {
  final String id;
  final String title;
  final String query;
  const _MoodSubQuery(this.id, this.title, this.query);
}

class _RealPlaylistCandidate {
  final String id;
  final String title;
  final String author;
  final String artworkUrl;
  const _RealPlaylistCandidate({
    required this.id,
    required this.title,
    required this.author,
    required this.artworkUrl,
  });
}

class SearchPlaylistResult {
  final String id;
  final String title;
  final String author;
  final String artworkUrl;
  const SearchPlaylistResult({
    required this.id,
    required this.title,
    required this.author,
    required this.artworkUrl,
  });
}

class YtHomePlaylistCard {
  final String id;
  final String title;
  final String subtitle;
  final String artworkUrl;
  final List<Song> songs;
  const YtHomePlaylistCard({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    required this.songs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'artworkUrl': artworkUrl,
        'songs': songs.map((s) => s.toJson()).toList(),
      };

  factory YtHomePlaylistCard.fromJson(Map<String, dynamic> json) =>
      YtHomePlaylistCard(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        subtitle: json['subtitle'] as String? ?? '',
        artworkUrl: json['artworkUrl'] as String? ?? '',
        songs: ((json['songs'] as List?) ?? [])
            .whereType<Map>()
            .map((s) => Song.fromJson(Map<String, dynamic>.from(s)))
            .toList(),
      );
}

class HomeAlbumCard {
  final String albumId;
  final String title;
  final String artist;
  final String artworkUrl;
  const HomeAlbumCard({
    required this.albumId,
    required this.title,
    required this.artist,
    required this.artworkUrl,
  });

  Map<String, dynamic> toJson() => {
        'albumId': albumId,
        'title': title,
        'artist': artist,
        'artworkUrl': artworkUrl,
      };

  factory HomeAlbumCard.fromJson(Map<String, dynamic> json) => HomeAlbumCard(
        albumId: json['albumId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        artworkUrl: json['artworkUrl'] as String? ?? '',
      );
}

class HomeShelfItem {
  final String browseId;
  final String title;
  final String subtitle;
  final String artworkUrl;
  final bool isAlbum;

  final bool isRadioMix;
  const HomeShelfItem({
    required this.browseId,
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    required this.isAlbum,
    this.isRadioMix = false,
  });

  Map<String, dynamic> toJson() => {
        'browseId': browseId,
        'title': title,
        'subtitle': subtitle,
        'artworkUrl': artworkUrl,
        'isAlbum': isAlbum,
        'isRadioMix': isRadioMix,
      };

  factory HomeShelfItem.fromJson(Map<String, dynamic> json) => HomeShelfItem(
        browseId: (json['browseId'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        subtitle: (json['subtitle'] ?? '').toString(),
        artworkUrl: (json['artworkUrl'] ?? '').toString(),
        isAlbum: json['isAlbum'] == true,
        isRadioMix: json['isRadioMix'] == true,
      );
}

class HomeShelf {
  final String title;
  final List<HomeShelfItem> items;

  final String? strapline;

  final bool isList;

  final List<Song> songs;
  const HomeShelf({
    required this.title,
    required this.items,
    this.strapline,
    this.isList = false,
    this.songs = const [],
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'items': items.map((i) => i.toJson()).toList(),
        'strapline': strapline,
        'isList': isList,
        'songs': songs.map((s) => s.toJson()).toList(),
      };

  factory HomeShelf.fromJson(Map<String, dynamic> json) => HomeShelf(
        title: (json['title'] ?? '').toString(),
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((i) => HomeShelfItem.fromJson(Map<String, dynamic>.from(i)))
            .toList(),
        strapline: json['strapline']?.toString(),
        isList: json['isList'] == true,
        songs: ((json['songs'] as List?) ?? const [])
            .whereType<Map>()
            .map((s) => Song.fromJson(Map<String, dynamic>.from(s)))
            .toList(),
      );
}

class MoodGenreCategory {
  final String browseId;
  final String params;
  final String title;
  final int? color;

  final String? artworkUrl;
  const MoodGenreCategory({
    required this.browseId,
    required this.params,
    required this.title,
    this.color,
    this.artworkUrl,
  });

  MoodGenreCategory copyWithArtwork(String? artworkUrl) => MoodGenreCategory(
        browseId: browseId,
        params: params,
        title: title,
        color: color,
        artworkUrl: artworkUrl,
      );

  Map<String, dynamic> toJson() => {
        'browseId': browseId,
        'params': params,
        'title': title,
        if (color != null) 'color': color,
        if (artworkUrl != null && artworkUrl!.isNotEmpty)
          'artworkUrl': artworkUrl,
      };

  factory MoodGenreCategory.fromJson(Map<String, dynamic> json) =>
      MoodGenreCategory(
        browseId: (json['browseId'] ?? '').toString(),
        params: (json['params'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        color: json['color'] as int?,
        artworkUrl: json['artworkUrl'] as String?,
      );
}

class MoodGenreSection {
  final String title;
  final List<MoodGenreCategory> items;
  const MoodGenreSection({required this.title, required this.items});

  Map<String, dynamic> toJson() => {
        'title': title,
        'items': items.map((e) => e.toJson()).toList(),
      };

  factory MoodGenreSection.fromJson(Map<String, dynamic> json) =>
      MoodGenreSection(
        title: (json['title'] ?? '').toString(),
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MoodGenreCategory.fromJson)
            .toList(),
      );
}

class MoodGenreCacheStore {
  static const _key = 'mood_genre_sections_cache_v1';
  static const _timeKey = 'mood_genre_sections_cache_time_v1';
  static const _freshWindow = Duration(hours: 6);

  static Future<void> save(List<MoodGenreSection> sections) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          jsonEncode(sections.map((s) => s.toJson()).toList());
      await prefs.setString(_key, encoded);
      await prefs.setInt(
          _timeKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {

    }
  }

  static Future<List<MoodGenreSection>?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as List;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(MoodGenreSection.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isFresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedAt = prefs.getInt(_timeKey);
      if (savedAt == null) return false;
      final age = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(savedAt));
      return age < _freshWindow;
    } catch (_) {
      return false;
    }
  }
}

class HomeMoodChip {
  final String id;
  final String label;
  const HomeMoodChip(this.id, this.label);
}

const List<HomeMoodChip> kHomeMoodChips = [

  HomeMoodChip('bollywood', 'Bollywood'),
  HomeMoodChip('nineties', '90s'),
  HomeMoodChip('trendingIndia', 'Trending'),
  HomeMoodChip('podcasts', 'Podcasts'),
  HomeMoodChip('relax', 'Relax'),
  HomeMoodChip('workout', 'Workout'),
  HomeMoodChip('energize', 'Energize'),
  HomeMoodChip('romantic', 'Romantic'),
  HomeMoodChip('party', 'Party'),
  HomeMoodChip('focus', 'Focus'),
  HomeMoodChip('sad', 'Sad'),
];

class HomePlaylistHistory {
  static const _keyPrefix = 'home_playlists_for_you_shown_song_ids';
  static const _cap = 60;

  static String _keyFor(String? mood) =>
      '$_keyPrefix${(mood == null || mood.isEmpty) ? '' : '_$mood'}';

  static Future<List<String>> getShownIds(String? mood) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_keyFor(mood)) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> recordShown(String? mood, List<String> songIds) async {
    if (songIds.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _keyFor(mood);
      final existing = prefs.getStringList(key) ?? const [];
      final merged = <String>[];
      final seen = <String>{};
      for (final id in [...songIds, ...existing]) {
        if (seen.contains(id)) continue;
        seen.add(id);
        merged.add(id);
        if (merged.length >= _cap) break;
      }
      await prefs.setStringList(key, merged);
    } catch (_) {

    }
  }
}

class YtHomeArtist {
  final String channelId;
  final String name;
  final String imageUrl;
  const YtHomeArtist({
    required this.channelId,
    required this.name,
    required this.imageUrl,
  });
}

class ApiService {

  static String lastArtistFetchDebug = '(not run yet)';

  static set workerMaintenanceMode(bool value) {
    _WorkerHealth.maintenanceMode = value;
  }
  static bool get workerMaintenanceMode => _WorkerHealth.maintenanceMode;

  static final http.Client _client = IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 3)
      ..maxConnectionsPerHost = 6,
  );

  static http.Client get httpClient => _client;
  static final YoutubeExplode _yt     = YoutubeExplode();

  static const bool _saavnDisabled = true;

  static const List<String> _saavnNodeHosts = [
    'https://jiosaavn-op-c4oo.onrender.com',

  ];

  static const List<String> _saavnFlaskHosts = [
    'https://jiosavan-ecc1.onrender.com',
    'https://jiosavan-three.vercel.app',
  ];

  static const List<String> _saavnNoPaginationFlaskHosts = [
    'https://jiosaavnapi-il2o.onrender.com',
  ];

  static Future<Map<String, dynamic>?> _getFromHosts(
    List<String> hosts,
    String pathAndQuery, {
    Duration timeout = const Duration(seconds: 8),
    bool Function(Map<String, dynamic> body)? isValid,
  }) async {
    for (final host in hosts) {
      try {
        final res = await _client
            .get(Uri.parse('$host$pathAndQuery'))
            .timeout(timeout);
        if (res.statusCode != 200) continue;
        final body = jsonDecode(res.body);
        if (body is! Map<String, dynamic>) continue;
        if (isValid != null && !isValid(body)) continue;
        return body;
      } catch (e) {
        _log('[_getFromHosts] $host failed: $e');
        continue;
      }
    }
    return null;
  }

  static const String _saavnPrimary   = 'https://jiosavan-ecc1.onrender.com';
  static const String _saavnSecondary = 'https://jiosavan-three.vercel.app';

  static const String _saavn          = 'https://aurum-worker.shivamsharma962122.workers.dev';
  static const String _worker         = AppConstants.apiBase;

  static final LightweightStreamCache _streamCache = LightweightStreamCache();
  static const Duration _streamTtl   = Duration(minutes: 50);
  static const int      _maxCacheSize = 30;

  static final Map<String, _CachedSearch> _searchCache = {};
  static const Duration _searchTtl     = Duration(minutes: 5);
  static const int      _maxSearchCache = 100;

  static final Map<String, _CachedQuickSearch> _quickSearchCache = {};
  static const Duration _quickSearchTtl      = Duration(seconds: 45);
  static const int      _maxQuickSearchCache = 60;

  static void _writeQuickSearchCache(String key, List<Song> results) {
    if (_quickSearchCache.length >= _maxQuickSearchCache) {
      final expiredKeys = _quickSearchCache.entries
          .where((e) => e.value.isExpired).map((e) => e.key).toList();
      for (final k in expiredKeys) _quickSearchCache.remove(k);
      if (_quickSearchCache.length >= _maxQuickSearchCache) {
        final oldest = _quickSearchCache.entries.reduce(
          (a, b) => a.value.cachedAt.isBefore(b.value.cachedAt) ? a : b,
        );
        _quickSearchCache.remove(oldest.key);
      }
    }
    _quickSearchCache[key] = _CachedQuickSearch(results);
  }

  static final Map<String, List<String>> _selectionHistory = {};
  static bool _selectionHistoryLoaded = false;
  static const String _selectionPrefsKey = 'aurum_search_selection_learning';
  static const int _maxSelectionQueries = 200;
  static const int _maxSongsPerQuery = 3;

  static Future<void>? _selectionHistoryLoadFuture;
  static Future<void> _ensureSelectionHistoryLoaded() {

    if (_selectionHistoryLoaded) return Future.value();
    return _selectionHistoryLoadFuture ??= () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_selectionPrefsKey);
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((key, value) {

              if (_selectionHistory.containsKey(key)) return;
              if (key is String && value is List) {
                _selectionHistory[key] = value.whereType<String>().toList();
              }
            });
          }
        }
      } catch (e) {
        _log('[selectionHistory] load failed: $e');
      } finally {
        _selectionHistoryLoaded = true;
      }
    }();
  }

  static Timer? _selectionPersistDebounce;
  static void _persistSelectionHistorySoon() {

    _selectionPersistDebounce?.cancel();
    _selectionPersistDebounce = Timer(const Duration(seconds: 2), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_selectionPrefsKey, jsonEncode(_selectionHistory));
      } catch (e) {
        _log('[selectionHistory] persist failed: $e');
      }
    });
  }

  static void recordSearchSelection(String query, Song song) {
    final key = _normalise(query);

    if (key.length < 3) return;
    () async {
      await _ensureSelectionHistoryLoaded();
      final list = _selectionHistory.putIfAbsent(key, () => <String>[]);
      list.remove(song.id);
      list.insert(0, song.id);
      if (list.length > _maxSongsPerQuery) list.removeRange(_maxSongsPerQuery, list.length);

      _selectionHistory.remove(key);
      _selectionHistory[key] = list;
      if (_selectionHistory.length > _maxSelectionQueries) {
        _selectionHistory.remove(_selectionHistory.keys.first);
      }
      _persistSelectionHistorySoon();
    }();
  }

  static double _selectionHistoryBoost(String query, String songId) {
    if (!_selectionHistoryLoaded || _selectionHistory.isEmpty) return 0;
    final key = _normalise(query);
    final exact = _selectionHistory[key];
    if (exact != null) {
      final idx = exact.indexOf(songId);
      if (idx == 0) return 45;
      if (idx > 0)  return 25;
    }

    if (key.length >= 4) {
      for (final entry in _selectionHistory.entries) {
        if (entry.key == key) continue;
        if (entry.key.length < 4) continue;
        final shorter = key.length < entry.key.length ? key : entry.key;
        final longer  = key.length < entry.key.length ? entry.key : key;
        if (!longer.startsWith(shorter)) continue;
        if (shorter.length / longer.length < 0.7) continue;
        if (entry.value.isNotEmpty && entry.value.first == songId) return 15;
      }
    }
    return 0;
  }

  static final Map<String, Future<String?>> _pendingResolutions = {};
  static CancelableOperation<void>? _activePrefetch;

  static final List<CancelableOperation<void>> _prefetchQueue = [];

  static bool _explodeWarmedUp = false;

  static const bool _kDebugLogging =
      bool.fromEnvironment('AURUM_DEBUG', defaultValue: false);

  static void _log(String message) {
    if (kDebugMode || _kDebugLogging) dev.log(message, name: 'ApiService');
  }

  static void dispose() {
    _yt.close();
    _client.close();
    _streamCache.clear();
    _pendingResolutions.clear();
    _searchCache.clear();
    _quickSearchCache.clear();
    LyricsCache.clear();
    _activePrefetch?.cancel();
    _activePrefetch = null;
    _selectionPersistDebounce?.cancel();
  }

  static void wakeSaavn() {

    _client
        .get(Uri.parse('$_saavnPrimary/result/?query=hello&limit=1'))
        .timeout(const Duration(seconds: 30))
        .then((_) => _log('[wakeSaavn] onrender warm ✓'))
        .catchError((e) => _log('[wakeSaavn] onrender ping failed: $e'));

    _client
        .get(Uri.parse('$_saavnSecondary/result/?query=hello&limit=1'))
        .timeout(const Duration(seconds: 15))
        .then((_) => _log('[wakeSaavn] Vercel warm ✓'))
        .catchError((e) => _log('[wakeSaavn] Vercel ping failed: $e'));

    _client
        .get(Uri.parse('$_saavn/result/?query=hello&limit=1'))
        .timeout(const Duration(seconds: 15))
        .then((_) => _log('[wakeSaavn] CF worker warm ✓'))
        .catchError((e) => _log('[wakeSaavn] CF worker ping failed: $e'));

    if (!_explodeWarmedUp) {
      _explodeWarmedUp = true;
      Future.microtask(() async {
        try {

          await _yt.videos.get('JGwWNGJdvx8')
              .timeout(const Duration(seconds: 8));
          _log('[warmup] youtube_explode_dart warmed up ✓');
        } catch (_) {

          _explodeWarmedUp = false;
        }
      });
    }
  }

  static final List<_PoolEntry> _pool = [

    _PoolEntry('arijit singh best bollywood songs',           'Arijit Singh'),
    _PoolEntry('atif aslam best hindi songs',                 'Atif Aslam'),
    _PoolEntry('jubin nautiyal romantic songs',                'Jubin Nautiyal'),
    _PoolEntry('shreya ghoshal bollywood hits',                'Shreya Ghoshal'),
    _PoolEntry('armaan malik songs playlist',                  'Armaan Malik'),
    _PoolEntry('sonu nigam bollywood hit songs',                'Sonu Nigam'),
    _PoolEntry('kk hindi songs playlist',                       'KK'),
    _PoolEntry('kishore kumar hindi classics',                  'Kishore Kumar'),
    _PoolEntry('lata mangeshkar timeless songs',                'Lata Mangeshkar'),
    _PoolEntry('mohammed rafi golden hits',                     'Mohammed Rafi'),
    _PoolEntry('a.r. rahman best songs',                        'A.R. Rahman'),
    _PoolEntry('rd burman classic bollywood songs',             'R.D. Burman Classics'),

    _PoolEntry('trending hindi songs this week',                'Trending Now'),
    _PoolEntry('new hindi songs 2026 latest',                    'New Releases'),
    _PoolEntry('viral hindi songs reels',                        'Viral Hits'),
    _PoolEntry('trending songs india',                           'Trending in India'),
    _PoolEntry('new music hindi bollywood',                      'New Music'),
    _PoolEntry('top charts bollywood songs',                     'Top Charts'),
    _PoolEntry('hidden gems bollywood underrated songs',         'Discovery'),

    _PoolEntry('new bollywood movie album songs 2025 2026',      'Top Albums'),
    _PoolEntry('best bollywood hit songs playlist',              'Fan Favorites'),

    _PoolEntry('90s bollywood superhits original',              '90s Bollywood'),
    _PoolEntry('2000s bollywood original songs',                '2000s Bollywood'),
    _PoolEntry('2010s bollywood hit songs',                     '2010s Bollywood'),
    _PoolEntry('2020s bollywood hit songs',                     '2020s Hits'),
    _PoolEntry('old is gold hindi songs kishore kumar lata',     'Old Is Gold'),
    _PoolEntry('retro bollywood hindi classics',                 'Retro'),

    _PoolEntry('romantic bollywood songs hindi',                 'Romance'),
    _PoolEntry('sad hindi songs heartbreak',                     'Sad Songs'),
    _PoolEntry('lofi chill hindi songs',                         'Chill'),
    _PoolEntry('bollywood party songs dance',                    'Party'),
    _PoolEntry('workout gym hindi motivation songs',              'Workout'),
    _PoolEntry('bhakti bhajan aarti original songs',              'Devotional'),
    _PoolEntry('sufi qawwali hindi songs original',              'Sufi'),
    _PoolEntry('ghazal jagjit singh mehdi hassan',               'Ghazals'),
    _PoolEntry('feel good happy bollywood songs',                'Feel Good'),
    _PoolEntry('late night hindi songs drive',                   'Late Night'),
    _PoolEntry('road trip hindi songs playlist',                  'Road Trip'),

    _PoolEntry('bollywood hits songs',                            'Bollywood'),
    _PoolEntry('punjabi hits songs',                              'Punjabi'),
    _PoolEntry('indie india hindi songs',                         'Indie India'),
    _PoolEntry('hindi pop songs playlist',                        'Hindi Pop'),
    _PoolEntry('tamil hits songs',                                'Tamil'),
    _PoolEntry('telugu hits songs',                               'Telugu'),
    _PoolEntry('marathi hit songs',                               'Marathi'),
    _PoolEntry('bengali hit songs',                               'Bengali'),
    _PoolEntry('bhojpuri hit songs',                              'Bhojpuri'),
    _PoolEntry('gujarati hit songs',                              'Gujarati'),
    _PoolEntry('malayalam hit songs',                             'Malayalam'),
    _PoolEntry('kannada hit songs',                               'Kannada'),
  ];

  static const Set<String> _mainstreamArtists = {
    'arijit singh', 'atif aslam', 'jubin nautiyal', 'shreya ghoshal',
    'armaan malik', 'sonu nigam', 'kk', 'kishore kumar', 'lata mangeshkar',
    'mohammed rafi', 'asha bhosle', 'udit narayan', 'alka yagnik',
    'sunidhi chauhan', 'shaan', 'mohit chauhan', 'rahat fateh ali khan',
    'neha kakkar', 'darshan raval', 'vishal mishra', 'sachet tandon',
    'yasser desai', 'stebin ben', 'javed ali', 'kumar sanu', 'anuradha paudwal',
    'a.r. rahman', 'ar rahman', 'pritam', 'vishal-shekhar', 'amit trivedi',
  };

  static const Set<String> _homeEligibleGenres = {
    'bollywood', 'devotional', 'lofi', 'punjabi', 'bhojpuri', 'tamil',
    'telugu', 'english', 'hiphop',
  };

  static const Set<String> _homeEligibleLanguages = {
    'hindi', 'punjabi', 'english', 'tamil', 'telugu', 'bengali',
    'marathi', 'gujarati', 'malayalam', 'bhojpuri',
  };

  static const Map<String, String> _languageQueryMap = {
    'punjabi':   'punjabi hits songs',
    'english':   'english pop hits songs',
    'tamil':     'tamil hits songs',
    'telugu':    'telugu hits songs',
    'bengali':   'bengali hit songs',
    'marathi':   'marathi hit songs',
    'gujarati':  'gujarati hit songs',
    'malayalam': 'malayalam hit songs',
    'bhojpuri':  'bhojpuri hit songs',
    'hindi':     'bollywood hits songs',
  };

  static const Map<String, String> _languageLabelMap = {
    'punjabi':   'Punjabi',
    'english':   'English',
    'tamil':     'Tamil',
    'telugu':    'Telugu',
    'bengali':   'Bengali',
    'marathi':   'Marathi',
    'gujarati':  'Gujarati',
    'malayalam': 'Malayalam',
    'bhojpuri':  'Bhojpuri',
    'hindi':     'Hindi',
  };

  static List<String> _filterMainstream(List<String> artists) => artists
      .where((a) => _mainstreamArtists.contains(a.toLowerCase().trim()))
      .toList();

  static List<String> _filterHomeGenres(List<String> genres) =>
      genres.where((g) => _homeEligibleGenres.contains(g.toLowerCase().trim())).toList();

  static Future<List<SongSection>> fetchHome({List<String> topArtists = const [], List<Song> recentlyPlayed = const []}) async {
    await RecommendationEngine.load();
    final now = DateTime.now();
    final hourSeed = now.difference(DateTime(2026, 1, 1)).inHours;
    final refreshSalt = math.Random().nextInt(1000000);
    final rng = math.Random(hourSeed ^ refreshSalt);
    final shuffledPool = List<_PoolEntry>.from(_pool)..shuffle(rng);

    final affinityArtists = _filterMainstream(
      RecommendationEngine.rotatingAffinityArtists(count: 4, seed: refreshSalt),
    );
    final personalArtists = affinityArtists.isNotEmpty ? affinityArtists : _filterMainstream(topArtists);
    final topGenres = _filterHomeGenres(
      RecommendationEngine.rotatingAffinityGenres(count: 3, seed: refreshSalt ^ 0x9E3779B9),
    );

    final topLanguages = RecommendationEngine.topAffinityLanguages(count: 2)
        .where((l) => _homeEligibleLanguages.contains(l))
        .toList();

    final slot = RecommendationEngine.currentTimeSlot();
    final timeMoodQuery = _timeMoodQuery(slot);
    final timeMoodLabel = _timeMoodLabel(slot);

    final queryList = <_SectionQuery>[];
    queryList.add(_SectionQuery(timeMoodQuery, timeMoodLabel, priority: true));
    for (final artist in personalArtists.take(4)) {
      queryList.add(_SectionQuery('$artist best songs', 'Made for You · $artist', priority: true));
    }
    for (final genre in topGenres) {
      queryList.add(_SectionQuery(_genreMixQuery(genre), _genreMixLabel(genre), priority: true));
    }
    for (final lang in topLanguages) {
      final q = _languageQueryMap[lang];
      final lbl = _languageLabelMap[lang];
      if (q == null || lbl == null) continue;
      if (queryList.any((sq) => sq.label == lbl)) continue;
      queryList.add(_SectionQuery(q, lbl, priority: true));
    }

    final recentOnline = recentlyPlayed
        .where((s) => !s.isLocal && s.source == SongSource.saavn && s.id.isNotEmpty)
        .take(3)
        .toList();
    for (final recent in recentOnline) {
      final cleanId = recent.id.replaceFirst(RegExp(r'^[a-z]+_'), '');
      final lbl = 'Because You Played · ${recent.title.length > 22 ? recent.title.substring(0, 22) + "…" : recent.title}';
      if (!queryList.any((q) => q.label == lbl)) {
        queryList.add(_SectionQuery('__suggestions__$cleanId', lbl, isSuggestion: true, suggestionSongId: cleanId));
      }
    }

    final targetTotal = 7 + math.Random(refreshSalt ^ 0x51ED270B).nextInt(4);
    int poolPicks = 0;
    for (final entry in shuffledPool) {
      if (queryList.length >= targetTotal) break;
      if (queryList.any((q) => q.label == entry.label)) continue;
      queryList.add(_SectionQuery(entry.query, entry.label));
      poolPicks++;
    }
    if (personalArtists.isEmpty && topGenres.isEmpty && topLanguages.isEmpty && recentOnline.isEmpty) {
      for (final entry in shuffledPool.reversed) {
        if (queryList.length >= targetTotal) break;
        if (!queryList.any((q) => q.label == entry.label)) {
          queryList.add(_SectionQuery(entry.query, entry.label));
        }
      }
    }

    final results = <SongSection?>[];
    const batchSize = 3;
    for (int i = 0; i < queryList.length; i += batchSize) {
      final batch = queryList.skip(i).take(batchSize).toList();
      final batchResults = await Future.wait(
        batch.map((sq) => sq.isSuggestion
            ? _suggestionSection(sq.suggestionSongId!, sq.label)

            : _fetchSaavnSection(
                sq.query,
                sq.label,
                variants: <String>{
                  sq.query,
                  '${sq.query} audio',
                  '${sq.query} official',
                  '${sq.query} hd',
                  '${sq.query} hits',
                },
                includeDeepPage: true,
                target: _kHomeSectionTarget,
              )),
      );
      results.addAll(batchResults);
      if (i + batchSize < queryList.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    final globalSeenIds = <String>{};
    final seen = <String>{};
    final sections = <SongSection>[];
    for (final s in results.whereType<SongSection>()) {
      if (!seen.add(s.title)) continue;
      final uniqueSongs = s.songs.where((song) => globalSeenIds.add(song.id)).toList();
      if (uniqueSongs.isNotEmpty) {
        sections.add(SongSection(title: s.title, songs: uniqueSongs));
      }
    }
    return sections;
  }

  static Future<List<Song>> _searchSaavnDeep(String query, {int limit = 80}) async {

    final startPage = 1 + math.Random().nextInt(4);
    final pages = List.generate(3, (i) => startPage + i);
    final futures = pages.map((p) => _fetchSaavnPage(
          '$_saavnPrimary/result/?query=${Uri.encodeQueryComponent(query)}&limit=$limit&page=$p',
          limit,
        ).catchError((_) => <Song>[]));
    final results = await Future.wait(futures);
    final anyResults = results.any((r) => r.isNotEmpty);
    if (!anyResults) return _searchSaavn(query, limit: limit);
    final seen = <String>{};
    final merged = <Song>[];
    for (final page in results) {
      for (final s in page) {
        if (seen.add(s.id)) merged.add(s);
      }
    }
    return merged;
  }

  static const int _kHomeSectionTarget = 100;

  static const int _kFastFirstTarget = 28;

  static Future<SongSection?> _saavnSectionV4(String query, String label) async {
    final fast = await _fetchSaavnSection(
      query,
      label,
      variants: <String>{query, '$query audio'},
      includeDeepPage: false,
      target: _kFastFirstTarget,
    );
    return fast;
  }

  static void _topUpSectionInBackground(
    String query,
    String label,
    void Function(SongSection section) onTopUp,
  ) {
    unawaited(_fetchSaavnSection(
      query,
      label,
      variants: <String>{query, '$query audio', '$query official', '$query hd', '$query hits'},
      includeDeepPage: true,
      target: _kHomeSectionTarget,
    ).then((full) {
      if (full != null && full.songs.length > _kFastFirstTarget) {
        onTopUp(full);
      }
    }).catchError((_) {}));
  }

  static Future<SongSection?> _fetchSaavnSection(
    String query,
    String label, {
    required Set<String> variants,
    required bool includeDeepPage,
    required int target,
  }) async {

    final variantResults = await Future.wait(
      variants.map((q) => _searchYt(q, limit: 60)),
    );

    List<Song> deepSongs = const [];
    if (includeDeepPage) {
      final deepVideos = await _searchYtPaged(query, 100).catchError((_) => <Video>[]);
      deepSongs = deepVideos.map(_songFromYtVideo).toList();
    }

    final rawYt = <Song>[];
    final seenRawIds = <String>{};
    for (final list in [...variantResults, deepSongs]) {
      for (final s in list) {
        if (s.id.isNotEmpty && seenRawIds.add(s.id)) rawYt.add(s);
      }
    }
    if (rawYt.isEmpty) return null;

    final seenIds    = <String>{};
    final seenTitles = <String>{};

    final seenRawTitles = <String>[];
    final merged = <Song>[];

    bool tryAdd(Song s) {
      if (merged.length >= target) return false;
      if (!seenIds.add(s.id)) return false;
      if (RecommendationEngine.isInherentVariant(s.title)) return false;
      if (RecommendationEngine.isLowQualityUpload(s.title)) return false;
      if (!RecommendationEngine.isPremiumQuality(s)) return false;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) return false;
      for (final seenRaw in seenRawTitles) {
        if (RecommendationEngine.isSameSongSmart(s.title, seenRaw)) return false;
      }
      seenRawTitles.add(s.title);
      merged.add(s);
      return true;
    }

    for (final s in rawYt) {
      if (merged.length >= target) break;
      tryAdd(s);
    }

    if (merged.isEmpty) return null;
    return SongSection(title: label, songs: merged.take(target).toList());
  }

  static Future<SongSection?> _suggestionSection(String songId, String label) async {
    return null;
  }

  static Future<void> fetchHomeStreaming({
    List<String> topArtists = const [],
    List<String> topArtistsRotating = const [],
    List<Song> recentlyPlayed = const [],
    bool fastFirstSection = false,
    required void Function(SongSection section) onSection,
  }) async {
    await RecommendationEngine.load();

    if (fastFirstSection) {
      unawaited(_searchYt('trending songs 2026', limit: 30).then((songs) {
        if (songs.isEmpty) return;
        final quick = songs
            .where((s) => RecommendationEngine.isPremiumQuality(s))
            .take(20)
            .toList();
        if (quick.isNotEmpty) {
          onSection(SongSection(title: 'Trending Now', songs: quick));
        }
      }).catchError((_) {}));
    }
    final now = DateTime.now();
    final hourSeed = now.difference(DateTime(2026, 1, 1)).inHours;
    final refreshSalt = math.Random().nextInt(1000000);
    final rng = math.Random(hourSeed ^ refreshSalt);
    final shuffledPool = List<_PoolEntry>.from(_pool)..shuffle(rng);

    final affinityArtists = _filterMainstream(
      RecommendationEngine.rotatingAffinityArtists(count: 4, seed: refreshSalt),
    );

    final personalArtists = affinityArtists.isNotEmpty
        ? affinityArtists
        : _filterMainstream(
            topArtistsRotating.isNotEmpty ? topArtistsRotating : topArtists,
          );
    final topGenres = _filterHomeGenres(
      RecommendationEngine.rotatingAffinityGenres(count: 3, seed: refreshSalt ^ 0x9E3779B9),
    );

    final slot = RecommendationEngine.currentTimeSlot();
    final timeMoodQuery = _timeMoodQuery(slot);
    final timeMoodLabel = _timeMoodLabel(slot);

    const int _kMaxHomeSections = 12;
    final queryList = <_SectionQuery>[];
    queryList.add(_SectionQuery(timeMoodQuery, timeMoodLabel, priority: true));
    for (final artist in personalArtists.take(2)) {
      queryList.add(_SectionQuery('$artist best songs', 'Made for You · $artist', priority: true));
    }
    for (final genre in topGenres.take(1)) {
      queryList.add(_SectionQuery(_genreMixQuery(genre), _genreMixLabel(genre), priority: true));
    }

    const englishQueries = [
      ('top english songs 2026', 'Top English Hits'),
    ];
    for (final (q, label) in englishQueries) {
      queryList.add(_SectionQuery(q, label, isEnglish: true));
    }
    final recentOnline = recentlyPlayed
        .where((s) => !s.isLocal && s.source == SongSource.saavn && s.id.isNotEmpty)
        .take(1)
        .toList();
    for (final recent in recentOnline) {
      final cleanId = recent.id.replaceFirst(RegExp(r'^[a-z]+_'), '');
      final lbl = 'Because You Played · ${recent.title.length > 22 ? recent.title.substring(0, 22) + "…" : recent.title}';
      if (!queryList.any((q) => q.label == lbl)) {
        queryList.add(_SectionQuery('__suggestions__$cleanId', lbl, isSuggestion: true, suggestionSongId: cleanId));
      }
    }

    int poolPicks = 0;

    for (final entry in shuffledPool) {
      if (queryList.length >= _kMaxHomeSections) break;
      if (poolPicks >= 6) break;
      if (queryList.any((q) => q.label == entry.label)) continue;
      queryList.add(_SectionQuery(entry.query, entry.label));
      poolPicks++;
    }

    if (personalArtists.isEmpty && topGenres.isEmpty && recentOnline.isEmpty) {

      const coldStartLabels = [
        'Trending Now',
        'New Releases',
        'Top Charts',
      ];
      for (final label in coldStartLabels.reversed) {
        if (queryList.length >= _kMaxHomeSections) break;
        final entry = _pool.firstWhere(
          (e) => e.label == label,
          orElse: () => _PoolEntry('', ''),
        );
        if (entry.label.isEmpty) continue;
        final existingIndex = queryList.indexWhere((q) => q.label == entry.label);
        if (existingIndex != -1) {

          if (!queryList[existingIndex].priority) {
            queryList[existingIndex] = _SectionQuery(entry.query, entry.label, priority: true);
          }
          continue;
        }

        queryList.insert(1, _SectionQuery(entry.query, entry.label, priority: true));
      }
    }

    final _trimmedQueryList = queryList.length > _kMaxHomeSections
        ? queryList.take(_kMaxHomeSections).toList()
        : queryList;

    final globalSeenIds = <String>{};
    final seenTitles = <String>{};

    final sectionOwnIds = <String, Set<String>>{};

    Future<void> runQuery(_SectionQuery sq) {
      final future = sq.isSuggestion
          ? _suggestionSection(sq.suggestionSongId!, sq.label)
          : sq.isEnglish
              ? _ytSectionV1(sq.query, sq.label)
              : _saavnSectionV4(sq.query, sq.label);
      return future.then((s) {
        if (s == null) return;
        if (!seenTitles.add(s.title)) return;
        final uniqueSongs = s.songs.where((song) => globalSeenIds.add(song.id)).toList();
        sectionOwnIds[s.title] = uniqueSongs.map((song) => song.id).toSet();
        if (uniqueSongs.isNotEmpty) {
          onSection(SongSection(title: s.title, songs: uniqueSongs));
        }

        if (!sq.isSuggestion && !sq.isEnglish) {
          _topUpSectionInBackground(sq.query, sq.label, (fullSection) {
            if (!seenTitles.contains(fullSection.title)) return;
            final myIds = sectionOwnIds[fullSection.title] ?? const <String>{};
            final uniqueFullSongs = fullSection.songs
                .where((song) => myIds.contains(song.id) || globalSeenIds.add(song.id))
                .toList();
            if (uniqueFullSongs.isEmpty) return;
            sectionOwnIds[fullSection.title] = uniqueFullSongs.map((song) => song.id).toSet();
            onSection(SongSection(
              title: fullSection.title,
              songs: uniqueFullSongs,
              id: fullSection.id,
            ));
          });
        }
      }).catchError((_) {

      });
    }

    final priorityQueries = _trimmedQueryList.where((q) => q.priority).toList();
    final restQueries = _trimmedQueryList.where((q) => q.priority == false).toList();

    const waveSize = 3;
    const waveGap = Duration(milliseconds: 200);
    final pending = <Future<void>>[];
    for (var i = 0; i < priorityQueries.length; i += waveSize) {
      if (i > 0) await Future.delayed(waveGap);
      final wave = priorityQueries.skip(i).take(waveSize);
      for (final sq in wave) {
        pending.add(runQuery(sq));
      }
    }

    for (var i = 0; i < restQueries.length; i += waveSize) {
      await Future.delayed(waveGap);
      final wave = restQueries.skip(i).take(waveSize);
      for (final sq in wave) {
        pending.add(runQuery(sq));
      }
    }

    await Future.wait(pending);

    await fetchSaavnChartsStreaming(onSection: onSection);
  }

  static const String _saavnInternalApi = 'https://www.jiosaavn.com/api.php';

  static const List<String> _saavnLanguages = [
    'hindi', 'punjabi', 'tamil', 'telugu', 'kannada',
    'malayalam', 'marathi', 'bengali', 'bhojpuri', 'gujarati',
    'english', 'rajasthani', 'odia', 'haryanvi', 'assamese',
  ];

  static const List<String> _saavnHomeDefaultLanguages = [
    'hindi', 'punjabi', 'tamil', 'telugu',
  ];

  static const Map<String, String> _languageLabels = {
    'hindi':      'Hindi Top 50',
    'punjabi':    'Punjabi Top 50',
    'tamil':      'Tamil Top 50',
    'telugu':     'Telugu Top 50',
    'kannada':    'Kannada Top 50',
    'malayalam':  'Malayalam Top 50',
    'marathi':    'Marathi Top 50',
    'bengali':    'Bengali Top 50',
    'bhojpuri':   'Bhojpuri Top 50',
    'gujarati':   'Gujarati Top 50',
    'english':    'English Top 50',
    'rajasthani': 'Rajasthani Hits',
    'odia':       'Odia Hits',
    'haryanvi':   'Haryanvi Hits',
    'assamese':   'Assamese Hits',
  };

  static Future<List<Map<String, dynamic>>> fetchSaavnFeaturedPlaylists({
    String language = 'hindi',
    int limit = 10,
  }) async {
    try {
      final url = Uri.parse(_saavnInternalApi).replace(queryParameters: {
        '__call': 'playlist.getFeaturedPlaylists',
        '_format': 'json',
        '_marker': 'false',
        'language': language,
        'offset': '0',
        'size': '$limit',
      });
      final res = await _client.get(url, headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final playlists = data is Map
          ? (data['featuredPlaylists'] ?? data['playlist'] ?? data['data'] ?? [])
          : (data is List ? data : []);
      if (playlists is! List) return [];
      return playlists.whereType<Map<String, dynamic>>().map((p) => {
        'id': (p['listid'] ?? p['id'] ?? '').toString(),
        'name': _cleanText((p['listname'] ?? p['name'] ?? p['title'] ?? '').toString()),
        'image': _cleanText((p['image'] ?? '').toString()),
        'songCount': int.tryParse((p['numsongs'] ?? p['song_count'] ?? p['songCount'] ?? '0').toString()) ?? 0,
        'language': language,
      }).where((p) => p['id']!.toString().isNotEmpty).toList();
    } catch (e) {
      _log('[fetchSaavnFeaturedPlaylists] $language error: $e');
      return [];
    }
  }

  static Future<List<Song>> fetchSaavnPlaylistById(String playlistId, {int limit = 50}) async {
    if (playlistId.isEmpty) return [];
    try {
      final path = '/api/playlists?id=${Uri.encodeQueryComponent(playlistId)}&limit=$limit';
      for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
        final body = await _getFromHosts(hosts, path,
            timeout: const Duration(seconds: 10),
            isValid: (b) => b['success'] == true && b['data'] != null);
        if (body == null) continue;
        final data = body['data'];
        if (data is! Map) continue;

        final rawSongs = (data['songs'] as List?) ??
            (data['list'] as List?) ??
            (data['data'] as List?) ?? [];
        if (rawSongs.isEmpty) continue;
        final songs = rawSongs
            .whereType<Map>()
            .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
            .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
            .toList();
        if (songs.isNotEmpty) return songs;
      }

      return await _fetchSaavnPlaylistInternal(playlistId, limit: limit);
    } catch (e) {
      _log('[fetchSaavnPlaylistById] $playlistId error: $e');
      return [];
    }
  }

  static Future<List<Song>> _fetchSaavnPlaylistInternal(String listId, {int limit = 50}) async {
    try {
      final url = Uri.parse(_saavnInternalApi).replace(queryParameters: {
        '__call': 'playlist.getDetails',
        '_format': 'json',
        '_marker': 'false',
        'listid': listId,
        'limit': '$limit',
      });
      final res = await _client.get(url, headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final rawSongs = (data is Map)
          ? ((data['list'] as List?) ?? (data['songs'] as List?) ?? [])
          : [];
      if (rawSongs is! List || rawSongs.isEmpty) return [];
      return rawSongs
          .whereType<Map>()
          .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
          .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
          .toList();
    } catch (e) {
      _log('[_fetchSaavnPlaylistInternal] $listId error: $e');
      return [];
    }
  }

  static Future<SongSection?> fetchSaavnLanguageSection(String language) async {
    final label = _languageLabels[language] ?? '$language Hits';
    try {

      return await _fetchSaavnSection(
        '$language top songs',
        label,
        variants: <String>{
          '$language top songs',
          '$language top songs audio',
          '$language top songs official',
          '$language top songs hd',
          '$language top songs hits',
        },
        includeDeepPage: true,
        target: _kHomeSectionTarget,
      );
    } catch (e) {
      _log('[fetchSaavnLanguageSection] $language error: $e');
      return null;
    }
  }

  static Future<void> fetchSaavnChartsStreaming({
    required void Function(SongSection section) onSection,
    List<String> languages = _saavnHomeDefaultLanguages,
  }) async {

    const waveSize = 3;
    const waveGap = Duration(milliseconds: 200);
    for (var i = 0; i < languages.length; i += waveSize) {
      if (i > 0) await Future.delayed(waveGap);
      final wave = languages.skip(i).take(waveSize);
      await Future.wait(wave.map((lang) async {
        try {
          final section = await fetchSaavnLanguageSection(lang)
              .timeout(const Duration(seconds: 12), onTimeout: () => null);
          if (section != null) onSection(section);
        } catch (_) {}
      }));
    }
  }

  static Future<List<Song>> fetchPlaylistSongs(String query, {int limit = 79}) async {
    final songs = await _searchSaavn(query, limit: limit);
    if (songs.isEmpty) return [];
    final seed = query.hashCode ^ DateTime.now().millisecondsSinceEpoch ^ math.Random().nextInt(1000000);
    final shuffled = List<Song>.from(songs)..shuffle(math.Random(seed));
    final seenIds = <String>{};
    final seenTitles = <String>{};
    final result = <Song>[];
    for (final s in shuffled) {
      if (!seenIds.add(s.id)) continue;
      if (RecommendationEngine.isInherentVariant(s.title)) continue;
      if (RecommendationEngine.isLowQualityUpload(s.title)) continue;
      if (!RecommendationEngine.isPremiumQuality(s)) continue;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) continue;
      result.add(s);
    }
    return result;
  }

  static Future<List<Song>> fetchNewReleaseSongs({int limit = 80}) async {
    final songs = await _searchSaavn('new bollywood songs 2026', limit: limit * 2);
    if (songs.isEmpty) return [];

    final seenIds = <String>{};
    final seenTitles = <String>{};
    final deduped = <Song>[];
    for (final s in songs) {
      if (!seenIds.add(s.id)) continue;
      if (RecommendationEngine.isInherentVariant(s.title)) continue;
      if (RecommendationEngine.isLowQualityUpload(s.title)) continue;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) continue;
      deduped.add(s);
    }

    int yearOf(Song s) => int.tryParse(s.year ?? '') ?? -1;
    deduped.sort((a, b) => yearOf(b).compareTo(yearOf(a)));

    return deduped.take(limit).toList();
  }

  static Future<List<Song>> fetchSimilarSongs({
    required String songId,
    String? artist,
    String? title,
    List<String> excludeIds = const [],
  }) async {
    final cleanId = songId.replaceFirst(RegExp(r'^[a-z]+_'), '');
    final excludeSet = excludeIds.toSet();

    final section = await _suggestionSection(cleanId, '__similar__');
    if (section != null && section.songs.isNotEmpty) {
      final filtered = section.songs.where((s) => !excludeSet.contains(s.id)).toList();
      if (filtered.isNotEmpty) return filtered;
    }

    if ((artist != null && artist.isNotEmpty) || (title != null && title.isNotEmpty)) {
      final query = [artist, 'songs'].where((e) => e != null && e.isNotEmpty).join(' ');
      final searched = await _searchSaavn(query.isNotEmpty ? query : (title ?? ''), limit: 20);
      final seenTitles = <String>{};
      final filtered = <Song>[];
      for (final s in searched) {
        if (excludeSet.contains(s.id)) continue;
        if (RecommendationEngine.isInherentVariant(s.title)) continue;
        final tk = _normTitle(s.title);
        if (!seenTitles.add(tk)) continue;
        filtered.add(s);
      }
      if (filtered.isNotEmpty) return filtered;
    }
    return [];
  }

  static Future<String?> resolveDownloadUrl(Song song, {List<String> qualityOrder = const ['320kbps', '160kbps']}) async {
    if (song.isLocal) return song.localPath;

    if (song.source == SongSource.saavn && song.id.isNotEmpty) {
      final url = await _retry(
        () => _saavnStreamById(
          song.id,
          title: song.title,
          artist: song.artist,
          qualityOrder: qualityOrder,
        ),
        attempts: 2,
      );
      if (url != null) return url;

    }
    return resolveStreamUrl(song);
  }

  static String _timeMoodQuery(TimeSlot slot) {
    switch (slot) {
      case TimeSlot.morning:   return 'fresh morning upbeat songs hindi';
      case TimeSlot.afternoon: return 'popular bollywood songs';
      case TimeSlot.evening:   return 'evening vibes hindi songs';
      case TimeSlot.night:     return 'romantic night songs hindi';
      case TimeSlot.lateNight: return 'lofi chill late night songs';
    }
  }
  static String _timeMoodLabel(TimeSlot slot) {
    switch (slot) {
      case TimeSlot.morning:   return 'Morning Vibes';
      case TimeSlot.afternoon: return 'Afternoon Picks';
      case TimeSlot.evening:   return 'Evening Flow';
      case TimeSlot.night:     return 'Night Mode';
      case TimeSlot.lateNight: return 'Late Night Chill';
    }
  }
  static String _genreMixLabel(String genre) {
    const labels = {
      'bollywood':  'Bollywood Mix', 'punjabi': 'Punjabi Blast',
      'hiphop':     'Hip Hop Mix',   'english': 'English Mix',
      'lofi':       'Lofi Mix',      'devotional': 'Devotional',
      'tamil':      'Tamil Hits',    'telugu': 'Telugu Hits',
    };
    return labels[genre] ?? '$genre Mix';
  }
  static String _genreMixQuery(String genre) {
    const queries = {
      'bollywood':  'bollywood hits songs', 'punjabi': 'punjabi hits songs',
      'hiphop':     'hindi rap hip hop hits','english': 'english pop hits songs',
      'lofi':       'lofi chill hindi songs','devotional': 'bhakti devotional songs',
      'tamil':      'tamil hits songs',      'telugu': 'telugu hits songs',
    };
    return queries[genre] ?? '$genre top songs';
  }

  // How many of hop 1's own top results get used as extra seeds for
  // hop 2 (and, if still short, hop 3 — see _buildAutoQueue). TUNED
  // 2 -> 4 as part of the "Up Next sirf 12-20 songs pe atak jaata hai"
  // fix: with hop1/hop2 results now actually surviving isPremiumQuality
  // (see addToPool's `trusted` flag), the old value of 2 became the
  // real limiting factor on reaching a full ~80-song pool fast. All
  // seeds within one hop still fire in parallel via Future.wait, so
  // widening this doesn't turn generation into a sequential chain of
  // calls — total latency stays roughly one extra request-time
  // regardless of seed count, same as before, just with each of those
  // requests now actually contributing songs instead of being filtered
  // out afterward.
  static const int _autoQueueHop2SeedCount = 4;

  // In-flight/completed Up Next builds, keyed by the seed song's id.
  // This is what makes Up Next feel "instant" like the real YT Music
  // app: player_provider.dart already fires its Phase-1/Phase-2
  // getAutoQueue() calls the moment a song starts playing (see
  // _buildInitialSmartQueue, un-awaited from playSong()) — well before
  // Up Next is actually opened or needed. Caching the Future itself
  // here (not just the result) means if a second caller asks for the
  // same song's queue while that first build is still in flight, it
  // gets the exact same in-progress Future instead of firing a
  // duplicate network round-trip — and once it resolves, every caller
  // for that song gets the answer immediately with zero extra work.
  // Bounded to a handful of entries since only the current + next few
  // songs are ever realistically in play on a phone at once.
  static final Map<String, Future<List<Song>>> _autoQueueCache = {};
  // Bumped 8 -> 16: cache keys are now (song id + dedup-context) pairs
  // instead of song id alone (see getAutoQueue's FIX comment), so the
  // same anchor song legitimately produces more than one live entry
  // during a session (initial build key, then a distinct key each time
  // auto-extend re-anchors on it with a larger exclusion set). Doubling
  // the cap keeps that from evicting a still-useful entry too eagerly.
  static const int _autoQueueCacheMaxEntries = 16;

  static void _rememberAutoQueueFuture(String cacheKey, Future<List<Song>> future) {
    // Simple FIFO eviction — good enough here since entries are cheap
    // Futures, not the song data itself, and playback is linear so the
    // oldest entry is almost always the least likely to be reused.
    if (_autoQueueCache.length >= _autoQueueCacheMaxEntries) {
      _autoQueueCache.remove(_autoQueueCache.keys.first);
    }
    _autoQueueCache[cacheKey] = future;
    // Don't let a failed build poison the cache for future attempts on
    // the same song — drop it on error so the next call retries fresh
    // instead of forever replaying the same failure.
    future.catchError((_) {
      _autoQueueCache.remove(cacheKey);
      return <Song>[];
    });
  }

  static Future<String?> _resolveYtIdForSong(Song song) async {
    if (song.source == SongSource.youtube) return song.id;
    try {
      final hits = await _searchYt('${song.title} ${song.artist}', limit: 5)
          .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[]);
      return hits.isNotEmpty ? hits.first.id : null;
    } catch (_) {
      return null;
    }
  }

  /// Pure YouTube-Music-algorithm Up Next: every candidate comes from
  /// the same WEB_REMIX "Related"/"You might also like" graph the real
  /// YT Music app itself serves for a given video — no keyword search,
  /// no guessing. Hop 1 is the seed song's own related shelf; hop 2
  /// fans out from a couple of hop 1's top hits, exactly the way the
  /// real app's Up Next keeps extending itself as you play through it.
  static Future<List<Song>> getAutoQueue(
    Song currentSong, {
    int limit = 60,
    Set<String>? existingQueueIds,
  }) async {
    // FIX ("Up Next 13 songs pe hi ruk jata hai" — the cache used to be
    // keyed by currentSong.id ALONE. _buildInitialSmartQueue seeds the
    // cache early with a SMALL existingQueueIds set; later,
    // _maybeExtendQueue can walk backward and land on that exact same
    // anchor song again (e.g. after a local track, or a short queue) and
    // call getAutoQueue for it a SECOND time with a much LARGER
    // existingQueueIds set (everything added since). Keyed on song id
    // only, that second call got back the FIRST call's cached result —
    // a batch already fully deduped against the old, smaller queue, so
    // every song in it now already exists in the live queue.
    // _maybeExtendQueue's own dedup loop then filtered the entire
    // returned batch out (`toAdd` ends up empty), silently ending the
    // auto-extend chain for that whole session even though real,
    // never-seen recommendations still exist. Keying on the *combined*
    // set of ids we're deduping against (not just the anchor song) means
    // a call with a different exclusion set is treated as a distinct
    // request instead of replaying a stale, already-consumed answer.
    // Order-independent hash of the exclusion set (cheap: XOR of each id's
    // hashCode, no sorting/joining a potentially long id list on every
    // call) combined with its length so two different-sized sets landing
    // on the same XOR by coincidence still produce different keys.
    int idsHash = 0;
    for (final id in existingQueueIds ?? const <String>{}) {
      idsHash ^= id.hashCode;
    }
    final cacheKey =
        '${currentSong.id}|${existingQueueIds?.length ?? 0}|$idsHash';

    // Reuse an in-flight or already-completed build for this exact song
    // + dedup-context pair instead of doing the network work again — see
    // _autoQueueCache doc comment above for why this is what makes
    // repeat/overlapping calls (Phase 1 + Phase 2, or a queue-extend
    // shortly after with the SAME exclusion set) feel instant.
    final cached = _autoQueueCache[cacheKey];
    if (cached != null) return cached;

    final future = _buildAutoQueue(
      currentSong,
      limit: limit,
      existingQueueIds: existingQueueIds,
    );
    _rememberAutoQueueFuture(cacheKey, future);
    return future;
  }

  static Future<List<Song>> _buildAutoQueue(
    Song currentSong, {
    int limit = 60,
    Set<String>? existingQueueIds,
  }) async {
    await RecommendationEngine.load();
    if (currentSong.isLocal) return [];

    final allExistingIds = <String>{
      currentSong.id,
      ...?existingQueueIds,
      ...RecommendationEngine.sessionRecentIds,
    };
    final mergedIds    = <String>{...allExistingIds};

    final mergedTitles = <String>{
      for (final t in RecommendationEngine.sessionRecentTitles) _normTitle(t),
    };

    final mergedRawTitles = <String>[];
    final pool         = <Song>[];

    // FIX ("Up Next sirf 12-20 songs pe atak jaata hai, category-wise
    // poore related songs nahi aate — ekdam fast, top-level, kam se kam
    // 80 songs chahiye"): `trusted` marks a song as coming from YT
    // Music's own curated "Related" graph (hop1/hop2 below) rather than
    // a raw keyword search — see isPremiumQuality's trustedRelatedGraph
    // doc for why this source needs it (no view count OR duration in
    // that endpoint's response at all, by format, not by parse failure).
    // Before this, addToPool always called isPremiumQuality with its
    // default (untrusted) check, so isPremiumQuality's very first line —
    // `if (song.viewCount == null) return false` — rejected literally
    // every hop1/hop2 result outright. hop1/hop2 together are meant to
    // supply the vast majority of a fast, broad, ~80-song pool; with
    // both silently emptied, `pool` fell straight to the "pool.isEmpty"
    // keyword-search safety net below on nearly every call — a single
    // narrow query for one song's own title+artist, which naturally
    // returns only a small, same-song-flavored batch (further thinned
    // by the variant/dedup checks already in this function) — exactly
    // the 12-20 ceiling being reported, instead of the broad top-level
    // related fan-out this function exists to build.
    bool addToPool(Song song, {bool trusted = false}) {
      if (mergedIds.contains(song.id)) return false;
      if (song.id.isEmpty || song.title.isEmpty) return false;
      if (RecommendationEngine.isInherentVariant(song.title)) return false;
      if (RecommendationEngine.isLowQualityUpload(song.title)) return false;
      if (RecommendationEngine.isNonMusicContent(song)) return false;
      if (!RecommendationEngine.isPremiumQuality(song, trustedRelatedGraph: trusted)) {
        return false;
      }
      final tk = _normTitle(song.title);
      if (mergedTitles.contains(tk)) return false;
      for (final seenRaw in mergedRawTitles) {
        if (RecommendationEngine.isSameSongSmart(song.title, seenRaw)) return false;
      }
      mergedIds.add(song.id);
      mergedTitles.add(tk);
      mergedRawTitles.add(song.title);
      pool.add(song);
      return true;
    }

    final seedYtId = await _resolveYtIdForSong(currentSong);
    if (seedYtId == null) {
      _log('[autoQueue] no YT id resolvable for seed — empty queue');
      return const [];
    }

    // Hop 1: the seed song's own real related shelf.
    final hop1 = await fetchYouMightAlsoLike(seedYtId,
            timeout: const Duration(seconds: 6))
        .catchError((_) => <Song>[]);
    for (final s in hop1) addToPool(s, trusted: true);
    _log('[autoQueue] hop1 (real YT Music related): ${pool.length}');

    // Hop 2: fan out from hop 1's own top (already-ranked) hits so the
    // pool keeps growing toward a full ~80-song Up Next instead of
    // stopping at whatever a single hop returns. TUNED (same fix as
    // above): widened from a fixed 2-seed cap to as many of hop 1's
    // results as it takes to comfortably clear `limit`, since hop1
    // alone (now that its results actually survive the quality filter)
    // is usually not quite enough on its own for the larger ~80-song
    // initial-build limit — still bounded (_autoQueueHop2SeedCount is
    // now a ceiling, not a fixed count) so a single call never fires
    // an unbounded number of parallel network round-trips.
    if (pool.length < limit && hop1.isNotEmpty) {
      final hop2Seeds = hop1.take(_autoQueueHop2SeedCount).toList();
      final hop2Results = await Future.wait(hop2Seeds.map((s) =>
          fetchYouMightAlsoLike(s.id, timeout: const Duration(seconds: 6))
              .catchError((_) => <Song>[])));
      for (final list in hop2Results) {
        for (final s in list) addToPool(s, trusted: true);
      }
      _log('[autoQueue] hop2 (chained real related): ${pool.length}');
    }

    // Hop 3: only reached if hop1+hop2 genuinely still fall short of a
    // full pool (rare now that hop1/hop2 aren't silently discarded) —
    // fans out one more level from hop 2's fresh (not-yet-seeded) top
    // hits, same trusted related-graph source, so a thin niche seed
    // still reaches the ~80-song target instead of dropping to the
    // narrow keyword fallback below.
    if (pool.length < limit && hop1.length > _autoQueueHop2SeedCount) {
      final hop3Seeds = hop1.skip(_autoQueueHop2SeedCount).take(_autoQueueHop2SeedCount).toList();
      if (hop3Seeds.isNotEmpty) {
        final hop3Results = await Future.wait(hop3Seeds.map((s) =>
            fetchYouMightAlsoLike(s.id, timeout: const Duration(seconds: 6))
                .catchError((_) => <Song>[])));
        for (final list in hop3Results) {
          for (final s in list) addToPool(s, trusted: true);
        }
        _log('[autoQueue] hop3 (extra related fan-out): ${pool.length}');
      }
    }

    // Safety net only — real related graph coming back completely dry
    // (rare: brand-new/obscure upload) falls back to a single
    // keyword search rather than leaving Up Next empty. Kept untrusted
    // (default isPremiumQuality check) since these are raw search hits,
    // not YT Music's own curated recommendation graph.
    if (pool.isEmpty) {
      final fallback = await _searchYt(
              '${currentSong.title} ${currentSong.artist}', limit: limit)
          .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])
          .catchError((_) => <Song>[]);
      for (final s in fallback) addToPool(s);
      _log('[autoQueue] related graph empty — used keyword fallback: ${pool.length}');
    }

    return RecommendationEngine.rankAndFilter(
      pool: pool, currentSong: currentSong,
      existingIds: allExistingIds, limit: limit,
    );
  }

  static Future<List<Song>> similarFromSaavnRaw(Song song, {int limit = 20}) {
    return _fetchSimilarFromSaavn(song, limit: limit);
  }

  static Future<List<Song>> _fetchSimilarFromSaavn(Song song, {int limit = 20}) async {
    final queries = <String>[];
    if (song.album.trim().isNotEmpty) queries.add(song.album);
    queries.add('${song.artist} songs');

    final resultsList = await Future.wait(queries.map((q) =>
        _searchSaavn(q, limit: 25)
            .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[])));

    final merged = <String, Song>{};
    for (final results in resultsList) {
      for (final s in results) {
        if (s.id.isEmpty || s.id == song.id) continue;
        merged[s.id] = s;
      }
    }
    return merged.values.toList();
  }

  static Future<SearchResult> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const SearchResult(direct: [], related: []);

    _ensureSelectionHistoryLoaded();

    RecommendationEngine.load();

    final cacheKey = _normalise(q);
    final cached = _searchCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      _log('[search] Cache HIT: "$q"');
      return cached.results;
    }

    final wantsVariant = _wantsVariantQuery(q);

    final movieCoreQuery = _extractMovieCoreQuery(q) ?? q;
    final movieSearchFuture = _searchYt('$movieCoreQuery all songs', limit: 40)
        .timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])
        .catchError((_) => <Song>[]);

    final earlySearchYtFuture = _searchYt(q, limit: 100)
        .timeout(const Duration(seconds: 10), onTimeout: () => <Song>[])
        .catchError((_) => <Song>[]);

    final ytScored = <_ScoredSong>[];

    const minRelevanceScore = 5.0;

    final ytResults = await earlySearchYtFuture;
    final ytRawTitlesAccepted = <String>[];
    for (final song in ytResults) {

      if (!RecommendationEngine.isSearchQuality(song)) continue;

      if (RecommendationEngine.isNonMusicContent(song)) continue;
      final score = _scoreSearchResult(song, q, wantsVariant);
      if (score < minRelevanceScore) continue;
      if (_isDupOfAny(song.title, ytRawTitlesAccepted)) continue;
      ytRawTitlesAccepted.add(song.title);
      ytScored.add(_ScoredSong(song, score));
    }

    {
      final movieResults = await movieSearchFuture;
      const movieMatchScore = 55.0;
      for (final song in movieResults) {
        if (!RecommendationEngine.isSearchQuality(song)) continue;
        if (RecommendationEngine.isNonMusicContent(song)) continue;
        if (RecommendationEngine.isInherentVariant(song.title)) continue;
        if (_isDupOfAny(song.title, ytRawTitlesAccepted)) continue;
        ytRawTitlesAccepted.add(song.title);
        ytScored.add(_ScoredSong(song, movieMatchScore));
      }
    }
    ytScored.sort((a, b) => b.score.compareTo(a.score));

    final directResults = ytScored.map((s) => s.song).toList();

    final directScores = ytScored.map((s) => s.score).toList();

    final results = List<Song>.from(directResults);

    final topMatchScore = directScores.isNotEmpty ? directScores.first : 0.0;
    if (directResults.isNotEmpty && directResults.length < 45 && topMatchScore >= 60) {
      final topMatch = directResults.first;
      final directIds    = <String>{for (final s in directResults) s.id};
      final directTitles = <String>{for (final s in directResults) _normTitle(s.title)};

      final relatedQueries = [
        if (topMatch.album.trim().isNotEmpty)
          AutoQueueQuery('${topMatch.album.trim()} movie all songs', weight: 3),
        ...RecommendationEngine.generateQueries(topMatch),
      ];
      final relatedPool = <Song>[];
      final seenRelated = <String>{};

      final seenRelatedRawTitles = <String>[];

      const relatedCap = 80;

      final sessionPlayedIds = RecommendationEngine.sessionRecentIds;

      final ytRelatedFutures = relatedQueries.map((rq) => _searchYt(rq.query, limit: 50)
          .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[])
          .catchError((_) => <Song>[])).toList();
      final ytRelatedLists = await Future.wait(ytRelatedFutures);

      void addToPool(Song s) {
        if (relatedPool.length >= relatedCap) return;
        if (directIds.contains(s.id)) return;
        if (sessionPlayedIds.contains(s.id)) return;
        if (RecommendationEngine.isInherentVariant(s.title)) return;

        if (s.source == SongSource.youtube && !RecommendationEngine.isSearchQuality(s)) return;
        final tk = _normTitle(s.title);
        if (directTitles.contains(tk) || seenRelated.contains(tk)) return;
        if (_isDupOfAny(s.title, seenRelatedRawTitles)) return;
        seenRelated.add(tk);
        seenRelatedRawTitles.add(s.title);
        relatedPool.add(s);
      }

      for (final list in ytRelatedLists) {
        for (final s in list) {
          if (relatedPool.length >= relatedCap) break;
          addToPool(s);
        }
      }
      results.addAll(relatedPool);
    }

    final relatedOnly = results.length > directResults.length
        ? results.sublist(directResults.length)
        : <Song>[];
    final result = SearchResult(direct: directResults, related: relatedOnly);

    _writeSearchCache(cacheKey, result);
    _log('[search] "$q" → direct:${directResults.length} related:${relatedOnly.length}');
    return result;
  }

  static double _scoreSearchResult(Song song, String query, bool wantsVariant) {
    double score = 0;

    final qNorm      = _normalise(query);
    final titleNorm  = _normalise(song.title);
    final artistNorm = _normalise(song.artist);
    final qNormSp      = _normalizeForMatch(query);
    final titleNormSp  = _normalizeForMatch(song.title);
    final artistNormSp = _normalizeForMatch(song.artist);

    if (titleNorm == qNorm)                score += 100;
    else if (artistNorm == qNorm)          score += 80;
    else if (titleNorm.startsWith(qNorm))  {
      score += 60;

      final extraChars = titleNorm.length - qNorm.length;
      score += (8 - extraChars.clamp(0, 8)).toDouble();
    }
    else if (artistNorm.startsWith(qNorm)) score += 40;
    else if (titleNorm.contains(qNorm))    score += 20;
    else if (artistNorm.contains(qNorm))   score += 10;

    final queryWords = qNormSp.split(' ').where((w) => w.length > 2).toList();
    final queryWordSet = queryWords.toSet();

    const _fillerWords = {
      'aap', 'aaye', 'aaya', 'aayi', 'hai', 'hain', 'mai', 'main', 'mein',
      'mera', 'meri', 'mere', 'tera', 'teri', 'tere', 'uska', 'uski', 'uske',
      'iska', 'iski', 'iske', 'hum', 'humara', 'tum', 'tumhara', 'aur',
      'nahi', 'nahin', 'kya', 'kar', 'kyun', 'kyu', 'kaise', 'kaisi',
      'kaisa', 'jab', 'tab', 'yeh', 'woh', 'wo', 'ye', 'ka', 'ki', 'ke',
      'ko', 'se', 'hi', 'bhi', 'toh', 'to', 'na', 'wala', 'wali',
      'wale', 'sab', 'sabhi', 'kisi', 'koi', 'kuch', 'ab', 'phir', 'thi',
      'tha', 'the', 'hoga', 'hogi', 'hoye', 'hoja', 'jaye', 'jaa', 'jao',
    };
    final distinctiveQueryWords =
        queryWordSet.where((w) => !_fillerWords.contains(w)).toSet();

    if (queryWords.length == 1 && qNormSp.length > 2 && titleNormSp != qNormSp) {
      final titleTokens = titleNormSp.split(' ');
      if (titleTokens.contains(qNormSp)) {
        score += 35;
      } else {
        var titleFuzzyMatched = false;
        for (final token in titleTokens) {
          if (token.length > 2 && _fuzzyWordMatch(qNormSp, token)) {
            score += 30;
            titleFuzzyMatched = true;
            break;
          }
        }

        if (!titleFuzzyMatched) {
          final artistTokens = artistNormSp.split(' ');
          for (final token in artistTokens) {
            if (token.length > 2 && _fuzzyWordMatch(qNormSp, token)) {
              score += 30;
              break;
            }
          }
        }
      }
    }

    if (queryWords.length > 1) {
      int wordMatches = 0;

      for (final word in queryWordSet) {
        if (titleNormSp.contains(word) || artistNormSp.contains(word)) {
          wordMatches++;
        } else if (_fuzzyWordMatch(word, titleNormSp) || _fuzzyWordMatch(word, artistNormSp)) {
          wordMatches++;
        }
      }
      final coverage = wordMatches / queryWordSet.length;

      final titleWords = titleNormSp.split(' ');
      int bestRun = 0;
      for (var i = 0; i < queryWords.length; i++) {
        var run = 0;
        var searchFrom = 0;
        for (var j = i; j < queryWords.length; j++) {
          final idx = titleWords.indexOf(queryWords[j], searchFrom);
          if (idx == -1) break;
          run++;
          searchFrom = idx + 1;
        }
        if (run > bestRun) bestRun = run;
      }
      final phraseRatio = bestRun / queryWords.length;

      score += wordMatches * 8.0 * coverage;

      score += phraseRatio * 60.0;

      if (queryWords.length >= 4 && coverage < 0.5) {
        score -= 40;
      }

      if (queryWords.length >= 2) {
        final sourceWords = distinctiveQueryWords.isNotEmpty
            ? distinctiveQueryWords
            : queryWordSet;
        final distinctiveWords = ([...sourceWords]..sort((a, b) => b.length.compareTo(a.length)))
            .take(2)
            .toList();
        final distinctiveMatched = distinctiveWords.every((w) =>
            titleNormSp.contains(w) ||
            artistNormSp.contains(w) ||
            _fuzzyWordMatch(w, titleNormSp) ||
            _fuzzyWordMatch(w, artistNormSp));
        if (!distinctiveMatched) score -= 35;
      }
    }

    if (_isOfficialAudio(song)) score += 30;

    if (!wantsVariant && RecommendationEngine.shouldBlock(song)) {
      score -= 50;
    } else if (wantsVariant && RecommendationEngine.isInherentVariant(song.title)) {
      score += 15;
    }

    if (song.source == SongSource.saavn) {
      score += song.streamUrl != null ? 20 : 15;
    }

    score += _selectionHistoryBoost(query, song.id);

    if (score < 60 && score > 0) {
      double tasteBoost = 0;

      final artistName = song.artist.trim().toLowerCase();
      if (artistName.isNotEmpty &&
          RecommendationEngine.topAffinityArtists(count: 8)
              .any((a) => a.trim().toLowerCase() == artistName)) {
        tasteBoost += 5;
      }
      if (RecommendationEngine.topAffinityGenres(count: 3)
          .contains(RecommendationEngine.detectGenre(song))) {
        tasteBoost += 3;
      }
      if (RecommendationEngine.topAffinityLanguages(count: 2)
          .contains(RecommendationEngine.detectLanguage(song))) {
        tasteBoost += 2;
      }
      score += tasteBoost;
    }

    return score;
  }

  static bool _isOfficialAudio(Song song) {
    final title = song.title.toLowerCase();
    if (title.contains('official audio') ||
        title.contains('official video') ||
        title.contains('official music video') ||
        title.contains('original')) return true;
    return !RecommendationEngine.isInherentVariant(song.title) &&
           !title.contains('cover') &&
           song.artist.isNotEmpty &&
           song.artist.toLowerCase() != 'unknown';
  }

  static bool _wantsVariantQuery(String query) =>
      RecommendationEngine.isInherentVariant(query);

  static final List<RegExp> _movieTriggerPatterns = [
    RegExp(r'^(.*?)\s+(movie|film|picture)$', caseSensitive: false),
    RegExp(r'^(.*?)\s+(soundtrack|ost)$', caseSensitive: false),
    RegExp(r'^(.*?)\s+(all songs|full album|album songs)$', caseSensitive: false),
  ];
  static String? _extractMovieCoreQuery(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;
    for (final pattern in _movieTriggerPatterns) {
      final match = pattern.firstMatch(trimmed);
      final core = match?.group(1)?.trim();
      if (core != null && core.isNotEmpty && core.split(RegExp(r'\s+')).length >= 1) {
        return core;
      }
    }
    return null;
  }

  static bool _isDupOfAny(String title, List<String> acceptedTitles) {
    for (final t in acceptedTitles) {
      if (RecommendationEngine.isSameSongSmart(title, t)) return true;
    }
    return false;
  }

  static String _normTitle(String title) {
    final clean = title
        .toLowerCase()
        .replaceAll(RegExp(r'\b(remix|lofi|lo[- ]?fi|slowed|reverb|nightcore|cover|'
                           r'karaoke|instrumental|bass[ -]?boost(?:ed)?|8d|sped[- ]?up|'
                           r'reprise|mashup|acoustic|unplugged|official|audio|video|'
                           r'lyric(?:s)?|full song|hd|4k)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), '')
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .trim();
    return clean.substring(0, clean.length.clamp(0, 30));
  }

  static Future<List<Song>> quickSearch(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final quickCacheKey = '${_normalise(q)}::$limit';
    final cachedQuick = _quickSearchCache[quickCacheKey];
    if (cachedQuick != null && !cachedQuick.isExpired) {
      return cachedQuick.results;
    }

    _ensureSelectionHistoryLoaded();
    RecommendationEngine.load();

    final wantsVariant = _wantsVariantQuery(q);
    const minLiveRelevanceScore = 5.0;

    List<Song> ytQuickResults;
    final ytFuture = _searchYt(q, limit: limit + 20);
    try {
      ytQuickResults = await ytFuture.timeout(const Duration(seconds: 4));
    } on TimeoutException {

      try {
        ytQuickResults = await ytFuture.timeout(const Duration(seconds: 5));
      } catch (_) {
        ytQuickResults = const <Song>[];
      }
    } catch (_) {
      ytQuickResults = const <Song>[];
    }

    const needsTypoVariants = false;
    const needsLyricVariants = false;
    final qWordsForVariants = needsTypoVariants || needsLyricVariants
        ? q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList()
        : const <String>[];

    final typoVariants = needsTypoVariants
        ? _generateTypoVariants(q, qWordsForVariants)
        : <String>{};

    final extraFutures = <Future<List<Song>>>[
      for (final v in typoVariants)
        _searchSaavn(v, limit: 15)
            .timeout(const Duration(seconds: 5), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[]),
      if (needsLyricVariants) ...[
        _searchSaavn(qWordsForVariants.sublist(0, qWordsForVariants.length - 1).join(' '), limit: 15)
            .timeout(const Duration(seconds: 3), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[]),
        _searchSaavn(qWordsForVariants.sublist(1).join(' '), limit: 15)
            .timeout(const Duration(seconds: 3), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[]),
      ],
    ];

    final variantResults = <Song>[];
    if (extraFutures.isNotEmpty) {
      final variantBatches = await Future.wait(extraFutures);
      for (final l in variantBatches) variantResults.addAll(l);
    }
    ytQuickResults = [...ytQuickResults, ...variantResults];

    final ytScoredQuick = <_ScoredSong>[];
    final ytRawTitlesAcceptedQuick = <String>[];
    for (final ys in ytQuickResults) {
      if (!RecommendationEngine.isSearchQuality(ys)) continue;
      if (RecommendationEngine.isLowQualityUpload(ys.title)) continue;
      if (RecommendationEngine.isNonMusicContent(ys)) continue;
      final score = _scoreSearchResult(ys, q, wantsVariant);
      if (score < minLiveRelevanceScore) continue;
      if (_isDupOfAny(ys.title, ytRawTitlesAcceptedQuick)) continue;
      ytRawTitlesAcceptedQuick.add(ys.title);
      ytScoredQuick.add(_ScoredSong(ys, score));
    }
    ytScoredQuick.sort((a, b) => b.score.compareTo(a.score));

    final mergedQuick = <Song>[...ytScoredQuick.map((s) => s.song)];

    final quickResult = mergedQuick.take(limit).toList();
    _writeQuickSearchCache(quickCacheKey, quickResult);
    return quickResult;
  }

  static Future<List<String>> suggest(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    List<String> results = await _suggestYtMusic(q);

    if (results.isEmpty) {

      results = await _suggestSaavn(q).catchError((_) => const <String>[]);
    }

    final deduped = results.toSet().toList();
    if (deduped.isEmpty) return deduped;

    final qNorm = _normalise(q);
    final qNormSp = _normalizeForMatch(q);
    final scored = results.map((s) {
      final sNorm = _normalise(s);
      final sNormSp = _normalizeForMatch(s);
      double score = 0;
      if (sNorm == qNorm) {
        score = 100;
      } else if (sNorm.startsWith(qNorm)) {
        score = 60;
      } else if (sNorm.contains(qNorm)) {
        score = 30;
      } else {

        final words = qNormSp.split(' ').where((w) => w.length > 2);
        var matched = 0;
        var total = 0;
        for (final w in words) {
          total++;
          if (sNormSp.contains(w) || _fuzzyWordMatch(w, sNormSp)) matched++;
        }
        score = total == 0 ? 0 : (matched / total) * 25;
      }
      return MapEntry(s, score);
    }).where((e) => e.value > 0).toList();

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).take(10).toList();
  }

  static Future<List<String>> _suggestSaavn(String query) async {

    for (final base in [_saavn, _saavnPrimary, _saavnSecondary]) {
      try {
        final url = Uri.parse(
          '$base/result/?query=${Uri.encodeQueryComponent(query)}&limit=10',
        );
        final res = await _client.get(url).timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final results = data is List ? data : (data['data']?['results'] ?? []);
          if (results is List && results.isNotEmpty) {
            return results
                .whereType<Map<String, dynamic>>()
                .map((j) => _cleanText(
                      (j['song'] ?? j['name'] ?? j['title'] ?? '').toString()))
                .where((s) => s.isNotEmpty)

                .where((s) => !s.toLowerCase().startsWith('not '))
                .take(5)
                .toList();
          }
        }
      } catch (_) {}
    }
    return [];
  }

  static Future<List<String>> _suggestYtMusic(String query) async {
    try {
      final url = Uri.parse(
        '$_worker/api/yt-suggest?query=${Uri.encodeQueryComponent(query)}&limit=8',
      );
      final res = await _client.get(url).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final results = data?['data']?['results'];
        if (results is List && results.isNotEmpty) {
          return results
              .map((s) => _cleanText(s.toString()))
              .where((s) => s.isNotEmpty)
              .toList();
        }
      }
    } catch (_) {}
    return const [];
  }

  static Future<List<Song>> searchSaavnRaw(String query, {int limit = 20}) {
    return _searchSaavn(query, limit: limit);
  }

  static Future<List<Song>> _searchSaavn(String query, {int limit = 20, bool allowMultiPage = true}) async {

    final effectiveLimit = limit > 40 ? 40 : limit;
    final pagesNeeded = allowMultiPage
        ? (limit / effectiveLimit).ceil().clamp(1, 10)
        : 1;

    Future<List<Song>?> tryNodeHost(String host, int page) async {
      try {
        final url = Uri.parse(
          '$host/api/search/songs?query=${Uri.encodeQueryComponent(query)}&limit=$effectiveLimit&page=$page',
        );
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) return null;
        final data = jsonDecode(res.body);
        final results = data is Map ? (data['data']?['results'] ?? []) : [];
        if (results is! List || results.isEmpty) return null;
        final songs = results
            .whereType<Map<String, dynamic>>()
            .take(effectiveLimit)
            .map(_songFromSaavn)
            .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
            .toList();
        return songs.isNotEmpty ? songs : null;
      } catch (e) {
        _log('[_searchSaavn] $host page $page error: $e');
        return null;
      }
    }

    Future<List<Song>?> tryResultRoute(String host, int page) async {
      try {
        final url = Uri.parse(
          '$host/result/?query=${Uri.encodeQueryComponent(query)}&limit=$effectiveLimit&page=$page',
        );
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) return null;
        final data = jsonDecode(res.body);
        final results = data is List
            ? data
            : (data['data']?['results'] ?? data['data'] ?? []);
        if (results is! List || results.isEmpty) return null;
        final songs = results
            .whereType<Map<String, dynamic>>()
            .take(effectiveLimit)
            .map(_songFromSaavn)
            .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
            .toList();
        return songs.isNotEmpty ? songs : null;
      } catch (e) {
        _log('[_searchSaavn] $host page $page error: $e');
        return null;
      }
    }

    final allResults = await Future.wait(<Future<List<Song>?>>[
      for (final host in _saavnNodeHosts)
        for (int p = 1; p <= pagesNeeded; p++) tryNodeHost(host, p),
      for (int p = 1; p <= pagesNeeded; p++) tryResultRoute(_saavn, p),

      for (final host in _saavnNoPaginationFlaskHosts) tryResultRoute(host, 1),
    ]);
    final seenIds = <String>{};
    final merged = <Song>[];
    for (final r in allResults) {
      if (r == null) continue;
      for (final s in r) {
        if (seenIds.add(s.id)) merged.add(s);
      }
    }
    return merged;
  }

  static Future<List<Song>> _fetchSaavnPage(String urlStr, int limit) async {
    try {
      final res = await _client.get(Uri.parse(urlStr)).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final results = (data is Map ? (data['data']?['results']) : null) ?? [];
      if (results is! List || results.isEmpty) return [];
      return results
          .whereType<Map<String, dynamic>>()
          .take(limit)
          .map(_songFromSaavn)
          .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<Song>> searchYtRaw(String query, {int limit = 30}) {
    return _searchYt(query, limit: limit);
  }

  static Future<List<Song>> _searchYt(String query, {int limit = 30}) async {

    final workerFuture = _searchYtMusic(query, limit)
        .timeout(const Duration(seconds: 9), onTimeout: () => <Song>[])
        .catchError((e) {
          _log('[_searchYt] yt-music-search (worker) error: $e');
          return <Song>[];
        });
    final directFuture = _searchYtMusicDirect(query, limit)
        .timeout(const Duration(seconds: 9), onTimeout: () => <Song>[])
        .catchError((e) {
          _log('[_searchYt] yt-music-search (direct) error: $e');
          return <Song>[];
        });

    List<Song>? workerResult;
    List<Song>? directResult;
    final firstNonEmpty = Completer<List<Song>>();
    void checkDone() {
      if (firstNonEmpty.isCompleted) return;
      if (workerResult != null && workerResult!.isNotEmpty) {
        firstNonEmpty.complete(workerResult!);
      } else if (directResult != null && directResult!.isNotEmpty) {
        firstNonEmpty.complete(directResult!);
      } else if (workerResult != null && directResult != null) {

        firstNonEmpty.complete(const <Song>[]);
      }
    }

    workerFuture.then((r) {
      workerResult = r;
      checkDone();
    });
    directFuture.then((r) {
      directResult = r;
      checkDone();
    });

    try {
      return await firstNonEmpty.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      return firstNonEmpty.future.timeout(
        const Duration(seconds: 7),
        onTimeout: () => workerResult ?? directResult ?? const <Song>[],
      );
    }
  }

  static const String _ytmApiKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
  static const String _ytmClientVersion = '1.20250310.01.00';

  static Iterable<Map<String, dynamic>> _findRenderers(
      dynamic node, String rendererKey) sync* {
    if (node is Map) {
      final match = node[rendererKey];
      if (match is Map) yield Map<String, dynamic>.from(match);
      for (final value in node.values) {
        yield* _findRenderers(value, rendererKey);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _findRenderers(value, rendererKey);
      }
    }
  }

  static ({String browseId, bool isArtist})? _artistEndpointOf(
      Map<String, dynamic>? navigationEndpoint) {
    final browseEndpoint = navigationEndpoint?['browseEndpoint'];
    if (browseEndpoint is! Map) return null;
    final browseId = (browseEndpoint['browseId'] ?? '').toString();
    if (!browseId.startsWith('UC') && !browseId.startsWith('MPLA')) return null;
    final pageType = browseEndpoint['browseEndpointContextSupportedConfigs']
        ?['browseEndpointContextMusicConfig']?['pageType'];
    return (browseId: browseId, isArtist: pageType == 'MUSIC_PAGE_TYPE_ARTIST');
  }

  static List<dynamic>? _deepFindThumbnailsList(dynamic node) {
    if (node is Map) {
      final direct = node['thumbnails'];
      if (direct is List && direct.isNotEmpty) return direct;
      for (final value in node.values) {
        final found = _deepFindThumbnailsList(value);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _deepFindThumbnailsList(value);
        if (found != null) return found;
      }
    }
    return null;
  }

  static String _ytmThumbnailUrl(Map<String, dynamic>? renderer) {

    if (renderer == null) return '';
    // BUGFIX ("artist album thumbnails not loading" — recheck 2026-09-14):
    // musicResponsiveListItemRenderer (search rows, playlist rows, etc.)
    // nests its thumbnail directly under renderer['thumbnail']. But
    // musicTwoRowItemRenderer (used for every artist "topAlbums"/
    // "singles"/"relatedArtists" card — see fetchArtist's collectReleaseCards)
    // nests it one level deeper, under renderer['thumbnailRenderer']
    // (confirmed by the already-working _parseHomeTwoRowItem above, which
    // reads r['thumbnailRenderer']). This helper only ever checked
    // renderer['thumbnail'], so every call site passing a raw
    // musicTwoRowItemRenderer card (topAlbums, singles, relatedArtists)
    // silently got an empty thumbField and returned '' — artwork always
    // fell back to the placeholder music-note icon for those cards, even
    // though the real thumbnail data was present in the response the
    // whole time, just one key over.
    final thumbField = renderer['thumbnail'] is Map
        ? renderer['thumbnail']
        : renderer['thumbnailRenderer'];
    if (thumbField is! Map) return '';
    var thumbs = (thumbField['musicThumbnailRenderer']?['thumbnail']
                ?['thumbnails'] as List?) ??
        (thumbField['croppedSquareThumbnailRenderer']?['thumbnail']
                ?['thumbnails'] as List?) ??
        const [];

    if (thumbs.isEmpty) {
      final scoped = _deepFindThumbnailsList(thumbField);
      if (scoped != null && scoped.isNotEmpty) thumbs = scoped;
    }
    if (thumbs.isEmpty) return '';
    final best = thumbs.last;
    final rawUrl = (best is Map ? (best['url'] ?? '') : '').toString();
    if (rawUrl.isEmpty) return '';

    return rawUrl.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w500-h500-p');
  }

  static String _flexColumnText(Map<String, dynamic> item, int index) {
    final flexColumns = (item['flexColumns'] as List?) ?? const [];
    if (index >= flexColumns.length) return '';
    final runs = flexColumns[index]
            ?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']
        as List? ??
        const [];
    return runs
        .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
        .join()
        .trim();
  }

  static List<({String channelId, String name})> _artistRunsInSubtitle(
      Map<String, dynamic> item) {
    final flexColumns = (item['flexColumns'] as List?) ?? const [];
    if (flexColumns.length < 2) return const [];
    final runs = flexColumns[1]
            ?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']
        as List? ??
        const [];
    final out = <({String channelId, String name})>[];
    for (final run in runs) {
      if (run is! Map) continue;
      final endpoint = _artistEndpointOf(
          (run['navigationEndpoint'] as Map?)?.cast<String, dynamic>());
      if (endpoint == null || !endpoint.isArtist) continue;
      final name = (run['text'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      out.add((channelId: endpoint.browseId, name: name));
    }
    return out;
  }

  static Future<Map<String, dynamic>?> _ytmSearchRaw(
    String query, {
    String? params,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    try {
      final uri = Uri.parse(
        'https://music.youtube.com/youtubei/v1/search?key=$_ytmApiKey&prettyPrint=false',
      );
      final resp = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
        },
        body: jsonEncode({
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': _ytmClientVersion,
              'hl': 'en',
              'gl': 'IN',
            },
          },
          'query': query,
          if (params != null) 'params': params,
        }),
      ).timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (e) {
      _log('[_ytmSearchRaw] error for "$query": $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _ytmBrowseRaw(
    String browseId, {
    String? params,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final uri = Uri.parse(
        'https://music.youtube.com/youtubei/v1/browse?key=$_ytmApiKey&prettyPrint=false',
      );
      final resp = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
        },
        body: jsonEncode({
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': _ytmClientVersion,
              'hl': 'en',
              'gl': 'IN',
            },
          },
          'browseId': browseId,
          if (params != null) 'params': params,
        }),
      ).timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (e) {
      _log('[_ytmBrowseRaw] error for "$browseId": $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _ytmBrowseContinuationRaw(
    String continuationToken, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final uri = Uri.parse(
        'https://music.youtube.com/youtubei/v1/browse?key=$_ytmApiKey&prettyPrint=false',
      );
      final resp = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
        },
        body: jsonEncode({
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': _ytmClientVersion,
              'hl': 'en',
              'gl': 'IN',
            },
          },
          'continuation': continuationToken,
        }),
      ).timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (e) {
      _log('[_ytmBrowseContinuationRaw] error: $e');
      return null;
    }
  }

  static Future<void> _fetchFullTopSongsPlaylist(
    String playlistBrowseId, {
    required int targetCount,
    required String fallbackArtistName,
    required String resolvedChannelId,
    required List<Song> topSongs,
    required Set<String> seenVideoIds,
    Duration timeout = const Duration(seconds: 8),

    int maxContinuations = 10,
  }) async {
    Map<String, dynamic>? data = await _ytmBrowseRaw(playlistBrowseId, timeout: timeout);
    var hops = 0;

    while (data != null && topSongs.length < targetCount && hops <= maxContinuations) {
      for (final item in _findRenderers(data, 'musicResponsiveListItemRenderer')) {
        if (topSongs.length >= targetCount) break;
        final videoId = (item['playlistItemData']?['videoId'] ?? '').toString();
        if (videoId.isEmpty || !seenVideoIds.add(videoId)) continue;

        final title = _flexColumnText(item, 0);
        if (title.isEmpty) continue;

        final artistRuns = _artistRunsInSubtitle(item);
        final artistName =
            artistRuns.isNotEmpty ? artistRuns.first.name : fallbackArtistName;

        final thumbs = (item['thumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            const [];
        String artworkUrl = '';
        if (thumbs.isNotEmpty) {
          final rawUrl = (thumbs.last['url'] ?? '').toString();
          artworkUrl = _scaledArtworkUrl(rawUrl, 1000);
        }

        final flexColumns = (item['flexColumns'] as List?) ?? const [];
        int? duration;
        if (flexColumns.isNotEmpty) {
          final lastColRuns = (flexColumns.last
                      ?['musicResponsiveListItemFlexColumnRenderer']?['text']
                  ?['runs'] as List?) ??
              const [];
          final lastColText = lastColRuns
              .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
              .join()
              .trim();
          duration = _parseDurationText(lastColText);
        }

        final song = Song(
          id: videoId,
          title: _cleanText(title),
          artist: _cleanText(artistName, collapseJukeboxTitle: false),
          album: '',
          artworkUrl: artworkUrl,
          streamUrl: null,
          duration: duration,
          source: SongSource.youtube,
          viewCount: 1000000,
          artistChannelId: resolvedChannelId,
        );
        if (RecommendationEngine.isNonMusicContent(song)) continue;
        topSongs.add(song);
      }

      if (topSongs.length >= targetCount) break;

      String? nextToken;
      for (final cont in _findRenderers(data, 'continuationItemRenderer')) {
        final token = (cont['continuationEndpoint']?['continuationCommand']
                ?['token'] ??
            '')
            .toString();
        if (token.isNotEmpty) {
          nextToken = token;
          break;
        }
      }
      if (nextToken == null) break;

      hops++;
      data = await _ytmBrowseContinuationRaw(nextToken, timeout: timeout);
    }
  }

  static Future<Map<String, dynamic>?> _ytmHomeRaw({
    Duration timeout = const Duration(seconds: 8),
  }) =>
      _ytmBrowseRaw('FEmusic_home', timeout: timeout);

  static ({
    String browseId,
    String title,
    String subtitle,
    String artworkUrl,
    String pageType,
  })? _parseHomeTwoRowItem(Map<String, dynamic> item) {
    final r = item['musicTwoRowItemRenderer'];
    if (r is! Map) return null;
    final titleRuns = (r['title']?['runs'] as List?) ?? const [];
    if (titleRuns.isEmpty) return null;
    final title = _cleanHomeText((titleRuns.first['text'] ?? '').toString());
    if (title.isEmpty) return null;

    final nav = titleRuns.first['navigationEndpoint'];
    final browseEndpoint = nav is Map ? nav['browseEndpoint'] : null;
    if (browseEndpoint is! Map) return null;
    final browseId = (browseEndpoint['browseId'] ?? '').toString();
    if (browseId.isEmpty) return null;
    final pageType = (browseEndpoint['browseEndpointContextSupportedConfigs']
                ?['browseEndpointContextMusicConfig']?['pageType'] ??
            '')
        .toString();

    final subtitleRuns = (r['subtitle']?['runs'] as List?) ?? const [];
    final subtitle = _cleanHomeText(
        subtitleRuns.map((run) => (run['text'] ?? '').toString()).join());

    final thumbs = (r['thumbnailRenderer']?['musicThumbnailRenderer']
            ?['thumbnail']?['thumbnails'] as List?) ??
        const [];
    String artworkUrl = '';
    if (thumbs.isNotEmpty) {

      artworkUrl = (thumbs.last['url'] ?? '').toString();
    }

    return (
      browseId: browseId,
      title: title,
      subtitle: subtitle,
      artworkUrl: _hqArtworkGeneric(artworkUrl),
      pageType: pageType,
    );
  }

  static String _cleanHomeText(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  // FIX ("data saver on karne ke baad bhe app extreme MB le raha hai" —
  // 2026-09-15): AudioPrefs.dataSaver (the app's own Data Saver toggle)
  // only ever fed qualityOrder() — i.e. which AUDIO bitrate to stream.
  // Every artwork/thumbnail/banner URL across the app was hardcoded to a
  // fixed large size (=w300-h300 for shelf/list cards via
  // _hqArtworkGeneric, =w1000-h1000 / =w1080-h1080-p for
  // artist/album/playlist headers, and =w1440-h1440-p for artist
  // banners) with NO regard for the toggle at all — a Data Saver user
  // pulling a shelf of 12 sections x 10 cards each still downloaded 120+
  // full 300x300 thumbnails, and opening a single artist page still
  // pulled a 1440x1440 banner plus a 1080x1080 avatar, exactly as if
  // Data Saver were off. Since images (fetched on every scroll/shelf/
  // refresh, far more often than a single audio stream is chosen) are
  // the actual dominant MB cost here, Data Saver needs to shrink these
  // too, not just the audio ladder. This scales every requested
  // dimension down by a fixed factor whenever dataSaver is on (covers
  // both the standalone toggle and the 'DataSaver' streamQuality tier,
  // same "either flag counts" contract qualityOrder() already uses) —
  // still crisp enough for card-sized art on screen, just meaningfully
  // fewer bytes over the wire.
  static int _dataSaverScaledSize(int fullSize) {
    final saverActive = AudioPrefs.dataSaverActiveNotifier.value;
    if (!saverActive) return fullSize;
    // ~40% of the full size — well above visible-blur territory for a
    // shelf card or list thumbnail, but a real byte reduction (roughly
    // 1/6th the pixel count) for banners/headers that were previously
    // forced all the way up to 1440px regardless of how small they
    // actually render on screen.
    final scaled = (fullSize * 0.4).round();
    // Floor so a tiny already-small request never gets scaled below
    // something legible.
    return scaled < 96 ? 96 : scaled;
  }

  static String _hqArtworkGeneric(String url) {
    if (url.isEmpty) return url;
    final size = _dataSaverScaledSize(300);
    return url.replaceAll(RegExp(r'=w\d+-h\d+[\w-]*$'), '=w$size-h$size');
  }

  // Shared helper for the =wN-hN[-p] header/banner/top-songs artwork URLs
  // scattered across the InnerTube parsing below — all six of those call
  // sites previously hardcoded their own fixed size (=w1000-h1000,
  // =w1080-h1080-p, =w1440-h1440-p) directly in a .replaceAll() call with
  // no Data Saver awareness at all. [suffix] preserves each site's own
  // trailing modifier (some InnerTube header URLs need the '-p' crop
  // hint, list/top-songs thumbnails don't) so behaviour is otherwise
  // identical to before, just at a Data-Saver-scaled size.
  static String _scaledArtworkUrl(String rawUrl, int fullSize, {String suffix = ''}) {
    if (rawUrl.isEmpty) return rawUrl;
    final size = _dataSaverScaledSize(fullSize);
    return rawUrl.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w$size-h$size$suffix');
  }

  static Future<List<HomeShelf>> fetchRealHomeShelves({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final data = await _ytmHomeRaw(timeout: timeout);
    if (data == null) return const [];
    try {
      final tabs = (data['contents']?['singleColumnBrowseResultsRenderer']
              ?['tabs'] as List?) ??
          const [];
      final firstTab = tabs.isNotEmpty ? tabs.first : null;
      final tabRenderer = firstTab is Map ? firstTab['tabRenderer'] : null;
      final tabContent = tabRenderer is Map ? tabRenderer['content'] : null;
      final sectionListRenderer =
          tabContent is Map ? tabContent['sectionListRenderer'] : null;
      final sections = (sectionListRenderer is Map
              ? sectionListRenderer['contents'] as List?
              : null) ??
          const [];

      final shelves = <HomeShelf>[];
      for (final section in sections) {
        if (section is! Map) continue;

        final listShelf = section['musicShelfRenderer'];
        if (listShelf is Map) {
          final listTitleRuns = (listShelf['title']?['runs'] as List?) ??
              const [];
          final listShelfTitle = listTitleRuns.isNotEmpty
              ? _cleanHomeText((listTitleRuns.first['text'] ?? '').toString())
              : '';
          if (listShelfTitle.isEmpty) continue;

          final rows = (listShelf['contents'] as List?) ?? const [];
          final parsedSongs = <Song>[];
          for (final raw in rows) {
            if (raw is! Map<String, dynamic>) continue;
            final song = _parseHomeShelfSongRow(raw);
            if (song == null || song.artworkUrl.isEmpty) continue;
            parsedSongs.add(song);
          }
          if (parsedSongs.isEmpty) continue;

          shelves.add(HomeShelf(
            title: listShelfTitle,
            items: const [],
            isList: true,
            songs: parsedSongs,
          ));
          continue;
        }

        final shelf = section['musicCarouselShelfRenderer'];

        if (shelf is! Map) continue;

        final titleRuns = (shelf['header']
                    ?['musicCarouselShelfBasicHeaderRenderer']?['title']
                ?['runs'] as List?) ??
            const [];
        final shelfTitle = titleRuns.isNotEmpty
            ? _cleanHomeText((titleRuns.first['text'] ?? '').toString())
            : '';
        if (shelfTitle.isEmpty) continue;

        final straplineRuns = (shelf['header']
                    ?['musicCarouselShelfBasicHeaderRenderer']?['strapline']
                ?['runs'] as List?) ??
            const [];
        final shelfStrapline = straplineRuns.isNotEmpty
            ? _cleanHomeText((straplineRuns.first['text'] ?? '').toString())
            : null;

        final items = (shelf['contents'] as List?) ?? const [];
        final parsed = <HomeShelfItem>[];
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final it = _parseHomeTwoRowItem(raw);
          if (it == null || it.artworkUrl.isEmpty) continue;
          parsed.add(HomeShelfItem(
            browseId: it.browseId,
            title: it.title,
            subtitle: it.subtitle,
            artworkUrl: it.artworkUrl,
            isAlbum: it.pageType == 'MUSIC_PAGE_TYPE_ALBUM',
            isRadioMix: it.pageType == 'MUSIC_PAGE_TYPE_RADIO',
          ));
        }
        if (parsed.isEmpty) continue;

        shelves.add(HomeShelf(
          title: shelfTitle,
          items: parsed,
          strapline: (shelfStrapline != null && shelfStrapline.isNotEmpty)
              ? shelfStrapline
              : null,
        ));
      }
      return shelves;
    } catch (e) {
      _log('[fetchRealHomeShelves] parse error: $e');
      return const [];
    }
  }

  static Song? _parseHomeShelfSongRow(Map<String, dynamic> item) {
    final r = item['musicResponsiveListItemRenderer'];
    if (r is! Map) return null;

    var videoId = (r['playlistItemData']?['videoId'] ?? '').toString();

    final flexCols = (r['flexColumns'] as List?) ?? const [];
    String colText(int index) {
      if (index >= flexCols.length) return '';
      final col = flexCols[index]['musicResponsiveListItemFlexColumnRenderer'];
      if (col is! Map) return '';
      final runs = (col['text']?['runs'] as List?) ?? const [];
      return _cleanHomeText(
          runs.map((run) => (run['text'] ?? '').toString()).join());
    }

    if (videoId.isEmpty) {
      final col0 = flexCols.isNotEmpty
          ? flexCols[0]['musicResponsiveListItemFlexColumnRenderer']
          : null;
      final runs = (col0 is Map ? (col0['text']?['runs'] as List?) : null) ??
          const [];
      for (final run in runs) {
        final vid =
            (run['navigationEndpoint']?['watchEndpoint']?['videoId'] ?? '')
                .toString();
        if (vid.isNotEmpty) {
          videoId = vid;
          break;
        }
      }
    }
    if (videoId.isEmpty) return null;

    final title = colText(0);
    if (title.isEmpty) return null;
    final artist = colText(1);
    final caption = colText(2);

    final thumbs = (r['thumbnail']?['musicThumbnailRenderer']?['thumbnail']
            ?['thumbnails'] as List?) ??
        const [];
    String artworkUrl = '';
    if (thumbs.isNotEmpty) {
      artworkUrl = (thumbs.last['url'] ?? '').toString();
    }
    if (artworkUrl.isEmpty) return null;

    return Song(
      id: videoId,
      title: title,
      artist: artist,
      album: caption,
      artworkUrl: _hqArtworkGeneric(artworkUrl),
      source: SongSource.youtube,
    );
  }

  static Future<Map<String, dynamic>?> _ytmMoodsAndGenresRaw({
    Duration timeout = const Duration(seconds: 8),
  }) =>
      _ytmBrowseRaw('FEmusic_moods_and_genres', timeout: timeout);

  static MoodGenreCategory? _parseMoodGenreTile(Map<String, dynamic> item) {
    final r = item['musicNavigationButtonRenderer'];
    if (r is! Map) return null;
    final renderer = Map<String, dynamic>.from(r);

    final titleRuns = (renderer['buttonText']?['runs'] as List?) ?? const [];
    if (titleRuns.isEmpty) return null;
    final title = _cleanHomeText((titleRuns.first['text'] ?? '').toString());
    if (title.isEmpty) return null;

    String browseId = '';
    String params = '';
    for (final ep in _findRenderers(renderer, 'browseEndpoint')) {
      final id = (ep['browseId'] ?? '').toString();
      final p = (ep['params'] ?? '').toString();
      if (id.isNotEmpty && p.isNotEmpty) {
        browseId = id;
        params = p;
        break;
      }
    }
    if (browseId.isEmpty || params.isEmpty) return null;

    int? color;
    final solid = renderer['solid'];
    if (solid is Map) {
      final raw = solid['leftStripeColor'] ?? solid['color'] ?? solid['backgroundColor'];
      if (raw is int) color = raw;
    }

    return MoodGenreCategory(
      browseId: browseId,
      params: params,
      title: title,
      color: color,
    );
  }

  static Future<List<MoodGenreSection>> fetchMoodsAndGenres({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final data = await _ytmMoodsAndGenresRaw(timeout: timeout);
    if (data == null) return const [];
    try {
      final sections = <MoodGenreSection>[];

      String gridFingerprint(Map grid) {
        final items = (grid['items'] as List?) ?? const [];
        final ids = <String>[];
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          for (final ep in _findRenderers(raw, 'browseEndpoint')) {
            final p = (ep['params'] ?? '').toString();
            if (p.isNotEmpty) ids.add(p);
          }
        }
        return ids.join(',');
      }

      final consumedGridFingerprints = <String>{};

      for (final shelf in _findRenderers(data, 'musicCarouselShelfRenderer')) {
        final titleRuns = (shelf['header']
                    ?['musicCarouselShelfBasicHeaderRenderer']?['title']
                ?['runs'] as List?) ??
            const [];
        final shelfTitle = titleRuns.isNotEmpty
            ? _cleanHomeText((titleRuns.first['text'] ?? '').toString())
            : '';

        final tiles = <MoodGenreCategory>[];

        for (final raw in ((shelf['contents'] as List?) ?? const [])) {
          if (raw is! Map<String, dynamic>) continue;
          final tile = _parseMoodGenreTile(raw);
          if (tile != null) tiles.add(tile);
        }
        for (final nestedGrid in _findRenderers(shelf, 'gridRenderer')) {
          consumedGridFingerprints.add(gridFingerprint(nestedGrid));
          for (final raw in ((nestedGrid['items'] as List?) ?? const [])) {
            if (raw is! Map<String, dynamic>) continue;
            final tile = _parseMoodGenreTile(raw);
            if (tile != null) tiles.add(tile);
          }
        }
        if (tiles.isEmpty) continue;
        sections.add(MoodGenreSection(
          title: shelfTitle.isNotEmpty ? shelfTitle : 'Moods & genres',
          items: tiles,
        ));
      }

      for (final grid in _findRenderers(data, 'gridRenderer')) {
        if (consumedGridFingerprints.contains(gridFingerprint(grid))) continue;
        final headerRuns = (grid['header']?['gridHeaderRenderer']?['title']
                    ?['runs'] as List?) ??
            const [];
        final sectionTitle = headerRuns.isNotEmpty
            ? _cleanHomeText((headerRuns.first['text'] ?? '').toString())
            : '';

        final tiles = <MoodGenreCategory>[];
        final items = (grid['items'] as List?) ?? const [];
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final tile = _parseMoodGenreTile(raw);
          if (tile != null) tiles.add(tile);
        }
        if (tiles.isEmpty) continue;

        sections.add(MoodGenreSection(
          title: sectionTitle.isNotEmpty ? sectionTitle : 'Moods & genres',
          items: tiles,
        ));
      }
      return await _topupMoodGenreArtwork(sections);
    } catch (e) {
      _log('[fetchMoodsAndGenres] parse error: $e');
      return const [];
    }
  }

  static Future<List<MoodGenreSection>> _topupMoodGenreArtwork(
    List<MoodGenreSection> sections,
  ) async {
    final uniqueTitles = <String>{};
    for (final section in sections) {
      for (final tile in section.items) {
        uniqueTitles.add(tile.title);
      }
    }
    if (uniqueTitles.isEmpty) return sections;

    final titleList = uniqueTitles.toList();
    final results = await Future.wait(
      titleList.map(
        (title) => _searchAsHomeShelf('$title playlist', title, take: 1)
            .catchError((_) => null),
      ),
    );

    final artworkByTitle = <String, String>{};
    for (var i = 0; i < titleList.length; i++) {
      final shelf = results[i];
      if (shelf == null || shelf.items.isEmpty) continue;
      final art = shelf.items.first.artworkUrl;
      if (art.isNotEmpty) artworkByTitle[titleList[i]] = art;
    }
    if (artworkByTitle.isEmpty) return sections;

    return sections
        .map((section) => MoodGenreSection(
              title: section.title,
              items: section.items
                  .map((tile) =>
                      tile.copyWithArtwork(artworkByTitle[tile.title]))
                  .toList(),
            ))
        .toList();
  }

  static Future<List<HomeShelf>> fetchMoodGenreCategory(
    String browseId,
    String params, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final data = await _ytmBrowseRaw(browseId, params: params, timeout: timeout);
    if (data == null) return const [];
    try {
      final shelves = <HomeShelf>[];
      for (final shelf in _findRenderers(data, 'musicCarouselShelfRenderer')) {
        final titleRuns = (shelf['header']
                    ?['musicCarouselShelfBasicHeaderRenderer']?['title']
                ?['runs'] as List?) ??
            const [];
        final shelfTitle = titleRuns.isNotEmpty
            ? _cleanHomeText((titleRuns.first['text'] ?? '').toString())
            : '';
        if (shelfTitle.isEmpty) continue;

        final items = (shelf['contents'] as List?) ?? const [];
        final parsed = <HomeShelfItem>[];
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final it = _parseHomeTwoRowItem(raw);
          if (it == null || it.artworkUrl.isEmpty) continue;
          parsed.add(HomeShelfItem(
            browseId: it.browseId,
            title: it.title,
            subtitle: it.subtitle,
            artworkUrl: it.artworkUrl,
            isAlbum: it.pageType == 'MUSIC_PAGE_TYPE_ALBUM',
            isRadioMix: it.pageType == 'MUSIC_PAGE_TYPE_RADIO',
          ));
        }
        if (parsed.isEmpty) continue;
        shelves.add(HomeShelf(title: shelfTitle, items: parsed));
      }

      if (shelves.isEmpty) {
        final flat = <HomeShelfItem>[];
        for (final grid in _findRenderers(data, 'gridRenderer')) {
          final items = (grid['items'] as List?) ?? const [];
          for (final raw in items) {
            if (raw is! Map<String, dynamic>) continue;
            final it = _parseHomeTwoRowItem(raw);
            if (it == null || it.artworkUrl.isEmpty) continue;
            flat.add(HomeShelfItem(
              browseId: it.browseId,
              title: it.title,
              subtitle: it.subtitle,
              artworkUrl: it.artworkUrl,
              isAlbum: it.pageType == 'MUSIC_PAGE_TYPE_ALBUM',
              isRadioMix: it.pageType == 'MUSIC_PAGE_TYPE_RADIO',
            ));
          }
        }
        if (flat.isNotEmpty) {
          shelves.add(HomeShelf(title: 'Playlists', items: flat));
        }
      }

      return shelves;
    } catch (e) {
      _log('[fetchMoodGenreCategory] parse error for "$browseId": $e');
      return const [];
    }
  }

  static const List<({String label, String query, String? strapline})> _kSeedHomeShelfQueries = [
    (
      label: 'Fresh finds, old favorites',

      query: 'new releases and old favorites mix playlist',
      strapline: null,
    ),
    (
      label: 'Dancing on your own',
      query: 'dancing on your own playlist',
      strapline: 'Dance your stress away',
    ),
    (
      label: 'Easy Evenings',
      query: 'easy evenings playlist',
      strapline: 'Comfy and cozy, as evenings should be',
    ),
    (
      label: 'Old School Romance',
      query: 'old school romantic songs playlist',
      strapline: 'Celebrate love the old fashioned way',
    ),
    (
      label: '90s Throwback Fun',
      query: '90s bollywood songs playlist',
      strapline: 'From the weird to the wonderful. Relive the magic',
    ),
    (label: 'Trending community playlists', query: 'trending community playlist', strapline: null),
  ];

  static Future<({String artistName, List<ArtistSimple> related})?>
      fetchSimilarArtistChips(String artistName) async {
    try {
      final id = await resolveArtistId(artistName);
      if (id == null) return null;
      final artist = await fetchArtist(id, songCount: 0, albumCount: 0);
      if (artist == null || artist.relatedArtists.isEmpty) return null;
      final chips = artist.relatedArtists
          .map((r) => ArtistSimple(id: r.id, name: r.name, imageUrl: r.imageUrl))
          .toList();
      return (artistName: artistName, related: chips);
    } catch (_) {
      return null;
    }
  }

  static Future<({
    String artistName,
    String? artistImageUrl,
    RelatedArtist? relatedArtist,
    List<ArtistAlbum> albums,
  })?> fetchSimilarArtistAlbums(String artistName, {int albumCount = 10}) async {
    try {
      final id = await resolveArtistId(artistName);
      if (id == null) return null;

      final artist = await fetchArtist(id, songCount: 5, albumCount: albumCount);
      if (artist == null || artist.topAlbums.isEmpty) return null;
      return (
        artistName: artistName,
        artistImageUrl: artist.imageUrl,
        relatedArtist:
            artist.relatedArtists.isNotEmpty ? artist.relatedArtists.first : null,
        albums: artist.topAlbums.take(albumCount).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<HomeShelf?> _searchAsHomeShelf(String query, String label,
      {int take = 10, String? strapline}) async {
    try {
      final decoded = await _ytmSearchRaw(query,
          params: _ytmPlaylistsFilterParam, timeout: const Duration(seconds: 6));
      if (decoded == null) return null;

      final items = <HomeShelfItem>[];
      final seenIds = <String>{};
      for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
        final browseId = (item['navigationEndpoint']?['browseEndpoint']?['browseId'] ??
                item['overlay']?['musicItemThumbnailOverlayRenderer']?['content']
                        ?['musicPlayButtonRenderer']?['playNavigationEndpoint']
                    ?['watchPlaylistEndpoint']?['playlistId'] ??
                '')
            .toString();
        if (browseId.isEmpty || !seenIds.add(browseId)) continue;

        if (_isYtMixPlaylistId(browseId)) continue;
        if (!browseId.startsWith('VL') &&
            !browseId.startsWith('PL') &&
            !browseId.startsWith('OLAK5uy')) {
          continue;
        }

        final title = _flexColumnText(item, 0);
        if (title.isEmpty || RecommendationEngine.isLowQualityUpload(title)) continue;

        final thumbs = (item['thumbnail']?['musicThumbnailRenderer']?['thumbnail']
                    ?['thumbnails'] as List?) ??
            const [];
        if (thumbs.isEmpty) continue;
        final artworkUrl = _hqArtworkGeneric((thumbs.last['url'] ?? '').toString());

        final subtitleRuns = ((item['flexColumns'] as List?)?.length ?? 0) > 1
            ? ((item['flexColumns'][1]?['musicResponsiveListItemFlexColumnRenderer']
                        ?['text']?['runs'] as List?) ??
                const [])
            : const [];
        final subtitle = _cleanHomeText(subtitleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .where((t) => t != ' • ' && t.trim().isNotEmpty)
            .lastWhere((_) => true, orElse: () => ''));

        // FIX ("Similar to" shelf showing a random creator channel /
        // thin devotional-album card instead of a real curated playlist):
        // reject channel-style results (subtitle says "N subscribers")
        // and thin one-off albums/compilations (no song-count marker, or
        // below the minimum) before they ever reach the shelf.
        if (RecommendationEngine.isLowQualityPlaylistShelfItem(subtitle)) continue;

        items.add(HomeShelfItem(
          browseId: browseId,
          title: _cleanHomeText(title),
          subtitle: subtitle,
          artworkUrl: artworkUrl,
          isAlbum: false,
        ));
        if (items.length >= take) break;
      }
      if (items.isEmpty) return null;
      return HomeShelf(title: label, items: items, strapline: strapline);
    } catch (e) {
      _log('[_searchAsHomeShelf] error for "$query": $e');
      return null;
    }
  }

  static Future<HomeShelf?> fetchFeaturedPlaylistsForYou() async {
    const queries = [
      'weekly top videos tamil',
      'weekly top videos punjabi',
      'weekly top videos hindi',
    ];
    final perQuery = await Future.wait(
      queries.map((q) => _searchAsHomeShelf(q, 'Featured playlists for you', take: 1)),
    );
    final items = <HomeShelfItem>[];
    for (final shelf in perQuery) {
      if (shelf != null && shelf.items.isNotEmpty) items.add(shelf.items.first);
    }
    if (items.isEmpty) return null;
    return HomeShelf(title: 'Featured playlists for you', items: items);
  }

  static Future<List<SearchPlaylistResult>> fetchFeaturedPlaylistsForSearch() async {
    const queries = [
      'weekly top videos hindi',
      'weekly top videos tamil',
      'weekly top videos punjabi',
      'weekly top videos telugu',
    ];
    final perQuery = await Future.wait(
      queries.map((q) => _searchAsHomeShelf(q, 'Featured playlists', take: 5)),
    );
    final results = <SearchPlaylistResult>[];
    final seenIds = <String>{};
    for (final shelf in perQuery) {
      if (shelf == null) continue;
      for (final item in shelf.items) {
        if (!seenIds.add(item.browseId)) continue;
        results.add(SearchPlaylistResult(
          id: item.browseId,
          title: item.title,
          author: item.subtitle,
          artworkUrl: item.artworkUrl,
        ));
      }
    }
    return results;
  }

  static Future<HomeShelf?> fetchPersonalizedHomeShelf({int? seed}) async {
    final topArtists = RecommendationEngine.rotatingAffinityArtists(count: 3, seed: seed);
    if (topArtists.isEmpty) return null;

    final perArtist = await Future.wait(
      topArtists.map((a) => _searchAsHomeShelf('$a mix playlist', a, take: 4)),
    );
    final items = <HomeShelfItem>[];
    final seenIds = <String>{};
    for (final shelf in perArtist) {
      if (shelf == null) continue;
      for (final it in shelf.items) {
        if (seenIds.add(it.browseId)) items.add(it);
      }
    }
    if (items.isEmpty) return null;
    items.shuffle(math.Random(seed));
    return HomeShelf(title: 'Made for you', items: items);
  }

  static Future<List<HomeShelf>> fetchSimilarToArtistShelves({int? seed, int artistCount = 3}) async {
    final topArtists =
        RecommendationEngine.rotatingAffinityArtists(count: artistCount, seed: seed);
    if (topArtists.isEmpty) return const [];

    final perArtist = await Future.wait(
      topArtists.map((a) => _searchAsHomeShelf('$a mix playlist', 'Similar to $a', take: 10)),
    );
    return perArtist.whereType<HomeShelf>().toList();
  }

  static Future<List<HomeShelf>> fetchHomeShelvesForDisplay({int? refreshSeed}) async {
    final realFuture = fetchRealHomeShelves();
    final similarFuture = fetchSimilarToArtistShelves(seed: refreshSeed);
    final featuredFuture = fetchFeaturedPlaylistsForYou();
    final seededFuture = Future.wait<HomeShelf?>(
      _kSeedHomeShelfQueries.map(
        (sq) => _searchAsHomeShelf(sq.query, sq.label, strapline: sq.strapline),
      ),
    );

    final real = await realFuture;
    final similar = await similarFuture;
    final featured = await featuredFuture;
    final seeded = (await seededFuture).whereType<HomeShelf>().toList();

    // FIX ("home page pe ek hi category kitne baar aa raha hai" — same
    // shelf, e.g. "Dancing on your own", showing up 2-3 times in a row):
    // `real` (raw FEmusic_home parse), `similar` (per-affinity-artist
    // shelves), `featured`, and `seeded` (the fixed _kSeedHomeShelfQueries
    // list, which itself includes a literal "Dancing on your own" entry)
    // were concatenated with NO title-level dedup at all. Two ways that
    // produced visible repeats: (1) FEmusic_home's own raw payload can
    // legitimately include the same shelf title more than once across
    // different sections of the response — fetchRealHomeShelves() just
    // parses every section it finds, so both copies survived into `real`
    // unchanged; (2) `seeded`'s fixed "Dancing on your own" entry could
    // land right alongside a same-titled shelf already pulled in via
    // `real` or `similar` for the same session. Either way, nothing
    // downstream ever checked one shelf's title against another's before
    // this list got capped and handed to the UI, so a genuine duplicate
    // rode all the way to the screen. Dedup by normalized title here,
    // first-seen-wins (in `real -> similar -> featured -> seeded`
    // priority order — the real personalized shelves should never lose
    // their slot to a generic fixed-query one with the same name), before
    // the maxShelves cap so a duplicate never displaces a genuinely
    // different shelf that would otherwise have made the cut.
    final combined = [
      ...real,
      ...similar,
      if (featured != null) featured,
      ...seeded,
    ];

    final seenTitles = <String>{};
    final deduped = <HomeShelf>[];
    for (final shelf in combined) {
      final key = shelf.title.trim().toLowerCase();
      if (key.isEmpty || !seenTitles.add(key)) continue;
      deduped.add(shelf);
    }

    const maxShelves = 7;
    return deduped.take(maxShelves).toList();
  }

  static Future<List<Song>> resolveHomeShelfPlaylist(
    HomeShelfItem item, {
    int targetCount = 25,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final songs = <Song>[];
    final seenIds = <String>{};
    await _fetchFullTopSongsPlaylist(
      item.browseId,
      targetCount: targetCount,
      fallbackArtistName: item.subtitle.isNotEmpty ? item.subtitle : item.title,
      resolvedChannelId: '',
      topSongs: songs,
      seenVideoIds: seenIds,
      timeout: timeout,
    );
    return songs;
  }

  static Future<List<Song>> fetchHomeShelfPlaylistMore(
    HomeShelfItem item, {
    required List<String> existingVideoIds,
    int targetCount = 100,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final songs = <Song>[];
    final seenIds = existingVideoIds.toSet();
    await _fetchFullTopSongsPlaylist(
      item.browseId,
      targetCount: targetCount,
      fallbackArtistName: item.subtitle.isNotEmpty ? item.subtitle : item.title,
      resolvedChannelId: '',
      topSongs: songs,
      seenVideoIds: seenIds,
      timeout: timeout,
    );
    return songs;
  }

  static Future<String?> _fetchRelatedBrowseId(
    String videoId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final uri = Uri.parse(
        'https://music.youtube.com/youtubei/v1/next?key=$_ytmApiKey&prettyPrint=false',
      );
      final resp = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
        },
        body: jsonEncode({
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': _ytmClientVersion,
              'hl': 'en',
              'gl': 'IN',
            },
          },
          'videoId': videoId,
        }),
      ).timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;

      final tabs = (decoded['contents']?['singleColumnMusicWatchNextResultsRenderer']
              ?['tabbedRenderer']?['watchNextTabbedResultsRenderer']?['tabs']
          as List?) ??
          const [];
      for (final tab in tabs) {
        if (tab is! Map) continue;
        final tr = tab['tabRenderer'];
        if (tr is! Map) continue;
        if ((tr['title'] ?? '').toString() != 'Related') continue;
        final browseId =
            (tr['endpoint']?['browseEndpoint']?['browseId'] ?? '').toString();
        return browseId.isEmpty ? null : browseId;
      }
      return null;
    } catch (e) {
      _log('[_fetchRelatedBrowseId] error for "$videoId": $e');
      return null;
    }
  }

  static ({
    String videoId,
    String title,
    String artist,
    String artworkUrl,
  })? _parseRelatedListItem(Map<String, dynamic> item) {
    final r = item['musicResponsiveListItemRenderer'];
    if (r is! Map) return null;

    final videoId = (r['playlistItemData']?['videoId'] ?? '').toString();
    if (videoId.isEmpty) return null;

    final flexCols = (r['flexColumns'] as List?) ?? const [];
    String colText(int index) {
      if (index >= flexCols.length) return '';
      final col = flexCols[index]['musicResponsiveListItemFlexColumnRenderer'];
      if (col is! Map) return '';
      final runs = (col['text']?['runs'] as List?) ?? const [];
      return _cleanHomeText(
          runs.map((run) => (run['text'] ?? '').toString()).join());
    }

    final title = colText(0);
    if (title.isEmpty) return null;
    final artist = colText(1);

    final thumbs = (r['thumbnail']?['musicThumbnailRenderer']?['thumbnail']
            ?['thumbnails'] as List?) ??
        const [];
    String artworkUrl = '';
    if (thumbs.isNotEmpty) {
      artworkUrl = (thumbs.last['url'] ?? '').toString();
    }

    return (
      videoId: videoId,
      title: title,
      artist: artist,
      artworkUrl: _hqArtworkGeneric(artworkUrl),
    );
  }

  // Shelf titles YT Music's own "Related" browse page groups results
  // under. Only "You might also like" (sometimes plain "Related" on
  // some locales) is the real recommendation signal — "Other
  // performances" / "Live performances" are covers, remixes, and
  // duplicate uploads of the SAME song, which is noise for an Up Next
  // queue (it just plays variants of what you're already hearing).
  static bool _isRealRecommendationShelf(String shelfTitle) {
    final t = shelfTitle.trim().toLowerCase();
    if (t.isEmpty) return true; // some locales omit the header — don't drop it
    return t == 'you might also like' || t == 'related';
  }

  static String _shelfTitleOf(Map shelf) {
    try {
      final runs = shelf['header']?['musicCarouselShelfBasicHeaderRenderer']
          ?['title']?['runs'] as List?;
      if (runs == null || runs.isEmpty) return '';
      return (runs.first['text'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  static Future<List<Song>> fetchYouMightAlsoLike(
    String videoId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (videoId.isEmpty) return const [];
    try {
      final relatedBrowseId = await _fetchRelatedBrowseId(videoId, timeout: timeout);
      if (relatedBrowseId == null) return const [];

      final data = await _ytmBrowseRaw(relatedBrowseId, timeout: timeout);
      if (data == null) return const [];

      final sections =
          (data['contents']?['sectionListRenderer']?['contents'] as List?) ??
              const [];
      final songs = <Song>[];
      for (final section in sections) {
        if (section is! Map) continue;
        final shelf = section['musicCarouselShelfRenderer'];
        if (shelf is! Map) continue;
        if (!_isRealRecommendationShelf(_shelfTitleOf(shelf))) continue;
        final items = (shelf['contents'] as List?) ?? const [];
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final it = _parseRelatedListItem(raw);
          if (it == null || it.artworkUrl.isEmpty) continue;
          songs.add(Song(
            id: it.videoId,
            title: it.title,
            artist: it.artist,
            album: '',
            artworkUrl: it.artworkUrl,
            source: SongSource.youtube,
            // FIX ("Up Next sirf 12-20 songs pe atak jaata hai, category-
            // wise poore related songs nahi aate"): this "Related"/"You
            // might also like" browse endpoint is YT Music's OWN curated
            // recommendation graph for this exact video — the same trust
            // tier as the sentinel used for _searchYtMusic's curated
            // catalog results (see viewCount: 1000000 elsewhere in this
            // file) — but its response format never carries a real view
            // count or duration at all (that data simply isn't part of
            // this endpoint's payload, unlike search results). Leaving
            // viewCount null here meant EVERY song from this hop failed
            // isPremiumQuality's "no view count = don't trust it" check
            // outright, so addToPool silently dropped the entire related
            // graph — hop1 and hop2 together contributed ~0 songs to the
            // pool, and getAutoQueue fell through to its keyword-search
            // safety net, which only ever returns a small, narrow batch
            // for one song's title+artist (exactly the 12-20 ceiling
            // being reported) instead of the broad, fast related-graph
            // fan-out this function exists to provide. Same sentinel used
            // elsewhere marks this as trusted-by-construction so the real
            // quality bar (isNonMusicContent, isLowQualityUpload, variant/
            // dedup checks) still applies — only the not-available view/
            // duration signal is skipped.
            viewCount: 1000000,
          ));
        }
      }
      return songs;
    } catch (e) {
      _log('[fetchYouMightAlsoLike] error: $e');
      return const [];
    }
  }

  static Future<List<ArtistSimple>> fetchFansMightAlsoLike(
    String artistChannelId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (artistChannelId.isEmpty) return const [];
    try {
      final data = await _ytmBrowseRaw(artistChannelId, timeout: timeout);
      if (data == null) return const [];

      final tabs = (data['contents']?['singleColumnBrowseResultsRenderer']
              ?['tabs'] as List?) ??
          const [];
      final firstTab = tabs.isNotEmpty ? tabs.first : null;
      final tabRenderer = firstTab is Map ? firstTab['tabRenderer'] : null;
      final tabContent = tabRenderer is Map ? tabRenderer['content'] : null;
      final sectionListRenderer =
          tabContent is Map ? tabContent['sectionListRenderer'] : null;
      final sections = (sectionListRenderer is Map
              ? sectionListRenderer['contents'] as List?
              : null) ??
          const [];

      for (final section in sections) {
        if (section is! Map) continue;
        final shelf = section['musicCarouselShelfRenderer'];
        if (shelf is! Map) continue;
        final titleRuns = (shelf['header']
                    ?['musicCarouselShelfBasicHeaderRenderer']?['title']
                ?['runs'] as List?) ??
            const [];
        final shelfTitle =
            titleRuns.isNotEmpty ? (titleRuns.first['text'] ?? '').toString() : '';
        if (shelfTitle != 'Fans might also like') continue;

        final items = (shelf['contents'] as List?) ?? const [];
        final artists = <ArtistSimple>[];
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final it = _parseHomeTwoRowItem(raw);
          if (it == null || it.pageType != 'MUSIC_PAGE_TYPE_ARTIST') continue;
          if (it.browseId.isEmpty || it.artworkUrl.isEmpty) continue;
          artists.add(ArtistSimple(
            id: it.browseId,
            name: it.title,
            imageUrl: it.artworkUrl,
          ));
        }
        return artists;
      }

      return const [];
    } catch (e) {
      _log('[fetchFansMightAlsoLike] error: $e');
      return const [];
    }
  }

  static const String _ytmSongsFilterParam = 'EgWKAQIIAWoKEAMQBBAJEAoQBQ%3D%3D';

  static Future<List<Song>> _searchYtMusicDirect(String query, int limit) async {
    return _searchYtMusicDirectRaw(query, limit, filterParam: _ytmSongsFilterParam);
  }

  static Future<List<Song>> _searchYtMusicDirectPaginated(
    String query,
    int limit, {
    String? filterParam,
  }) async {
    final out = <Song>[];
    final seenIds = <String>{};
    void addUnique(List<Song> songs) {
      for (final s in songs) {
        if (out.length >= limit) return;
        if (seenIds.add(s.id)) out.add(s);
      }
    }

    String? continuationToken;
    const maxPages = 15;
    for (var page = 0; page < maxPages; page++) {
      if (out.length >= limit) break;
      final Map<String, dynamic> result;
      try {
        result = await _searchYtMusicDirectRawWithContinuation(
          query,
          limit,
          filterParam: filterParam,
          continuationToken: continuationToken,
        ).timeout(const Duration(seconds: 8));
      } catch (e) {
        _log('[_searchYtMusicDirectPaginated] page $page failed: $e');
        break;
      }
      final songs = result['songs'] as List<Song>;
      if (songs.isEmpty) break;
      addUnique(songs);
      continuationToken = result['continuation'] as String?;
      if (continuationToken == null || continuationToken.isEmpty) break;
    }
    return out;
  }

  static Future<List<Song>> _searchYtMusicDirectUnfiltered(String query, int limit) async {
    return _searchYtMusicDirectRaw(query, limit, filterParam: null);
  }

  static Future<List<Song>> _searchYtMusicDirectRaw(
    String query,
    int limit, {
    required String? filterParam,
  }) async {
    final result = await _searchYtMusicDirectRawWithContinuation(
      query,
      limit,
      filterParam: filterParam,
      continuationToken: null,
    );
    return result['songs'] as List<Song>;
  }

  static Future<Map<String, dynamic>> _searchYtMusicDirectRawWithContinuation(
    String query,
    int limit, {
    required String? filterParam,
    required String? continuationToken,
  }) async {

    final uri = continuationToken == null
        ? Uri.parse(
            'https://music.youtube.com/youtubei/v1/search?key=$_ytmApiKey&prettyPrint=false',
          )
        : Uri.parse(
            'https://music.youtube.com/youtubei/v1/search'
            '?key=$_ytmApiKey&prettyPrint=false&ctoken=$continuationToken'
            '&continuation=$continuationToken&type=next',
          );
    final resp = await _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
      },
      body: jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': _ytmClientVersion,
            'hl': 'en',
            'gl': 'IN',
          },
        },
        if (continuationToken == null) 'query': query,
        if (continuationToken == null && filterParam != null) 'params': filterParam,
        if (continuationToken != null) 'continuation': continuationToken,
      }),
    );
    if (resp.statusCode != 200) return {'songs': <Song>[], 'continuation': null};
    final dynamic decoded = jsonDecode(resp.body);

    if (decoded is! Map) return {'songs': <Song>[], 'continuation': null};
    return _parseYtMusicDirectSearchWithContinuation(decoded, limit);
  }

  static List<Song> _parseYtMusicDirectSearch(dynamic json, int limit) {
    return _parseYtMusicDirectSearchWithContinuation(json, limit)['songs'] as List<Song>;
  }

  static Map<String, dynamic> _parseYtMusicDirectSearchWithContinuation(
      dynamic json, int limit) {
    final out = <Song>[];
    String? nextContinuation;
    try {
      final shelves = <dynamic>[];
      final tabs = json?['contents']?['tabbedSearchResultsRenderer']?['tabs']
              as List? ??
          const [];
      for (final tab in tabs) {
        final sections = tab?['tabRenderer']?['content']
                ?['sectionListRenderer']?['contents'] as List? ??
            const [];
        for (final section in sections) {
          if (section?['musicShelfRenderer'] != null) {
            shelves.add(section['musicShelfRenderer']);
          }
        }
      }
      if (shelves.isEmpty) {
        final sections =
            json?['contents']?['sectionListRenderer']?['contents'] as List? ??
                const [];
        for (final section in sections) {
          if (section?['musicShelfRenderer'] != null) {
            shelves.add(section['musicShelfRenderer']);
          }
        }
      }

      if (shelves.isEmpty) {
        final continuationShelf = json?['continuationContents']
            ?['musicShelfContinuation'];
        if (continuationShelf != null) shelves.add(continuationShelf);
      }

      for (final shelf in shelves) {

        final continuations = shelf?['continuations'] as List? ?? const [];
        if (continuations.isNotEmpty) {
          final token = continuations
              .first?['nextContinuationData']?['continuation']
              ?.toString();
          if (token != null && token.isNotEmpty) nextContinuation = token;
        }

        final items = shelf?['contents'] as List? ?? const [];
        for (final item in items) {
          final r = item?['musicResponsiveListItemRenderer'];
          if (r == null) continue;

          final videoId = r['playlistItemData']?['videoId'] ??
              r['overlay']?['musicItemThumbnailOverlayRenderer']?['content']
                  ?['musicPlayButtonRenderer']?['playNavigationEndpoint']
                  ?['watchEndpoint']?['videoId'];
          if (videoId == null || videoId.toString().isEmpty) continue;

          final flexColumns = r['flexColumns'] as List? ?? const [];
          final title = flexColumns.isNotEmpty
              ? (flexColumns[0]?['musicResponsiveListItemFlexColumnRenderer']
                          ?['text']?['runs']?[0]?['text'] ??
                      '')
                  .toString()
              : '';
          if (title.isEmpty) continue;

          final subRuns = flexColumns.length > 1
              ? (flexColumns[1]?['musicResponsiveListItemFlexColumnRenderer']
                      ?['text']?['runs'] as List? ??
                  const [])
              : const [];
          final artistRuns = subRuns.where((run) {
            final pageType = run?['navigationEndpoint']?['browseEndpoint']
                ?['browseEndpointContextSupportedConfigs']
                ?['browseEndpointContextMusicConfig']?['pageType'];
            return pageType == 'MUSIC_PAGE_TYPE_ARTIST';
          }).toList();
          final artistSource =
              artistRuns.isNotEmpty ? artistRuns : subRuns.take(1).toList();
          final artist = artistSource
              .map((r2) => (r2?['text'] ?? '').toString())
              .where((s) => s.isNotEmpty)
              .join(', ');

          final firstArtistChannelId = artistRuns.isNotEmpty
              ? (artistRuns.first?['navigationEndpoint']?['browseEndpoint']
                      ?['browseId'] ??
                  '')
                  .toString()
              : '';

          dynamic albumRun;
          for (final run in subRuns) {
            final pageType = run?['navigationEndpoint']?['browseEndpoint']
                ?['browseEndpointContextSupportedConfigs']
                ?['browseEndpointContextMusicConfig']?['pageType'];
            if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') { albumRun = run; break; }
          }
          final album = (albumRun?['text'] ?? '').toString();

          dynamic durationRun;
          for (final run in subRuns) {
            final t = (run?['text'] ?? '').toString();
            if (RegExp(r'^\d+:\d{2}$').hasMatch(t)) { durationRun = run; break; }
          }
          final durationText = (durationRun?['text'] ?? '').toString();
          int? durationSec;
          if (durationText.isNotEmpty) {
            final parts = durationText.split(':');
            if (parts.length == 2) {
              final mins = int.tryParse(parts[0]);
              final secs = int.tryParse(parts[1]);
              if (mins != null && secs != null) durationSec = mins * 60 + secs;
            }
          }

          final thumbs = r['thumbnail']?['musicThumbnailRenderer']
                  ?['thumbnail']?['thumbnails'] as List? ??
              const [];
          final best = thumbs.isNotEmpty ? thumbs.last : null;
          var thumbnail = (best?['url'] ?? '').toString();
          if (thumbnail.isNotEmpty) {
            thumbnail =
                thumbnail.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w544-h544');
          }

          out.add(Song(
            id: videoId.toString(),
            title: _cleanText(title),
            artist: _cleanText(artist, collapseJukeboxTitle: false).isNotEmpty
                ? _cleanText(artist, collapseJukeboxTitle: false)
                : 'Unknown',
            album: _cleanText(album),
            artworkUrl: thumbnail,
            streamUrl: null,
            duration: durationSec,
            source: SongSource.youtube,

            viewCount: 1000000,
            artistChannelId: firstArtistChannelId.isNotEmpty ? firstArtistChannelId : null,
          ));
          if (out.length >= limit) {
            return {'songs': out, 'continuation': nextContinuation};
          }
        }
      }
    } catch (e) {
      _log('[_parseYtMusicDirectSearchWithContinuation] parse error: $e');
    }
    return {'songs': out, 'continuation': nextContinuation};
  }

  static Future<List<Song>> _searchYtMusic(String query, int limit) async {

    if (_YtSearchHealth.isLikelyDown) return [];
    try {
      final uri = Uri.parse(
        '$_saavn/api/yt-music-search?query=${Uri.encodeComponent(query)}&limit=$limit',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) { _YtSearchHealth.markFailure(); return []; }
      final data = jsonDecode(resp.body);
      if (data['success'] != true) { _YtSearchHealth.markFailure(); return []; }
      final results = (data['data']?['results'] as List?) ?? [];
      final songs = results
          .map<Song>((r) {
            final rawArtist = _cleanText((r['artist'] ?? '').toString(), collapseJukeboxTitle: false);

            final rawArtistChannelId = (r['artistChannelId'] ?? '').toString();
            return Song(
              id: (r['videoId'] ?? '').toString(),
              title: _cleanText((r['title'] ?? '').toString()),

              artist: rawArtist.isNotEmpty ? rawArtist : 'Unknown',
              album: _cleanText((r['album'] ?? '').toString()),
              artworkUrl: _upgradeYtThumbnail((r['image'] ?? '').toString()),
              streamUrl: null,
              duration: r['duration'] is int ? r['duration'] as int : null,
              source: SongSource.youtube,
              artistChannelId: rawArtistChannelId.isNotEmpty ? rawArtistChannelId : null,

              viewCount: 1000000,
            );
          })
          .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
          .toList();
      if (songs.isNotEmpty) {
        _YtSearchHealth.markSuccess();
      }

      return songs;
    } catch (e) {
      _log('[_searchYtMusic] Error: $e');
      _YtSearchHealth.markFailure();
      return [];
    }
  }

  static Future<List<Video>> _searchYtPaged(String query, int limit) async {
    final seen = <String>{};
    final videos = <Video>[];
    try {
      var page = await _yt.search.search(query);
      for (final v in page) {
        if (seen.add(v.id.value)) videos.add(v);
      }
      var pagesFetched = 1;
      while (videos.length < limit * 2 && pagesFetched < 6) {
        final next = await page.nextPage();
        if (next == null || next.isEmpty) break;
        page = next;
        for (final v in page) {
          if (seen.add(v.id.value)) videos.add(v);
        }
        pagesFetched++;
      }
    } catch (e) {
      _log('[_searchYtPaged] Error: $e');
    }
    return videos;
  }

  static bool _isYtMixPlaylistId(String id) =>
      id.startsWith('RD') || id.startsWith('UL') || id.startsWith('LM');

  static String? _extractYtPlaylistId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    if (!trimmed.contains('://') && !trimmed.contains('.')) return trimmed;
    try {
      final uri = Uri.parse(trimmed);
      final listParam = uri.queryParameters['list'];
      if (listParam != null && listParam.isNotEmpty) return listParam;
    } catch (_) {

    }
    return null;
  }

  static Future<List<Video>> _fetchPlaylistVideosWithRetry(
      String playlistId, int limit) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final videos = await _yt.playlists
            .getVideos(playlistId)
            .take(limit)
            .toList()
            .timeout(const Duration(seconds: 20));
        return videos;
      } catch (e) {
        _log('[fetchYtPlaylistSongs] attempt ${attempt + 1} failed: $e');
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }
        rethrow;
      }
    }
    return const [];
  }

  static Future<List<HomeShelfItem>>? _seedArtistReleasesCache;

  static Future<List<HomeShelfItem>> _fetchSeedArtistReleases() {
    return _seedArtistReleasesCache ??= () async {
      try {
        final seedArtists = await _fetchYtMusicArtistsDirect(limit: 8);
        if (seedArtists.isEmpty) return const <HomeShelfItem>[];

        final browses = await Future.wait(seedArtists.map(
          (a) => _ytmBrowseRaw(a.channelId, timeout: const Duration(seconds: 6)),
        ));

        final out = <HomeShelfItem>[];
        final seenIds = <String>{};
        for (final decoded in browses) {
          if (decoded == null) continue;
          for (final carousel in _findRenderers(decoded, 'musicCarouselShelfRenderer')) {
            final headerTitleRuns = (carousel['header']
                        ?['musicCarouselShelfBasicHeaderRenderer']?['title']
                    ?['runs'] as List?) ??
                const [];
            final headerTitle = headerTitleRuns
                .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
                .join()
                .toLowerCase();
            if (!headerTitle.contains('album') && !headerTitle.contains('single')) {
              continue;
            }
            final cards = (carousel['contents'] as List?) ?? const [];
            for (final raw in cards) {
              if (raw is! Map<String, dynamic>) continue;
              final it = _parseHomeTwoRowItem(raw);
              if (it == null || it.artworkUrl.isEmpty) continue;
              if (it.pageType != 'MUSIC_PAGE_TYPE_ALBUM') continue;
              if (!seenIds.add(it.browseId)) continue;
              out.add(HomeShelfItem(
                browseId: it.browseId,
                title: it.title,
                subtitle: it.subtitle,
                artworkUrl: it.artworkUrl,
                isAlbum: true,
              ));
            }
          }
        }
        return out;
      } catch (e) {
        _log('[_fetchSeedArtistReleases] error: $e');
        return const <HomeShelfItem>[];
      }
    }();
  }

  static Future<List<YtHomePlaylistCard>> fetchYtMusicHomePlaylists({
    int limit = 8,
    String? mood,
    List<String>? excludeIds,
  }) async {
    final exclude = (excludeIds ?? const []).toSet();
    final realCards = <YtHomePlaylistCard>[];

    if (mood == null) {
      try {
        final realShelves = await fetchRealHomeShelves();

        var playlistItems = realShelves
            .expand((s) => s.items.where((it) => !it.isAlbum)
                .map((it) => (shelfTitle: s.title, item: it)))
            .toList();

        playlistItems.shuffle();

        const kMaxParallelCardFetches = 6;
        final candidateItems = playlistItems.take(limit).toList();
        for (var i = 0; i < candidateItems.length; i += kMaxParallelCardFetches) {
          final batch = candidateItems.skip(i).take(kMaxParallelCardFetches);
          final batchFutures = batch.map((entry) {
            final it = entry.item;
            return () async {
              try {

                final songs = <Song>[];
                final seenIds = <String>{};
                await _fetchFullTopSongsPlaylist(
                  it.browseId,
                  targetCount: 100,
                  fallbackArtistName: entry.shelfTitle,
                  resolvedChannelId: '',
                  topSongs: songs,
                  seenVideoIds: seenIds,
                  timeout: const Duration(seconds: 8),
                );
                final cleaned = songs.where((s) => s.id.isNotEmpty).toList();
                final fresh =
                    cleaned.where((s) => !exclude.contains(s.id)).toList();
                final finalSongs =
                    (fresh.length >= 10 ? fresh : cleaned).take(100).toList();
                if (finalSongs.length < 10) return null;
                return YtHomePlaylistCard(
                  id: 'realhome_${it.browseId}',
                  title: it.title,
                  subtitle: it.subtitle.isNotEmpty ? it.subtitle : entry.shelfTitle,
                  artworkUrl: it.artworkUrl,
                  songs: finalSongs,
                );
              } catch (_) {
                return null;
              }
            }();
          }).toList();
          final resolved = await Future.wait(batchFutures);
          realCards.addAll(resolved.whereType<YtHomePlaylistCard>());
          if (realCards.length >= limit) break;
        }

      } catch (_) {

      }
    }

    final remaining = limit - realCards.length;
    if (remaining <= 0) {
      if (realCards.isNotEmpty) {
        final shownIds = <String>[];
        for (final c in realCards) {
          shownIds.addAll(c.songs.map((s) => s.id));
        }
        unawaited(HomePlaylistHistory.recordShown(mood, shownIds));
      }
      return realCards.take(limit).toList();
    }

    final subQueries = _kMoodSubQueries[mood] ?? _kMoodSubQueries[null]!;

    const songsPerCard = 100;

    final isPodcastMood = mood == 'podcasts';

    final cardFutures = subQueries.take(remaining).map((sub) async {

      if (!isPodcastMood) {
        final real = await _realPlaylistCard(sub, mood, exclude, songsPerCard);
        if (real != null) return real;
      }
      final songs = await _raceSongSources(
        sub.query,
        limit: songsPerCard + exclude.length,
        isPodcastQuery: isPodcastMood,
      );
      final cleaned = songs.where((s) => s.id.isNotEmpty).toList();
      final fresh = cleaned.where((s) => !exclude.contains(s.id)).toList();
      final finalSongs = (fresh.length >= 10 ? fresh : cleaned).take(songsPerCard).toList();
      if (finalSongs.isEmpty) return null;
      return YtHomePlaylistCard(
        id: 'mood_${mood ?? "all"}_${sub.id}',
        title: sub.title,
        subtitle: 'Playlist',
        artworkUrl: finalSongs
            .firstWhere((s) => s.artworkUrl.isNotEmpty, orElse: () => finalSongs.first)
            .artworkUrl,
        songs: finalSongs,
      );
    });

    final results = await Future.wait(cardFutures);
    final fallbackCards = results.whereType<YtHomePlaylistCard>().toList();
    final cards = [...realCards, ...fallbackCards];

    if (cards.isNotEmpty) {
      final shownIds = <String>[];
      for (final c in cards) {
        shownIds.addAll(c.songs.map((s) => s.id));
      }
      unawaited(HomePlaylistHistory.recordShown(mood, shownIds));
    }

    return cards;
  }

  static Future<List<HomeAlbumCard>> fetchYtMusicHomeAlbums({
    int limit = 8,
    String? mood,
  }) async {

    final realCards = <HomeAlbumCard>[];
    if (mood == null) {
      try {
        final realShelves = await fetchRealHomeShelves();
        final albumItems = realShelves
            .expand((s) => s.items)
            .where((it) => it.isAlbum)
            .toList();

        albumItems.shuffle();
        final seenIds = <String>{};
        realCards.addAll(albumItems
            .where((it) => seenIds.add(it.browseId))
            .map((it) => HomeAlbumCard(
                  albumId: it.browseId,
                  title: it.title,

                  artist: it.subtitle.contains(' • ')
                      ? it.subtitle.split(' • ').last
                      : it.subtitle,
                  artworkUrl: it.artworkUrl,
                ))
            .take(limit));

      } catch (_) {

      }

      if (realCards.length < limit) {
        try {
          final seedReleases = await _fetchSeedArtistReleases();
          final existingIds = realCards.map((c) => c.albumId).toSet();
          final extra = seedReleases.where((it) => existingIds.add(it.browseId)).toList();
          extra.shuffle();
          realCards.addAll(extra.take(limit - realCards.length).map((it) => HomeAlbumCard(
                albumId: it.browseId,
                title: it.title,
                artist: it.subtitle.contains(' • ')
                    ? it.subtitle.split(' • ').last
                    : it.subtitle,
                artworkUrl: it.artworkUrl,
              )));
        } catch (_) {

        }
      }
    }

    final remaining = limit - realCards.length;
    if (remaining <= 0) return realCards.take(limit).toList();

    final subQueries = _kMoodSubQueries[mood] ?? _kMoodSubQueries[null]!;

    final cardFutures = subQueries.take(remaining).map((sub) async {
      final albums = await searchAlbumsYtOnly(sub.query, limit: 1);
      if (albums.isEmpty) return null;
      final a = albums.first;
      if (a.collectionId.isEmpty || a.name.isEmpty) return null;
      return HomeAlbumCard(
        albumId: a.collectionId,
        title: a.name,
        artist: a.artist,
        artworkUrl: a.artworkUrl,
      );
    });

    final results = await Future.wait(cardFutures);
    final fallbackCards = results.whereType<HomeAlbumCard>().toList();
    final cards = [...realCards, ...fallbackCards];

    final seenIds = <String>{};
    return cards.where((c) => seenIds.add(c.albumId)).toList();
  }

  static Future<YtHomePlaylistCard?> _realPlaylistCard(
    _MoodSubQuery sub,
    String? mood,
    Set<String> exclude,
    int songsPerCard,
  ) async {
    try {
      final candidates = await _searchRealPlaylists(sub.query, take: 5);
      if (candidates.isEmpty) return null;

      for (final candidate in candidates) {
        try {

          final songs = <Song>[];
          final seenIds = <String>{};
          await _fetchFullTopSongsPlaylist(
            candidate.id.startsWith('VL') ? candidate.id : 'VL${candidate.id}',
            targetCount: songsPerCard,
            fallbackArtistName: candidate.author,
            resolvedChannelId: '',
            topSongs: songs,
            seenVideoIds: seenIds,
            timeout: const Duration(seconds: 8),
          );
          final cleaned = songs.where((s) => s.id.isNotEmpty).toList();
          final fresh = cleaned.where((s) => !exclude.contains(s.id)).toList();
          final finalSongs =
              (fresh.length >= 10 ? fresh : cleaned).take(songsPerCard).toList();

          if (finalSongs.length < 10) continue;
          return YtHomePlaylistCard(
            id: 'realpl_${mood ?? "all"}_${sub.id}_${candidate.id}',
            title: sub.title,
            subtitle: candidate.author.isNotEmpty ? candidate.author : 'Playlist',
            artworkUrl: candidate.artworkUrl.isNotEmpty
                ? candidate.artworkUrl
                : finalSongs
                    .firstWhere((s) => s.artworkUrl.isNotEmpty,
                        orElse: () => finalSongs.first)
                    .artworkUrl,
            songs: finalSongs,
          );
        } catch (_) {

          continue;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static const int _kMinPlaylistVideoCount = 15;

  static Future<List<_RealPlaylistCandidate>> _searchRealPlaylists(
    String query, {
    int take = 5,
  }) async {

    try {
      final decoded = await _ytmSearchRaw(query, params: _ytmPlaylistsFilterParam,
          timeout: const Duration(seconds: 6));
      if (decoded == null) return const [];

      final candidates = <_RealPlaylistCandidate>[];
      for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
        final browseId = (item['navigationEndpoint']?['browseEndpoint']?['browseId'] ??
                item['overlay']?['musicItemThumbnailOverlayRenderer']?['content']
                        ?['musicPlayButtonRenderer']?['playNavigationEndpoint']
                    ?['watchPlaylistEndpoint']?['playlistId'] ??
                '')
            .toString();
        if (browseId.isEmpty) continue;

        if (_isYtMixPlaylistId(browseId)) continue;
        if (!browseId.startsWith('VL') && !browseId.startsWith('PL') &&
            !browseId.startsWith('OLAK5uy')) {
          continue;
        }

        final title = _flexColumnText(item, 0);
        if (title.isEmpty || RecommendationEngine.isLowQualityUpload(title)) continue;

        final thumbs = (item['thumbnail']?['musicThumbnailRenderer']?['thumbnail']
                    ?['thumbnails'] as List?) ??
            const [];
        final artworkUrl = thumbs.isNotEmpty
            ? _hqArtworkGeneric((thumbs.last['url'] ?? '').toString())
            : '';

        final subtitleRuns = ((item['flexColumns'] as List?)?.length ?? 0) > 1
            ? ((item['flexColumns'][1]?['musicResponsiveListItemFlexColumnRenderer']
                        ?['text']?['runs'] as List?) ??
                const [])
            : const [];
        final author = subtitleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .where((t) => t != ' • ' && t.trim().isNotEmpty)
            .lastWhere((_) => true, orElse: () => '');

        candidates.add(_RealPlaylistCandidate(
          id: browseId.startsWith('VL') ? browseId.substring(2) : browseId,
          title: _cleanHomeText(title),
          author: _cleanHomeText(author),
          artworkUrl: artworkUrl,
        ));
        if (candidates.length >= take) break;
      }
      return candidates;
    } catch (_) {

      return const [];
    }
  }

  static Future<List<SearchPlaylistResult>> searchPlaylists(
    String query, {
    int take = 15,
  }) async {
    if (query.trim().isEmpty) return const [];
    final candidates = await _searchRealPlaylists(query.trim(), take: take);
    return candidates
        .where((c) => c.title.isNotEmpty)
        .map((c) => SearchPlaylistResult(
              id: c.id,
              title: c.title,
              author: c.author,
              artworkUrl: c.artworkUrl,
            ))
        .toList();
  }

  static Future<List<Song>> _raceSongSources(
    String query, {
    required int limit,
    bool isPodcastQuery = false,
  }) async {
    final completer = Completer<List<Song>>();
    var pending = isPodcastQuery ? 2 : 3;

    void settle(List<Song> songs) {
      if (completer.isCompleted) return;
      if (songs.isNotEmpty) {
        completer.complete(songs);
      } else {
        pending--;
        if (pending == 0 && !completer.isCompleted) completer.complete(const []);
      }
    }

    unawaited(
      _searchYtMusic(query, limit)
          .timeout(const Duration(seconds: 6), onTimeout: () => const [])
          .then(settle, onError: (_) => settle(const [])),
    );
    unawaited(
      (isPodcastQuery
              ? _searchYtMusicDirectUnfiltered(query, limit)
              : _searchYtMusicDirect(query, limit))
          .timeout(const Duration(seconds: 6), onTimeout: () => const [])
          .then(settle, onError: (_) => settle(const [])),
    );
    if (!isPodcastQuery) {
      unawaited(

        _searchSaavn(query, limit: limit, allowMultiPage: false)
            .timeout(const Duration(seconds: 5), onTimeout: () => const [])
            .then(settle, onError: (_) => settle(const [])),
      );
    }

    return completer.future;
  }

  static const Map<String?, List<_MoodSubQuery>> _kMoodSubQueries = {
    null: [
      _MoodSubQuery('top_global', 'Top Songs Global', 'top hits global playlist'),
      _MoodSubQuery('trending_now', 'Trending Now', 'trending songs now'),
      _MoodSubQuery('top100_india', 'Top 100 India', 'top 100 India songs'),
      _MoodSubQuery('new_releases', 'New Releases', 'new song releases'),
      _MoodSubQuery('viral_hits', 'Viral Hits', 'viral hit songs'),
      _MoodSubQuery('feel_good', 'Feel Good Mix', 'feel good happy songs'),
    ],
    'bollywood': [
      _MoodSubQuery('bw_romance', 'Bollywood Romance', 'bollywood romantic songs'),
      _MoodSubQuery('bw_party', 'Bollywood Party', 'bollywood party dance songs'),
      _MoodSubQuery('bw_sad', 'Bollywood Sad', 'bollywood sad songs'),
      _MoodSubQuery('bw_classic', 'Bollywood Classics', 'bollywood classic old songs'),
      _MoodSubQuery('bw_new', 'New Bollywood', 'new bollywood songs'),
      _MoodSubQuery('bw_item', 'Bollywood Dance', 'bollywood item dance songs'),
    ],
    'nineties': [
      _MoodSubQuery('90s_bw', '90s Bollywood', '90s bollywood hits'),
      _MoodSubQuery('90s_romance', '90s Love Songs', '90s bollywood romantic songs'),
      _MoodSubQuery('90s_dance', '90s Dance Hits', '90s bollywood dance songs'),
      _MoodSubQuery('90s_sad', '90s Sad Songs', '90s bollywood sad songs'),
      _MoodSubQuery('90s_english', '90s English Hits', '90s english pop hits'),
      _MoodSubQuery('90s_rock', '90s Rock', '90s rock hits'),
    ],
    'trendingIndia': [
      _MoodSubQuery('trend_now', 'Trending Now', 'trending India songs now'),
      _MoodSubQuery('trend_viral', 'Viral in India', 'viral India songs'),
      _MoodSubQuery('trend_charts', 'India Charts', 'India top charts songs'),
      _MoodSubQuery('trend_new', 'New & Trending', 'new trending India songs'),
      _MoodSubQuery('trend_regional', 'Regional Hits', 'trending regional India songs'),
      _MoodSubQuery('trend_reels', 'Reels Trending', 'trending reels songs India'),
    ],
    'podcasts': [
      _MoodSubQuery('pod_top', 'Top Podcasts', 'popular podcast'),
      _MoodSubQuery('pod_comedy', 'Comedy', 'comedy podcast'),
      _MoodSubQuery('pod_news', 'News & Talk', 'news talk podcast'),
      _MoodSubQuery('pod_stories', 'True Stories', 'true crime podcast'),
      _MoodSubQuery('pod_business', 'Business', 'business podcast'),
      _MoodSubQuery('pod_hindi', 'Hindi Podcasts', 'hindi podcast'),
    ],
    'relax': [
      _MoodSubQuery('relax_chill', 'Chill Mix', 'chill relax songs'),
      _MoodSubQuery('relax_lofi', 'Lo-fi', 'lofi chill beats'),
      _MoodSubQuery('relax_acoustic', 'Acoustic', 'acoustic relax songs'),
      _MoodSubQuery('relax_piano', 'Piano Calm', 'calm piano instrumental'),
      _MoodSubQuery('relax_sleep', 'Sleep Sounds', 'sleep relaxing music'),
      _MoodSubQuery('relax_nature', 'Nature Sounds', 'nature ambient relax music'),
    ],
    'workout': [
      _MoodSubQuery('gym_pump', 'Gym Pump Up', 'gym workout pump up songs'),
      _MoodSubQuery('gym_cardio', 'Cardio Mix', 'cardio workout songs'),
      _MoodSubQuery('gym_hiit', 'HIIT Energy', 'hiit workout energy songs'),
      _MoodSubQuery('gym_running', 'Running Mix', 'running workout songs'),
      _MoodSubQuery('gym_strength', 'Strength Training', 'strength training gym songs'),
      _MoodSubQuery('gym_bollywood', 'Bollywood Workout', 'bollywood gym workout songs'),
    ],
    'energize': [
      _MoodSubQuery('energy_hype', 'Hype Mix', 'hype energetic songs'),
      _MoodSubQuery('energy_dance', 'Dance Energy', 'energetic dance songs'),
      _MoodSubQuery('energy_edm', 'EDM Boost', 'edm energetic songs'),
      _MoodSubQuery('energy_rock', 'Rock Energy', 'energetic rock songs'),
      _MoodSubQuery('energy_bollywood', 'Bollywood Energy', 'energetic bollywood songs'),
      _MoodSubQuery('energy_morning', 'Morning Boost', 'morning energy motivation songs'),
    ],
    'romantic': [
      _MoodSubQuery('rom_bollywood', 'Bollywood Romance', 'bollywood romantic love songs'),
      _MoodSubQuery('rom_english', 'English Love Songs', 'english romantic love songs'),
      _MoodSubQuery('rom_wedding', 'Wedding Romance', 'wedding romantic songs'),
      _MoodSubQuery('rom_slow', 'Slow Romance', 'slow romantic songs'),
      _MoodSubQuery('rom_duets', 'Love Duets', 'romantic duet songs'),
      _MoodSubQuery('rom_valentine', 'Valentine Mix', 'valentine love songs'),
    ],
    'party': [
      _MoodSubQuery('party_bollywood', 'Bollywood Party', 'bollywood party songs'),
      _MoodSubQuery('party_edm', 'EDM Party', 'edm party dance songs'),
      _MoodSubQuery('party_club', 'Club Hits', 'club dance hits'),
      _MoodSubQuery('party_wedding', 'Wedding Party', 'wedding party dance songs'),
      _MoodSubQuery('party_punjabi', 'Punjabi Party', 'punjabi party songs'),
      _MoodSubQuery('party_english', 'English Party', 'english party dance songs'),
    ],
    'focus': [
      _MoodSubQuery('focus_study', 'Study Focus', 'study focus concentration music'),
      _MoodSubQuery('focus_instrumental', 'Instrumental', 'instrumental focus music'),
      _MoodSubQuery('focus_lofi', 'Lo-fi Focus', 'lofi study focus beats'),
      _MoodSubQuery('focus_classical', 'Classical Focus', 'classical focus music'),
      _MoodSubQuery('focus_ambient', 'Ambient Focus', 'ambient focus concentration music'),
      _MoodSubQuery('focus_work', 'Deep Work', 'deep work focus music'),
    ],
    'sad': [
      _MoodSubQuery('sad_bollywood', 'Bollywood Sad', 'bollywood sad emotional songs'),
      _MoodSubQuery('sad_breakup', 'Breakup Songs', 'breakup sad songs'),
      _MoodSubQuery('sad_english', 'English Sad Songs', 'english sad emotional songs'),
      _MoodSubQuery('sad_slow', 'Slow Sad', 'slow sad emotional songs'),
      _MoodSubQuery('sad_heartbreak', 'Heartbreak Mix', 'heartbreak sad songs'),
      _MoodSubQuery('sad_alone', 'Lonely Nights', 'lonely sad night songs'),
    ],
  };

  static Future<List<Song>> fetchMixRefreshSongs({
    required String seed,
    required List<String> existingVideoIds,
    int limit = 15,
  }) async {
    if (seed.trim().isEmpty) return const [];
    final excludeSet = existingVideoIds.toSet();

    final completer = Completer<List<Song>>();
    var pending = 2;
    void settle(List<Song> songs) {
      if (completer.isCompleted) return;
      final fresh = songs.where((s) => !excludeSet.contains(s.id)).toList();
      if (fresh.isNotEmpty) {
        completer.complete(fresh);
      } else {
        pending--;
        if (pending == 0 && !completer.isCompleted) completer.complete(const []);
      }
    }

    unawaited(
      _fetchMixRefreshSongsViaWorker(seed: seed, existingVideoIds: existingVideoIds, limit: limit)
          .timeout(const Duration(seconds: 7), onTimeout: () => const [])
          .then(settle, onError: (_) => settle(const [])),
    );
    unawaited(
      _searchYtMusicDirect(seed, limit + excludeSet.length)
          .timeout(const Duration(seconds: 6), onTimeout: () => const [])
          .then(settle, onError: (_) => settle(const [])),
    );

    return completer.future;
  }

  static Future<List<Song>> _fetchMixRefreshSongsViaWorker({
    required String seed,
    required List<String> existingVideoIds,
    int limit = 15,
  }) async {
    try {
      final excludeParam = existingVideoIds.isEmpty
          ? ''
          : '&exclude=${Uri.encodeQueryComponent(existingVideoIds.join(','))}';
      final uri = Uri.parse(
        '$_saavn/api/mix-refresh?seed=${Uri.encodeComponent(seed)}&limit=$limit$excludeParam',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body);
      if (data['success'] != true) return const [];
      final results = (data['data']?['results'] as List?) ?? [];

      return results
          .map<Song>((r) {
            final rawArtist = _cleanText((r['artist'] ?? '').toString(), collapseJukeboxTitle: false);
            final rawArtistChannelId = (r['artistChannelId'] ?? '').toString();
            return Song(
              id: (r['videoId'] ?? '').toString(),
              title: _cleanText((r['title'] ?? '').toString()),
              artist: rawArtist.isNotEmpty ? rawArtist : 'Unknown',
              album: _cleanText((r['album'] ?? '').toString()),
              artworkUrl: _upgradeYtThumbnail((r['image'] ?? '').toString()),
              streamUrl: null,
              duration: r['duration'] is int ? r['duration'] as int : null,
              source: SongSource.youtube,
              viewCount: 1000000,
              artistChannelId: rawArtistChannelId.isNotEmpty ? rawArtistChannelId : null,
            );
          })
          .where((s) => s.id.isNotEmpty && s.title.isNotEmpty)
          .toList();
    } catch (e) {
      _log('[_fetchMixRefreshSongsViaWorker] error: $e');
      return const [];
    }
  }

  static Future<List<YtHomeArtist>> fetchYtMusicHomeArtists(
      {int limit = 12}) async {
    return _fetchYtMusicArtistsDirectExpanded(limit: limit);
  }

  static Future<List<YtHomeArtist>> _fetchYtMusicArtistsDirectExpanded(
      {int limit = 12}) async {
    const seedPool = [
      'Arijit Singh', 'Diljit Dosanjh', 'Shreya Ghoshal', 'Anirudh Ravichander',
      'Pritam', 'AP Dhillon', 'Sony Music India', 'T-Series',
      'Jubin Nautiyal', 'Neha Kakkar', 'Atif Aslam', 'Sonu Nigam',
      'Armaan Malik', 'Darshan Raval', 'B Praak', 'Vishal Mishra',
      'Badshah', 'Guru Randhawa', 'Hardy Sandhu', 'Jassie Gill',
      'Anuv Jain', 'Prateek Kuhad', 'Ritviz', 'A.R. Rahman',
      'Amit Trivedi', 'Shankar Mahadevan', 'Sunidhi Chauhan', 'Udit Narayan',
      'Kishore Kumar', 'Mohd Rafi', 'Lata Mangeshkar', 'Asha Bhosle',
      'Shaan', 'KK Singer', 'Alka Yagnik', 'Sachin-Jigar',
    ];
    final rng = math.Random(DateTime.now().difference(DateTime(2026, 1, 1)).inHours);
    final seeds = (List<String>.from(seedPool)..shuffle(rng))
        .take(math.min(seedPool.length, limit + 8))
        .toList();
    return _resolveAndBrowseArtistSeeds(seeds, limit: limit, debugTag: 'direct-expanded');
  }

  static Future<List<YtHomeArtist>> _fetchYtMusicArtistsDirect(
      {int limit = 12}) async {
    const seeds = [
      'Arijit Singh',
      'Diljit Dosanjh',
      'Sony Music India',
      'T-Series',
      'Shreya Ghoshal',
      'Anirudh Ravichander',
      'Pritam',
      'AP Dhillon',
    ];

    try {

      final searchResponses = await Future.wait(seeds.map(
        (q) => _ytmSearchRaw(q, params: _ytmSongsFilterParam,
            timeout: const Duration(seconds: 4)),
      ));

      final seen = <String>{};
      final resolved = <({String channelId, String name})>[];
      for (final json in searchResponses) {
        if (json == null) continue;

        var foundForThisSeed = false;
        for (final item in _findRenderers(json, 'musicResponsiveListItemRenderer')) {
          for (final run in _artistRunsInSubtitle(item)) {
            if (!seen.add(run.channelId)) continue;
            resolved.add((channelId: run.channelId, name: _cleanText(run.name)));
            foundForThisSeed = true;
            break;
          }
          if (foundForThisSeed) break;
        }
        if (resolved.length >= limit) break;
      }

      final browseResponses = await Future.wait(resolved.map(
        (r) => _ytmBrowseRaw(r.channelId, timeout: const Duration(seconds: 6)),
      ));

      final out = <YtHomeArtist>[];
      for (var i = 0; i < resolved.length; i++) {
        final data = browseResponses[i];
        if (data == null) continue;
        final header = data['header'];
        final headerRenderer = header is Map
            ? (header['musicImmersiveHeaderRenderer'] ??
                header['musicVisualHeaderRenderer'] ??
                header['musicHeaderRenderer'])
            : null;
        if (headerRenderer is! Map) continue;

        final thumbs = (headerRenderer['thumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            (headerRenderer['foregroundThumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            const [];
        if (thumbs.isEmpty) continue;
        final rawUrl = (thumbs.last['url'] ?? '').toString();
        if (rawUrl.isEmpty) continue;
        final imageUrl = rawUrl.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w500-h500-p');

        final headerNameRuns = (headerRenderer['title']?['runs'] as List?) ?? const [];
        final headerName = headerNameRuns.isNotEmpty
            ? _cleanText(headerNameRuns
                    .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
                    .join())
                .replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), '')
                .trim()
            : '';

        out.add(YtHomeArtist(
          channelId: resolved[i].channelId,
          name: headerName.isNotEmpty ? headerName : resolved[i].name,
          imageUrl: imageUrl,
        ));
        if (out.length >= limit) break;
      }
      return out;
    } catch (e) {
      _log('[_fetchYtMusicArtistsDirect] error: $e');
      return const [];
    }
  }

  static Future<List<YtHomeArtist>> _resolveAndBrowseArtistSeeds(
    List<String> seeds, {
    required int limit,
    required String debugTag,
  }) async {
    try {

      final searchResponses = await Future.wait(seeds.map(
        (q) => _ytmSearchRaw(q, params: _ytmSongsFilterParam,
            timeout: const Duration(seconds: 4)),
      ));

      final seen = <String>{};
      final resolved = <({String channelId, String name})>[];
      for (final json in searchResponses) {
        if (json == null) continue;

        var foundForThisSeed = false;
        for (final item in _findRenderers(json, 'musicResponsiveListItemRenderer')) {
          for (final run in _artistRunsInSubtitle(item)) {
            if (!seen.add(run.channelId)) continue;
            resolved.add((channelId: run.channelId, name: _cleanText(run.name)));
            foundForThisSeed = true;
            break;
          }
          if (foundForThisSeed) break;
        }
        if (resolved.length >= limit) break;
      }

      final browseResponses = await Future.wait(resolved.map(
        (r) => _ytmBrowseRaw(r.channelId, timeout: const Duration(seconds: 6)),
      ));

      final out = <YtHomeArtist>[];
      for (var i = 0; i < resolved.length; i++) {
        final data = browseResponses[i];
        if (data == null) continue;
        final header = data['header'];
        final headerRenderer = header is Map
            ? (header['musicImmersiveHeaderRenderer'] ??
                header['musicVisualHeaderRenderer'] ??
                header['musicHeaderRenderer'])
            : null;
        if (headerRenderer is! Map) continue;

        final thumbs = (headerRenderer['thumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            (headerRenderer['foregroundThumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            const [];
        if (thumbs.isEmpty) continue;
        final rawUrl = (thumbs.last['url'] ?? '').toString();
        if (rawUrl.isEmpty) continue;
        final imageUrl = rawUrl.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w500-h500-p');

        final headerNameRuns = (headerRenderer['title']?['runs'] as List?) ?? const [];
        final headerName = headerNameRuns.isNotEmpty
            ? _cleanText(headerNameRuns
                    .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
                    .join())
                .replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), '')
                .trim()
            : '';

        out.add(YtHomeArtist(
          channelId: resolved[i].channelId,
          name: headerName.isNotEmpty ? headerName : resolved[i].name,
          imageUrl: imageUrl,
        ));
        if (out.length >= limit) break;
      }
      lastArtistFetchDebug =
          '$debugTag: ${seeds.length} seeds -> resolved=${resolved.length} -> out=${out.length}';
      return out;
    } catch (e) {
      lastArtistFetchDebug = '$debugTag threw: $e';
      _log('[_resolveAndBrowseArtistSeeds/$debugTag] error: $e');
      return const [];
    }
  }

  static Future<List<Song>> fetchYtPlaylistSongs(String playlistUrlOrId,
      {int limit = 200}) async {
    final playlistId = _extractYtPlaylistId(playlistUrlOrId);
    if (playlistId == null || playlistId.isEmpty) {
      throw const YtPlaylistImportException(YtPlaylistImportError.invalidLink);
    }
    if (_isYtMixPlaylistId(playlistId)) {
      throw const YtPlaylistImportException(YtPlaylistImportError.isMix);
    }

    final completer = Completer<List<Song>>();
    var pending = 2;
    Object? lastError;

    void settleIfBest(List<Song> songs, String source, {Object? error}) {
      if (completer.isCompleted) return;
      if (songs.isNotEmpty) {
        _log('[fetchYtPlaylistSongs] winner: $source (${songs.length})');
        completer.complete(songs);
      } else {
        if (error != null) lastError = error;
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          completer.complete(const []);
        }
      }
    }

    unawaited(
      _fetchYtPlaylistViaWorker(playlistId, limit)
          .timeout(const Duration(seconds: 8), onTimeout: () => null)
          .then(
        (result) => settleIfBest(result ?? const [], 'worker'),
        onError: (e) {
          _log('[fetchYtPlaylistSongs] worker path error: $e');
          settleIfBest(const [], 'worker', error: e);
        },
      ),
    );

    unawaited(
      _fetchPlaylistVideosWithRetry(playlistId, limit)
          .timeout(const Duration(seconds: 12), onTimeout: () => const [])
          .then(
        (videos) => settleIfBest(
            videos.map(_songFromYtVideo).toList(), 'explode_dart'),
        onError: (e) {
          _log('[fetchYtPlaylistSongs] explode_dart path error: $e');
          settleIfBest(const [], 'explode_dart', error: e);
        },
      ),
    );

    final result = await completer.future;
    if (result.isEmpty) {

      if (lastError is YtPlaylistImportException) throw lastError!;
      throw const YtPlaylistImportException(YtPlaylistImportError.notFound);
    }
    return _dedupAndFilterPlaylistSongs(result);
  }

  static Future<List<Song>?> _fetchYtPlaylistViaWorker(
      String playlistId, int limit) async {
    try {
      final uri = Uri.parse(
        '$_saavn/api/yt-playlist?id=${Uri.encodeComponent(playlistId)}&limit=$limit',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 404) {

        throw const YtPlaylistImportException(YtPlaylistImportError.empty);
      }
      if (resp.statusCode != 200) {
        _log('[fetchYtPlaylistSongs] worker route HTTP ${resp.statusCode}');
        return null;
      }

      final data = await compute(jsonDecode, resp.body);
      if (data['success'] != true) return null;
      final results = (data['data']?['results'] as List?) ?? [];
      if (results.isEmpty) return null;
      return results.map<Song>((r) {
        final rawArtist = _cleanText((r['artist'] ?? '').toString(), collapseJukeboxTitle: false);
        return Song(
          id: (r['videoId'] ?? '').toString(),
          title: _cleanText((r['title'] ?? '').toString()),
          artist: rawArtist.isNotEmpty ? rawArtist : 'Unknown',
          album: _cleanText((r['album'] ?? '').toString()),
          artworkUrl: _upgradeYtThumbnail((r['image'] ?? '').toString()),
          streamUrl: null,
          duration: r['duration'] is int ? r['duration'] as int : null,
          source: SongSource.youtube,
          viewCount: null,
        );
      }).toList();
    } on YtPlaylistImportException {
      rethrow;
    } catch (e) {
      _log('[fetchYtPlaylistSongs] worker route error: $e');
      return null;
    }
  }

  static List<Song> _dedupAndFilterPlaylistSongs(List<Song> songs) {
    final seenIds = <String>{};
    final seenTitles = <String>{};
    final result = <Song>[];
    for (final s in songs) {
      if (s.id.isEmpty || s.title.isEmpty) continue;
      if (!seenIds.add(s.id)) continue;
      if (RecommendationEngine.isLowQualityUpload(s.title)) continue;
      if (RecommendationEngine.isNonMusicContent(s)) continue;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) continue;
      result.add(s);
    }

    if (result.isEmpty) {

      throw const YtPlaylistImportException(YtPlaylistImportError.empty);
    }
    return result;
  }

  static Future<SongSection?> _ytSectionV1(String query, String label) async {

    final variants = <String>{
      query,
      '$query audio',
      '$query official',
      '$query lyrics',
      '$query hd songs',
    };
    final results = await Future.wait(
      variants.map((q) => _searchYt(q, limit: 60)),
    );

    final deepVideos = await _searchYtPaged(query, 100).catchError((_) => <Video>[]);
    final deepSongs = deepVideos.map(_songFromYtVideo).toList();

    final seenIdsRaw = <String>{};
    final ytSongs = <Song>[];
    for (final list in [...results, deepSongs]) {
      for (final s in list) {
        if (seenIdsRaw.add(s.id)) ytSongs.add(s);
      }
    }
    if (ytSongs.isEmpty) return null;
    final seenIds = <String>{};
    final seenTitles = <String>{};
    final merged = <Song>[];
    for (final s in ytSongs) {
      if (merged.length >= _kHomeSectionTarget) break;
      if (!seenIds.add(s.id)) continue;
      if (RecommendationEngine.isInherentVariant(s.title)) continue;
      if (RecommendationEngine.isLowQualityUpload(s.title)) continue;
      if (!RecommendationEngine.isPremiumQuality(s)) continue;
      final tk = _normTitle(s.title);
      if (!seenTitles.add(tk)) continue;
      merged.add(s);
    }
    if (merged.isEmpty) return null;
    return SongSection(title: label, songs: merged);
  }

  static Song _songFromYtVideo(Video v) => Song(
        id:         v.id.value,
        title:      _cleanText(v.title),
        artist:     _cleanText(v.author, collapseJukeboxTitle: false),
        album:      '',
        artworkUrl: _bestThumbnail(v.thumbnails),
        streamUrl:  null,
        duration:   v.duration?.inSeconds,
        source:     SongSource.youtube,
        viewCount:  _safeViewCount(v),
      );

  static int? _safeViewCount(Video v) {
    try {
      return v.engagement.viewCount;
    } catch (_) {
      return null;
    }
  }

  static String _bestThumbnail(dynamic t) {
    for (final url in [t.highResUrl, t.mediumResUrl, t.lowResUrl]) {
      if (url != null && url.toString().isNotEmpty) return url.toString();
    }
    return '';
  }

  static String _upgradeYtThumbnail(String url) {
    if (url.isEmpty) return url;
    return url.replaceAll(RegExp(r'=w\d+-h\d+.*$'), '=w544-h544');
  }

  static int _anonymousResolveCounter = 0;

  static Future<bool> _isUrlAlive(String url) async {
    Future<bool> attempt(Duration timeout) async {
      try {
        final uri = Uri.parse(url);
        final head = await _client.head(uri).timeout(timeout);
        if (head.statusCode >= 200 && head.statusCode < 400) return true;
        if (head.statusCode == 405 || head.statusCode == 403) {

          final ranged = await _client
              .get(uri, headers: {'Range': 'bytes=0-255'})
              .timeout(timeout);
          return ranged.statusCode == 200 || ranged.statusCode == 206;
        }
        return false;
      } catch (_) {
        return false;
      }
    }

    if (await attempt(const Duration(seconds: 3))) return true;

    return attempt(const Duration(seconds: 5));
  }

  static Future<String?> resolveStreamUrl(Song song, {bool forceRefresh = false}) async {
    if (song.isLocal) return song.localPath;

    final hasStableId = song.id.isNotEmpty;
    final cacheKey = hasStableId
        ? '${song.source.name}:${song.id}'
        : '${song.source.name}:anon:${song.title}:${song.artist}:${_anonymousResolveCounter++}';

    if (!forceRefresh && hasStableId) {
      final cachedUrl = _streamCache.get(cacheKey);
      if (cachedUrl != null) {
        _log('[resolve] Cache HIT: "${song.title}"');
        return cachedUrl;
      }
    }

    if (!forceRefresh && hasStableId && _pendingResolutions.containsKey(cacheKey)) {
      _log('[resolve] Joining in-flight: "$cacheKey"');
      return _pendingResolutions[cacheKey];
    }

    if (!forceRefresh &&
        hasStableId &&
        song.source == SongSource.saavn &&
        song.streamUrl != null &&
        song.streamUrl!.contains('/stream-proxy?url=')) {
      final cachedUrl = _streamCache.get(cacheKey);
      if (cachedUrl == null) {
        _log('[resolve] Pre-fetched Saavn URL (proxied): "${song.title}"');
        _writeStreamCache(cacheKey, song.streamUrl!);
        return song.streamUrl;
      }
      return cachedUrl;
    }

    _log('[resolve] Resolving "${song.title}" source=${song.source.name}');
    final resolutionFuture = _doResolve(song, cacheKey);
    _pendingResolutions[cacheKey] = resolutionFuture;
    try {
      return await resolutionFuture;
    } finally {
      _pendingResolutions.remove(cacheKey);
    }
  }

  static Future<String?> _doResolve(Song song, String cacheKey) async {
    String? url;
    switch (song.source) {
      case SongSource.saavn:
        if (song.id.isNotEmpty) {
          url = await _retry(
            () => _saavnStreamById(song.id, title: song.title, artist: song.artist),
            attempts: 2,
          );
          if (url != null && !await _isUrlAlive(url)) {

            _log('[resolve] Saavn URL for "${song.title}" failed liveness check — one bounded retry before YT');
            url = await () async {
              final retryUrl = await _saavnStreamById(song.id, title: song.title, artist: song.artist);
              if (retryUrl != null && await _isUrlAlive(retryUrl)) return retryUrl;
              return null;
            }().timeout(const Duration(seconds: 6), onTimeout: () => null);
            _log('[resolve] Saavn bounded retry for "${song.title}": ${url != null ? "OK" : "FAILED"}');
          }
          _log('[resolve] Saavn by ID "${song.title}": ${url != null ? "OK" : "FAILED"}');
        }
        if (url == null) {
          _log('[resolve] Saavn fallback → YT search for "${song.title} ${song.artist}"');
          url = await _ytStreamFull('${song.title} ${song.artist}');
        }
        break;

      case SongSource.youtube:
        if (song.id.isNotEmpty) {
          url = await _ytStreamById(song.id);

          _log('[resolve] YT "${song.id}": ${url != null ? "OK" : "FAILED"}');
        }
        if (url == null) {
          _log('[resolve] YT by-ID failed → search "${song.title} ${song.artist}"');
          url = await _ytStreamFull('${song.title} ${song.artist}');
        }
        break;

      case SongSource.local:
        return song.localPath;
    }

    if (url != null) {
      _writeStreamCache(cacheKey, url);
      _log('[resolve] SUCCESS "${song.title}"');
    } else {
      _log('[resolve] FAILED all sources "${song.title}"');
    }
    return url;
  }

  static Future<String?> _ytStreamById(String videoId) async {
    if (_WorkerHealth.maintenanceMode) {
      _log('[ytStreamById] Worker maintenance mode active — skipping resolve for $videoId');
      return null;
    }
    final url = await _workerYtStream(videoId);
    if (url == null) {
      _log('[ytStreamById] Worker unreachable for $videoId — this means the '
          'Cloudflare Worker itself is down. Check the Worker deployment.');
    }
    return url;
  }

  static Future<String?> _blastRace(List<Future<String?> Function()> fns) async {
    if (fns.isEmpty) return null;
    final completer = Completer<String?>();
    var remaining = fns.length;

    for (final fn in fns) {
      fn().then((url) {
        remaining--;
        if (completer.isCompleted) return;
        if (url != null && url.isNotEmpty) {
          completer.complete(url);
        } else if (remaining == 0) {
          completer.complete(null);
        }
      }).catchError((_) {
        remaining--;
        if (!completer.isCompleted && remaining == 0) completer.complete(null);
      });
    }

    return completer.future;
  }

  static Future<String?> _ytStreamFull(String query) async {
    try {
      final results = await Future.any<List<dynamic>>([
        _yt.search.search(query).then((list) => list.toList()),
        Future.delayed(const Duration(seconds: 8), () => <dynamic>[]),
      ]);
      final videos = results.whereType<Video>().toList();
      if (videos.isEmpty) return null;
      return _ytStreamById(videos.first.id.value);
    } catch (e) {
      _log('[ytStreamFull] Error: $e');
    }
    return null;
  }

  static Future<String?> _workerYtStream(String videoId) async {
    const routeTimeout = Duration(seconds: 16);

    Future<String?> tryProxy() async {
      try {
        final proxyUrl = '$_worker/api/yt-proxy?id=$videoId';
        final probe = await _client
            .get(Uri.parse(proxyUrl), headers: {'Range': 'bytes=0-255'})
            .timeout(routeTimeout);
        if (probe.statusCode == 200 || probe.statusCode == 206) {
          final ct = (probe.headers['content-type'] ?? '').toLowerCase();
          final looksAudio = ct.contains('audio') || ct.contains('octet') ||
              ct.contains('mp4') || ct.contains('mpeg') || ct.contains('webm');
          if (looksAudio || probe.bodyBytes.length > 128) {
            _log('[worker] /api/yt-proxy OK for $videoId (IP-safe path)');
            return proxyUrl;
          }
        }
        _log('[worker] /api/yt-proxy probe failed for $videoId '
            '(status=${probe.statusCode})');
        return null;
      } catch (e) {
        _log('[worker] /api/yt-proxy failed for $videoId: $e');
        DiagnosticLogService.logNetworkError('yt-proxy', 'videoId=$videoId error=$e');
        return null;
      }
    }

    Future<String?> tryDirect() async {
      try {
        final res = await _client
            .get(Uri.parse('$_worker/api/yt-stream?id=$videoId'))
            .timeout(routeTimeout);
        if (res.statusCode != 200) {
          _log('[worker] /api/yt-stream ${res.statusCode} for $videoId');
          return null;
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['success'] != true) {
          _log('[worker] /api/yt-stream success=false for $videoId');
          return null;
        }
        final url = data['url']?.toString();
        if (url == null || url.isEmpty) {
          _log('[worker] /api/yt-stream empty URL for $videoId');
          return null;
        }

        final directOk = await _isUrlAlive(url);
        if (!directOk) {
          _log('[worker] /api/yt-stream URL for $videoId failed device-side '
              'liveness check (IP-lock mismatch) - discarding direct URL');
          return null;
        }
        _log('[worker] /api/yt-stream OK for $videoId '
            '(${data["source"]} ${data["quality"]}) - direct path, verified');
        return url;
      } catch (e) {
        _log('[worker] /api/yt-stream failed for $videoId: $e');
        DiagnosticLogService.logNetworkError('yt-stream', 'videoId=$videoId error=$e');
        return null;
      }
    }

    final result = await _blastRace([tryProxy, tryDirect]);
    if (result != null) {
      _WorkerHealth.markAlive();
    } else {
      _WorkerHealth.markDead();
    }
    return result;
  }

  static Future<String?> _pipedStream(String videoId, String instance) async {
    try {
      final uri = Uri.parse('$instance/streams/$videoId');
      final res = await _client.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0',
      }).timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final streams = data['audioStreams'] as List?;
        if (streams == null || streams.isEmpty) return null;

        final m4a = streams.where((s) {
          final mime = (s['mimeType'] ?? '').toString().toLowerCase();
          return mime.contains('mp4') || mime.contains('m4a');
        }).toList();

        final pool = m4a.isNotEmpty ? m4a : streams;
        pool.sort((a, b) {
          final bA = (a['bitrate'] as num? ?? 0).toInt();
          final bB = (b['bitrate'] as num? ?? 0).toInt();
          return bB.compareTo(bA);
        });

        final url = pool.first['url']?.toString();
        if (url != null && url.startsWith('http')) {
          _log('[piped] OK $instance for $videoId');
          return url;
        }
      }
    } catch (e) {
      _log('[piped] $instance error: $e');
    }
    return null;
  }

  static Future<String?> _saavnStreamById(
    String songId, {
    String title = '',
    String artist = '',
    List<String>? qualityOrder,
  }) async {

    Future<String?> tryNodeHostById(String host) async {
      try {
        final url = Uri.parse('$host/api/songs/$songId');
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final raw = jsonDecode(res.body);
          if (raw is Map<String, dynamic> && raw['success'] == true) {
            final data = raw['data'];
            Map<String, dynamic>? songData;
            if (data is List && data.isNotEmpty) {
              songData = data.first as Map<String, dynamic>?;
            } else if (data is Map<String, dynamic>) {
              songData = data;
            }
            if (songData != null) {
              return _extractSaavnStreamUrl(songData, qualityOrder: qualityOrder);
            }
          }
        }
      } catch (e) {
        _log('[saavnById] $host error for $songId: $e');
      }
      return null;
    }

    final nodeFutures = [for (final host in _saavnNodeHosts) tryNodeHostById(host)];
    final nodeCompleter = Completer<String?>();
    var nodeRemaining = nodeFutures.length;
    void onNodeDone(String? r) {
      if (nodeCompleter.isCompleted) return;
      if (r != null && r.isNotEmpty) {
        nodeCompleter.complete(r);
        return;
      }
      nodeRemaining--;
      if (nodeRemaining == 0 && !nodeCompleter.isCompleted) {
        nodeCompleter.complete(null);
      }
    }
    for (final f in nodeFutures) {
      f.then(onNodeDone).catchError((_) => onNodeDone(null));
    }
    final nodeResult = await nodeCompleter.future;
    if (nodeResult != null) return nodeResult;

    if (title.isEmpty) return null;
    final q = artist.isNotEmpty ? '$title $artist' : title;

    Future<String?> tryResultRouteById(String base) async {
      try {
        final url = Uri.parse(
          '$base/result/?query=${Uri.encodeQueryComponent(q)}&limit=10',
        );
        final res = await _client.get(url).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final results = data is List
              ? data
              : (data['data']?['results'] ?? data['data'] ?? []);
          if (results is List && results.isNotEmpty) {
            final list = results.whereType<Map<String, dynamic>>().toList();
            final match = list.firstWhere(
              (j) => (j['id'] ?? '').toString() == songId,
              orElse: () => list.first,
            );
            return _onrenderStreamUrl(match, qualityOrder: qualityOrder) ??
                _extractSaavnStreamUrl(match, qualityOrder: qualityOrder);
          }
        }
      } catch (e) {
        _log('[saavnById] $base error for $songId: $e');
      }
      return null;
    }

    final fallbackFutures = [
      for (final base in [_saavnPrimary, _saavnSecondary, _saavn])
        tryResultRouteById(base),
    ];
    final fallbackCompleter = Completer<String?>();
    var fallbackRemaining = fallbackFutures.length;
    void onFallbackDone(String? r) {
      if (fallbackCompleter.isCompleted) return;
      if (r != null && r.isNotEmpty) {
        fallbackCompleter.complete(r);
        return;
      }
      fallbackRemaining--;
      if (fallbackRemaining == 0 && !fallbackCompleter.isCompleted) {
        fallbackCompleter.complete(null);
      }
    }
    for (final f in fallbackFutures) {
      f.then(onFallbackDone).catchError((_) => onFallbackDone(null));
    }
    return fallbackCompleter.future;
  }

  static String? _onrenderStreamUrl(Map<String, dynamic> j, {List<String>? qualityOrder}) {

    if (qualityOrder != null) {
      final viaLadder = _extractSaavnStreamUrl(j, qualityOrder: qualityOrder);
      if (viaLadder != null) return viaLadder;
    }
    final url320   = (j['320kbps'] ?? '').toString();
    if (url320.startsWith('http')) {
      AudioPrefs.lastResolvedKbps = 320;
      return _proxiedSaavnUrl(url320);
    }
    final urlMedia = (j['media_url'] ?? '').toString();
    if (urlMedia.startsWith('http')) {
      AudioPrefs.lastResolvedKbps = null;
      return _proxiedSaavnUrl(urlMedia);
    }

    return _extractSaavnStreamUrl(j, qualityOrder: qualityOrder);
  }

  static String? _extractSaavnStreamUrl(Map<String, dynamic> song, {List<String>? qualityOrder}) {
    final downloads = song['downloadUrl'] as List?;
    if (downloads != null && downloads.isNotEmpty) {
      for (final q in qualityOrder ?? AudioPrefs.qualityOrder()) {
        final match = downloads.firstWhere(
          (d) => d is Map && d['quality'] == q &&
                 (d['url'] as String?)?.startsWith('http') == true,
          orElse: () => null,
        );
        if (match != null) {
          AudioPrefs.lastResolvedKbps = int.tryParse(q.replaceAll(RegExp(r'[^0-9]'), ''));
          return _proxiedSaavnUrl(match['url'] as String);
        }
      }

      final withKbps = downloads
          .whereType<Map>()
          .where((d) => (d['url'] as String?)?.startsWith('http') == true)
          .map((d) => (
                kbps: int.tryParse((d['quality'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '')) ?? -1,
                url: d['url'] as String,
              ))
          .where((e) => e.kbps >= 0)
          .toList();
      if (withKbps.isNotEmpty) {
        withKbps.sort((a, b) => b.kbps.compareTo(a.kbps));
        final best = withKbps.first;
        AudioPrefs.lastResolvedKbps = best.kbps;
        return _proxiedSaavnUrl(best.url);
      }
    }
    final su = song['media_url'] ?? song['streamUrl'];
    if (su is String && su.startsWith('http')) {
      AudioPrefs.lastResolvedKbps = null;
      return _proxiedSaavnUrl(su);
    }
    return null;
  }

  static Future<String?> _raceFirstValid(List<Future<String?> Function()> fns) async {
    final completer = Completer<String?>();
    var remaining = fns.length;
    void onDone(String? value) {
      remaining--;
      if (completer.isCompleted) return;
      if (value != null && value.isNotEmpty) completer.complete(value);
      else if (remaining == 0) completer.complete(null);
    }
    for (final fn in fns) fn().then(onDone).catchError((_) => onDone(null));
    return completer.future;
  }

  static Future<String?> _retry(
    Future<String?> Function() fn, {
    int attempts = 3,
    Duration baseDelay = const Duration(milliseconds: 300),
  }) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final result = await fn();
        if (result != null && result.isNotEmpty) return result;
      } catch (e) {
        _log('[retry] Attempt ${i + 1}/$attempts failed: $e');
      }
      if (i < attempts - 1) await Future.delayed(baseDelay * (1 << i));
    }
    return null;
  }

  static void _writeStreamCache(String key, String url) {

    _streamCache.set(key, url);
  }

  static void invalidateStream(Song song) {
    _streamCache.invalidate('${song.source.name}:${song.id}');
  }

  static void clearExpiredCache() {
    _streamCache.cleanup();
    _searchCache.removeWhere((_, v) => v.isExpired);
    _quickSearchCache.removeWhere((_, v) => v.isExpired);
  }

  static void _writeSearchCache(String key, SearchResult results) {
    if (_searchCache.length >= _maxSearchCache) {
      final expiredKeys = _searchCache.entries
          .where((e) => e.value.isExpired).map((e) => e.key).toList();
      for (final k in expiredKeys) _searchCache.remove(k);
      if (_searchCache.length >= _maxSearchCache) {
        final oldest = _searchCache.entries.reduce(
          (a, b) => a.value.cachedAt.isBefore(b.value.cachedAt) ? a : b,
        );
        _searchCache.remove(oldest.key);
      }
    }
    _searchCache[key] = _CachedSearch(results);
  }

  static Future<void> onNetworkRestored({Song? currentSong}) async {
    _streamCache.removeWhere((_, v) => v.isExpired);
    if (currentSong != null && !currentSong.isLocal) {
      try { await resolveStreamUrl(currentSong, forceRefresh: true); } catch (_) {}
    }
  }

  static void prefetchNext(Song song) {
    if (song.isLocal) return;
    _activePrefetch?.cancel();
    _activePrefetch = null;
    _activePrefetch = CancelableOperation.fromFuture(
      Future.delayed(const Duration(milliseconds: 500), () async {
        try { await resolveStreamUrl(song); } catch (_) {}
      }),
    );
  }

  static void prefetchQueue(List<Song> upcoming, {int count = 5}) {

    for (final op in _prefetchQueue) op.cancel();
    _prefetchQueue.clear();

    final toFetch = upcoming
        .where((s) => !s.isLocal && s.id.isNotEmpty)
        .take(count)
        .toList();

    for (int i = 0; i < toFetch.length; i++) {
      final song = toFetch[i];

      final delay = Duration(milliseconds: 300 + (i * 400));
      final op = CancelableOperation.fromFuture(
        Future.delayed(delay, () async {

          final cacheKey = '${song.source.name}:${song.id}';
          if (_streamCache.get(cacheKey) != null) {
            _log('[prefetch] Already cached: "${song.title}"');
            return;
          }
          _log('[prefetch] Pre-resolving #$i: "${song.title}"');
          try {
            await resolveStreamUrl(song);
            _log('[prefetch] ✓ Ready: "${song.title}"');
          } catch (e) {
            _log('[prefetch] Failed: "${song.title}": $e');
          }
        }),
      );
      _prefetchQueue.add(op);
    }
  }

  static void cancelPrefetch() {
    _activePrefetch?.cancel();
    _activePrefetch = null;
    for (final op in _prefetchQueue) op.cancel();
    _prefetchQueue.clear();
  }

  static final Set<String> _prewarmedIds = {};

  static int _prewarmInFlight = 0;
  static const int _maxPrewarmConcurrency = 2;
  static final List<Song> _prewarmQueue = [];

  static void prewarmYtStream(Song song) {
    if (song.source != SongSource.youtube) return;
    if (song.id.isEmpty) return;
    if (_prewarmedIds.contains(song.id)) return;

    final cacheKey = 'youtube:${song.id}';
    if (_streamCache.get(cacheKey) != null) return;

    if (_prewarmedIds.length > 1000) _prewarmedIds.clear();
    _prewarmedIds.add(song.id);

    if (_prewarmInFlight >= _maxPrewarmConcurrency) {
      _prewarmQueue.add(song);
      return;
    }
    _runPrewarm(song);
  }

  static void _runPrewarm(Song song) {
    _prewarmInFlight++;
    resolveStreamUrl(song)
        .then((_) => _log('[prewarm] resolved & cached: "${song.title}"'))
        .catchError((_) {
          _prewarmedIds.remove(song.id);
        })
        .whenComplete(() {
          _prewarmInFlight--;
          if (_prewarmQueue.isNotEmpty) {
            final next = _prewarmQueue.removeAt(0);
            _runPrewarm(next);
          }
        });
  }

  static Song _songFromSaavn(Map<String, dynamic> j) {
    final title = _cleanText((j['song'] ?? j['name'] ?? j['title'] ?? 'Unknown').toString());

    String artist = '';
    final artistsField = j['artists'];
    if (artistsField is Map && artistsField['primary'] is List) {
      final primaryList = (artistsField['primary'] as List).whereType<Map>().toList();

      final singers = primaryList
          .where((a) => (a['role'] ?? '').toString().toLowerCase() == 'singer')
          .map((a) => (a['name'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();

      if (singers.isNotEmpty) {
        artist = singers.join(', ');
      } else {

        artist = primaryList
            .map((a) => (a['name'] ?? '').toString())
            .where((s) => s.isNotEmpty)
            .toSet()
            .join(', ');
      }
    }
    if (artist.isEmpty) {
      final fallback = j['primary_artists'] ?? j['singers'] ?? j['artist'];
      if (fallback is String) artist = fallback;
    }
    artist = _cleanText(artist, collapseJukeboxTitle: false);

    String album = '';
    final albumField = j['album'];
    if (albumField is Map) {
      album = (albumField['name'] ?? '').toString();
    } else if (albumField is String) {
      album = albumField;
    }
    album = _cleanText(album);

    final artwork   = _onrenderArtwork(j);
    final streamUrl = _onrenderStreamUrl(j);
    return Song(
      id:         (j['id'] ?? '').toString(),
      title:      title,
      artist:     artist.isEmpty ? 'Unknown Artist' : artist,
      album:      album,
      artworkUrl: artwork,
      streamUrl:  streamUrl,
      duration:   _parseInt(j['duration']),
      language:   j['language']?.toString() ?? 'hindi',
      year:       j['year']?.toString(),
      source:     SongSource.saavn,
    );
  }

  static Future<List<ArtistSimple>> fetchHomeArtists() async {

    const pool = [

      _ArtistEntry('arijit singh',      'Arijit Singh'),
      _ArtistEntry('jubin nautiyal',    'Jubin Nautiyal'),
      _ArtistEntry('neha kakkar',       'Neha Kakkar'),
      _ArtistEntry('atif aslam',        'Atif Aslam'),
      _ArtistEntry('shreya ghoshal',    'Shreya Ghoshal'),
      _ArtistEntry('sonu nigam',        'Sonu Nigam'),
      _ArtistEntry('armaan malik',      'Armaan Malik'),
      _ArtistEntry('darshan raval',     'Darshan Raval'),
      _ArtistEntry('b praak',           'B Praak'),
      _ArtistEntry('vishal mishra',     'Vishal Mishra'),
      _ArtistEntry('kumar sanu',        'Kumar Sanu'),
      _ArtistEntry('lata mangeshkar',   'Lata Mangeshkar'),
      _ArtistEntry('kishore kumar',     'Kishore Kumar'),
      _ArtistEntry('mohd rafi',         'Mohd. Rafi'),
      _ArtistEntry('sunidhi chauhan',   'Sunidhi Chauhan'),
      _ArtistEntry('udit narayan',      'Udit Narayan'),
      _ArtistEntry('asha bhosle',       'Asha Bhosle'),
      _ArtistEntry('kavita krishnamurthy', 'Kavita Krishnamurthy'),
      _ArtistEntry('alka yagnik',       'Alka Yagnik'),
      _ArtistEntry('kumar sanu',        'Kumar Sanu'),
      _ArtistEntry('shaan',             'Shaan'),
      _ArtistEntry('kk singer',         'KK'),
      _ArtistEntry('shankar mahadevan', 'Shankar Mahadevan'),
      _ArtistEntry('a r rahman',        'A.R. Rahman'),
      _ArtistEntry('pritam',            'Pritam'),
      _ArtistEntry('amit trivedi',      'Amit Trivedi'),
      _ArtistEntry('vishal shekhar',    'Vishal-Shekhar'),
      _ArtistEntry('sachin jigar',      'Sachin-Jigar'),

      _ArtistEntry('ap dhillon',        'AP Dhillon'),
      _ArtistEntry('diljit dosanjh',    'Diljit Dosanjh'),
      _ArtistEntry('badshah',           'Badshah'),
      _ArtistEntry('guru randhawa',     'Guru Randhawa'),
      _ArtistEntry('hardy sandhu',      'Hardy Sandhu'),
      _ArtistEntry('jasmine sandlas',   'Jasmine Sandlas'),
      _ArtistEntry('harrdy sandhu',     'Harrdy Sandhu'),
      _ArtistEntry('gippy grewal',      'Gippy Grewal'),
      _ArtistEntry('ammy virk',         'Ammy Virk'),
      _ArtistEntry('jassie gill',       'Jassie Gill'),
      _ArtistEntry('satinder sartaaj',  'Satinder Sartaaj'),

      _ArtistEntry('anuv jain',         'Anuv Jain'),
      _ArtistEntry('prateek kuhad',     'Prateek Kuhad'),
      _ArtistEntry('ritviz',            'Ritviz'),
      _ArtistEntry('nucleya',           'Nucleya'),
      _ArtistEntry('when chai met toast', 'When Chai Met Toast'),
    ];

    final rng = math.Random(DateTime.now().difference(DateTime(2026, 1, 1)).inHours);
    final shuffled = List<_ArtistEntry>.from(pool)..shuffle(rng);

    final seen = <String>{};
    final deduped = shuffled.where((a) => seen.add(a.displayName)).toList();

    final picked = deduped.take(20).toList();

    final results = await Future.wait(picked.map((a) async {

      try {
        final path = '/api/search/artists?query=${Uri.encodeQueryComponent(a.query)}&limit=1';
        for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
          final body = await _getFromHosts(hosts, path,
              timeout: const Duration(seconds: 6),
              isValid: (b) => b['data']?['results'] is List &&
                  (b['data']['results'] as List).isNotEmpty);
          if (body == null) continue;
          final r = (body['data']['results'] as List).first as Map<String, dynamic>;
          final imageList = r['image'] as List?;
          String imageUrl = '';
          if (imageList != null && imageList.isNotEmpty) {
            imageUrl = (imageList.last['url'] ?? imageList.last['link'] ?? '').toString();
          }
          if (imageUrl.isNotEmpty) {
            return ArtistSimple(
              id: (r['id'] ?? '').toString(),
              name: a.displayName,
              imageUrl: imageUrl,
            );
          }
        }
      } catch (_) {}

      return null;
    }));

    return results.whereType<ArtistSimple>().toList();
  }

  static Future<List<ArtistSimple>> fetchHomeArtistsCombined() async {

    unawaited(fetchHomeArtists().catchError((_) => <ArtistSimple>[]));

    final ytArtists = await fetchYtMusicHomeArtists(limit: 40);
    final seenNames = <String>{};
    final merged = <ArtistSimple>[];
    for (final a in ytArtists) {
      final key = a.name.trim().toLowerCase();
      if (key.isEmpty || !seenNames.add(key)) continue;
      merged.add(ArtistSimple(id: 'yt_${a.channelId}', name: a.name, imageUrl: a.imageUrl));
    }
    return merged;
  }

  static Future<void> fetchHomeArtistsStreaming(
    void Function(List<ArtistSimple> artists) onUpdate,
  ) async {
    List<YtHomeArtist> ytArtists = const [];
    try {
      ytArtists = await fetchYtMusicHomeArtists(limit: 40);
    } catch (_) {}

    final seenNames = <String>{};
    final merged = <ArtistSimple>[];
    for (final a in ytArtists) {
      final key = a.name.trim().toLowerCase();
      if (key.isEmpty || !seenNames.add(key)) continue;
      merged.add(ArtistSimple(id: 'yt_${a.channelId}', name: a.name, imageUrl: a.imageUrl));
    }
    onUpdate(_uniqueIds(merged));
  }

  static List<ArtistSimple> _uniqueIds(List<ArtistSimple> list) {
    final seenIds = <String>{};
    final out = List<ArtistSimple>.from(list);
    for (var i = 0; i < out.length; i++) {
      final a = out[i];
      if (a.id.isEmpty || !seenIds.add(a.id)) {
        final fallbackId = 'artist_$i';
        seenIds.add(fallbackId);
        out[i] = ArtistSimple(id: fallbackId, name: a.name, imageUrl: a.imageUrl);
      }
    }
    return out;
  }

  static Future<String?> _resolveYtChannelId(String name) async {
    if (name.trim().isEmpty) return null;

    final matches = await _searchArtistsAttempt(name, 1,
        useArtistFilter: true, timeout: const Duration(seconds: 6));
    if (matches.isNotEmpty) {
      return matches.first.id.startsWith('yt_')
          ? matches.first.id.substring(3)
          : matches.first.id;
    }
    final fallback = await _searchArtistsAttempt(name, 1,
        useArtistFilter: false, timeout: const Duration(seconds: 6));
    if (fallback.isEmpty) return null;
    return fallback.first.id.startsWith('yt_')
        ? fallback.first.id.substring(3)
        : fallback.first.id;
  }

  static const String _ytmArtistsFilterParam = 'EgWKAQIgAWoKEAMQBBAJEAoQBQ%3D%3D';

  static const String _ytmPlaylistsFilterParam = 'EgWKAQIoAWoKEAMQBBAJEAoQBQ%3D%3D';

  static Future<List<ArtistSimple>> searchArtists(String query, {int limit = 12}) async {
    return _searchArtistsInternal(query, limit: limit, includeSaavn: true);
  }

  static Future<List<ArtistSimple>> searchArtistsRegionScoped(
    String query, {
    int limit = 12,
    required bool includeSaavn,
  }) {
    return _searchArtistsInternal(query, limit: limit, includeSaavn: includeSaavn);
  }

  static Future<List<ArtistSimple>> _searchArtistsInternal(
    String query, {
    required int limit,
    required bool includeSaavn,
  }) async {
    if (query.trim().isEmpty) return const [];

    return _firstNonEmptyArtists([
      _searchArtistsAttempt(query, limit,
          useArtistFilter: true, timeout: const Duration(seconds: 4)),
      _searchArtistsAttempt(query, limit,
          useArtistFilter: false, timeout: const Duration(seconds: 4)),
      if (includeSaavn) _searchArtistsSaavn(query, limit),
    ]);
  }

  static Future<List<ArtistSimple>> _firstNonEmptyArtists(
      List<Future<List<ArtistSimple>>> futures) async {
    final completer = Completer<List<ArtistSimple>>();
    var remaining = futures.length;
    List<ArtistSimple> lastResult = const [];
    for (final f in futures) {
      f.then((result) {
        if (completer.isCompleted) return;
        if (result.isNotEmpty) {
          completer.complete(result);
          return;
        }
        lastResult = result;
        remaining--;
        if (remaining == 0) completer.complete(lastResult);
      }).catchError((_) {
        if (completer.isCompleted) return;
        remaining--;
        if (remaining == 0) completer.complete(lastResult);
      });
    }
    return completer.future;
  }

  static Future<List<ArtistSimple>> _searchArtistsSaavn(String query, int limit) async {
    if (_saavnDisabled) return const [];
    final path = '/api/search/artists?query=${Uri.encodeQueryComponent(query)}&limit=$limit';
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(hosts, path,
          isValid: (b) => b['data']?['results'] is List &&
              (b['data']['results'] as List).isNotEmpty);
      if (body == null) continue;
      final results = (body['data']['results'] as List);
      final out = <ArtistSimple>[];
      for (final r in results) {
        if (out.length >= limit) break;
        if (r is! Map) continue;
        final ba = BrowseArtist.fromSaavn(r.cast<String, dynamic>());
        if (ba.artistId.isEmpty || ba.name.isEmpty) continue;
        out.add(ArtistSimple(id: 'saavn_${ba.artistId}', name: ba.name, imageUrl: ba.imageUrl));
      }
      if (out.isNotEmpty) return out;
    }
    return const [];
  }

  static Future<List<ArtistSimple>> _searchArtistsAttempt(
      String query, int limit,
      {required bool useArtistFilter, required Duration timeout}) async {
    final decoded = await _ytmSearchRaw(
      query,
      params: useArtistFilter ? _ytmArtistsFilterParam : null,
      timeout: timeout,
    );
    if (decoded == null) return const [];

    final out = <ArtistSimple>[];
    final seen = <String>{};

    void addCandidate(String browseId, String name, String image) {

      final isValidArtistId = browseId.startsWith('UC') || browseId.startsWith('MPLA');
      if (name.isEmpty || !isValidArtistId || !seen.add(browseId)) return;
      out.add(ArtistSimple(id: 'yt_$browseId', name: _cleanText(name), imageUrl: image));
    }

    for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
      if (out.length >= limit) return out;
      final endpoint = _artistEndpointOf(
          (item['navigationEndpoint'] as Map?)?.cast<String, dynamic>());
      if (endpoint == null) continue;
      if (!useArtistFilter && !endpoint.isArtist) continue;
      final name = _flexColumnText(item, 0);
      addCandidate(endpoint.browseId, name, _ytmThumbnailUrl(item));
    }

    if (out.length < limit) {
      for (final item in _findRenderers(decoded, 'musicTwoRowItemRenderer')) {
        if (out.length >= limit) return out;
        final endpoint = _artistEndpointOf(
            (item['navigationEndpoint'] as Map?)?.cast<String, dynamic>());
        if (endpoint == null) continue;
        if (!useArtistFilter && !endpoint.isArtist) continue;
        final name = ((item['title']?['runs'] as List?) ?? const [])
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .trim();
        addCandidate(endpoint.browseId, name, _ytmThumbnailUrl(item));
      }
    }

    if (out.length < limit) {
      for (final card in _findRenderers(decoded, 'musicCardShelfRenderer')) {
        if (out.length >= limit) return out;
        final titleRuns = (card['title']?['runs'] as List?) ?? const [];
        if (titleRuns.isEmpty) continue;
        final firstRun = (titleRuns.first as Map).cast<String, dynamic>();
        final endpoint = _artistEndpointOf(
            (firstRun['navigationEndpoint'] as Map?)?.cast<String, dynamic>());
        if (endpoint == null) continue;
        if (!useArtistFilter && !endpoint.isArtist) continue;
        final name = titleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .trim();
        addCandidate(endpoint.browseId, name, _ytmThumbnailUrl(card));
      }
    }

    return out;
  }

  static const String _ytmAlbumsFilterParam = 'EgWKAQIYAWoKEAMQBBAJEAoQBQ%3D%3D';

  static Future<List<BrowseAlbum>> searchAlbums(String query, {int limit = 12}) async {
    if (query.trim().isEmpty) return const [];

    return _firstNonEmptyAlbums([
      _searchAlbumsAttempt(query, limit,
          useAlbumFilter: true, timeout: const Duration(seconds: 4)),
      _searchAlbumsAttempt(query, limit,
          useAlbumFilter: false, timeout: const Duration(seconds: 4)),
      _searchAlbumsSaavn(query, limit),
    ]);
  }

  static Future<List<BrowseAlbum>> searchAlbumsYtOnly(String query, {int limit = 12}) async {
    if (query.trim().isEmpty) return const [];
    return _firstNonEmptyAlbums([
      _searchAlbumsAttempt(query, limit,
          useAlbumFilter: true, timeout: const Duration(seconds: 4)),
      _searchAlbumsAttempt(query, limit,
          useAlbumFilter: false, timeout: const Duration(seconds: 4)),
    ]);
  }

  static Future<List<BrowseAlbum>> _firstNonEmptyAlbums(
      List<Future<List<BrowseAlbum>>> futures) async {
    final completer = Completer<List<BrowseAlbum>>();
    var remaining = futures.length;
    List<BrowseAlbum> lastResult = const [];
    for (final f in futures) {
      f.then((result) {
        if (completer.isCompleted) return;
        if (result.isNotEmpty) {
          completer.complete(result);
          return;
        }
        lastResult = result;
        remaining--;
        if (remaining == 0) completer.complete(lastResult);
      }).catchError((_) {
        if (completer.isCompleted) return;
        remaining--;
        if (remaining == 0) completer.complete(lastResult);
      });
    }
    return completer.future;
  }

  static Future<List<BrowseAlbum>> _searchAlbumsSaavn(String query, int limit) async {
    if (_saavnDisabled) return const [];
    final path = '/api/search/albums?query=${Uri.encodeQueryComponent(query)}&limit=$limit';
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(hosts, path,
          isValid: (b) => b['data']?['results'] is List &&
              (b['data']['results'] as List).isNotEmpty);
      if (body == null) continue;
      final results = (body['data']['results'] as List);
      final out = <BrowseAlbum>[];
      for (final r in results) {
        if (out.length >= limit) break;
        if (r is! Map) continue;
        final album = BrowseAlbum.fromSaavn(r.cast<String, dynamic>());
        if (album.collectionId.isEmpty || album.name.isEmpty) continue;
        out.add(album);
      }
      if (out.isNotEmpty) return out;
    }
    return const [];
  }

  static Future<List<BrowseAlbum>> _searchAlbumsAttempt(
      String query, int limit,
      {required bool useAlbumFilter, required Duration timeout}) async {
    final decoded = await _ytmSearchRaw(
      query,
      params: useAlbumFilter ? _ytmAlbumsFilterParam : null,
      timeout: timeout,
    );
    if (decoded == null) return const [];

    final out = <BrowseAlbum>[];
    final seen = <String>{};

    void addCandidate(String browseId, String name, String artist, String image, String? year) {
      if (name.isEmpty || !browseId.startsWith('MPRE') || !seen.add(browseId)) return;
      out.add(BrowseAlbum(
        collectionId: browseId,
        name: _cleanText(name),
        artist: _cleanText(artist.isEmpty ? 'Various Artists' : artist),
        artworkUrl: image,
        releaseYear: year,
        isFromYoutube: true,
      ));
    }

    for (final card in _findRenderers(decoded, 'musicTwoRowItemRenderer')) {
      if (out.length >= limit) return out;
      final endpoint = _artistEndpointOf(
          (card['navigationEndpoint'] as Map?)?.cast<String, dynamic>());

      final browseEndpoint = (card['navigationEndpoint'] as Map?)?['browseEndpoint'];
      final pageType = browseEndpoint?['browseEndpointContextSupportedConfigs']
          ?['browseEndpointContextMusicConfig']?['pageType'];
      if (!useAlbumFilter && pageType != 'MUSIC_PAGE_TYPE_ALBUM') continue;
      final browseId = (endpoint?.browseId.isNotEmpty == true
              ? endpoint!.browseId
              : (browseEndpoint?['browseId'] ?? '').toString());
      final title = ((card['title']?['runs'] as List?) ?? const [])
          .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
          .join()
          .trim();

      final subtitleRuns = ((card['subtitle']?['runs'] as List?) ?? const []);
      String artistName = '';
      String? year;
      for (final r in subtitleRuns) {
        if (r is! Map) continue;
        final text = (r['text'] ?? '').toString().trim();
        if (text.isEmpty || text == '•') continue;
        final hasLink = r['navigationEndpoint'] != null;
        if (hasLink) {

          final linkedBrowseId =
              (r['navigationEndpoint']?['browseEndpoint']?['browseId'] ?? '').toString();
          if (!linkedBrowseId.startsWith('MPRE') && artistName.isEmpty) {
            artistName = text;
          }
        } else if (RegExp(r'^(19|20)\d{2}$').hasMatch(text)) {
          year = text;
        } else if (!RegExp(r'^(Album|Single|EP)$', caseSensitive: false).hasMatch(text)) {

          if (artistName.isEmpty) artistName = text;
        }
      }
      addCandidate(browseId, title, artistName, _ytmThumbnailUrl(card), year);
    }

    if (out.length < limit) {
      for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
        if (out.length >= limit) return out;
        final navEndpoint = (item['navigationEndpoint'] as Map?)?['browseEndpoint'];
        final pageType = navEndpoint?['browseEndpointContextSupportedConfigs']
            ?['browseEndpointContextMusicConfig']?['pageType'];
        if (!useAlbumFilter && pageType != 'MUSIC_PAGE_TYPE_ALBUM') continue;
        final browseId = (navEndpoint?['browseId'] ?? '').toString();
        final title = _flexColumnText(item, 0);
        final artistRuns = _artistRunsInSubtitle(item);
        addCandidate(browseId, title, artistRuns.isNotEmpty ? artistRuns.first.name : '',
            _ytmThumbnailUrl(item), null);
      }
    }

    return out;
  }

  static Future<String?> resolveArtistId(String name) async {
    final ytId = await _resolveYtChannelId(name);
    if (ytId != null && ytId.isNotEmpty) return 'yt_$ytId';
    return null;
  }

  static Future<String?> searchArtistByName(String name) async {
    if (name.trim().isEmpty || _saavnDisabled) return null;
    final lower = name.trim().toLowerCase();
    final path = '/api/search/artists?query=${Uri.encodeQueryComponent(name)}';

    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(hosts, path,
          isValid: (b) => b['data']?['results'] is List &&
              (b['data']['results'] as List).isNotEmpty);
      if (body == null) continue;
      final results = (body['data']['results'] as List);
      final exact = results.firstWhere(
        (r) => (r is Map ? (r['name'] ?? '') : '').toString().toLowerCase() == lower,
        orElse: () => results.first,
      );
      if (exact is Map) return (exact['id'] ?? '').toString();
    }
    _log('[artist] searchArtistByName: all hosts failed for "$name"');
    return null;
  }

  static Future<void> fetchArtistStreaming(
    String artistId, {
    int songCount = 100,
    int albumCount = 100,
    required void Function(Artist artist) onUpdate,
  }) async {
    if (artistId.isEmpty) return;
    if (!artistId.startsWith('yt_')) {

      final artist = await fetchArtist(artistId, songCount: songCount, albumCount: albumCount);
      if (artist != null) onUpdate(artist);
      return;
    }
    final channelId = artistId.substring(3);
    final browseArtist = await _fetchArtistFromYtMusicBrowse(channelId, songCount: songCount);
    if (browseArtist == null) {

      final ytArtist = await _fetchArtistFromYoutube(channelId, songCount: songCount);
      if (ytArtist != null) onUpdate(ytArtist);
      return;
    }

    onUpdate(browseArtist);
    if (browseArtist.topSongs.length >= songCount) return;

    final seenIds = <String>{};
    final seenTitles = <String>{};
    final seenRawTitles = <String>[];
    final mergedSongs = <Song>[];
    void addAll(Iterable<Song> songs) {
      for (final s in songs) {
        if (mergedSongs.length >= songCount) break;
        if (!seenIds.add(s.id)) continue;
        final tk = _normTitle(s.title);
        if (!seenTitles.add(tk)) continue;
        if (_isDupOfAny(s.title, seenRawTitles)) continue;
        seenRawTitles.add(s.title);
        mergedSongs.add(s);
      }
    }
    addAll(browseArtist.topSongs);

    Artist snapshot() => Artist(
          id: browseArtist.id,
          name: browseArtist.name,
          imageUrl: browseArtist.imageUrl,
          followerCount: browseArtist.followerCount,
          isVerified: browseArtist.isVerified,
          bio: browseArtist.bio,
          topSongs: List<Song>.from(mergedSongs),
          topAlbums: browseArtist.topAlbums,
          singles: browseArtist.singles,
          source: browseArtist.source,
          bannerUrl: browseArtist.bannerUrl,

          relatedArtists: browseArtist.relatedArtists,
        );

    try {
      final uploadsArtist = await _fetchArtistFromYoutube(channelId, songCount: songCount)
          .timeout(const Duration(seconds: 100), onTimeout: () => null);
      if (uploadsArtist != null) addAll(uploadsArtist.topSongs);
      onUpdate(snapshot());
    } catch (e) {
      _log('[fetchArtistStreaming] uploads top-up failed for "${browseArtist.name}": $e');
    }
    if (mergedSongs.length >= songCount) return;

    if (browseArtist.name.isNotEmpty) {
      try {

        final extra = await _searchYtMusicDirectPaginated(
          browseArtist.name,
          songCount * 2,
          filterParam: _ytmSongsFilterParam,
        ).timeout(const Duration(seconds: 45), onTimeout: () => <Song>[]);
        final filtered = extra.where((s) {
          if (RecommendationEngine.isNonMusicContent(s)) return false;
          if (s.artistChannelId != null) return s.artistChannelId == channelId;
          return s.artist.trim().toLowerCase() == browseArtist.name.trim().toLowerCase();
        });
        addAll(filtered);
        onUpdate(snapshot());
      } catch (e) {
        _log('[fetchArtistStreaming] final 100-floor top-up failed for "${browseArtist.name}": $e');
      }
    }
  }

  static Future<Artist?> fetchArtist(String artistId,
      {int songCount = 100, int albumCount = 100}) async {
    if (artistId.isEmpty) return null;
    if (artistId.startsWith('yt_')) {
      final channelId = artistId.substring(3);

      final browseArtist = await _fetchArtistFromYtMusicBrowse(channelId, songCount: songCount);
      if (browseArtist != null && browseArtist.topSongs.isNotEmpty) {

        if (browseArtist.topSongs.length >= songCount) return browseArtist;

        try {

          final uploadsArtist = await _fetchArtistFromYoutube(channelId, songCount: songCount)
              .timeout(const Duration(seconds: 100), onTimeout: () => null);

          final seenIds = <String>{};
          final seenTitles = <String>{};
          final seenRawTitles = <String>[];
          final mergedSongs = <Song>[];

          if (uploadsArtist != null) {
            for (final s in [...browseArtist.topSongs, ...uploadsArtist.topSongs]) {
              if (mergedSongs.length >= songCount) break;
              if (!seenIds.add(s.id)) continue;
              final tk = _normTitle(s.title);
              if (!seenTitles.add(tk)) continue;
              if (_isDupOfAny(s.title, seenRawTitles)) continue;
              seenRawTitles.add(s.title);
              mergedSongs.add(s);
            }
          } else {

            for (final s in browseArtist.topSongs) {
              if (mergedSongs.length >= songCount) break;
              if (!seenIds.add(s.id)) continue;
              final tk = _normTitle(s.title);
              if (!seenTitles.add(tk)) continue;
              if (_isDupOfAny(s.title, seenRawTitles)) continue;
              seenRawTitles.add(s.title);
              mergedSongs.add(s);
            }
          }

          if (mergedSongs.length < songCount && browseArtist.name.isNotEmpty) {
            try {

              final extra = await _searchYtMusicDirectPaginated(
                browseArtist.name,
                songCount * 2,
                filterParam: _ytmSongsFilterParam,
              ).timeout(const Duration(seconds: 45), onTimeout: () => <Song>[]);
              final matched = extra.where((s) {
                if (s.artistChannelId != null) return s.artistChannelId == channelId;
                return s.artist.trim().toLowerCase() == browseArtist.name.trim().toLowerCase();
              });
              for (final s in matched) {
                if (mergedSongs.length >= songCount) break;
                if (!seenIds.add(s.id)) continue;
                final tk = _normTitle(s.title);
                if (!seenTitles.add(tk)) continue;
                if (_isDupOfAny(s.title, seenRawTitles)) continue;
                if (RecommendationEngine.isNonMusicContent(s)) continue;
                seenRawTitles.add(s.title);
                mergedSongs.add(s);
              }
            } catch (e) {
              _log('[fetchArtist] final 100-floor top-up failed for "${browseArtist.name}": $e');
            }
          }

          return Artist(
            id: browseArtist.id,
            name: browseArtist.name,
            imageUrl: browseArtist.imageUrl,
            followerCount: browseArtist.followerCount,
            isVerified: browseArtist.isVerified,
            bio: browseArtist.bio,
            topSongs: mergedSongs,
            topAlbums: browseArtist.topAlbums,
            singles: browseArtist.singles,
            source: browseArtist.source,
            bannerUrl: browseArtist.bannerUrl,

            relatedArtists: browseArtist.relatedArtists,
          );
        } catch (e) {
          _log('[fetchArtist] YT uploads top-up failed for "${browseArtist.name}": $e');
          return browseArtist;
        }
      }

      final ytArtist = await _fetchArtistFromYoutube(channelId, songCount: songCount);
      if (ytArtist != null) return ytArtist;

      return browseArtist;
    }

    // BUGFIX ("Saavn band hai, artist/album abhi bhi Saavn se try ho rahe
    // the" — recheck 2026-09-14): every OTHER Saavn entry point in this
    // file (_searchArtistsSaavn, _searchAlbumsSaavn, searchArtistByName)
    // already checks _saavnDisabled and short-circuits to InnerTube. This
    // branch — reached whenever an artistId does NOT start with 'yt_'
    // (a 'saavn_'-prefixed id, e.g. from a Saavn song's artist field, or
    // any other non-YT id) — was the one place that called straight into
    // _fetchArtistFromSaavn's live HTTP endpoint with no _saavnDisabled
    // check and no InnerTube fallback at all. With the Saavn backend
    // down, that meant landing on any Saavn-sourced artist's profile page
    // just hung/failed outright instead of falling back the same way the
    // 'yt_' branch above already does.
    //
    // Fix: fail fast with null instead of hanging/erroring on the dead
    // Saavn endpoint. This id has no artist NAME attached (just an opaque
    // Saavn id), so it can't be re-resolved via InnerTube search here —
    // callers holding only a stale 'saavn_'-prefixed id (e.g. an artist
    // followed back when Saavn was live) should re-resolve via
    // resolveArtistId(name)/searchArtistByName(name) with the artist's
    // NAME instead, which already goes through the same InnerTube-first
    // pipeline every 'yt_' artist above uses.
    if (_saavnDisabled) {
      final saavnId = artistId.startsWith('saavn_') ? artistId.substring(6) : artistId;
      _log('[fetchArtist] Saavn disabled, cannot resolve bare id "$saavnId" via InnerTube (no name to search)');
      return null;
    }

    final saavnId = artistId.startsWith('saavn_') ? artistId.substring(6) : artistId;
    return _fetchArtistFromSaavn(saavnId, songCount: songCount, albumCount: albumCount);
  }

  static Future<Artist?> _fetchArtistFromYtMusicBrowse(String channelId,
      {int songCount = 100}) async {
    try {
      final decoded = await _ytmBrowseRaw(channelId, timeout: const Duration(seconds: 8));
      if (decoded == null) return null;

      final header = decoded['header'];
      final headerRenderer = header is Map
          ? (header['musicImmersiveHeaderRenderer'] ??
              header['musicVisualHeaderRenderer'] ??
              header['musicHeaderRenderer'])
          : null;
      String name = '';
      String bio = '';
      String imageUrl = '';
      String? bannerUrl;
      int followerCount = 0;
      if (headerRenderer is Map) {
        name = ((headerRenderer['title']?['runs'] as List?) ?? const [])
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .trim();
        final descRuns = (headerRenderer['description']?['runs'] as List?) ?? const [];
        bio = descRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .trim();
        final thumbs = (headerRenderer['thumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            (headerRenderer['foregroundThumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            const [];
        if (thumbs.isNotEmpty) {
          final rawUrl = (thumbs.last['url'] ?? '').toString();
          imageUrl = _scaledArtworkUrl(rawUrl, 1080, suffix: '-p');
        }
        final bannerThumbs = (headerRenderer['background']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            const [];
        if (bannerThumbs.isNotEmpty) {
          final rawBannerUrl = (bannerThumbs.last['url'] ?? '').toString();
          bannerUrl = rawBannerUrl.isNotEmpty
              ? _scaledArtworkUrl(rawBannerUrl, 1440, suffix: '-p')
              : null;
        }

        final monthlyListenersText = ((headerRenderer['monthlyListenerCount']?['runs'] as List?) ?? const [])
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join();
        final subscriberRuns = (headerRenderer['subscriptionButton']
                    ?['subscribeButtonRenderer']?['subscriberCountText']
                    ?['runs'] as List?) ??
            const [];
        final subscriberText = subscriberRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join();
        followerCount = _parseCompactCount(
            monthlyListenersText.isNotEmpty ? monthlyListenersText : subscriberText);
      }
      name = _cleanText(name)
          .replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), '')
          .trim();
      if (name.isEmpty) return null;

      final canonicalChannelId = ((headerRenderer is Map)
              ? (headerRenderer['subscriptionButton']
                      ?['subscribeButtonRenderer']?['channelId'])
                  ?.toString()
              : null) ??
          '';
      final resolvedChannelId = canonicalChannelId.startsWith('UC')
          ? canonicalChannelId
          : channelId;

      final topSongs = <Song>[];
      final seenVideoIds = <String>{};
      for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
        if (topSongs.length >= songCount) break;
        final videoId = (item['playlistItemData']?['videoId'] ??
                (item['overlay']?['musicItemThumbnailOverlayRenderer']?['content']
                        ?['musicPlayButtonRenderer']?['playNavigationEndpoint']
                    ?['watchEndpoint']?['videoId']))
            ?.toString();
        if (videoId == null || videoId.isEmpty || !seenVideoIds.add(videoId)) continue;

        final title = _flexColumnText(item, 0);
        if (title.isEmpty) continue;

        final artistRuns = _artistRunsInSubtitle(item);
        final artistName = artistRuns.isNotEmpty ? artistRuns.first.name : name;

        final thumbs = (item['thumbnail']?['musicThumbnailRenderer']
                    ?['thumbnail']?['thumbnails'] as List?) ??
            const [];
        String artworkUrl = '';
        if (thumbs.isNotEmpty) {
          final rawUrl = (thumbs.last['url'] ?? '').toString();
          artworkUrl = _scaledArtworkUrl(rawUrl, 1000);
        }

        final flexColumns = (item['flexColumns'] as List?) ?? const [];
        int? duration;
        if (flexColumns.isNotEmpty) {
          final lastColRuns = (flexColumns.last
                      ?['musicResponsiveListItemFlexColumnRenderer']?['text']
                  ?['runs'] as List?) ??
              const [];
          final lastColText = lastColRuns
              .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
              .join()
              .trim();
          duration = _parseDurationText(lastColText);
        }

        final song = Song(
          id: videoId,
          title: _cleanText(title),
          artist: _cleanText(artistName, collapseJukeboxTitle: false),
          album: '',
          artworkUrl: artworkUrl,
          streamUrl: null,
          duration: duration,
          source: SongSource.youtube,
          viewCount: 1000000,
          artistChannelId: resolvedChannelId,
        );
        if (RecommendationEngine.isNonMusicContent(song)) continue;
        topSongs.add(song);
      }

      if (topSongs.length < songCount) {
        String? topSongsPlaylistId;
        for (final shelf in _findRenderers(decoded, 'musicShelfRenderer')) {
          final bottomBrowseId = (shelf['bottomEndpoint']?['browseEndpoint']
                  ?['browseId'] ??
              '')
              .toString();
          if (bottomBrowseId.startsWith('VL')) {
            topSongsPlaylistId = bottomBrowseId;
            break;
          }
        }

        if (topSongsPlaylistId != null) {
          try {
            await _fetchFullTopSongsPlaylist(
              topSongsPlaylistId,
              targetCount: songCount,
              fallbackArtistName: name,
              resolvedChannelId: resolvedChannelId,
              topSongs: topSongs,
              seenVideoIds: seenVideoIds,
            );
          } catch (e) {
            _log('[_fetchArtistFromYtMusicBrowse] Top Songs playlist top-up failed: $e');

          }
        }
      }

      final moreReleaseBrowses = <(String, bool, String?)>[];
      for (final carousel in _findRenderers(decoded, 'musicCarouselShelfRenderer')) {
        final headerRendererForCarousel =
            (carousel['header']?['musicCarouselShelfBasicHeaderRenderer'] as Map?)
                ?.cast<String, dynamic>();
        final headerTitleRuns =
            (headerRendererForCarousel?['title']?['runs'] as List?) ?? const [];
        final headerTitle = headerTitleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .toLowerCase();
        final isSingles = headerTitle.contains('single');
        final isAlbums = headerTitle.contains('album');
        if (!isSingles && !isAlbums) continue;

        final moreEndpoint = (headerRendererForCarousel?['moreContentButton']
                ?['buttonRenderer']?['navigationEndpoint']?['browseEndpoint']
            as Map?)
            ?.cast<String, dynamic>();
        final moreBrowseId = (moreEndpoint?['browseId'] ?? '').toString();
        if (moreBrowseId.startsWith('MPAD')) {
          moreReleaseBrowses.add(
              (moreBrowseId, isSingles, moreEndpoint?['params']?.toString()));
        }
      }

      final moreGrids = await Future.wait(moreReleaseBrowses.map((entry) async {
        try {

          final grid = await _ytmBrowseRaw(entry.$1,
              params: entry.$3, timeout: const Duration(seconds: 8));
          return (grid, entry.$2);
        } catch (_) {
          return (null, entry.$2);
        }
      }));

      final topAlbums = <ArtistAlbum>[];
      final singles = <ArtistAlbum>[];
      final seenAlbumBrowseIds = <String>{};

      void collectReleaseCards(dynamic node, bool isSinglesShelf) {
        for (final card in _findRenderers(node, 'musicTwoRowItemRenderer')) {

          final cardTitleRuns = (card['title']?['runs'] as List?) ?? const [];
          final cardTitle = cardTitleRuns
              .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
              .join()
              .trim();
          if (cardTitle.isEmpty || cardTitleRuns.isEmpty) continue;
          final titleNav = ((cardTitleRuns.first as Map)['navigationEndpoint']
                  as Map?)
              ?.cast<String, dynamic>();
          final browseId = (titleNav?['browseEndpoint']?['browseId'] ?? '').toString();
          if (browseId.isEmpty || !seenAlbumBrowseIds.add(browseId)) continue;

          final cardArt = _ytmThumbnailUrl(card);
          final subtitleRuns = ((card['subtitle']?['runs'] as List?) ?? const []);
          String? year;
          for (final r in subtitleRuns) {
            final text = (r is Map ? (r['text'] ?? '') : '').toString();
            final yearMatch = RegExp(r'^(19|20)\d{2}$').firstMatch(text.trim());
            if (yearMatch != null) {
              year = yearMatch.group(0);
              break;
            }
          }
          final album = ArtistAlbum(
            id: browseId,
            name: _cleanText(cardTitle),
            artworkUrl: cardArt,
            year: year,
            type: isSinglesShelf ? 'single' : 'album',
          );
          if (isSinglesShelf) {
            singles.add(album);
          } else {
            topAlbums.add(album);
          }
        }
      }

      for (final (grid, isSinglesShelf) in moreGrids) {
        if (grid != null) collectReleaseCards(grid, isSinglesShelf);
      }
      for (final carousel in _findRenderers(decoded, 'musicCarouselShelfRenderer')) {
        final headerRendererForCarousel =
            (carousel['header']?['musicCarouselShelfBasicHeaderRenderer'] as Map?)
                ?.cast<String, dynamic>();
        final headerTitleRuns =
            (headerRendererForCarousel?['title']?['runs'] as List?) ?? const [];
        final headerTitle = headerTitleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .toLowerCase();
        final isSingles = headerTitle.contains('single');
        final isAlbums = headerTitle.contains('album');
        if (!isSingles && !isAlbums) continue;
        collectReleaseCards(carousel['contents'], isSingles);
      }

      final relatedArtists = <RelatedArtist>[];
      final seenRelatedIds = <String>{};
      for (final carousel in _findRenderers(decoded, 'musicCarouselShelfRenderer')) {
        final headerRendererForCarousel =
            (carousel['header']?['musicCarouselShelfBasicHeaderRenderer'] as Map?)
                ?.cast<String, dynamic>();
        final headerTitleRuns =
            (headerRendererForCarousel?['title']?['runs'] as List?) ?? const [];
        final headerTitle = headerTitleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .toLowerCase();
        if (!headerTitle.contains('fans might also like') &&
            !headerTitle.contains('fans also like')) {
          continue;
        }
        for (final card in _findRenderers(carousel['contents'], 'musicTwoRowItemRenderer')) {
          final cardTitleRuns = (card['title']?['runs'] as List?) ?? const [];
          final cardTitle = cardTitleRuns
              .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
              .join()
              .trim();
          if (cardTitle.isEmpty || cardTitleRuns.isEmpty) continue;
          final titleNav = ((cardTitleRuns.first as Map)['navigationEndpoint']
                  as Map?)
              ?.cast<String, dynamic>();
          final browseEndpoint =
              (titleNav?['browseEndpoint'] as Map?)?.cast<String, dynamic>();
          final pageType = (browseEndpoint
                      ?['browseEndpointContextSupportedConfigs']
                  ?['browseEndpointContextMusicConfig']?['pageType'] ??
              '').toString();
          if (pageType != 'MUSIC_PAGE_TYPE_ARTIST') continue;
          final relatedId = (browseEndpoint?['browseId'] ?? '').toString();
          if (relatedId.isEmpty || !seenRelatedIds.add(relatedId)) continue;

          final cardArt = _ytmThumbnailUrl(card);
          relatedArtists.add(RelatedArtist(
            id: relatedId,
            name: _cleanText(cardTitle),
            imageUrl: cardArt,
          ));
        }
      }

      return Artist(
        id: 'yt_$resolvedChannelId',
        name: name,
        imageUrl: imageUrl,
        followerCount: followerCount,
        isVerified: false,
        bio: _cleanText(bio),
        topSongs: topSongs,
        topAlbums: topAlbums,
        singles: singles,
        source: ArtistSource.youtube,
        bannerUrl: bannerUrl,
        relatedArtists: relatedArtists,
      );
    } catch (e) {
      _log('[_fetchArtistFromYtMusicBrowse] failed for channelId=$channelId: $e');
      return null;
    }
  }

  static int _parseCompactCount(String text) {
    final match = RegExp(r'([\d.,]+)\s*([KMB]?)', caseSensitive: false).firstMatch(text.trim());
    if (match == null) return 0;
    final numPart = match.group(1)?.replaceAll(',', '') ?? '';
    final suffix = (match.group(2) ?? '').toUpperCase();
    final base = double.tryParse(numPart);
    if (base == null) return 0;
    final multiplier = switch (suffix) {
      'K' => 1000,
      'M' => 1000000,
      'B' => 1000000000,
      _ => 1,
    };
    return (base * multiplier).round();
  }

  static int? _parseDurationText(String text) {
    if (!RegExp(r'^\d{1,2}(:\d{2}){1,2}$').hasMatch(text.trim())) return null;
    final parts = text.trim().split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return null;
    var seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p!;
    }
    return seconds;
  }

  static Future<Artist?> _fetchArtistFromYoutube(String channelId,
      {int songCount = 100}) async {
    try {

      final channelFuture = _yt.channels.get(channelId)
          .timeout(const Duration(seconds: 8));
      final aboutFuture = () async {
        try {
          return await _yt.channels.getAboutPage(channelId)
              .timeout(const Duration(seconds: 6));
        } catch (e) {
          _log('[_fetchArtistFromYoutube] getAboutPage failed: $e');
          return null;
        }
      }();
      final uploadsFuture = () async {
        try {
          return await _yt.channels
              .getUploadsFromPage(channelId, videoSorting: VideoSorting.popularity)
              .timeout(const Duration(seconds: 7));
        } catch (e) {
          _log('[_fetchArtistFromYoutube] getUploadsFromPage failed: $e');
          return null;
        }
      }();

      final channel = await channelFuture;
      final about = await aboutFuture;
      final firstPage = await uploadsFuture;

      final bio = _cleanText(about?.description ?? '');

      final cleanName = _cleanText(channel.title)
          .replaceAll(RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false), '')
          .trim();

      final topSongs = <Song>[];
      if (firstPage != null) {
        try {
          var page = firstPage;

          const maxPages = 200;
          final walkDeadline = DateTime.now().add(const Duration(seconds: 90));

          var pageCount = 0;
          while (true) {
            pageCount++;
            for (final v in page) {
              final base = _songFromYtVideo(v);
              final song = Song(
                id: base.id, title: base.title, artist: base.artist,
                album: base.album, artworkUrl: base.artworkUrl, streamUrl: null,
                duration: base.duration, source: SongSource.youtube,

                viewCount: base.viewCount ?? 1000000,
                artistChannelId: channelId,
              );
              if (RecommendationEngine.isNonMusicContent(song)) continue;
              if (song.duration != null && (song.duration! < 60 || song.duration! > 1200)) continue;
              topSongs.add(song);
            }
            if (topSongs.length >= songCount || pageCount >= maxPages) break;
            if (DateTime.now().isAfter(walkDeadline)) break;

            final next = await page.nextPage().timeout(const Duration(seconds: 5), onTimeout: () => null);
            if (next == null) break;
            page = next;
          }
        } catch (e) {
          _log('[_fetchArtistFromYoutube] getUploadsFromPage failed: $e');
        }
      }

      if (topSongs.length < songCount && cleanName.isNotEmpty) {
        try {

          final fallbackResults = await _searchYtMusicDirectPaginated(
            cleanName,
            songCount * 2,
            filterParam: _ytmSongsFilterParam,
          ).timeout(const Duration(seconds: 45), onTimeout: () => <Song>[]);
          final matched = fallbackResults.where((s) {
            if (s.artistChannelId != null) return s.artistChannelId == channelId;
            return s.artist.trim().toLowerCase() == cleanName.toLowerCase();
          }).toList();
          if (matched.isNotEmpty) {
            final seenIds = topSongs.map((s) => s.id).toSet();
            final seenTitles = topSongs.map((s) => _normTitle(s.title)).toSet();
            final seenRawTitles = topSongs.map((s) => s.title).toList();

            for (final s in matched) {
              if (topSongs.length >= songCount) break;
              if (!seenIds.add(s.id)) continue;
              final tk = _normTitle(s.title);
              if (!seenTitles.add(tk)) continue;
              if (_isDupOfAny(s.title, seenRawTitles)) continue;
              final song = Song(
                id: s.id, title: s.title, artist: s.artist, album: s.album,
                artworkUrl: s.artworkUrl, streamUrl: null, duration: s.duration,
                source: SongSource.youtube, viewCount: s.viewCount ?? 1000000,
                artistChannelId: channelId,
              );
              if (RecommendationEngine.isNonMusicContent(song)) continue;
              seenRawTitles.add(s.title);
              topSongs.add(song);
            }
          }
        } catch (e) {
          _log('[_fetchArtistFromYoutube] search fallback failed: $e');
        }
      }

      return Artist(
        id: 'yt_$channelId',
        name: cleanName.isNotEmpty ? cleanName : _cleanText(channel.title),
        imageUrl: channel.logoUrl,
        followerCount: channel.subscribersCount ?? 0,
        isVerified: false,
        bio: bio,
        topSongs: topSongs,
        topAlbums: const [],
        singles: const [],
        source: ArtistSource.youtube,
        bannerUrl: channel.bannerUrl.isNotEmpty ? channel.bannerUrl : null,
      );
    } catch (e) {
      _log('[_fetchArtistFromYoutube] failed for channelId=$channelId: $e');
      return null;
    }
  }

  static Future<Artist?> _fetchArtistFromSaavn(String artistId,
      {int songCount = 100, int albumCount = 100}) async {
    final path = '/api/artists/$artistId?songCount=$songCount&albumCount=$albumCount';
    Map<String, dynamic>? body;
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      body = await _getFromHosts(
        hosts, path,
        timeout: const Duration(seconds: 15),
        isValid: (b) => b['success'] == true && b['data'] is Map,
      );
      if (body != null) break;
    }
    if (body == null) {
      _log('[artist] fetchArtist: all hosts failed for id=$artistId');
      return null;
    }

    try {
      final d = body['data'] as Map<String, dynamic>;

      final saavnTopSongs = ((d['topSongs'] as List?) ?? [])
          .whereType<Map>()
          .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
          .toList();

      final artistNameForYt = (d['name'] ?? '').toString();
      final ytTopSongs = artistNameForYt.isEmpty
          ? <Song>[]
          : await _searchYt('$artistNameForYt songs', limit: 150)
              .timeout(const Duration(seconds: 8), onTimeout: () => <Song>[])
              .catchError((_) => <Song>[]);

      final seenIds = <String>{};
      final seenTitles = <String>{};
      final topSongs = <Song>[];

      final seenRawTitles = <String>[];
      for (final s in [...saavnTopSongs, ...ytTopSongs]) {

        if (s.source == SongSource.youtube) {
          if (!RecommendationEngine.isSearchQuality(s)) continue;
          if (RecommendationEngine.isNonMusicContent(s)) continue;
        }
        if (!seenIds.add(s.id)) continue;
        final tk = _normTitle(s.title);
        if (!seenTitles.add(tk)) continue;
        if (_isDupOfAny(s.title, seenRawTitles)) continue;
        seenRawTitles.add(s.title);
        topSongs.add(s);
      }

      final topAlbums = ((d['topAlbums'] as List?) ?? [])
          .whereType<Map>()
          .map((a) => _artistAlbumFromJson(Map<String, dynamic>.from(a), type: 'album'))
          .toList();

      final singles = ((d['singles'] as List?) ?? [])
          .whereType<Map>()
          .map((a) => _artistAlbumFromJson(Map<String, dynamic>.from(a), type: 'single'))
          .toList();

      String bio = '';
      final bioField = d['bio'];
      if (bioField is List && bioField.isNotEmpty) {
        final first = bioField.first;
        if (first is Map && first['text'] is String) {
          bio = _cleanText(first['text'] as String);
        }
      }

      return Artist(
        id: 'saavn_${(d['id'] ?? artistId).toString()}',
        name: _cleanText((d['name'] ?? '').toString()),
        imageUrl: _onrenderArtwork(d),
        followerCount: _parseInt(d['followerCount']) ?? 0,
        isVerified: d['isVerified'] == true,
        bio: bio,
        topSongs: topSongs,
        topAlbums: topAlbums,
        singles: singles,
        source: ArtistSource.saavn,
      );
    } catch (e) {
      _log('[artist] fetchArtist parse failed: $e');
      return null;
    }
  }

  static Future<String?> searchAlbumByName(String name) async {
    if (name.trim().isEmpty) return null;
    final lower = name.trim().toLowerCase();
    final path = '/api/search/albums?query=${Uri.encodeQueryComponent(name)}';

    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(hosts, path,
          isValid: (b) => b['data']?['results'] is List &&
              (b['data']['results'] as List).isNotEmpty);
      if (body == null) continue;
      final results = (body['data']['results'] as List);
      final exact = results.firstWhere(
        (r) => (r is Map ? (r['name'] ?? '') : '').toString().toLowerCase() == lower,
        orElse: () => results.first,
      );
      if (exact is Map) return (exact['id'] ?? '').toString();
    }
    _log('[artist] searchAlbumByName: all hosts failed for "$name"');
    return null;
  }

  static Future<List<Song>> fetchAlbumSongs(String albumId) async {
    if (albumId.isEmpty) return [];
    if (albumId.startsWith('MPRE')) {
      return _fetchYtAlbumSongs(albumId);
    }

    final path = '/api/albums?id=$albumId';
    for (final hosts in [_saavnNodeHosts, _saavnFlaskHosts]) {
      final body = await _getFromHosts(
        hosts, path,
        timeout: const Duration(seconds: 10),
        isValid: (b) => b['success'] == true && b['data']?['songs'] is List,
      );
      if (body == null) continue;
      final songs = (body['data']['songs'] as List);
      return songs
          .whereType<Map>()
          .map((s) => _songFromSaavn(Map<String, dynamic>.from(s)))
          .toList();
    }
    _log('[artist] fetchAlbumSongs: all hosts failed for id=$albumId');
    return [];
  }

  static Future<({List<Song> songs, String headerArtworkUrl, List<AlbumRelatedShelf> relatedShelves})>
      fetchAlbumSongsWithArtwork(String albumId) async {
    if (!albumId.startsWith('MPRE')) {
      return (songs: await fetchAlbumSongs(albumId), headerArtworkUrl: '', relatedShelves: <AlbumRelatedShelf>[]);
    }
    return _fetchYtAlbumSongsWithArtwork(albumId);
  }

  static Future<List<Song>> _fetchYtAlbumSongs(String albumBrowseId) async {
    final result = await _fetchYtAlbumSongsWithArtwork(albumBrowseId);
    return result.songs;
  }

  static Future<({List<Song> songs, String headerArtworkUrl, List<AlbumRelatedShelf> relatedShelves})>
      _fetchYtAlbumSongsWithArtwork(String albumBrowseId) async {
    try {
      final decoded = await _ytmBrowseRaw(albumBrowseId, timeout: const Duration(seconds: 8));
      if (decoded == null) {
        return (songs: <Song>[], headerArtworkUrl: '', relatedShelves: <AlbumRelatedShelf>[]);
      }

      final albumTitle = ((decoded['header']?['musicResponsiveHeaderRenderer']?['title']
                      ?['runs'] as List?) ??
                  (decoded['header']?['musicDetailHeaderRenderer']?['title']?['runs']
                      as List?) ??
                  const [])
          .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
          .join()
          .trim();

      String headerArtworkUrl = '';
      final headerThumbs = ((decoded['header']?['musicResponsiveHeaderRenderer']
                      ?['thumbnail']?['musicThumbnailRenderer']?['thumbnail']
                  ?['thumbnails'] as List?) ??
              (decoded['header']?['musicDetailHeaderRenderer']?['thumbnail']
                      ?['croppedSquareThumbnailRenderer']?['thumbnail']?['thumbnails']
                  as List?) ??
              const [])
          .whereType<Map>()
          .toList();
      if (headerThumbs.isNotEmpty) {
        final rawUrl = (headerThumbs.last['url'] ?? '').toString();
        if (rawUrl.isNotEmpty) {
          headerArtworkUrl = _scaledArtworkUrl(rawUrl, 1080, suffix: '-p');
        }
      }

      String? audioPlaylistId;
      final header = decoded['header'];
      for (final btn in _findRenderers(header, 'musicPlayButtonRenderer')) {
        final playlistId = (btn['playNavigationEndpoint']?['watchPlaylistEndpoint']?['playlistId'] ??
                btn['playNavigationEndpoint']?['watchEndpoint']?['playlistId'])
            ?.toString();
        if (playlistId != null && playlistId.isNotEmpty) {
          audioPlaylistId = playlistId;
          break;
        }
      }

      final relatedShelves = _parseAlbumRelatedShelves(decoded);

      if (audioPlaylistId != null) {
        try {

          final songs = await fetchYtPlaylistSongs(audioPlaylistId, limit: 2000)
              .timeout(const Duration(seconds: 12));
          if (songs.isNotEmpty) {

            final stampedSongs = headerArtworkUrl.isEmpty
                ? songs
                : songs.map((s) => s.copyWith(artworkUrl: headerArtworkUrl)).toList();
            if (albumTitle.isEmpty) {
              return (songs: stampedSongs, headerArtworkUrl: headerArtworkUrl, relatedShelves: relatedShelves);
            }

            return (
              songs: stampedSongs
                  .map((s) => Song(
                        id: s.id,
                        title: s.title,
                        artist: s.artist,
                        album: _cleanText(albumTitle),
                        artworkUrl: s.artworkUrl,
                        streamUrl: s.streamUrl,
                        duration: s.duration,
                        source: s.source,
                        viewCount: s.viewCount,
                        artistChannelId: s.artistChannelId,
                      ))
                  .toList(),
              headerArtworkUrl: headerArtworkUrl,
              relatedShelves: relatedShelves,
            );
          }
        } catch (e) {
          _log('[_fetchYtAlbumSongs] playlist fetch failed for $audioPlaylistId: $e');

        }
      }

      final songs = <Song>[];
      final seenIds = <String>{};
      for (final item in _findRenderers(decoded, 'musicResponsiveListItemRenderer')) {
        final videoId = (item['playlistItemData']?['videoId'] ??
                item['overlay']?['musicItemThumbnailOverlayRenderer']?['content']
                    ?['musicPlayButtonRenderer']?['playNavigationEndpoint']
                ?['watchEndpoint']?['videoId'])
            ?.toString();
        if (videoId == null || videoId.isEmpty || !seenIds.add(videoId)) continue;
        final title = _flexColumnText(item, 0);
        if (title.isEmpty) continue;
        final artistRuns = _artistRunsInSubtitle(item);

        final rowArt = _ytmThumbnailUrl(item);
        final song = Song(
          id: videoId,
          title: _cleanText(title),
          artist: _cleanText(
              artistRuns.isNotEmpty ? artistRuns.first.name : '', collapseJukeboxTitle: false),
          album: _cleanText(albumTitle),
          artworkUrl: headerArtworkUrl.isNotEmpty ? headerArtworkUrl : rowArt,
          streamUrl: null,
          source: SongSource.youtube,
          artistChannelId: artistRuns.isNotEmpty ? artistRuns.first.channelId : null,
        );

        if (RecommendationEngine.isNonMusicContent(song)) continue;
        songs.add(song);
      }
      return (songs: songs, headerArtworkUrl: headerArtworkUrl, relatedShelves: relatedShelves);
    } catch (e) {
      _log('[_fetchYtAlbumSongs] failed for $albumBrowseId: $e');
      return (songs: <Song>[], headerArtworkUrl: '', relatedShelves: <AlbumRelatedShelf>[]);
    }
  }

  static List<AlbumRelatedShelf> _parseAlbumRelatedShelves(dynamic decoded) {
    final shelves = <AlbumRelatedShelf>[];
    for (final carousel in _findRenderers(decoded, 'musicCarouselShelfRenderer')) {
      final headerRenderer =
          (carousel['header']?['musicCarouselShelfBasicHeaderRenderer'] as Map?)
              ?.cast<String, dynamic>();
      final titleRuns = (headerRenderer?['title']?['runs'] as List?) ?? const [];
      final shelfTitle = titleRuns
          .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
          .join()
          .trim();
      if (shelfTitle.isEmpty) continue;

      final albums = <ArtistAlbum>[];
      final seenIds = <String>{};
      for (final card in _findRenderers(carousel, 'musicTwoRowItemRenderer')) {
        final cardTitleRuns = (card['title']?['runs'] as List?) ?? const [];
        final cardTitle = cardTitleRuns
            .map((r) => (r is Map ? (r['text'] ?? '') : '').toString())
            .join()
            .trim();
        if (cardTitle.isEmpty || cardTitleRuns.isEmpty) continue;
        final titleNav =
            ((cardTitleRuns.first as Map)['navigationEndpoint'] as Map?)?.cast<String, dynamic>();
        final browseId = (titleNav?['browseEndpoint']?['browseId'] ?? '').toString();

        if (!browseId.startsWith('MPRE') || !seenIds.add(browseId)) continue;

        final cardArt = _ytmThumbnailUrl(card);
        final subtitleRuns = (card['subtitle']?['runs'] as List?) ?? const [];
        String? year;
        for (final r in subtitleRuns) {
          final text = (r is Map ? (r['text'] ?? '') : '').toString();
          final yearMatch = RegExp(r'^(19|20)\d{2}$').firstMatch(text.trim());
          if (yearMatch != null) {
            year = yearMatch.group(0);
            break;
          }
        }
        albums.add(ArtistAlbum(
          id: browseId,
          name: _cleanText(cardTitle),
          artworkUrl: cardArt,
          year: year,
          type: 'album',
        ));
      }
      if (albums.isNotEmpty) {
        shelves.add(AlbumRelatedShelf(title: shelfTitle, albums: albums));
      }
    }
    return shelves;
  }

  static ArtistAlbum _artistAlbumFromJson(Map<String, dynamic> j, {required String type}) {
    return ArtistAlbum(
      id: (j['id'] ?? '').toString(),
      name: _cleanText((j['name'] ?? j['title'] ?? 'Unknown').toString()),
      artworkUrl: _onrenderArtwork(j),
      year: j['year']?.toString(),
      type: type,
    );
  }

  static SongSource sourceFromString(String? s) {
    switch (s) {
      case 'saavn':   return SongSource.saavn;
      case 'youtube': return SongSource.youtube;
      case 'local':   return SongSource.local;
      default:        return SongSource.saavn;
    }
  }

  static Future<String?> fetchLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return null;
    final cacheKey = '${song.source.name}:${song.id}';
    if (LyricsCache.hasPlain(cacheKey)) return LyricsCache.getPlain(cacheKey);

    String? lyrics = await _fetchLrcLibLyrics(song.title, song.artist);
    if (lyrics == null || lyrics.isEmpty) {
      final saavnId = song.source == SongSource.saavn
          ? song.id
          : await _resolveSaavnIdForLyrics(song.title, song.artist);
      if (saavnId != null) lyrics = await _fetchSaavnLyrics(saavnId);
    }

    if (lyrics == null || lyrics.isEmpty) {
      lyrics = await _fetchLyricsOvh(song.artist, song.title);
    }
    if (lyrics == null || lyrics.isEmpty) {
      lyrics = await _fetchLyricsMania(song.artist, song.title);
    }
    if (lyrics != null && lyrics.isNotEmpty) {
      LyricsCache.setPlain(cacheKey, lyrics);
    }
    return lyrics;
  }

  static Future<LyricsResult> fetchSyncedLyrics(Song song) async {
    if (song.isLocal || song.id.isEmpty) return const LyricsResult();
    final cacheKey = '${song.source.name}:${song.id}';
    if (LyricsCache.hasSynced(cacheKey)) {
      return LyricsCache.getSynced(cacheKey)!;
    }

    try {
      return await _fetchSyncedLyricsChain(song, cacheKey)
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {

      return const LyricsResult();
    }
  }

  static Future<LyricsResult> _fetchSyncedLyricsChain(
    Song song,
    String cacheKey,
  ) async {
    final result = await _fetchLrcLibSynced(song.title, song.artist, song.duration);
    LyricsResult finalResult = result;

    if (!finalResult.hasAny) {
      final saavnId = song.source == SongSource.saavn
          ? song.id
          : await _resolveSaavnIdForLyrics(song.title, song.artist);
      if (saavnId != null) {
        final saavnPlain = await _fetchSaavnLyrics(saavnId);
        if (saavnPlain != null && saavnPlain.isNotEmpty) {
          finalResult = LyricsResult(plain: saavnPlain);
        }
      }
    }

    if (!finalResult.hasAny) {
      final ovhPlain = await _fetchLyricsOvh(song.artist, song.title);
      if (ovhPlain != null && ovhPlain.isNotEmpty) {
        finalResult = LyricsResult(plain: ovhPlain);
      }
    }

    if (!finalResult.hasAny) {
      final maniaPlain = await _fetchLyricsMania(song.artist, song.title);
      if (maniaPlain != null && maniaPlain.isNotEmpty) {
        finalResult = LyricsResult(plain: maniaPlain);
      }
    }

    if (finalResult.hasAny) {
      LyricsCache.setSynced(cacheKey, finalResult);
    }
    return finalResult;
  }

  static final Map<String, String?> _saavnIdForLyricsCache = {};
  static const int _maxSaavnIdCache = 500;

  static Future<String?> _resolveSaavnIdForLyrics(String title, String artist) async {
    final key = '$title|$artist';
    if (_saavnIdForLyricsCache.containsKey(key)) return _saavnIdForLyricsCache[key];
    String? foundId;
    try {
      final cleanTitle = _cleanTitleForLyricsSearch(title);
      final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();

      Song? best;
      double bestScore = 0.0;
      void consider(List<Song> candidates) {
        for (final s in candidates) {
          final titleSim = _tokenSimilarity(cleanTitle, s.title);
          if (titleSim < 0.42) continue;
          final artistSim = _tokenSimilarity(primaryArtist, s.artist);
          final score = (titleSim * 0.6) + (artistSim * 0.4);
          if (score > bestScore) {
            bestScore = score;
            best = s;
          }
        }
      }

      consider(await _searchSaavn('$cleanTitle $artist', limit: 5));
      if (bestScore < 0.95) {
        consider(await _searchSaavn(cleanTitle, limit: 5));
      }

      if (best != null && bestScore >= 0.48) foundId = best!.id;
    } catch (_) {}

    if (_saavnIdForLyricsCache.length >= _maxSaavnIdCache) {
      _saavnIdForLyricsCache.remove(_saavnIdForLyricsCache.keys.first);
    }
    _saavnIdForLyricsCache[key] = foundId;
    return foundId;
  }

  static Future<LyricsResult> _fetchLrcLibSynced(
    String title,
    String artist,
    int? durationSeconds,
  ) async {
    final best = await _searchLrcLib(title, artist, durationSeconds: durationSeconds);
    if (best == null) return const LyricsResult();

    final syncedRaw = best['syncedLyrics'] as String?;
    final plainRaw = best['plainLyrics'] as String?;

    if (syncedRaw != null && syncedRaw.isNotEmpty) {
      final parsed = LyricsResult.parseLrc(syncedRaw);
      if (parsed.isNotEmpty) {
        final plainFallback = parsed.map((l) => l.text).where((t) => t.isNotEmpty).join('\n');
        return LyricsResult(synced: parsed, plain: plainFallback);
      }
    }
    if (plainRaw != null && plainRaw.isNotEmpty) {
      return LyricsResult(plain: plainRaw);
    }
    return const LyricsResult();
  }

  static Future<String?> _fetchSaavnLyrics(String songId) async {
    try {
      final res = await _client
          .get(Uri.parse('$_saavn/lyrics/?id=$songId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final l = data['data']?['lyrics'] as String?;
        if (l == null || l.isEmpty) return null;
        final cleaned = _sanitizeHtmlLyrics(l);
        return cleaned.isNotEmpty ? cleaned : null;
      }
    } catch (_) {}
    return null;
  }

  static String _sanitizeHtmlLyrics(String raw) {
    var t = raw;
    t = t.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    t = t.replaceAll(RegExp(r'<p\s*/?>', caseSensitive: false), '\n');
    t = t.replaceAll(RegExp(r'</p>', caseSensitive: false), '');

    t = t.replaceAll(RegExp(r'<[^>]+>'), '');
    t = t
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');

    t = t
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
    return t.trim();
  }

  static Future<String?> _fetchLyricsOvh(String artist, String title) async {
    try {
      final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();
      final a = Uri.encodeComponent(_cleanTitleForLyricsSearch(primaryArtist));
      final t = Uri.encodeComponent(_cleanTitleForLyricsSearch(title));
      if (a.isEmpty || t.isEmpty) return null;
      final res = await _client
          .get(Uri.parse('https://api.lyrics.ovh/v1/$a/$t'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final l = data['lyrics'] as String?;
        if (l == null || l.isEmpty) return null;
        final cleaned = _sanitizeHtmlLyrics(l);
        return cleaned.isNotEmpty ? cleaned : null;
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _fetchLyricsMania(String artist, String title) async {
    try {
      final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();
      final a = _lyricsManiaSlug(primaryArtist);
      final t = _lyricsManiaSlug(_cleanTitleForLyricsSearch(title));
      if (a.isEmpty || t.isEmpty) return null;
      final uri = Uri.parse('https://www.lyricsmania.com/${t}_lyrics_$a.html');
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final document = html_parser.parse(res.body);
        final body = document.querySelectorAll('.lyrics-body');
        if (body.isNotEmpty) {
          final text = body.first.text.trim();
          return text.isNotEmpty ? text : null;
        }
      }
    } catch (_) {}
    return null;
  }

  static String _lyricsManiaSlug(String input) {
    var result = input.replaceAll(' ', '_').toLowerCase();
    result = result.replaceAll(RegExp(r'[^a-z0-9_]'), '');
    result = result.replaceAll(RegExp(r'_+'), '_');
    if (result.startsWith('_')) result = result.substring(1);
    if (result.endsWith('_')) result = result.substring(0, result.length - 1);
    return result;
  }

  static String _cleanTitleForLyricsSearch(String title) {
    var t = title;
    t = t.replaceAll(RegExp(r'\(From\s+["“][^"”]*["”]\)', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\((From|feat\.?|ft\.?)[^)]*\)', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'-\s*(Remastered|Reprise|Bonus Track).*$', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    return t.trim();
  }

  static String _normalizeForMatch(String s) {
    var t = s.toLowerCase();
    t = t.replaceAll(RegExp(r"[^\p{L}\p{N}\s]", unicode: true), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  static double _tokenSimilarity(String a, String b) {
    final ta = _normalizeForMatch(a).split(' ').where((w) => w.isNotEmpty).toSet();
    final tb = _normalizeForMatch(b).split(' ').where((w) => w.isNotEmpty).toSet();
    if (ta.isEmpty || tb.isEmpty) return 0.0;
    final overlap = ta.intersection(tb).length;
    final smaller = ta.length < tb.length ? ta.length : tb.length;
    return overlap / smaller;
  }

  static double _lrcLibMatchScore(
    Map<String, dynamic> entry,
    String title,
    String artist,
    int? durationSeconds,
  ) {
    final entryTitle = (entry['trackName'] as String?) ?? '';
    final entryArtist = (entry['artistName'] as String?) ?? '';
    final titleSim = _tokenSimilarity(_cleanTitleForLyricsSearch(title), entryTitle);
    final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();
    final artistSim = _tokenSimilarity(primaryArtist, entryArtist);

    if (titleSim < 0.42) return 0.0;

    double score = (titleSim * 0.6) + (artistSim * 0.4);

    final d = entry['duration'];
    if (durationSeconds != null && d is num) {
      final diff = (d.toInt() - durationSeconds).abs();
      if (diff <= 3) {
        score += 0.3;
      } else if (diff > 15) {
        score -= 0.4;
      }
    }
    return score.clamp(0.0, 1.0);
  }

  static Future<Map<String, dynamic>?> _searchLrcLib(
    String title,
    String artist, {
    int? durationSeconds,
  }) async {
    final cleanTitle = _cleanTitleForLyricsSearch(title);

    final primaryArtist = artist.split(RegExp(r'[,&/]')).first.trim();

    final bareTitle = cleanTitle
        .replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final noFeatTitle = cleanTitle
        .replaceAll(RegExp(r'\b(feat\.?|ft\.?)\s+.*$', caseSensitive: false), '')
        .trim();

    final queries = <String>{
      '$cleanTitle $artist',
      if (primaryArtist != artist && primaryArtist.isNotEmpty) '$cleanTitle $primaryArtist',
      if (cleanTitle != title) '$title $artist',
      cleanTitle,
      if (primaryArtist.isNotEmpty) '$primaryArtist $cleanTitle',
      if (bareTitle.isNotEmpty && bareTitle != cleanTitle) '$bareTitle $primaryArtist',
      if (bareTitle.isNotEmpty && bareTitle != cleanTitle) bareTitle,
      if (noFeatTitle.isNotEmpty && noFeatTitle != cleanTitle) '$noFeatTitle $primaryArtist',

      if (primaryArtist.isNotEmpty) '$primaryArtist - $cleanTitle',

      if (bareTitle.isNotEmpty) bareTitle,
    }.where((q) => q.trim().isNotEmpty).toList();

    Map<String, dynamic>? bestEntry;
    double bestScore = 0.0;

    for (final q in queries) {
      try {
        final res = await _client
            .get(Uri.parse('https://lrclib.net/api/search?q=${Uri.encodeQueryComponent(q)}'))
            .timeout(const Duration(seconds: 6));
        if (res.statusCode != 200) continue;
        final data = jsonDecode(res.body);
        if (data is! List || data.isEmpty) continue;

        for (final entry in data.take(8)) {
          if (entry is! Map<String, dynamic>) continue;
          final score = _lrcLibMatchScore(entry, title, artist, durationSeconds);
          if (score > bestScore) {
            bestScore = score;
            bestEntry = entry;
          }
        }

        if (bestScore >= 0.95) break;
      } catch (_) {
        continue;
      }
    }

    if (bestEntry != null && bestScore >= 0.48) return bestEntry;
    return null;
  }

  static Future<String?> _fetchLrcLibLyrics(String title, String artist) async {
    final best = await _searchLrcLib(title, artist);
    if (best == null) return null;
    final plain = best['plainLyrics'] as String?;
    if (plain != null && plain.isNotEmpty) return plain;
    final synced = best['syncedLyrics'] as String?;
    if (synced != null && synced.isNotEmpty) {
      return synced
          .split('\n')
          .map((line) => line.replaceFirst(RegExp(r'^\[\d{2}:\d{2}\.\d{2,3}\] ?'), ''))
          .where((line) => line.isNotEmpty)
          .join('\n');
    }
    return null;
  }

  static String _onrenderArtwork(Map<String, dynamic> j) {
    final imgField = j['image'];
    if (imgField is List && imgField.isNotEmpty) {

      const targetSize = 150;
      Map? best;
      int bestSize = -1;
      Map? closestAbove;
      int closestAboveSize = 1 << 30;
      for (final entry in imgField) {
        if (entry is! Map || entry['url'] is! String) continue;
        final u = entry['url'] as String;
        if (!u.startsWith('http')) continue;
        final q = (entry['quality'] ?? '').toString();
        final match = RegExp(r'(\d+)x\d+').firstMatch(q);
        // BUGFIX (production-hardening recheck): int.parse throws
        // FormatException on any non-numeric capture — the regex itself
        // only matches digits so this couldn't fail today, but this
        // function has no surrounding try/catch at any of its 3 call
        // sites, so a future Saavn response-format change here would
        // crash the whole artwork lookup instead of just skipping one
        // malformed entry. tryParse fails safe (treats it as size 0,
        // same as the "no match" branch already does) instead of throwing.
        final size = match != null ? (int.tryParse(match.group(1)!) ?? 0) : 0;
        if (size == targetSize) {
          best = entry;
          bestSize = size;
          break;
        }
        if (size > targetSize && size < closestAboveSize) {
          closestAbove = entry;
          closestAboveSize = size;
        }
        if (size >= bestSize) {
          bestSize = size;
          best = entry;
        }
      }
      final chosen = (bestSize == targetSize ? best : null) ?? closestAbove ?? best;
      if (chosen != null) return chosen['url'] as String;
    }
    if (imgField is String && imgField.startsWith('http')) {
      return imgField
          .replaceAll('150x150', '500x500')
          .replaceAll('50x50',   '500x500');
    }
    return '';
  }

  static final RegExp _emojiPattern = RegExp(
    r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]',
    unicode: true,
  );

  static final RegExp _bracketTagPattern = RegExp(
    r'[\(\[\{]\s*(official\s*(video|audio|music\s*video)?|lyrics?(\s*video)?|'
    r'hd|4k|8k|full\s*(video|song|audio|hd)?|new|latest|original|explicit|'
    r'visualizer|audio\s*only|with\s*lyrics|slowed\s*(down|\+?\s*reverb)?|'
    r'reverb|bass\s*boosted|extended|clean|dirty|radio\s*edit|'
    r'\d{3,4}p|prod\.?\s*by\s*.*?|from\s*.*?)\s*[\)\]\}]',
    caseSensitive: false,
  );

  static final RegExp _channelSuffixPattern = RegExp(
    r'\s*[\|•]\s*(t-?series|zee music|sony music|saregama|tips|speed records|'
    r'desi music|shemaroo|venus|eros now music|vevo|records?|'
    r'yrf|excel movies|ultra|goldmines|sagahits|wave music|'
    r'movies?\s*&?\s*music)\b.*$',
    caseSensitive: false,
  );

  static final RegExp _looseNoiseWords = RegExp(
    r'\b(official\s*(music\s*)?video|official\s*audio|lyrical\s*video|'
    r'lyrics\s*video|full\s*video\s*song|video\s*song|full\s*song|'
    r'audio\s*jukebox|hd\s*video|new\s*song\s*\d{4}|latest\s*(bollywood\s*)?'
    r'song\s*\d{4}|trending\s*song|viral\s*song|whatsapp\s*status|'
    r'status\s*video|ringtone)\b',
    caseSensitive: false,
  );

  static final RegExp _bareNoiseSegment = RegExp(
    r'[\|•]\s*(video|song|full\s*video|title\s*song)\s*(?=[\|•]|$)',
    caseSensitive: false,
  );

  static final RegExp _devanagariNoiseWords = RegExp(
    r'(गाना\s*वीडियो|फुल\s*वीडियो|ऑफिशियल\s*वीडियो|न्यू\s*सॉन्ग|लेटेस्ट\s*सॉन्ग|'
    r'वीडियो\s*सॉन्ग|फुल\s*सॉन्ग|गाना|वीडियो)',
  );

  static final RegExp _viewCountPromoPattern = RegExp(
    r'\b\d[\d,]*\s*(million|crore|lakh|k|m|b)?\+?\s*views?\b',
    caseSensitive: false,
  );

  static String _firstTitleSegment(String s) {
    final segments = s
        .split(RegExp(r'[\|•]'))
        .map((seg) => seg.trim())
        .where((seg) => seg.isNotEmpty)
        .toList();
    if (segments.length <= 1) return s;
    return segments.first;
  }

  static String _cleanText(String s, {bool collapseJukeboxTitle = true}) {
    var out = s
        .replaceAll('&amp;',  '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&lt;',   '<')
        .replaceAll('&gt;',   '>');
    out = out.replaceAll(_emojiPattern, '');
    out = out.replaceAll(_viewCountPromoPattern, '');
    out = out.replaceAll(_channelSuffixPattern, '');
    out = out.replaceAll(_bracketTagPattern, '');
    out = out.replaceAll(_looseNoiseWords, '');
    out = out.replaceAll(_devanagariNoiseWords, '');
    out = out.replaceAll(_bareNoiseSegment, '');

    out = out.replaceAll(RegExp(r'[\(\[\{]\s*[\)\]\}]'), '');

    out = out.replaceAll(RegExp(r'\s*[-|•]\s*(?=[-|•]|$)'), ' ');
    out = out.replaceAll(RegExp(r'^\s*[-|•]\s*'), '');
    out = out.replaceAll(RegExp(r'\s*[-|•]\s*$'), '');
    out = out.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    if (collapseJukeboxTitle) out = _firstTitleSegment(out);
    out = _titleCaseIfShouting(out);
    return out;
  }

  static String _titleCaseIfShouting(String s) {
    if (s.isEmpty) return s;
    final hasLower = s.contains(RegExp(r'[a-z]'));
    final hasMultiLetterWord = s.contains(RegExp(r'[A-Za-z]{2,}'));
    if (hasLower || !hasMultiLetterWord) return s;

    const _lowerMidWords = {
      'a', 'an', 'the', 'of', 'in', 'on', 'at', 'to', 'for', 'and',
      'or', 'nor', 'but', 'is', 'as', 'by', 'de', 'da',
    };

    const _keepUppercaseWords = {
      'dj', 'mtv', 'ost', 'hd', '4k', '8k', 'edm', 'rnb', 'ep', 'lp',
      'tv', 'fm', 'ft', 'vs', 'dvd', 'cd', 'usa', 'uk', 'ai',
    };
    final words = s.split(' ');
    final rebuilt = <String>[];
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      if (w.isEmpty) { rebuilt.add(w); continue; }

      if (!w.contains(RegExp(r'[A-Za-z]'))) { rebuilt.add(w); continue; }
      final lower = w.toLowerCase();
      final bareWord = lower.replaceAll(RegExp(r'[^a-z]'), '');
      if (_keepUppercaseWords.contains(bareWord)) {
        rebuilt.add(w);
        continue;
      }
      if (i != 0 && _lowerMidWords.contains(bareWord)) {
        rebuilt.add(lower);
        continue;
      }

      final buf = StringBuffer();
      var capitalizeNext = true;
      for (final ch in lower.split('')) {
        if (RegExp(r'[a-z]').hasMatch(ch)) {
          buf.write(capitalizeNext ? ch.toUpperCase() : ch);
          capitalizeNext = false;
        } else {
          buf.write(ch);
          capitalizeNext = true;
        }
      }
      rebuilt.add(buf.toString());
    }
    return rebuilt.join(' ');
  }

  static int? _parseInt(dynamic d) {
    if (d == null)   return null;
    if (d is int)    return d;
    if (d is double) return d.toInt();
    if (d is String) return int.tryParse(d);
    return null;
  }

  static String _normalise(String s) {
    final clean = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return clean.substring(0, clean.length.clamp(0, 25));
  }

  static const List<List<String>> _hinglishSubPairs = [
    ['q', 'k'], ['w', 'v'], ['ph', 'f'], ['sh', 's'],
    ['z', 'j'], ['aa', 'a'], ['ee', 'i'], ['oo', 'u'],
  ];

  static Set<String> _generateTypoVariants(String q, List<String> words) {
    final variants = <String>{};
    for (final w in words) {
      if (w.length < 5) continue;

      final collapsed = w.replaceAllMapped(
        RegExp(r'(.)\1+'), (m) => m.group(1)!,
      );
      if (collapsed != w && collapsed.length >= 3) {
        variants.add(words.map((ow) => ow == w ? collapsed : ow).join(' '));
      }

      if (w.length >= 6) {
        final trimmed = w.substring(0, w.length - 1);
        variants.add(words.map((ow) => ow == w ? trimmed : ow).join(' '));
      }

      for (final pair in _hinglishSubPairs) {
        final a = pair[0], b = pair[1];
        if (w.contains(a)) {
          final sub = w.replaceFirst(a, b);
          if (sub != w) variants.add(words.map((ow) => ow == w ? sub : ow).join(' '));
        }
        if (w.contains(b)) {
          final sub = w.replaceFirst(b, a);
          if (sub != w) variants.add(words.map((ow) => ow == w ? sub : ow).join(' '));
        }
      }
    }
    variants.remove(q);

    if (variants.length > 8) return variants.take(8).toSet();
    return variants;
  }

  static String _phoneticKey(String word) {
    if (word.isEmpty) return word;
    var w = word.toLowerCase();
    const clusterMap = <String, String>{
      'chh': 'c', 'sh': 's', 'ph': 'f', 'kh': 'k', 'gh': 'g',
      'th': 't', 'dh': 'd', 'jh': 'j', 'bh': 'b', 'ch': 'c',
    };
    for (final entry in clusterMap.entries) {
      w = w.replaceAll(entry.key, entry.value);
    }
    w = w.replaceAll('w', 'v');

    w = w.replaceAll('g', 'j');

    if (w.length > 1) {
      w = w[0] + w.substring(1).replaceAll('y', '');
    }

    w = w.replaceAll(RegExp(r'[aeiou]+'), 'a');

    w = w.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m.group(1)!);

    if (w.length > 1 && w.endsWith('a')) w = w.substring(0, w.length - 1);
    return w;
  }

  static bool _phoneticMatch(String a, String b) {
    if (a.length < 4 || b.length < 4) return false;
    final ka = _phoneticKey(a);
    final kb = _phoneticKey(b);
    if (ka.length < 2 || kb.length < 2) return false;
    return ka == kb;
  }

  static int _editDistance(String a, String b, {int maxDistance = 3}) {
    if (a == b) return 0;
    final la = a.length, lb = b.length;
    if ((la - lb).abs() > maxDistance) return maxDistance + 1;
    if (la == 0) return lb;
    if (lb == 0) return la;
    var prev = List<int>.generate(lb + 1, (j) => j);
    for (var i = 1; i <= la; i++) {
      final cur = List<int>.filled(lb + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= lb; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = [
          cur[j - 1] + 1,
          prev[j] + 1,
          prev[j - 1] + cost,
        ].reduce((v, e) => v < e ? v : e);
      }
      prev = cur;
    }
    return prev[lb];
  }

  static int _maxEditsFor(int wordLength) {
    if (wordLength <= 4) return 1;
    if (wordLength <= 7) return 2;
    return 3;
  }

  static bool _fuzzyWordMatch(String word, String target) {
    if (word.length < 3) return word == target;
    if (target.contains(word)) return true;

    final targetIsSingleWord = !target.contains(' ');
    if (targetIsSingleWord) {

      if (_phoneticMatch(word, target)) return true;
    }
    final maxEdits = _maxEditsFor(word.length);
    if (targetIsSingleWord &&
        _editDistance(word, target, maxDistance: maxEdits) <= maxEdits) {
      return true;
    }

    for (final token in target.split(RegExp(r'\s+'))) {
      if (token.length < 3) continue;
      if (_phoneticMatch(word, token)) return true;
      if (_editDistance(word, token, maxDistance: maxEdits) <= maxEdits) return true;
    }
    return false;
  }

  static Map<String, dynamic> getDiagnosticsSnapshot() {
    return {
      'timestamp':           DateTime.now().toIso8601String(),
      'stream_cache_size':   _streamCache.length,
      'search_cache_size':   _searchCache.length,
      'quick_search_cache_size': _quickSearchCache.length,
      'pending_resolutions': _pendingResolutions.length,
      'prefetch_active':     _activePrefetch != null,
      'prefetch_queue_size': _prefetchQueue.length,
      'explode_warmed_up':   _explodeWarmedUp,
      'lyrics_cached':       LyricsCache.plainSize,
      'worker_base':         _worker,
      'saavn_base':          _saavn,
      'piped_instances':     _kPipedInstances,
      'invidious_instances': _kInvidiousInstances,
    };
  }

  static Future<String> debugPlaybackPath({
    Future<RealPlaybackResult> Function(Song)? realPlaybackTest,
  }) async {
    final buf = StringBuffer();
    buf.writeln('=== Astra Playback Diagnostics v4 ===');
    buf.writeln('Time:   ${DateTime.now()}');
    buf.writeln('Worker: $_worker');
    buf.writeln('Saavn:  $_saavn');
    buf.writeln('');

    buf.writeln('▶ 1. Cloudflare Worker');
    try {
      final sw = Stopwatch()..start();
      final url = await _workerYtStream('dQw4w9WgXcQ');
      sw.stop();
      buf.writeln(url != null ? '   ✅ OK (${sw.elapsedMilliseconds}ms)' : '   ❌ FAILED');
    } catch (e) { buf.writeln('   ❌ $e'); }

    for (int i = 0; i < _kPipedInstances.length; i++) {
      buf.writeln('▶ ${i + 2}. Piped: ${_kPipedInstances[i]}');
      try {
        final sw = Stopwatch()..start();
        final url = await _pipedStream('dQw4w9WgXcQ', _kPipedInstances[i]);
        sw.stop();
        buf.writeln(url != null ? '   ✅ OK (${sw.elapsedMilliseconds}ms)' : '   ❌ FAILED');
      } catch (e) { buf.writeln('   ❌ $e'); }
    }

    buf.writeln('▶ ${_kPipedInstances.length + 2}. Saavn search');
    List<Song> testSongs = [];
    try {
      final sw = Stopwatch()..start();
      testSongs = await _searchSaavn('arijit singh', limit: 3);
      sw.stop();
      buf.writeln(testSongs.isNotEmpty
          ? '   ✅ OK (${sw.elapsedMilliseconds}ms) — ${testSongs.length} results, first: "${testSongs.first.title}"'
          : '   ❌ FAILED — 0 results');
    } catch (e) { buf.writeln('   ❌ $e'); }

    buf.writeln('▶ ${_kPipedInstances.length + 3}. Saavn STREAM resolve');
    String? resolvedUrl;
    if (testSongs.isNotEmpty) {
      final testSong = testSongs.first;
      buf.writeln('   song: "${testSong.title}" id=${testSong.id}');
      try {
        final sw = Stopwatch()..start();
        resolvedUrl = await resolveStreamUrl(testSong, forceRefresh: true)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        sw.stop();
        buf.writeln(resolvedUrl != null
            ? '   ✅ OK (${sw.elapsedMilliseconds}ms)\n   FULL URL:\n   $resolvedUrl'
            : '   ❌ FAILED — resolveStreamUrl returned null');
      } catch (e) {
        buf.writeln('   ❌ EXCEPTION: $e');
      }
    } else {
      buf.writeln('   ⏭ skipped — no test song available');
    }

    buf.writeln('▶ ${_kPipedInstances.length + 4}. REAL PLAYBACK TEST'
        '${realPlaybackTest != null ? " (via live AurumAudioEngine)" : " (throwaway player — no engine wired)"}');
    if (resolvedUrl != null && testSongs.isNotEmpty) {
      if (realPlaybackTest != null) {
        try {
          final sw = Stopwatch()..start();
          final result = await realPlaybackTest(testSongs.first)
              .timeout(const Duration(seconds: 15));
          sw.stop();
          buf.writeln('   setAudioSource+play attempted in ${sw.elapsedMilliseconds}ms');
          buf.writeln(result.success
              ? '   ✅ PLAYBACK CONFIRMED — position advanced to ${result.positionMs}ms, '
                'state=${result.processingState}'
              : '   ❌ PLAYBACK FAILED — position ${result.positionMs}ms after wait, '
                'state=${result.processingState}'
                '${result.errorMessage != null ? "\n      ERROR: ${result.errorMessage}" : ""}');
        } catch (e, st) {
          buf.writeln('   ❌ PLAYBACK EXCEPTION (real handler): $e');
          if (e is PlayerException) {
            buf.writeln('      code=${e.code} message=${e.message}');
          }
          buf.writeln('      STACK: $st');
          debugPrint('[Diagnostics] Real-handler playback test stack: $st');
        }
      } else {

        final testPlayer = AudioPlayer();
        try {
          final sw = Stopwatch()..start();
          await testPlayer.setAudioSource(
            AudioSource.uri(
              Uri.parse(resolvedUrl),
              headers: const {
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 11; Pixel 4) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
              },
            ),
            preload: true,
          ).timeout(const Duration(seconds: 15));
          sw.stop();
          final dur = testPlayer.duration;
          buf.writeln('   ✅ setAudioSource OK (${sw.elapsedMilliseconds}ms), '
              'duration=${dur ?? "null"}, state=${testPlayer.processingState}');

          await testPlayer.play();
          await Future.delayed(const Duration(seconds: 2));
          final pos = testPlayer.position;
          buf.writeln(pos.inMilliseconds > 200
              ? '   ✅ PLAYBACK CONFIRMED — position advanced to ${pos.inMilliseconds}ms'
              : '   ❌ PLAYBACK STUCK — position still ${pos.inMilliseconds}ms after 2s play, '
                'processingState=${testPlayer.processingState}');
        } catch (e, st) {
          buf.writeln('   ❌ PLAYBACK EXCEPTION: $e');
          if (e is PlayerException) {
            buf.writeln('      code=${e.code} message=${e.message}');
          }
          buf.writeln('      STACK: $st');
          debugPrint('[Diagnostics] Playback test stack: $st');
        } finally {
          await testPlayer.dispose();
        }
      }
    } else {
      buf.writeln('   ⏭ skipped — no resolved URL/test song to test');
    }

    return buf.toString();
  }

  static const Set<String> _saavnDirectSafeHosts = {

  };

  static String _proxiedSaavnUrl(String url) {
    if (url.isEmpty) return url;
    final decoded = Uri.decodeComponent(url);
    if (decoded.contains('/stream-proxy?url=') || url.contains('/stream-proxy?url=')) {
      return decoded;
    }
    Uri? parsed;
    try {
      parsed = Uri.parse(decoded);
    } catch (_) {
      parsed = null;
    }
    final host = parsed?.host ?? '';
    if (_saavnDirectSafeHosts.any((h) => host.endsWith(h))) {
      return decoded;
    }

    return '$_saavn/stream-proxy?url=${Uri.encodeComponent(decoded)}';
  }

  static Future<List<Song>> enrichWithCleanMetadata(
    List<Song> songs, {
    int maxLookups = 15,
    Duration overallTimeout = const Duration(seconds: 4),
  }) async {
    return songs;
  }
}

class _CachedStream {
  final String   url;
  final DateTime resolvedAt;
  _CachedStream(this.url) : resolvedAt = DateTime.now();
  bool get isExpired =>
      DateTime.now().difference(resolvedAt) > ApiService._streamTtl;
}

class _CachedSearch {
  final SearchResult results;
  final DateTime   cachedAt;
  _CachedSearch(this.results) : cachedAt = DateTime.now();
  bool get isExpired =>
      DateTime.now().difference(cachedAt) > ApiService._searchTtl;
}

class _CachedQuickSearch {
  final List<Song> results;
  final DateTime   cachedAt;
  _CachedQuickSearch(this.results) : cachedAt = DateTime.now();
  bool get isExpired =>
      DateTime.now().difference(cachedAt) > ApiService._quickSearchTtl;
}

class SearchResult {
  final List<Song> direct;
  final List<Song> related;
  const SearchResult({required this.direct, required this.related});
  List<Song> get all => [...direct, ...related];
  bool get isEmpty => direct.isEmpty && related.isEmpty;
}

class _ScoredSong {
  final Song   song;
  final double score;
  _ScoredSong(this.song, this.score);
}

class _SignalResult {
  final List<Song> songs;
  final int        weight;
  _SignalResult(this.songs, this.weight);
}

class _SectionQuery {
  final String  query;
  final String  label;
  final bool    priority;
  final bool    isSuggestion;
  final String? suggestionSongId;
  final bool    isEnglish;
  const _SectionQuery(this.query, this.label, {
    this.priority = false,
    this.isSuggestion = false,
    this.suggestionSongId,
    this.isEnglish = false,
  });
}

class _PoolEntry {
  final String query;
  final String label;
  const _PoolEntry(this.query, this.label);
}

class _ArtistEntry {
  final String query;
  final String displayName;
  const _ArtistEntry(this.query, this.displayName);
}

class ArtistSimple {
  final String id;
  final String name;
  final String imageUrl;
  const ArtistSimple({required this.id, required this.name, required this.imageUrl});
}
