import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/song.dart';
import '../providers/download_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/player_provider.dart';
import '../screens/album_screen.dart';
import '../screens/artist_screen.dart';
import '../screens/full_player_screen.dart'
    show shareSong, showSleepTimerForSong, showSongInfoDialog;
import '../screens/library_screen.dart' show showAddToPlaylistSheet;
import '../screens/settings_player_screen.dart'
    show SleepTimerService, EqualizerScreen;
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../utils/aurum_transitions.dart';
import 'aurum_artwork.dart';
import 'aurum_snack.dart';
import 'aurum_wide_thumb.dart';
import 'premium_gate.dart';

/// Single, shared song "3-dot" menu for the whole app.
///
/// Layout is measured 1:1 from the SimpMusic reference: small plain thumbnail
/// + title/artist header, a divider, then a flat list of 47dp rows with a
/// 24dp icon and a 16sp label. Colours come only from the active theme
/// (Light / Dark / Dynamic) — nothing is ever derived from the artwork.
///
/// Replaces the three old implementations:
///   • SongTile → _SongOptionsSheet
///   • Full player → _PremiumOptionsSheet
///   • Library → showAurumSongOptionsSheet
Future<void> showAurumSongOptions(
  BuildContext context,
  Song song, {
  /// Show player-only rows (Sleep Timer, Audio Effects). Turned on from the
  /// full player; off in lists where they'd just be noise.
  bool showPlayerTools = false,

  /// Clean YT Music-style track menu (wide thumbnail header, only the
  /// everyday actions — no sleep timer / playback speed). Used by the Mix
  /// screen's track rows.
  bool compact = false,

  /// YouTube Music-style menu (Quick Picks): Play next, Add to queue,
  /// Download, Add to liked songs, Save to playlist, Go to album/artist,
  /// View song credits, Share, Not interested, Don't recommend artist.
  bool ytStyle = false,
  VoidCallback? onNotInterested,
  VoidCallback? onDontRecommendArtist,
}) {
  AurumHaptics.light();
  return showAurumModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black54,
    builder: (_) => AurumSongOptionsSheet(
      song: song,
      rootContext: context,
      showPlayerTools: showPlayerTools,
      compact: compact,
      ytStyle: ytStyle,
      onNotInterested: onNotInterested,
      onDontRecommendArtist: onDontRecommendArtist,
    ),
  );
}

/// Playlist/mix-level 3-dot menu — exactly two actions (Add to queue,
/// Share), same flat sheet chrome as the track menu.
Future<void> showAurumPlaylistOptions(
  BuildContext context, {
  required List<Song> songs,
}) {
  AurumHaptics.light();
  return showAurumModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black54,
    builder: (sheetCtx) => _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Row(
            icon: Icons.playlist_add_rounded,
            label: 'Add to queue',
            enabled: songs.isNotEmpty,
            onTap: () {
              Navigator.of(sheetCtx).pop();
              final player = context.read<PlayerProvider>();
              unawaited(player.addSongsToQueue(songs).then((added) {
                if (!context.mounted) return;
                AurumSnack.show(
                  context,
                  added > 0
                      ? 'Added $added song${added == 1 ? '' : 's'} to queue'
                      : 'Already in queue',
                );
              }));
            },
          ),
          _Row(
            icon: Icons.share_rounded,
            label: 'Share',
            enabled: songs.isNotEmpty,
            onTap: () {
              Navigator.of(sheetCtx).pop();
              shareSong(context, songs.first);
            },
          ),
        ],
      ),
    ),
  );
}

class AurumSongOptionsSheet extends StatefulWidget {
  final Song song;
  final BuildContext rootContext;
  final bool showPlayerTools;
  final bool compact;
  final bool ytStyle;
  final VoidCallback? onNotInterested;
  final VoidCallback? onDontRecommendArtist;

  const AurumSongOptionsSheet({
    super.key,
    required this.song,
    required this.rootContext,
    this.showPlayerTools = false,
    this.compact = false,
    this.ytStyle = false,
    this.onNotInterested,
    this.onDontRecommendArtist,
  });

  @override
  State<AurumSongOptionsSheet> createState() => _AurumSongOptionsSheetState();
}

class _AurumSongOptionsSheetState extends State<AurumSongOptionsSheet> {
  @override
  void initState() {
    super.initState();
    SleepTimerService.instance.addListener(_onTick);
  }

  @override
  void dispose() {
    SleepTimerService.instance.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  // ── helpers ────────────────────────────────────────────────────────────────
  void _close() => Navigator.of(context).pop();

  void _toast(String msg) => AurumSnack.show(widget.rootContext, msg);

  List<String> get _artists {
    final raw = widget.song.artist;
    if (raw.trim().isEmpty || raw == 'Unknown') return const [];
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  void _openArtist() {
    final names = _artists;
    if (names.isEmpty) return;
    if (names.length == 1) {
      _pushArtist(names.first);
      return;
    }
    // Several artists → let the user pick one (still SimpMusic-flat list).
    _close();
    showAurumModalBottomSheet<void>(
      context: widget.rootContext,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      barrierColor: Colors.black54,
      builder: (sheetCtx) => _SheetShell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final n in names)
              _Row(
                icon: Icons.person_rounded,
                label: n,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _pushArtist(n, alreadyClosed: true);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _pushArtist(String name, {bool alreadyClosed = false}) {
    final song = widget.song;
    final isPrimary = _artists.isNotEmpty && _artists.first == name;
    final fastId = (isPrimary && song.artistChannelId != null)
        ? 'yt_${song.artistChannelId}'
        : null;
    if (!alreadyClosed) _close();
    Navigator.push(
      widget.rootContext,
      AurumDepthRoute(
        builder: (_) => ArtistScreen(artistId: fastId, artistName: name),
      ),
    );
  }

  // Normalises titles/names for comparison: lowercase, drops bracketed
  // suffixes like "(From "X")" / "[Remix]" and every non-alphanumeric.
  static String _albumKey(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), '')
      .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]'), '');

  Future<void> _openAlbum() async {
    final song = widget.song;
    if (song.album.isEmpty) return;
    final nav = Navigator.of(widget.rootContext);
    final messenger = ScaffoldMessenger.maybeOf(widget.rootContext);
    _close();
    messenger?.showSnackBar(SnackBar(
      content: const Text('Finding album…'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ));
    try {
      final albumKey = _albumKey(song.album);
      final songKey = _albumKey(song.title);
      final primaryArtist = song.artist
          .split(RegExp(r',|&|/| feat\.? ', caseSensitive: false))
          .first
          .trim();

      // Same-name albums are common (a movie soundtrack and an unrelated
      // single can share a title), so a name-only match opens the wrong one.
      // Search by album name AND album+artist, then verify by tracks below.
      final batches = await Future.wait([
        ApiService.searchAlbums(song.album, limit: 8),
        ApiService.searchAlbums(
            primaryArtist.isEmpty ? song.album : '${song.album} $primaryArtist',
            limit: 8),
      ]);
      final rawName = song.album.trim().toLowerCase();
      bool sameName(String n) => albumKey.isEmpty
          ? n.trim().toLowerCase() == rawName // non-Latin names normalise to ''
          : _albumKey(n) == albumKey;
      final all = [
        for (final batch in batches)
          for (final a in batch)
            if (a.collectionId.isNotEmpty) a,
      ];
      final seen = <String>{};
      var named = [
        for (final a in all)
          if (sameName(a.name) && seen.add(a.collectionId)) a,
      ];
      final exactName = named.isNotEmpty;
      if (named.isEmpty && albumKey.isNotEmpty) {
        // Slightly different titles ("X" vs "X Reloaded"): allow containment,
        // still verified by tracks below.
        final seen2 = <String>{};
        named = [
          for (final a in all)
            if (_albumKey(a.name).isNotEmpty &&
                (_albumKey(a.name).contains(albumKey) ||
                    albumKey.contains(_albumKey(a.name))) &&
                seen2.add(a.collectionId))
              a,
        ];
      }

      // Typed by inference (BrowseAlbum is not re-exported here) — no dynamic.
      final cands = named.take(4).toList();
      var pick = -1;
      if (cands.length == 1 && exactName) {
        // Only one album carries this exact name: nothing to disambiguate, so
        // skip the extra track fetch (saves data + a round-trip).
        pick = 0;
      } else if (cands.isNotEmpty) {
        // Verify: the right album actually contains this song.
        final tracks = await Future.wait(cands.map((a) => ApiService
            .fetchAlbumSongs(a.collectionId)
            .timeout(const Duration(seconds: 7), onTimeout: () => <Song>[])
            .catchError((_) => <Song>[])));
        // Containment only counts for reasonably long titles, so a short
        // title like "Dil" can't match "Dilbar" in the wrong album.
        bool sameTitle(String k) {
          if (k.isEmpty || songKey.isEmpty) return false;
          if (k == songKey) return true;
          final shorter = k.length < songKey.length ? k : songKey;
          return shorter.length >= 5 && (k.contains(songKey) || songKey.contains(k));
        }
        for (var i = 0; i < cands.length && pick < 0; i++) {
          if (tracks[i].any((t) => t.id == song.id || sameTitle(_albumKey(t.title)))) {
            pick = i;
          }
        }
        // Not verifiable: only accept an album whose credited artist matches.
        if (pick < 0 && primaryArtist.isNotEmpty) {
          final pa = _albumKey(primaryArtist);
          for (var i = 0; i < cands.length; i++) {
            final ak = _albumKey(cands[i].artist);
            if (pa.isNotEmpty && ak.isNotEmpty && (ak.contains(pa) || pa.contains(ak))) {
              pick = i;
              break;
            }
          }
        }
      }
      final match = pick >= 0 ? cands[pick] : null;

      messenger?.hideCurrentSnackBar();
      final albumId = match?.collectionId;
      if (albumId == null || albumId.isEmpty) {
        messenger?.showSnackBar(SnackBar(
          content: Text('Couldn\'t find "${song.album}"'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ));
        return;
      }
      nav.push(AurumDepthRoute(
        builder: (_) => AlbumScreen(
          albumId: albumId,
          albumName: song.album,
          artworkUrl: match?.artworkUrl ?? '',
        ),
      ));
    } catch (_) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(
        content: Text('Couldn\'t open "${song.album}"'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  void _download() {
    final l10n = AppLocalizations.of(context)!;
    final song = widget.song;
    final downloads = context.read<DownloadProvider>();

    if (downloads.isDownloaded(song.id)) {
      _toast(l10n.fpAlreadyDownloaded);
      return;
    }
    if (downloads.isDownloading(song.id)) {
      _toast(l10n.fpAlreadyDownloading);
      return;
    }
    if (song.isLocal) {
      _toast(l10n.fpAlreadyOnDevice);
      return;
    }

    _close();
    _toast(l10n.fpDownloadingSong(song.title));
    downloads.download(song).then((started) {
      if (!started) {
        final ctx = widget.rootContext;
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text(l10n.fpDownloadFailed(song.title)),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ));
        }
      }
    });
  }

  Future<void> _startRadio() async {
    final song = widget.song;
    final player = context.read<PlayerProvider>();
    final root = widget.rootContext;
    _close();
    _toast('Starting radio…');
    try {
      final similar = await ApiService.fetchSimilarSongs(
        songId: song.id,
        artist: song.artist,
        title: song.title,
        excludeIds: [song.id],
      );
      final queue = <Song>[song, ...similar];
      await player.playSong(song, queue: queue, index: 0, curatedQueue: true);
    } catch (_) {
      if (root.mounted) {
        ScaffoldMessenger.of(root).showSnackBar(const SnackBar(
          content: Text("Couldn't start radio"),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ));
      }
    }
  }

  Future<void> _openSpeed() async {
    final player = context.read<PlayerProvider>();
    final root = widget.rootContext;
    _close();
    final prefs = await SharedPreferences.getInstance();
    final start = prefs.getDouble('playback_speed') ?? 1.0;
    if (!root.mounted) return;
    await showAurumModalBottomSheet<void>(
      context: root,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      barrierColor: Colors.black54,
      builder: (_) => _SpeedSheet(
        initial: start,
        onChanged: (v) async {
          await prefs.setDouble('playback_speed', v);
          await player.handler.setSpeed(v);
        },
      ),
    );
  }

  // ── build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final song = widget.song;
    final player = context.read<PlayerProvider>();
    final fav = context.watch<FavoritesProvider>();
    final downloads = context.watch<DownloadProvider>();

    final isLiked = fav.isFavorite(song.id);
    final isDownloaded = downloads.isDownloaded(song.id);
    final isDownloading = downloads.isDownloading(song.id);
    final progress = downloads.statusOf(song.id)?.progress ?? 0;

    final sleepActive = SleepTimerService.instance.isActive;
    final sleepLabel = sleepActive
        ? l10n.fpSleepRemaining(
            '${(SleepTimerService.instance.remaining.inSeconds / 60).ceil()}m')
        : l10n.fpSleepTimer;

    if (widget.ytStyle) {
      final canNotInterested = widget.onNotInterested != null;
      final canHideArtist =
          widget.onDontRecommendArtist != null && _artists.isNotEmpty;
      return _SheetShell(
        header: _Header(
          title: song.title,
          subtitle: song.artist,
          artworkUrl: song.artworkUrl,
          square: true,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Playback ──
            _Row(
              icon: Icons.sensors_rounded,
              label: 'Start radio',
              onTap: _startRadio,
            ),
            _Row(
              icon: Icons.playlist_play_rounded,
              label: l10n.fpPlayNext,
              onTap: () {
                _close();
                unawaited(player.playNext(song));
                _toast('Playing "${song.title}" next');
              },
            ),
            _Row(
              icon: Icons.playlist_add_rounded,
              label: l10n.fpAddToQueue,
              onTap: () {
                _close();
                unawaited(player.addToQueue(song));
                _toast(l10n.fpAddedToQueue);
              },
            ),
            const _GroupDivider(),
            // ── Library ──
            _Row(
              icon: Icons.library_add_outlined,
              label: l10n.fpSaveToPlaylist,
              onTap: () {
                _close();
                showAddToPlaylistSheet(widget.rootContext, song);
              },
            ),
            _Row(
              icon: isLiked
                  ? Icons.thumb_up_alt_rounded
                  : Icons.thumb_up_off_alt_rounded,
              label: isLiked ? l10n.fpLiked : 'Add to liked songs',
              onTap: () {
                PremiumGate.guard(
                  context,
                  feature: l10n.fpLikeSongsFeature,
                  description: l10n.fpLikeSignInBuildLibrary,
                  requiresLoginOnly: true,
                  onAllowed: () {
                    fav.toggleFavorite(song);
                    final nowLiked = fav.isFavorite(song.id);
                    _close();
                    _toast(nowLiked
                        ? l10n.fpAddedToLiked
                        : l10n.fpRemovedFromLiked);
                  },
                );
              },
            ),
            _Row(
              icon: isDownloaded
                  ? Icons.check_circle_outline_rounded
                  : Icons.download_for_offline_outlined,
              label: isDownloaded
                  ? l10n.fpDownloaded
                  : isDownloading
                      ? '${l10n.fpDownloading} ${(progress * 100).toStringAsFixed(0)}%'
                      : l10n.fpDownload,
              onTap: _download,
            ),
            const _GroupDivider(),
            // ── Go to ──
            if (song.album.isNotEmpty)
              _Row(
                icon: Icons.album_outlined,
                label: 'Go to album',
                onTap: _openAlbum,
              ),
            if (_artists.isNotEmpty)
              _Row(
                icon: Icons.person_outline_rounded,
                label: _artists.length == 1 ? 'Go to artist' : 'Go to artists',
                onTap: _openArtist,
              ),
            _Row(
              icon: Icons.groups_outlined,
              label: 'View song credits',
              onTap: () {
                _close();
                showSongInfoDialog(widget.rootContext, song);
              },
            ),
            _Row(
              icon: Icons.share_rounded,
              label: l10n.fpShare,
              onTap: () {
                _close();
                shareSong(widget.rootContext, song);
              },
            ),
            // ── Feedback (YT Music: sabse neeche, alag group) ──
            if (canNotInterested || canHideArtist) const _GroupDivider(),
            if (canNotInterested)
              _Row(
                icon: Icons.block_rounded,
                label: 'Not interested',
                onTap: () {
                  _close();
                  widget.onNotInterested!();
                },
              ),
            if (canHideArtist)
              _Row(
                icon: Icons.remove_circle_outline_rounded,
                label: "Don't recommend artist",
                onTap: () {
                  _close();
                  widget.onDontRecommendArtist!();
                },
              ),
          ],
        ),
      );
    }

    if (widget.compact) {
      return _SheetShell(
        header: _Header(
          title: song.title,
          subtitle: song.artist,
          artworkUrl: song.artworkUrl,
          wide: true,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Row(
              icon: Icons.sensors_rounded,
              label: 'Start radio',
              onTap: _startRadio,
            ),
            _Row(
              icon: Icons.play_circle_outline_rounded,
              label: l10n.fpPlayNext,
              onTap: () {
                _close();
                unawaited(player.playNext(song));
                _toast('Playing "${song.title}" next');
              },
            ),
            _Row(
              icon: Icons.playlist_add_rounded,
              label: l10n.fpAddToQueue,
              onTap: () {
                _close();
                unawaited(player.addToQueue(song));
                _toast(l10n.fpAddedToQueue);
              },
            ),
            _Row(
              icon: Icons.library_add_outlined,
              label: l10n.fpSaveToPlaylist,
              onTap: () {
                _close();
                showAddToPlaylistSheet(widget.rootContext, song);
              },
            ),
            _Row(
              icon: isDownloaded
                  ? Icons.check_circle_outline_rounded
                  : Icons.download_for_offline_outlined,
              label: isDownloaded
                  ? l10n.fpDownloaded
                  : isDownloading
                      ? '${l10n.fpDownloading} ${(progress * 100).toStringAsFixed(0)}%'
                      : l10n.fpDownload,
              onTap: _download,
            ),
            _Row(
              icon: isLiked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              label: isLiked ? l10n.fpLiked : l10n.fpLikeAction,
              onTap: () {
                PremiumGate.guard(
                  context,
                  feature: l10n.fpLikeSongsFeature,
                  description: l10n.fpLikeSignInBuildLibrary,
                  requiresLoginOnly: true,
                  onAllowed: () {
                    fav.toggleFavorite(song);
                    final nowLiked = fav.isFavorite(song.id);
                    _close();
                    _toast(nowLiked
                        ? l10n.fpAddedToLiked
                        : l10n.fpRemovedFromLiked);
                  },
                );
              },
            ),
            if (song.album.isNotEmpty)
              _Row(
                icon: Icons.album_outlined,
                label: 'Go to album',
                onTap: _openAlbum,
              ),
            if (_artists.isNotEmpty)
              _Row(
                icon: Icons.person_outline_rounded,
                label: _artists.length == 1 ? 'Go to artist' : 'Go to artists',
                onTap: _openArtist,
              ),
            _Row(
              icon: Icons.share_rounded,
              label: l10n.fpShare,
              onTap: () {
                _close();
                shareSong(widget.rootContext, song);
              },
            ),
          ],
        ),
      );
    }

    return _SheetShell(
      header: _Header(
        title: song.title,
        subtitle: song.artist,
        artworkUrl: song.artworkUrl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Row(
            icon: isLiked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            label: isLiked ? l10n.fpLiked : l10n.fpLikeAction,
            onTap: () {
              PremiumGate.guard(
                context,
                feature: l10n.fpLikeSongsFeature,
                description: l10n.fpLikeSignInBuildLibrary,
                requiresLoginOnly: true,
                onAllowed: () {
                  fav.toggleFavorite(song);
                  final nowLiked = fav.isFavorite(song.id);
                  _close();
                  _toast(nowLiked
                      ? l10n.fpAddedToLiked
                      : l10n.fpRemovedFromLiked);
                },
              );
            },
          ),
          _Row(
            icon: isDownloaded
                ? Icons.check_circle_outline_rounded
                : Icons.download_for_offline_outlined,
            label: isDownloaded
                ? l10n.fpDownloaded
                : isDownloading
                    ? '${l10n.fpDownloading} ${(progress * 100).toStringAsFixed(0)}%'
                    : l10n.fpDownload,
            onTap: _download,
          ),
          _Row(
            icon: Icons.playlist_add_rounded,
            label: l10n.fpSaveToPlaylist,
            onTap: () {
              _close();
              showAddToPlaylistSheet(widget.rootContext, song);
            },
          ),
          _Row(
            icon: Icons.play_circle_filled_rounded,
            label: l10n.fpPlayNext,
            onTap: () {
              _close();
              unawaited(player.playNext(song));
              _toast('Playing "${song.title}" next');
            },
          ),
          _Row(
            icon: Icons.queue_music_rounded,
            label: l10n.fpAddToQueue,
            onTap: () {
              _close();
              unawaited(player.addToQueue(song));
              _toast(l10n.fpAddedToQueue);
            },
          ),
          if (_artists.isNotEmpty)
            _Row(
              icon: Icons.people_alt_rounded,
              label: 'Artists',
              onTap: _openArtist,
            ),
          _Row(
            icon: Icons.album_rounded,
            label: song.album.isNotEmpty ? song.album : 'No album',
            enabled: song.album.isNotEmpty,
            onTap: _openAlbum,
          ),
          _Row(
            icon: Icons.sensors_rounded,
            label: 'Start radio',
            onTap: _startRadio,
          ),
          _Row(
            icon: sleepActive ? Icons.bedtime_rounded : Icons.alarm_rounded,
            label: sleepLabel,
            onTap: () {
              _close();
              showSleepTimerForSong(widget.rootContext, player);
            },
          ),
          _Row(
            icon: Icons.speed_rounded,
            label: 'Playback speed',
            onTap: _openSpeed,
          ),
          if (widget.showPlayerTools) ...[
            _Row(
              icon: Icons.equalizer_rounded,
              label: l10n.fpAudioEffects,
              onTap: () {
                _close();
                Navigator.of(widget.rootContext).push(AurumPageRoute(
                  builder: (_) => EqualizerScreen(audioEngine: player.handler),
                ));
              },
            ),
            _Row(
              icon: Icons.info_outline_rounded,
              label: l10n.fpSongInfo,
              onTap: () {
                _close();
                showSongInfoDialog(widget.rootContext, song);
              },
            ),
          ],
          _Row(
            icon: Icons.share_rounded,
            label: l10n.fpShare,
            onTap: () {
              _close();
              shareSong(widget.rootContext, song);
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheet chrome — theme-only colours (Light / Dark / Dynamic).
// ─────────────────────────────────────────────────────────────────────────────
/// Neutral palette for the sheet.
///
/// The app's fixed dark theme is purple-tinted (0xFF201E2E) and its "muted"
/// text is very dark (0xFF4A4A5E) — fine for the app, but the reference sheet
/// is plain neutral grey. So:
///   • Dynamic (Material You) → straight from the wallpaper ColorScheme
///   • Dark                   → neutral grey, white text
///   • Light                  → neutral white/grey, near-black text
/// No per-song / artwork colour is ever involved.
class _SheetPalette {
  final Color surface;
  final Color text;
  final Color textMuted;
  final Color divider;
  final Color handle;
  const _SheetPalette({
    required this.surface,
    required this.text,
    required this.textMuted,
    required this.divider,
    required this.handle,
  });

  factory _SheetPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Dynamic detection: in Dynamic mode bgElevatedOf() returns the scheme's
    // surfaceContainerHighest; in fixed themes it returns a hardcoded const.
    final isDynamic =
        AurumTheme.bgElevatedOf(context) == scheme.surfaceContainerHighest;

    if (isDynamic) {
      return _SheetPalette(
        surface: scheme.surfaceContainerHigh,
        text: scheme.onSurface,
        textMuted: scheme.onSurfaceVariant,
        divider: scheme.outlineVariant,
        handle: scheme.onSurfaceVariant.withValues(alpha: 0.5),
      );
    }
    if (isDark) {
      return const _SheetPalette(
        surface: Color(0xFF242424),
        text: Colors.white,
        textMuted: Color(0xFFB9B9B0),
        divider: Color(0xFF474B4F),
        handle: Color(0xFF6A6A6A),
      );
    }
    return const _SheetPalette(
      surface: Color(0xFFF7F7F7),
      text: Color(0xFF121212),
      textMuted: Color(0xFF6B6B6B),
      divider: Color(0xFFD8D8D8),
      handle: Color(0xFFBDBDBD),
    );
  }
}

class _SheetShell extends StatelessWidget {
  final Widget? header;
  final Widget child;
  const _SheetShell({this.header, required this.child});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final maxH = MediaQuery.of(context).size.height * 0.92;
    final pal = _SheetPalette.of(context);

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Reference: one flat surface (#242424 in dark) — no tint, no blur.
          color: pal.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Grab handle — 58 x 4dp, sits 5dp from the top edge.
            Container(
              width: 58,
              height: 4,
              margin: const EdgeInsets.only(top: 9, bottom: 12),
              decoration: BoxDecoration(
                color: pal.handle,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (header != null) ...[
              header!,
              // Divider: 19.5dp side margins, 1dp.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 19.5),
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: pal.divider,
                ),
              ),
            ],
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(top: 6, bottom: 10 + bottomInset),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final bool wide;
  // YT Music track menu: chhota square cover (48dp, 6dp radius) — wide
  // crop gaane ke cover ko kaat deta tha.
  final bool square;
  const _Header({
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    this.wide = false,
    this.square = false,
  });

  @override
  Widget build(BuildContext context) {
    // Reference: thumbnail 43dp square at 17.5dp from the left edge, text
    // starts 28dp after the thumbnail, block sits ~10dp above the divider.
    final pal = _SheetPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(17.5, 0, 12, 12),
      child: Row(
        children: [
          // Plain thumbnail only — no glow / tint / colour extraction.
          if (square)
            AurumArtwork(url: artworkUrl, size: 48, borderRadius: 6)
          else if (wide)
            AurumWideThumb(
                url: artworkUrl, width: 76, height: 43, borderRadius: 6)
          else
            AurumArtwork(url: artworkUrl, size: 43, borderRadius: 2),
          SizedBox(width: square ? 14 : (wide ? 16 : 28)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: pal.text,
                    fontSize: 17,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: pal.textMuted,
                    fontSize: 14,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Menu groups ke beech patla divider (playback / library / go-to / feedback).
class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) {
    final pal = _SheetPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 19.5),
      child: Divider(height: 1, thickness: 1, color: pal.divider),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  const _Row({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final pal = _SheetPalette.of(context);
    final color = enabled ? pal.text : pal.text.withValues(alpha: 0.42);

    // Reference metrics: row pitch 47dp, 24dp icon centred 42.5dp from the
    // left edge, label starts 77dp from the left edge, ~16sp semi-bold.
    return InkWell(
      onTap: enabled
          ? () {
              AurumHaptics.selection();
              onTap();
            }
          : null,
      child: SizedBox(
        height: 47,
        child: Padding(
          padding: const EdgeInsets.only(left: 30.5, right: 24),
          child: Row(
            children: [
              Icon(icon, size: 24, color: color),
              const SizedBox(width: 22.5),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Playback speed sheet — same chrome as the options sheet.
// ─────────────────────────────────────────────────────────────────────────────
class _SpeedSheet extends StatefulWidget {
  final double initial;
  final Future<void> Function(double) onChanged;
  const _SpeedSheet({required this.initial, required this.onChanged});

  @override
  State<_SpeedSheet> createState() => _SpeedSheetState();
}

class _SpeedSheetState extends State<_SpeedSheet> {
  static const _steps = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  late double _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final pal = _SheetPalette.of(context);
    return _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Playback speed',
                style: TextStyle(
                  color: pal.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          for (final v in _steps)
            InkWell(
              onTap: () {
                AurumHaptics.selection();
                setState(() => _value = v);
                widget.onChanged(v);
                Navigator.of(context).pop();
              },
              child: SizedBox(
                height: 47,
                child: Padding(
                  padding: const EdgeInsets.only(left: 30.5, right: 24),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: (_value - v).abs() < 0.001
                            ? Icon(Icons.check_rounded, size: 24, color: pal.text)
                            : null,
                      ),
                      const SizedBox(width: 22.5),
                      Text(
                        v == 1.0 ? 'Normal' : '$v×',
                        style: TextStyle(
                          color: pal.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
