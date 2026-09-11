// =============================================================================
// FILE: lib/providers/followed_artists_provider.dart
// PROJECT: Astra Music
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

  bool isFollowing(String artistId) {
    final key = artistId.trim();
    if (key.isEmpty) return false;
    return _box?.containsKey(key) ?? false;
  }

  Future<void> toggleFollow({
    required String artistId,
    required String name,
    required String imageUrl,
  }) async {
    // ROBUSTNESS FIX ("follow ho raha hai (icon change hota hai) lekin
    // Library > Artists tab mein nahi dikh raha"): the most likely cause
    // of "saved but not visible" is a key mismatch — the id used to save
    // here ending up with different whitespace, or otherwise not
    // matching, the id used elsewhere to check/display. Trimming the key
    // once, right here, and using that SAME trimmed key for every read/
    // write in this class (isFollowing, toggleFollow, followFromRemote)
    // closes that gap outright — whatever variant of the id the caller
    // passes in, it's normalized the same way every time before it ever
    // touches Hive. An empty/blank id is also now a deliberate no-op
    // instead of silently writing under a blank key, since a blank-key
    // "follow" can never render meaningfully in the list anyway (the
    // Artists tab also now filters out any such entries defensively).
    final key = artistId.trim();
    if (key.isEmpty) return;
    final box = _box ?? await _boxReady.future;
    if (box.containsKey(key)) {
      await box.delete(key);
      if (kDebugMode) {
        debugPrint('[FollowedArtists] UNFOLLOWED id=$key name=$name '
            '— box now has ${box.length} artist(s)');
      }
      unawaited(SyncService.instance.pushUnfollowedArtist(key));
    } else {
      final data = {
        'id': key,
        'name': name,
        'imageUrl': imageUrl,
      };
      await box.put(key, data);
      // Verify the write actually landed instead of assuming it did —
      // if this somehow comes back false (corrupt box, disk full, etc),
      // we at least know that's the real cause rather than guessing.
      final saved = box.containsKey(key);
      if (kDebugMode) {
        debugPrint('[FollowedArtists] FOLLOWED id=$key name=$name '
            'saved=$saved — box now has ${box.length} artist(s): '
            '${box.values.map((m) => m['name']).toList()}');
      }
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
    final key = artistId.trim();
    if (key.isEmpty) return;
    if (isFollowing(key)) return;
    final box = _box ?? await _boxReady.future;
    await box.put(key, {
      'id': key,
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
