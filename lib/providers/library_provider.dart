import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/local_music_service.dart';
import '../utils/constants.dart';

enum LibraryStatus { idle, loading, loaded, noPermission, empty }

class LibraryProvider extends ChangeNotifier {
  // Local music
  LibraryStatus _localStatus = LibraryStatus.idle;
  List<Song> _localSongs = [];
  List<SongSection> _localSections = [];

  // Favorites
  final List<Song> _favorites = [];

  // Recently Played
  final List<Song> _recentlyPlayed = [];

  // Playlists — stored as Map<name, List<Song>>
  final Map<String, List<Song>> _playlists = {};

  // Downloads (locally downloaded online songs)
  final List<Song> _downloads = [];

  // Search query for local songs
  String _searchQuery = '';

  LibraryProvider() {
    _loadPersistedData();
  }

  // ── Getters ───────────────────────────────────────────────────────────────

  LibraryStatus get localStatus => _localStatus;
  List<Song> get localSongs => _localSongs;
  List<SongSection> get localSections => _localSections;
  bool get hasLocalLoaded =>
      _localStatus == LibraryStatus.loaded ||
      _localStatus == LibraryStatus.empty;

  List<Song> get favorites => List.unmodifiable(_favorites);
  List<Song> get recentlyPlayed => List.unmodifiable(_recentlyPlayed);
  List<Song> get downloads => List.unmodifiable(_downloads);
  Map<String, List<Song>> get playlists =>
      Map.unmodifiable(_playlists);

  bool isFavorite(String songId) =>
      _favorites.any((s) => s.id == songId);

  List<Song> get filteredLocalSongs {
    if (_searchQuery.isEmpty) return _localSongs;
    final q = _searchQuery.toLowerCase();
    return _localSongs
        .where((s) =>
            s.title.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q) ||
            s.album.toLowerCase().contains(q))
        .toList();
  }

  // ── Local Music ───────────────────────────────────────────────────────────

  Future<void> loadLocalMusic() async {
    if (_localStatus == LibraryStatus.loading) return;
    _localStatus = LibraryStatus.loading;
    notifyListeners();

    final hasPermission = await LocalMusicService.hasPermission();
    if (!hasPermission) {
      final granted = await LocalMusicService.requestPermission();
      if (!granted) {
        _localStatus = LibraryStatus.noPermission;
        notifyListeners();
        return;
      }
    }

    final songs = await LocalMusicService.scanLibrary();
    final sections = await LocalMusicService.scanLibrarySections();

    _localSongs = songs;
    _localSections = sections;
    _localStatus =
        songs.isEmpty ? LibraryStatus.empty : LibraryStatus.loaded;
    notifyListeners();
  }

  Future<void> refreshLocalMusic() async {
    _localStatus = LibraryStatus.idle;
    await loadLocalMusic();
  }

  void setLocalSearch(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  void clearLocalSearch() {
    _searchQuery = '';
    notifyListeners();
  }

  // ── Favorites ─────────────────────────────────────────────────────────────

  Future<void> toggleFavorite(Song song) async {
    final exists = _favorites.any((s) => s.id == song.id);
    if (exists) {
      _favorites.removeWhere((s) => s.id == song.id);
    } else {
      _favorites.insert(0, song);
    }
    notifyListeners();
    await _saveFavorites();
  }

  Future<void> addFavorite(Song song) async {
    if (!isFavorite(song.id)) {
      _favorites.insert(0, song);
      notifyListeners();
      await _saveFavorites();
    }
  }

  Future<void> removeFavorite(String songId) async {
    _favorites.removeWhere((s) => s.id == songId);
    notifyListeners();
    await _saveFavorites();
  }

  // ── Recently Played ───────────────────────────────────────────────────────

  Future<void> addToRecentlyPlayed(Song song) async {
    _recentlyPlayed.removeWhere((s) => s.id == song.id);
    _recentlyPlayed.insert(0, song);
    if (_recentlyPlayed.length > AppConstants.recentlyPlayedLimit) {
      _recentlyPlayed.removeLast();
    }
    notifyListeners();
    await _saveRecentlyPlayed();
  }

  // ── Playlists ─────────────────────────────────────────────────────────────

  Future<void> createPlaylist(String name) async {
    if (!_playlists.containsKey(name)) {
      _playlists[name] = [];
      notifyListeners();
      await _savePlaylists();
    }
  }

  Future<void> deletePlaylist(String name) async {
    _playlists.remove(name);
    notifyListeners();
    await _savePlaylists();
  }

  Future<void> addToPlaylist(String playlistName, Song song) async {
    _playlists.putIfAbsent(playlistName, () => []);
    final already =
        _playlists[playlistName]!.any((s) => s.id == song.id);
    if (!already) {
      _playlists[playlistName]!.add(song);
      notifyListeners();
      await _savePlaylists();
    }
  }

  Future<void> removeFromPlaylist(
      String playlistName, String songId) async {
    _playlists[playlistName]?.removeWhere((s) => s.id == songId);
    notifyListeners();
    await _savePlaylists();
  }

  // ── Downloads ─────────────────────────────────────────────────────────────

  bool isDownloaded(String songId) =>
      _downloads.any((s) => s.id == songId);

  Future<void> addDownload(Song song) async {
    if (!isDownloaded(song.id)) {
      _downloads.insert(0, song);
      notifyListeners();
      await _saveDownloads();
    }
  }

  Future<void> removeDownload(String songId) async {
    _downloads.removeWhere((s) => s.id == songId);
    notifyListeners();
    await _saveDownloads();
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _loadPersistedData() async {
    await Future.wait([
      _loadFavorites(),
      _loadRecentlyPlayed(),
      _loadPlaylists(),
      _loadDownloads(),
    ]);
    notifyListeners();
  }

  Future<void> _loadFavorites() async {
    try {
      final box = await Hive.openBox<String>(AppConstants.boxFavorites);
      for (final jsonStr in box.values) {
        try {
          final song = Song.fromJson(
              Map<String, dynamic>.from(jsonDecode(jsonStr)));
          _favorites.add(song);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _saveFavorites() async {
    try {
      final box = await Hive.openBox<String>(AppConstants.boxFavorites);
      await box.clear();
      for (final song in _favorites) {
        await box.add(jsonEncode(song.toJson()));
      }
    } catch (_) {}
  }

  Future<void> _loadRecentlyPlayed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConstants.boxRecentlyPlayed);
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      for (final j in list) {
        try {
          _recentlyPlayed
              .add(Song.fromJson(Map<String, dynamic>.from(j)));
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _saveRecentlyPlayed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AppConstants.boxRecentlyPlayed,
        jsonEncode(_recentlyPlayed.map((s) => s.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _loadPlaylists() async {
    try {
      final box =
          await Hive.openBox<String>(AppConstants.boxPlaylists);
      for (final key in box.keys) {
        try {
          final raw = box.get(key);
          if (raw == null) continue;
          final list = jsonDecode(raw) as List;
          _playlists[key.toString()] = list
              .map((j) =>
                  Song.fromJson(Map<String, dynamic>.from(j)))
              .toList();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _savePlaylists() async {
    try {
      final box =
          await Hive.openBox<String>(AppConstants.boxPlaylists);
      await box.clear();
      for (final entry in _playlists.entries) {
        await box.put(
          entry.key,
          jsonEncode(entry.value.map((s) => s.toJson()).toList()),
        );
      }
    } catch (_) {}
  }

  Future<void> _loadDownloads() async {
    try {
      final box =
          await Hive.openBox<String>(AppConstants.boxDownloads);
      for (final jsonStr in box.values) {
        try {
          _downloads.add(Song.fromJson(
              Map<String, dynamic>.from(jsonDecode(jsonStr))));
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _saveDownloads() async {
    try {
      final box =
          await Hive.openBox<String>(AppConstants.boxDownloads);
      await box.clear();
      for (final song in _downloads) {
        await box.add(jsonEncode(song.toJson()));
      }
    } catch (_) {}
  }
}
