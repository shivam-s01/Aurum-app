// =============================================================================
// FILE: lib/providers/playlist_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Spotify-style user playlists with Hive persistence.
//   ✅ Create / rename / delete playlists (unlimited)
//   ✅ Add / remove songs per playlist
//   ✅ Reorder songs via drag-and-drop
//   ✅ Duplicate-guard (song already in playlist)
//   ✅ Auto-persist to Hive on every mutation
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/song.dart';
import '../services/sync_service.dart';

// ── Model ────────────────────────────────────────────────────────────────────

class AurumPlaylist {
  final String id;
  String name;
  String description;
  List<Song> songs;
  final DateTime createdAt;
  DateTime updatedAt;

  AurumPlaylist({
    required this.id,
    required this.name,
    this.description = '',
    List<Song>? songs,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : songs = songs ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  int get songCount => songs.length;

  /// Total duration in seconds
  int get totalDurationSeconds =>
      songs.fold(0, (sum, s) => sum + (s.duration ?? 0));

  String get totalDurationString {
    final secs = totalDurationSeconds;
    if (secs == 0) return '';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m} min';
  }

  /// Thumbnail: first song's artwork, or null
  String? get coverArt =>
      songs.isNotEmpty ? songs.first.artworkUrl : null;

  /// Grid of up to 4 artwork URLs for mosaic cover
  List<String> get mosaicArts {
    final unique = songs
        .map((s) => s.artworkUrl)
        .where((url) => url.isNotEmpty)
        .toSet()
        .take(4)
        .toList();
    return unique;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'songs': songs.map((s) => s.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory AurumPlaylist.fromJson(Map<String, dynamic> json) {
    return AurumPlaylist(
      id: json['id'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      songs: (json['songs'] as List<dynamic>? ?? [])
          .map((e) => Song.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

// ── Provider ─────────────────────────────────────────────────────────────────

class PlaylistProvider extends ChangeNotifier {
  static const _boxName = 'aurum_playlists';
  late Box<Map> _box;
  List<AurumPlaylist> _playlists = [];
  bool _isLoading = true;

  List<AurumPlaylist> get playlists => List.unmodifiable(_playlists);
  bool get isLoading => _isLoading;
  int get count => _playlists.length;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
    _playlists = _box.values
        .map((m) => AurumPlaylist.fromJson(Map<String, dynamic>.from(m)))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _isLoading = false;
    notifyListeners();
  }

  // ── Create ────────────────────────────────────────────────────────────────

  Future<AurumPlaylist> createPlaylist({
    required String name,
    String description = '',
    Song? initialSong,
  }) async {
    final playlist = AurumPlaylist(
      id: _generateId(),
      name: name.trim().isEmpty ? 'My Playlist' : name.trim(),
      description: description.trim(),
      songs: initialSong != null ? [initialSong] : [],
    );
    _playlists.insert(0, playlist);
    await _persist(playlist);
    notifyListeners();
    return playlist;
  }

  // ── Rename ────────────────────────────────────────────────────────────────

  Future<void> renamePlaylist(String id, String newName,
      {String? newDescription}) async {
    final pl = _findById(id);
    if (pl == null) return;
    pl.name = newName.trim().isEmpty ? pl.name : newName.trim();
    if (newDescription != null) pl.description = newDescription.trim();
    pl.updatedAt = DateTime.now();
    await _persist(pl);
    _sortByUpdated();
    notifyListeners();
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> deletePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    await _box.delete(id);
    unawaited(SyncService.instance.pushPlaylistDeleted(id));
    notifyListeners();
  }

  // ── Add Song ──────────────────────────────────────────────────────────────

  /// Returns false if song already exists in playlist.
  Future<bool> addSong(String playlistId, Song song) async {
    final pl = _findById(playlistId);
    if (pl == null) return false;
    if (pl.songs.any((s) => s.id == song.id)) return false; // duplicate guard
    pl.songs.add(song);
    pl.updatedAt = DateTime.now();
    await _persist(pl);
    _sortByUpdated();
    notifyListeners();
    return true;
  }

  // ── Remove Song ───────────────────────────────────────────────────────────

  Future<void> removeSong(String playlistId, String songId) async {
    final pl = _findById(playlistId);
    if (pl == null) return;
    pl.songs.removeWhere((s) => s.id == songId);
    pl.updatedAt = DateTime.now();
    await _persist(pl);
    notifyListeners();
  }

  // ── Reorder Songs ─────────────────────────────────────────────────────────

  Future<void> reorderSong(
      String playlistId, int oldIndex, int newIndex) async {
    final pl = _findById(playlistId);
    if (pl == null) return;
    if (oldIndex < newIndex) newIndex -= 1;
    final song = pl.songs.removeAt(oldIndex);
    pl.songs.insert(newIndex, song);
    pl.updatedAt = DateTime.now();
    await _persist(pl);
    notifyListeners();
  }

  // ── Query ─────────────────────────────────────────────────────────────────

  AurumPlaylist? getById(String id) => _findById(id);

  bool isSongInPlaylist(String playlistId, String songId) {
    final pl = _findById(playlistId);
    return pl?.songs.any((s) => s.id == songId) ?? false;
  }

  /// Returns list of playlist IDs that contain this song
  List<String> playlistsContaining(String songId) => _playlists
      .where((p) => p.songs.any((s) => s.id == songId))
      .map((p) => p.id)
      .toList();

  // ── Internal ──────────────────────────────────────────────────────────────

  AurumPlaylist? _findById(String id) {
    try {
      return _playlists.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistLocalOnly(AurumPlaylist pl) async {
    await _box.put(pl.id, pl.toJson());
  }

  Future<void> _persist(AurumPlaylist pl) async {
    await _persistLocalOnly(pl);
    // Fire-and-forget: mirrors this playlist to Supabase in the
    // background so it shows up on the user's other signed-in devices
    // without waiting for their next full sign-in sync. Never awaited
    // here — a slow/offline network must never delay or block the local
    // save this function exists for.
    unawaited(SyncService.instance.pushPlaylist(pl));
  }

  void _sortByUpdated() {
    _playlists.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// Called by SyncService after pulling from Supabase
  Future<void> upsertFromRemote(AurumPlaylist pl) async {
    final existing = _findById(pl.id);
    if (existing != null) _playlists.remove(existing);
    _playlists.add(pl);
    _sortByUpdated();
    await _persistLocalOnly(pl);
    notifyListeners();
  }

  String _generateId() =>
      'pl_${DateTime.now().millisecondsSinceEpoch}_${_playlists.length}';

  /// Wipes all playlists — local only, called on sign-out.
  Future<void> clearAll() async {
    await _box.clear();
    _playlists = [];
    notifyListeners();
  }
}
