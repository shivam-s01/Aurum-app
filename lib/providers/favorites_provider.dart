// =============================================================================
// FILE: lib/providers/favorites_provider.dart
// PROJECT: Aurum Music
// VERSION: 2.0.0 — RecommendationEngine Integration
//
// WHAT'S NEW IN v2:
//   ✅ toggleFavorite() fires RecommendationEngine.onFavorited/onUnfavorited
//   ✅ All existing API unchanged — fully backward compatible
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/recommendation_engine.dart';
import 'download_provider.dart';

class FavoritesProvider extends ChangeNotifier {
  static const _boxName = 'aurum_favorites';
  late Box<Map> _box;
  List<Song> _favorites = [];
  bool _isLoading = true;

  /// Injected after init so FavoritesProvider can trigger auto-downloads
  /// when the user favorites a song with "Auto-Download Liked Songs" on.
  /// Set from main.dart after both providers are created.
  DownloadProvider? downloadProvider;

  List<Song> get favorites   => List.unmodifiable(_favorites);
  bool get isLoading         => _isLoading;
  bool isFavorite(String id) => _favorites.any((s) => s.id == id);

  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
    _favorites = _box.values
        .map((m) => Song.fromJson(Map<String, dynamic>.from(m)))
        .toList()
        .reversed
        .toList();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> toggleFavorite(Song song) async {
    if (isFavorite(song.id)) {
      await _remove(song.id);
      // Strong negative signal — user un-favorited
      if (song.source != SongSource.local) {
        RecommendationEngine.onUnfavorited(song);
      }
    } else {
      await _add(song);
      if (song.source != SongSource.local) {
        RecommendationEngine.onFavorited(song);
      }
      // Auto-download liked songs if setting is enabled
      final p = await SharedPreferences.getInstance();
      if (p.getBool('auto_download_liked') == true &&
          song.source != SongSource.local) {
        downloadProvider?.download(song);
      }
    }
  }

  Future<void> _add(Song song) async {
    await _box.put(song.id, song.toJson());
    _favorites.insert(0, song);
    notifyListeners();
  }

  Future<void> _remove(String id) async {
    await _box.delete(id);
    _favorites.removeWhere((s) => s.id == id);
    notifyListeners();
  }

  /// Called by SyncService after pulling from Supabase
  Future<void> addFromRemote(Map<String, dynamic> data) async {
    final song = Song.fromJson(data);
    if (!isFavorite(song.id)) {
      await _add(song);
    }
  }

  /// Wipes all liked songs — local only, called on sign-out so a fresh
  /// sign-in (same or different account) starts from an empty library
  /// instead of showing the previous account's likes. Does not touch
  /// Supabase; that data belongs to the account and is simply left behind
  /// until the user signs back in and SyncService pulls it down again.
  Future<void> clearAll() async {
    await _box.clear();
    _favorites = [];
    notifyListeners();
  }
}
