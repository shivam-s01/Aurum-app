// =============================================================================
// FILE: lib/providers/followed_artists_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Persists which artists the user has "Saved" (Follow button on
//   ArtistScreen), Spotify-style. Stores id/name/imageUrl only — enough to
//   render a "Followed Artists" row later without re-fetching.
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/sync_service.dart';

class FollowedArtistsProvider extends ChangeNotifier {
  static const _boxName = 'aurum_followed_artists';
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

  bool isFollowing(String artistId) => _box.containsKey(artistId);

  Future<void> toggleFollow({
    required String artistId,
    required String name,
    required String imageUrl,
  }) async {
    if (isFollowing(artistId)) {
      await _box.delete(artistId);
      unawaited(SyncService.instance.pushUnfollowedArtist(artistId));
    } else {
      final data = {
        'id': artistId,
        'name': name,
        'imageUrl': imageUrl,
      };
      await _box.put(artistId, data);
      unawaited(SyncService.instance.pushFollowedArtist(data));
    }
    notifyListeners();
  }

  /// Called by SyncService while pulling from Supabase — local write
  /// only, so data that just came FROM the cloud doesn't immediately
  /// get pushed straight back to it.
  Future<void> followFromRemote({
    required String artistId,
    required String name,
    required String imageUrl,
  }) async {
    if (isFollowing(artistId)) return;
    await _box.put(artistId, {
      'id': artistId,
      'name': name,
      'imageUrl': imageUrl,
    });
    notifyListeners();
  }

  /// Wipes all followed artists — local only, called on sign-out.
  Future<void> clearAll() async {
    await _box.clear();
    notifyListeners();
  }
}
