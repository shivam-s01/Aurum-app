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
  // PERF/SAFETY FIX (cold-start race): _box used to be `late Box<Map>`,
  // populated only once init()'s `await Hive.openBox` completes. Every
  // read below (isFollowing, followed, toggleFollow) touched _box
  // directly with no guard — a widget (song_tile.dart, artist_screen.dart)
  // reading isFollowing() in the window between "provider constructed"
  // and "box actually open" would hit a LateInitializationError and
  // crash. Nullable + null-safe reads below close that window: any
  // access before the box opens now returns a safe empty/false default
  // instead of throwing, exactly matching what _isLoading == true
  // already signals to callers.
  Box<Map>? _box;
  bool _isLoading = true;

  bool get isLoading => _isLoading;

  List<Map<String, dynamic>> get followed => (_box?.values ?? const [])
      .map((m) => Map<String, dynamic>.from(m))
      .toList()
      .reversed
      .toList();

  // Lets any mutation method await the box being ready instead of
  // crashing or silently no-op-ing if it's ever called in the (now
  // very small, but non-zero) window before init() finishes — e.g. a
  // user tapping Follow on ArtistScreen in the first instant after a
  // cold start. init() itself already assigns _box directly rather
  // than going through this, so there's no self-deadlock.
  final Completer<Box<Map>> _boxReady = Completer<Box<Map>>();

  Future<void> init() async {
    if (_boxReady.isCompleted) return;
    _box = await Hive.openBox<Map>(_boxName);
    _boxReady.complete(_box);
    _isLoading = false;
    notifyListeners();
  }

  bool isFollowing(String artistId) => _box?.containsKey(artistId) ?? false;

  Future<void> toggleFollow({
    required String artistId,
    required String name,
    required String imageUrl,
  }) async {
    final box = _box ?? await _boxReady.future;
    if (isFollowing(artistId)) {
      await box.delete(artistId);
      unawaited(SyncService.instance.pushUnfollowedArtist(artistId));
    } else {
      final data = {
        'id': artistId,
        'name': name,
        'imageUrl': imageUrl,
      };
      await box.put(artistId, data);
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
    final box = _box ?? await _boxReady.future;
    await box.put(artistId, {
      'id': artistId,
      'name': name,
      'imageUrl': imageUrl,
    });
    notifyListeners();
  }

  /// Wipes all followed artists — local only, called on sign-out.
  Future<void> clearAll() async {
    final box = _box ?? await _boxReady.future;
    await box.clear();
    notifyListeners();
  }
}
