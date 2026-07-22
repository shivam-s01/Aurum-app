// =============================================================================
// FILE: lib/providers/followed_albums_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Persists which albums the user has "Saved" (Save button on
//   AlbumScreen), Spotify-style. Stores id/name/artworkUrl only — enough to
//   render a "Saved Albums" grid later without re-fetching.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/song.dart';
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
    // Curated home-page mixes (Trending Now, 90s Bollywood, etc) don't have
    // a real JioSaavn album id to re-fetch songs from later, so when saving
    // one of these we snapshot its current song list instead. `isMix` flags
    // the entry so AlbumScreen knows to skip fetchAlbumSongs and use the
    // snapshot on reopen.
    bool isMix = false,
    List<Song> songs = const [],
  }) async {
    if (isFollowing(albumId)) {
      await _box.delete(albumId);
      if (!isMix) {
        unawaited(SyncService.instance.pushUnfollowedAlbum(albumId));
      }
    } else {
      final data = {
        'id': albumId,
        'name': name,
        'artworkUrl': artworkUrl,
        'isMix': isMix,
        if (isMix) 'songs': jsonEncode(songs.map((s) => s.toJson()).toList()),
      };
      await _box.put(albumId, data);
      if (!isMix) {
        unawaited(SyncService.instance.pushFollowedAlbum(data));
      }
    }
    notifyListeners();
  }

  /// Rehydrates the snapshotted song list for a saved mix entry.
  /// Returns an empty list for real albums (those re-fetch by id instead).
  List<Song> songsFor(String albumId) {
    final raw = _box.get(albumId);
    if (raw == null) return [];
    final data = Map<String, dynamic>.from(raw);
    if (data['isMix'] != true) return [];
    final encoded = data['songs'];
    if (encoded is! String) return [];
    final list = (jsonDecode(encoded) as List?) ?? [];
    return list
        .map((j) => Song.fromJson(Map<String, dynamic>.from(j as Map)))
        .toList();
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
