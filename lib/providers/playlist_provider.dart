// =============================================================================
// FILE: lib/providers/playlist_provider.dart
// PROJECT: Astra Music
// DESCRIPTION: Spotify-style user playlists with Hive persistence.
//   ✅ Create / rename / delete playlists (unlimited)
//   ✅ Add / remove songs per playlist
//   ✅ Reorder songs via drag-and-drop
//   ✅ Duplicate-guard (song already in playlist)
//   ✅ Auto-persist to Hive on every mutation
// =============================================================================

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../services/sync_service.dart';
import '../services/api_service.dart';

// ── Model ────────────────────────────────────────────────────────────────────

class AurumPlaylist {
  final String id;
  String name;
  String description;
  List<Song> songs;
  final DateTime createdAt;
  DateTime updatedAt;
  // User-chosen cover photo picked from the device gallery, stored as a
  // local file path (image itself lives in app documents dir, see
  // PlaylistProvider.setCoverImage). Null means "no custom cover" — falls
  // back to the first song's artwork via coverArt below.
  String? customCoverPath;

  // Manual drag-and-drop position in the "Custom order" sort mode (Playlists
  // tab). Lower sorts first. Assigned sequentially at creation time and
  // rewritten by PlaylistProvider.reorderPlaylist() when the user drags a
  // row — kept separate from updatedAt so custom ordering doesn't get
  // silently reshuffled every time a playlist's songs change.
  int sortOrder;

  // User-defined organizational tags (e.g. "Workout", "Chill") shown via the
  // Playlists tab's tag filter chip row and edited from "Manage Tags".
  List<String> tags;

  // True only for playlists created via PlaylistProvider.importYtPlaylist()
  // — drives the "YouTube synced" badge on the Playlists tab. Regular
  // locally-created playlists are never synced, so this defaults to false.
  bool isYtSynced;

  AurumPlaylist({
    required this.id,
    required this.name,
    this.description = '',
    List<Song>? songs,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.customCoverPath,
    this.sortOrder = 0,
    List<String>? tags,
    this.isYtSynced = false,
  })  : songs = songs ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        tags = tags ?? [];

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

  /// Whether this playlist has a user-picked cover (vs. an auto cover).
  bool get hasCustomCover =>
      customCoverPath != null && customCoverPath!.isNotEmpty;

  // CHANGE (playlist covers, "aisa kro users kud se hi usme vo abhi uska
  // main theme ban raha hai 4 thumbnail mila kr vaisa hata do bs upar wala
  // song ka thumbnail bane"): this used to expose a `mosaicArts` getter
  // that the UI combined into a 2x2 grid of up to 4 different songs'
  // artwork — a busy, collage-y look. The design now always resolves to
  // exactly one image: the user's own gallery-picked cover if they set
  // one (customCoverPath), otherwise simply the top/first song's artwork,
  // matching the single clean thumbnail every mainstream streaming app
  // (Spotify, YT Music) uses. mosaicArts is gone; every call site now
  // reads this one getter instead.
  String? get coverArt {
    if (hasCustomCover) return customCoverPath;
    return songs.isNotEmpty ? songs.first.artworkUrl : null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'songs': songs.map((s) => s.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'customCoverPath': customCoverPath,
        'sortOrder': sortOrder,
        'tags': tags,
        'isYtSynced': isYtSynced,
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
      customCoverPath: json['customCoverPath'] as String?,
      // Older saved playlists (pre-existing Hive entries) won't have these
      // keys at all — default to 0/empty/false so they load cleanly instead
      // of throwing, and just sort to the front of custom order until the
      // user drags them.
      sortOrder: (json['sortOrder'] as int?) ?? 0,
      tags: (json['tags'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      isYtSynced: (json['isYtSynced'] as bool?) ?? false,
    );
  }
}

// ── Provider ─────────────────────────────────────────────────────────────────

class PlaylistProvider extends ChangeNotifier {
  static const _boxName = 'aurum_playlists';
  // PERF/SAFETY FIX (cold-start race): see followed_artists_provider.dart's
  // matching comment. playlists/count/playlistsContaining/etc already
  // read the in-memory _playlists list (safe, defaults to []), but the
  // mutation methods below touch _box directly — nullable + Completer
  // keeps those crash-safe too. The window before init() finishes is
  // small in practice but never fully zero, so it's guarded regardless.
  final Completer<Box<Map>> _boxReady = Completer<Box<Map>>();
  Box<Map>? _box;
  List<AurumPlaylist> _playlists = [];
  bool _isLoading = true;

  List<AurumPlaylist> get playlists => List.unmodifiable(_playlists);
  bool get isLoading => _isLoading;
  int get count => _playlists.length;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_boxReady.isCompleted) return;
    final box = await Hive.openBox<Map>(_boxName);
    _box = box;
    _boxReady.complete(box);
    _playlists = box.values
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
      sortOrder: _nextSortOrder(),
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
    final pl = _findById(id);
    // Clean up the custom cover file on disk too, so deleting a playlist
    // doesn't silently leave its cover image behind forever.
    if (pl != null && pl.hasCustomCover) {
      final coverFile = File(pl.customCoverPath!);
      if (await coverFile.exists()) {
        try {
          await coverFile.delete();
        } catch (_) {
          // Non-fatal.
        }
      }
    }
    _playlists.removeWhere((p) => p.id == id);
    final box = _box ?? await _boxReady.future;
    await box.delete(id);
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

  /// Bulk remove — used by the playlist multi-select UI. Single persist +
  /// single notifyListeners for the whole batch, instead of calling
  /// removeSong() in a loop (which would persist/rebuild once per song).
  Future<void> removeSongs(String playlistId, Set<String> songIds) async {
    if (songIds.isEmpty) return;
    final pl = _findById(playlistId);
    if (pl == null) return;
    pl.songs.removeWhere((s) => songIds.contains(s.id));
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
    // FIX ("ghost grey drag-tile overlay stuck on screen after reordering
    // a playlist, surviving even a back-navigation until the app is force
    // restarted"): notifyListeners() used to fire only AFTER `await
    // _persist(pl)` (a Hive disk write) completed. SliverReorderableList
    // needs the very next frame after onReorder returns to run its own
    // internal drop/settle animation and tear down the elevated drag-proxy
    // it renders over the dragged tile. Awaiting the disk write first
    // delayed that frame by however long the write took, and if the user
    // navigated back inside that window, the proxy's AnimationController
    // was torn down mid-flight by the route disposing — leaving its last
    // painted frame (the grey elevated rectangle) with nothing left to
    // clear it. Persisting is fire-and-forget here instead: notifyListeners
    // now runs synchronously in the same frame onReorder returns, so the
    // proxy always gets its settle frame before any navigation can race it.
    unawaited(_persist(pl));
    notifyListeners();
  }

  // ── Reorder Playlists (Custom order / Playlists tab) ────────────────────────

  /// Drag-and-drop reorder of the playlists LIST itself (as opposed to
  /// reorderSong above, which reorders songs inside one playlist). Only
  /// meaningful while the Playlists tab's sort mode is "Custom order" —
  /// callers should gate the drag handle on that, since dragging while
  /// sorted by name/date would just get overwritten the next time that
  /// sort re-runs.
  Future<void> reorderPlaylist(int oldIndex, int newIndex) async {
    final ordered = customOrdered();
    if (oldIndex < 0 || oldIndex >= ordered.length) return;
    if (oldIndex < newIndex) newIndex -= 1;
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);
    for (var i = 0; i < ordered.length; i++) {
      ordered[i].sortOrder = i;
    }
    // Same fire-and-forget-then-notify ordering as reorderSong above, for
    // the same drag-proxy-teardown reason.
    for (final pl in ordered) {
      unawaited(_persistLocalOnly(pl));
    }
    notifyListeners();
  }

  /// Playlists sorted by their manual sortOrder (ascending). This is the
  /// list the Playlists tab's drag-and-drop UI should render from and index
  /// into when "Custom order" is the active sort mode.
  List<AurumPlaylist> customOrdered() {
    final list = List<AurumPlaylist>.from(_playlists);
    list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  int _nextSortOrder() => _playlists.isEmpty
      ? 0
      : (_playlists.map((p) => p.sortOrder).reduce((a, b) => a > b ? a : b) + 1);

  // ── Tags ──────────────────────────────────────────────────────────────────

  /// Every distinct tag currently used across all playlists, for populating
  /// the Playlists tab's filter-chip row ("All" + one chip per tag).
  List<String> get allTags {
    final set = <String>{};
    for (final pl in _playlists) {
      set.addAll(pl.tags);
    }
    final list = set.toList()..sort();
    return list;
  }

  Future<void> setTags(String playlistId, List<String> newTags) async {
    final pl = _findById(playlistId);
    if (pl == null) return;
    pl.tags = newTags.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList();
    pl.updatedAt = DateTime.now();
    unawaited(_persist(pl));
    notifyListeners();
  }

  /// Renames a tag across every playlist that has it — used by "Manage
  /// Tags" when the user renames a tag rather than editing one playlist's
  /// tags at a time.
  Future<void> renameTagEverywhere(String oldTag, String newTag) async {
    final trimmed = newTag.trim();
    if (trimmed.isEmpty) return;
    var changed = false;
    for (final pl in _playlists) {
      final idx = pl.tags.indexOf(oldTag);
      if (idx != -1) {
        pl.tags[idx] = trimmed;
        pl.tags = pl.tags.toSet().toList(); // de-dupe if newTag already existed
        pl.updatedAt = DateTime.now();
        unawaited(_persistLocalOnly(pl));
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Removes a tag from every playlist that has it — used by "Manage Tags"
  /// when the user deletes a tag outright.
  Future<void> deleteTagEverywhere(String tag) async {
    var changed = false;
    for (final pl in _playlists) {
      if (pl.tags.remove(tag)) {
        pl.updatedAt = DateTime.now();
        unawaited(_persistLocalOnly(pl));
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Playlists carrying the given tag, in custom order — feeds the
  /// Playlists tab when a specific tag chip (not "All") is selected.
  List<AurumPlaylist> byTag(String tag) =>
      customOrdered().where((p) => p.tags.contains(tag)).toList();

  // ── Cover Image ───────────────────────────────────────────────────────────

  /// Copies the picked gallery image into the app's own documents dir (so
  /// it survives even if the user deletes/moves the original from their
  /// gallery) and sets it as this playlist's cover. Old custom cover file
  /// (if any) is deleted first so covers don't silently accumulate on disk
  /// every time someone changes their mind.
  Future<void> setCoverImage(String playlistId, String pickedFilePath) async {
    final pl = _findById(playlistId);
    if (pl == null) return;

    final docsDir = await getApplicationDocumentsDirectory();
    final coversDir = Directory('${docsDir.path}/playlist_covers');
    if (!await coversDir.exists()) {
      await coversDir.create(recursive: true);
    }

    // Remove the previous custom cover file, if this playlist had one.
    if (pl.hasCustomCover) {
      final oldFile = File(pl.customCoverPath!);
      if (await oldFile.exists()) {
        try {
          await oldFile.delete();
        } catch (_) {
          // Non-fatal — orphaned file, not worth failing the whole
          // operation over.
        }
      }
    }

    final ext = pickedFilePath.split('.').last;
    final destPath =
        '${coversDir.path}/${pl.id}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await File(pickedFilePath).copy(destPath);

    pl.customCoverPath = destPath;
    pl.updatedAt = DateTime.now();
    unawaited(_persist(pl));
    _sortByUpdated();
    notifyListeners();
  }

  /// Reverts to the automatic cover (first song's artwork).
  Future<void> clearCoverImage(String playlistId) async {
    final pl = _findById(playlistId);
    if (pl == null || !pl.hasCustomCover) return;

    final oldFile = File(pl.customCoverPath!);
    if (await oldFile.exists()) {
      try {
        await oldFile.delete();
      } catch (_) {
        // Non-fatal.
      }
    }

    pl.customCoverPath = null;
    pl.updatedAt = DateTime.now();
    unawaited(_persist(pl));
    notifyListeners();
  }

  // ── Import from YouTube ──────────────────────────────────────────────────

  /// Creates a new local playlist from a pasted YouTube/YouTube Music
  /// playlist URL or bare playlist ID, using ApiService.fetchYtPlaylistSongs
  /// (already _cleanText'd + quality-gated — see api_service.dart). Returns
  /// null if the URL/ID didn't resolve to any songs (invalid link, private/
  /// deleted playlist, or a genuinely empty one) so the caller can show an
  /// error instead of silently creating an empty playlist.
  ///
  /// [name] defaults to the playlist ID itself when not given — the caller
  /// (import UI) should prefer passing the actual YouTube playlist title if
  /// it has one available; ApiService's playlist fetch only returns songs,
  /// not the playlist's own title, so this provider can't infer a better
  /// default on its own.
  /// Throws [YtPlaylistImportException] on failure (invalid link, Mix,
  /// empty playlist, network/parse error) so the caller can show the
  /// exact reason. Only returns null in the (should-be-impossible) case
  /// where the fetch call itself returns without either songs or a
  /// thrown exception, kept as a defensive fallback rather than a normal
  /// path — callers should primarily catch YtPlaylistImportException.
  Future<AurumPlaylist?> importYtPlaylist(String playlistUrlOrId,
      {String? name}) async {
    final songs = await ApiService.fetchYtPlaylistSongs(playlistUrlOrId);
    if (songs.isEmpty) return null;

    final playlist = AurumPlaylist(
      id: _generateId(),
      name: (name == null || name.trim().isEmpty)
          ? 'Imported Playlist'
          : name.trim(),
      songs: songs,
      sortOrder: _nextSortOrder(),
      isYtSynced: true,
    );
    _playlists.insert(0, playlist);
    await _persist(playlist);
    notifyListeners();
    return playlist;
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
    final box = _box ?? await _boxReady.future;
    await box.put(pl.id, pl.toJson());
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
    final box = _box ?? await _boxReady.future;
    await box.clear();
    _playlists = [];
    notifyListeners();
  }
}
