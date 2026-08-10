// =============================================================================
// FILE: lib/providers/favorites_provider.dart
// PROJECT: Aurum Music
// VERSION: 2.0.0 — RecommendationEngine Integration
//
// WHAT'S NEW IN v2:
//   ✅ toggleFavorite() fires RecommendationEngine.onFavorited/onUnfavorited
//   ✅ All existing API unchanged — fully backward compatible
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/recommendation_engine.dart';
import '../services/sync_service.dart';
import 'download_provider.dart';

class FavoritesProvider extends ChangeNotifier {
  static const _boxName = 'aurum_favorites';
  // PERF/SAFETY FIX (cold-start race): see followed_artists_provider.dart's
  // matching comment. isFavorite() already reads the in-memory _favorites
  // list (safe, defaults to []), but the mutation methods below touch
  // _box directly — nullable + Completer keeps those crash-safe too.
  // The window before init() finishes is small in practice but never
  // fully zero, so it's guarded regardless.
  Box<Map>? _box;
  final Completer<Box<Map>> _boxReady = Completer<Box<Map>>();
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
    // Guard against init() being called twice on the same instance (e.g.
    // a stray second call from some future refactor) — Completer.complete()
    // throws "Future already completed" the second time, which would
    // otherwise crash the app instead of safely no-op-ing.
    if (_boxReady.isCompleted) return;
    final box = await Hive.openBox<Map>(_boxName);
    _box = box;
    _boxReady.complete(box);
    _favorites = box.values
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
    final box = _box ?? await _boxReady.future;
    await box.put(song.id, song.toJson());
    _favorites.insert(0, song);
    unawaited(SyncService.instance.pushFavorite(song));
    notifyListeners();
  }

  Future<void> _remove(String id) async {
    final box = _box ?? await _boxReady.future;
    await box.delete(id);
    _favorites.removeWhere((s) => s.id == id);
    unawaited(SyncService.instance.pushUnfavorite(id));
    notifyListeners();
  }

  /// Called by SyncService after pulling from Supabase. Writes locally
  /// only — this song just came FROM the cloud, so mirroring it straight
  /// back up would be a wasteful (and potentially loopy, if another
  /// device is syncing at the same moment) round trip.
  Future<void> addFromRemote(Map<String, dynamic> data) async {
    final song = Song.fromJson(data);
    if (!isFavorite(song.id)) {
      final box = _box ?? await _boxReady.future;
      await box.put(song.id, song.toJson());
      _favorites.insert(0, song);
      notifyListeners();
    }
  }

  /// Wipes all liked songs — local only, called on sign-out so a fresh
  /// sign-in (same or different account) starts from an empty library
  /// instead of showing the previous account's likes. Does not touch
  /// Supabase; that data belongs to the account and is simply left behind
  /// until the user signs back in and SyncService pulls it down again.
  Future<void> clearAll() async {
    final box = _box ?? await _boxReady.future;
    await box.clear();
    _favorites = [];
    notifyListeners();
  }
}
