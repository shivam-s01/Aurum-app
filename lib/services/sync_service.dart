// =============================================================================
// FILE: lib/services/sync_service.dart
// PROJECT: Astra Music
// DESCRIPTION: Two-way sync between local Hive boxes and Supabase, keyed by
//   the signed-in user's id. Strategy: last-write-wins via `updatedAt`.
//
//   Supabase tables expected (create via SQL editor):
//
//   create table playlists (
//     id text not null,
//     user_id uuid references auth.users not null,
//     data jsonb not null,
//     updated_at timestamptz not null default now(),
//     primary key (id, user_id)
//   );
//   alter table playlists enable row level security;
//   create policy "own playlists" on playlists
//     for all using (auth.uid() = user_id);
//
//   create table followed_artists (
//     artist_id text not null,
//     user_id uuid references auth.users not null,
//     data jsonb not null,
//     primary key (artist_id, user_id)
//   );
//   alter table followed_artists enable row level security;
//   create policy "own followed artists" on followed_artists
//     for all using (auth.uid() = user_id);
//
//   create table followed_albums (
//     album_id text not null,
//     user_id uuid references auth.users not null,
//     data jsonb not null,
//     primary key (album_id, user_id)
//   );
//   alter table followed_albums enable row level security;
//   create policy "own followed albums" on followed_albums
//     for all using (auth.uid() = user_id);
//
//   create table favorites (
//     song_id text not null,
//     user_id uuid references auth.users not null,
//     data jsonb not null,
//     primary key (song_id, user_id)
//   );
//   alter table favorites enable row level security;
//   create policy "own favorites" on favorites
//     for all using (auth.uid() = user_id);
//
//   create table history (
//     song_id text not null,
//     user_id uuid references auth.users not null,
//     data jsonb not null,
//     played_at timestamptz not null default now(),
//     primary key (song_id, user_id)
//   );
//   alter table history enable row level security;
//   create policy "own history" on history
//     for all using (auth.uid() = user_id);
//   (see create_history_table.sql for the exact statements actually run)
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/song.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/recently_played_provider.dart';

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  SupabaseClient get _client => Supabase.instance.client;
  String? get _uid => _client.auth.currentUser?.id;

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  // Cloud sync is sign-in-gated only (every signed-in user gets it —
  // payment/isPremium is ads-only and has nothing to do with sync).
  bool get _canSync => _uid != null;

  // ── Incremental single-item pushes ──────────────────────────────────────
  //
  // These are meant to be called right after every local Hive write —
  // fire-and-forget, never awaited by the caller, never thrown from. A
  // playlist edit must always succeed locally regardless of network
  // state; the cloud push is a best-effort mirror on top of that, not a
  // condition for the local save to "count". If it fails here (offline,
  // Supabase hiccup, whatever), the next full syncAll() — on next
  // sign-in, or the app-resume/periodic sync wired in main.dart — will
  // pick this row up again because its local updatedAt will still be
  // newer than whatever's on the server.

  Future<void> pushPlaylist(AurumPlaylist pl) async {
    if (!_canSync) return;
    try {
      await _client.from('playlists').upsert({
        'id': pl.id,
        'user_id': _uid,
        'data': pl.toJson(),
        'updated_at': pl.updatedAt.toIso8601String(),
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] pushPlaylist error: $e');
    }
  }

  Future<void> pushPlaylistDeleted(String playlistId) async {
    if (!_canSync) return;
    final uid = _uid!;
    try {
      await _client
          .from('playlists')
          .delete()
          .eq('id', playlistId)
          .eq('user_id', uid);
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] pushPlaylistDeleted error: $e');
    }
  }

  Future<void> pushFollowedArtist(Map<String, dynamic> artist) async {
    if (!_canSync) return;
    try {
      await _client.from('followed_artists').upsert({
        'artist_id': artist['id'],
        'user_id': _uid,
        'data': artist,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] pushFollowedArtist error: $e');
    }
  }

  Future<void> pushUnfollowedArtist(String artistId) async {
    if (!_canSync) return;
    final uid = _uid!;
    try {
      await _client
          .from('followed_artists')
          .delete()
          .eq('artist_id', artistId)
          .eq('user_id', uid);
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] pushUnfollowedArtist error: $e');
    }
  }

  Future<void> pushFollowedAlbum(Map<String, dynamic> album) async {
    if (!_canSync) return;
    try {
      await _client.from('followed_albums').upsert({
        'album_id': album['id'],
        'user_id': _uid,
        'data': album,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] pushFollowedAlbum error: $e');
    }
  }

  Future<void> pushUnfollowedAlbum(String albumId) async {
    if (!_canSync) return;
    final uid = _uid!;
    try {
      await _client
          .from('followed_albums')
          .delete()
          .eq('album_id', albumId)
          .eq('user_id', uid);
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] pushUnfollowedAlbum error: $e');
    }
  }

  Future<void> pushFavorite(Song song) async {
    if (!_canSync) return;
    try {
      await _client.from('favorites').upsert({
        'song_id': song.id,
        'user_id': _uid,
        'data': song.toJson(),
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] pushFavorite error: $e');
    }
  }

  Future<void> pushUnfavorite(String songId) async {
    if (!_canSync) return;
    final uid = _uid!;
    try {
      await _client
          .from('favorites')
          .delete()
          .eq('song_id', songId)
          .eq('user_id', uid);
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] pushUnfavorite error: $e');
    }
  }

  // History is upsert-only (never deleted individually) — clearing
  // history is a full wipe, handled in _clearRemoteHistory() below, not
  // a per-song delete.
  Future<void> pushHistoryEntry(Song song, int playedAtMs) async {
    if (!_canSync) return;
    try {
      await _client.from('history').upsert({
        'song_id': song.id,
        'user_id': _uid,
        'data': song.toJson(),
        'played_at': DateTime.fromMillisecondsSinceEpoch(playedAtMs)
            .toUtc()
            .toIso8601String(),
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] pushHistoryEntry error: $e');
    }
  }

  /// Call on sign-out / "Clear history" so a wipe on one device doesn't
  /// get silently un-done by the next syncAll() pulling the old rows
  /// back down from another device's still-unsynced state.
  Future<void> clearRemoteHistory() async {
    if (!_canSync) return;
    final uid = _uid!;
    try {
      await _client.from('history').delete().eq('user_id', uid);
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] clearRemoteHistory error: $e');
    }
  }

  /// Call right after a successful sign-in. Pulls remote data down, then
  /// pushes anything local-only up (merge, not overwrite).
  Future<void> syncAll({
    required PlaylistProvider playlists,
    required FollowedArtistsProvider followedArtists,
    required FollowedAlbumsProvider followedAlbums,
    required FavoritesProvider favorites,
    RecentlyPlayedProvider? history,
  }) async {
    final uid = _uid;
    if (uid == null || _isSyncing) return;
    _isSyncing = true;
    try {
      await Future.wait([
        _syncPlaylists(uid, playlists),
        _syncFollowedArtists(uid, followedArtists),
        _syncFollowedAlbums(uid, followedAlbums),
        _syncFavorites(uid, favorites),
        if (history != null) _syncHistory(uid, history),
      ]);
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncService] syncAll error: $e');
    } finally {
      _isSyncing = false;
    }
  }

  // ── Playlists ────────────────────────────────────────────────────────────

  Future<void> _syncPlaylists(String uid, PlaylistProvider provider) async {
    final remoteRows =
        await _client.from('playlists').select().eq('user_id', uid);

    final remoteById = <String, Map<String, dynamic>>{
      for (final row in remoteRows) row['id'] as String: row,
    };

    final localById = {for (final p in provider.playlists) p.id: p};

    // Pull: remote newer or missing locally -> apply locally
    for (final row in remoteRows) {
      final id = row['id'] as String;
      final remoteUpdatedAt = DateTime.parse(row['updated_at'] as String);
      final local = localById[id];
      if (local == null || remoteUpdatedAt.isAfter(local.updatedAt)) {
        final data = Map<String, dynamic>.from(row['data'] as Map);
        await provider.upsertFromRemote(AurumPlaylist.fromJson(data));
      }
    }

    // Push: local newer or missing remotely -> upload
    for (final local in provider.playlists) {
      final remote = remoteById[local.id];
      final remoteUpdatedAt =
          remote != null ? DateTime.parse(remote['updated_at'] as String) : null;
      if (remote == null || local.updatedAt.isAfter(remoteUpdatedAt!)) {
        await _client.from('playlists').upsert({
          'id': local.id,
          'user_id': uid,
          'data': local.toJson(),
          'updated_at': local.updatedAt.toIso8601String(),
        });
      }
    }
  }

  // ── Followed artists ─────────────────────────────────────────────────────

  Future<void> _syncFollowedArtists(
      String uid, FollowedArtistsProvider provider) async {
    final remoteRows =
        await _client.from('followed_artists').select().eq('user_id', uid);

    final remoteIds = <String>{};
    for (final row in remoteRows) {
      final data = Map<String, dynamic>.from(row['data'] as Map);
      remoteIds.add(row['artist_id'] as String);
      if (!provider.isFollowing(data['id'] as String)) {
        await provider.followFromRemote(
          artistId: data['id'] as String,
          name: data['name'] as String? ?? '',
          imageUrl: data['imageUrl'] as String? ?? '',
        );
      }
    }

    for (final artist in provider.followed) {
      final id = artist['id'] as String;
      if (!remoteIds.contains(id)) {
        await _client.from('followed_artists').upsert({
          'artist_id': id,
          'user_id': uid,
          'data': artist,
        });
      }
    }
  }

  // ── Followed albums ──────────────────────────────────────────────────────

  Future<void> _syncFollowedAlbums(
      String uid, FollowedAlbumsProvider provider) async {
    final remoteRows =
        await _client.from('followed_albums').select().eq('user_id', uid);

    final remoteIds = <String>{};
    for (final row in remoteRows) {
      final data = Map<String, dynamic>.from(row['data'] as Map);
      remoteIds.add(row['album_id'] as String);
      if (!provider.isFollowing(data['id'] as String)) {
        await provider.followFromRemote(
          albumId: data['id'] as String,
          name: data['name'] as String? ?? '',
          artworkUrl: data['artworkUrl'] as String? ?? '',
        );
      }
    }

    for (final album in provider.followed) {
      final id = album['id'] as String;
      if (!remoteIds.contains(id)) {
        await _client.from('followed_albums').upsert({
          'album_id': id,
          'user_id': uid,
          'data': album,
        });
      }
    }
  }

  // ── Favorites ────────────────────────────────────────────────────────────

  Future<void> _syncFavorites(String uid, FavoritesProvider provider) async {
    final remoteRows =
        await _client.from('favorites').select().eq('user_id', uid);

    final remoteIds = <String>{};
    for (final row in remoteRows) {
      final data = Map<String, dynamic>.from(row['data'] as Map);
      final songId = row['song_id'] as String;
      remoteIds.add(songId);
      if (!provider.isFavorite(songId)) {
        await provider.addFromRemote(data);
      }
    }

    for (final song in provider.favorites) {
      if (!remoteIds.contains(song.id)) {
        await _client.from('favorites').upsert({
          'song_id': song.id,
          'user_id': uid,
          'data': song.toJson(),
        });
      }
    }
  }

  // ── History ──────────────────────────────────────────────────────────────
  //
  // Same shape as playlists' updated_at merge: newest played_at wins per
  // song, in both directions, so history survives sign-out, reinstall, or
  // a brand-new device instead of living only in local Hive. Local-file
  // entries are never pulled or pushed here — RecentlyPlayedProvider
  // already skips pushing them (see addPlay()), and a remote row can
  // never be a local-file entry in the first place since those are
  // never uploaded.
  Future<void> _syncHistory(String uid, RecentlyPlayedProvider provider) async {
    final remoteRows =
        await _client.from('history').select().eq('user_id', uid);

    final remoteById = <String, Map<String, dynamic>>{
      for (final row in remoteRows) row['song_id'] as String: row,
    };

    // Pull: remote newer or missing locally -> merge in.
    for (final row in remoteRows) {
      final data = Map<String, dynamic>.from(row['data'] as Map);
      final playedAt = DateTime.parse(row['played_at'] as String);
      await provider.upsertFromRemote(
        Song.fromJson(data),
        playedAt.millisecondsSinceEpoch,
      );
    }

    // Push: local newer or missing remotely -> upload. Uses the
    // provider's own tracked playedAt (playedAtById) rather than "now",
    // so a push during sync doesn't fake a fresher timestamp than when
    // the song actually played.
    for (final song in provider.history) {
      final localPlayedAt = provider.playedAtFor(song.id);
      if (localPlayedAt == null) continue; // shouldn't happen, but be safe
      final remote = remoteById[song.id];
      final remotePlayedAt = remote != null
          ? DateTime.parse(remote['played_at'] as String).millisecondsSinceEpoch
          : null;
      if (remotePlayedAt == null || localPlayedAt > remotePlayedAt) {
        await pushHistoryEntry(song, localPlayedAt);
      }
    }
  }
}
