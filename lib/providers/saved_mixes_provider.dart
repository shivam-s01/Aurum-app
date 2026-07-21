// =============================================================================
// FILE: lib/providers/saved_mixes_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Persists which curated "mixes" (the Trending Playlists row on
//   Home — Trending Now, Party Anthems, 90s Bollywood, etc) the user has
//   Saved via MixScreen's Save button, Spotify-style.
//
//   These aren't real JioSaavn album IDs — they're client-side curated
//   queries (see _kCuratedPlaylists in home_screen.dart), so unlike
//   FollowedAlbumsProvider (which only needs to store id/name/artworkUrl and
//   re-fetches songs by album ID on open), this provider stores the actual
//   song list snapshot too — there's no album ID to re-fetch from later.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/song.dart';

class SavedMixesProvider extends ChangeNotifier {
  static const _boxName = 'aurum_saved_mixes';
  late Box<String> _box;
  bool _isLoading = true;

  bool get isLoading => _isLoading;

  /// Saved mixes, most-recently-saved first.
  List<Map<String, dynamic>> get saved => _box.values
      .map((raw) => Map<String, dynamic>.from(jsonDecode(raw) as Map))
      .toList()
      .reversed
      .toList();

  Future<void> init() async {
    _box = await Hive.openBox<String>(_boxName);
    _isLoading = false;
    notifyListeners();
  }

  bool isSaved(String mixId) => _box.containsKey(mixId);

  Future<void> toggleSave({
    required String mixId,
    required String name,
    required String artworkUrl,
    required String emoji,
    required List<Song> songs,
  }) async {
    if (isSaved(mixId)) {
      await _box.delete(mixId);
    } else {
      final data = {
        'id': mixId,
        'name': name,
        'artworkUrl': artworkUrl,
        'emoji': emoji,
        // Snapshot at save-time — the mix's contents were already
        // fetched once for the thumbnail/open, no reason to keep
        // hitting the network every time the user reopens a saved mix.
        'songs': songs.map((s) => s.toJson()).toList(),
      };
      await _box.put(mixId, jsonEncode(data));
    }
    notifyListeners();
  }

  /// Rehydrates the stored song list for a saved mix back into [Song]s.
  List<Song> songsFor(String mixId) {
    final raw = _box.get(mixId);
    if (raw == null) return [];
    final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final list = (data['songs'] as List?) ?? [];
    return list
        .map((j) => Song.fromJson(Map<String, dynamic>.from(j as Map)))
        .toList();
  }

  /// Wipes all saved mixes — local only, called on sign-out.
  Future<void> clearAll() async {
    await _box.clear();
    notifyListeners();
  }
}
