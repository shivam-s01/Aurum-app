// =============================================================================
// FILE: lib/providers/followed_albums_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Persists which albums the user has "Saved" (Save button on
//   AlbumScreen), Spotify-style. Stores id/name/artworkUrl only — enough to
//   render a "Saved Albums" grid later without re-fetching.
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/sync_service.dart';

class FollowedAlbumsProvider extends ChangeNotifier {
  static const _boxName = 'aurum_followed_albums';
  late Box<Map> _box;
  bool _isLoading = true;

  bool get isLoading => _isLoading;

  List<Map<String, dynamic>> get followed => _box.values
      .map((m) => Map<String, dynamic>.from(m))
      .toList()
      .reversed
      .toList();

  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
    _isLoading = false;
    notifyListeners();
  }

  bool isFollowing(String albumId) => _box.containsKey(albumId);

  Future<void> toggleFollow({
    required String albumId,
    required String name,
    required String artworkUrl,
  }) async {
    if (isFollowing(albumId)) {
      await _box.delete(albumId);
      unawaited(SyncService.instance.pushUnfollowedAlbum(albumId));
    } else {
      final data = {
        'id': albumId,
        'name': name,
        'artworkUrl': artworkUrl,
      };
      await _box.put(albumId, data);
      unawaited(SyncService.instance.pushFollowedAlbum(data));
    }
    notifyListeners();
  }

  /// Called by SyncService while pulling from Supabase — local write
  /// only, so data that just came FROM the cloud doesn't immediately
  /// get pushed straight back to it.
  Future<void> followFromRemote({
    required String albumId,
    required String name,
    required String artworkUrl,
  }) async {
    if (isFollowing(albumId)) return;
    await _box.put(albumId, {
      'id': albumId,
      'name': name,
      'artworkUrl': artworkUrl,
    });
    notifyListeners();
  }

  /// Wipes all followed albums — local only, called on sign-out.
  Future<void> clearAll() async {
    await _box.clear();
    notifyListeners();
  }
}
