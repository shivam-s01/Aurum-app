import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/song.dart';

class LocalMusicService {
  static const _channel = MethodChannel('com.aurum.music/media_store');

  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return false;
    // Android 13+ = READ_MEDIA_AUDIO, older = READ_EXTERNAL_STORAGE
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  /// Opens the OEM-specific autostart/background-allow settings screen
  /// (realme/OPPO ColorOS, MIUI, Vivo, Huawei, etc.), falling back to the
  /// app's own info page if the device doesn't match a known OEM path.
  static Future<bool> openAutostartSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod('openAutostartSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> hasPermission() async {
    if (!Platform.isAndroid) return false;
    if (await Permission.audio.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    return false;
  }

  static Future<List<Song>> scanLibrary() async {
    final granted = await hasPermission();
    if (!granted) {
      final result = await requestPermission();
      if (!result) return [];
    }

    try {
      final List<dynamic> raw =
          await _channel.invokeMethod('getSongs') ?? [];

      final songs = <Song>[];
      for (final item in raw) {
        // FIX: map a single malformed entry individually instead of
        // letting one bad item's exception escape `.map()` and abort
        // the entire scan — that uncaught error was propagating up
        // through LibraryProvider.load() (which also had no try/catch)
        // and crashing the widget tree to a white screen the instant
        // the user switched to Offline.
        try {
          final map = Map<String, dynamic>.from(item as Map);
          final contentUri = map['contentUri']?.toString() ?? '';
          final dataPath   = map['localPath']?.toString() ?? '';
          // Prefer the raw file path over content:// — just_audio/ExoPlayer
          // plays MediaStore file paths far more reliably than generic
          // content:// URIs, which can silently fail to produce audio on
          // some Android versions/devices despite resolving fine for artwork.
          final resolvedPath = dataPath.isNotEmpty ? dataPath : contentUri;

          final song = Song(
            id: map['id']?.toString() ?? '',
            title: _cleanTitle(map['title']?.toString() ?? ''),
            artist: _cleanArtist(map['artist']?.toString()),
            album: map['album']?.toString() ?? '',
            artworkUrl: map['artworkUrl']?.toString() ?? '',
            localPath: resolvedPath,
            duration: map['duration'] is int ? map['duration'] as int : null,
            source: SongSource.local,
          );
          if (song.id.isNotEmpty && song.localPath!.isNotEmpty) {
            songs.add(song);
          }
        } catch (_) {
          // Skip this single malformed entry, keep scanning the rest.
          continue;
        }
      }
      return songs;
    } catch (_) {
      // FIX: was `on PlatformException catch` only — any other error
      // type (TypeError, MissingPluginException, cast failure, etc.)
      // used to propagate uncaught straight into the white-screen crash.
      // Offline mode degrades to "no local songs" instead of crashing.
      return [];
    }
  }

  static Future<List<SongSection>> scanLibrarySections(List<Song> songs) {
    if (songs.isEmpty) return Future.value([]);
    // REDESIGN ("premium, not one big generic shelf"): this used to dump
    // every local song into a single "Device Songs" section — with the
    // Home screen now rendering each section as its own horizontal
    // artwork-card shelf (see home_screen.dart's _OfflineSectionRow), one
    // giant section meant offline Home was still effectively ONE shelf no
    // matter how varied the actual library was, which is exactly what
    // read as generic rather than a real curated-feeling page. Grouping by
    // album (when known) gives multiple genuinely distinct shelves — same
    // "each shelf is its own real playlist" feel the online feed and
    // Spotify's own Downloaded tab both have — while still falling back to
    // one combined "Device Songs" section for whatever fraction of a
    // user's library has no usable album tag (common for random/renamed
    // downloads), so nothing here ever produces a shelf of size zero or
    // silently drops a song.
    const unknownAlbum = '<unknown>';
    final byAlbum = <String, List<Song>>{};
    final untagged = <Song>[];
    for (final song in songs) {
      final album = song.album.trim();
      if (album.isEmpty || album == unknownAlbum) {
        untagged.add(song);
      } else {
        (byAlbum[album] ??= []).add(song);
      }
    }

    // Only albums with more than one track read as a genuine "shelf" —
    // singles/one-offs are folded into the combined section instead of
    // each becoming its own near-empty row, which is what a real
    // curated-playlist feel actually requires (a shelf of one card looks
    // broken, not premium).
    final sections = <SongSection>[];
    final leftovers = <Song>[...untagged];
    byAlbum.forEach((album, albumSongs) {
      if (albumSongs.length > 1) {
        sections.add(SongSection(title: album, songs: albumSongs));
      } else {
        leftovers.addAll(albumSongs);
      }
    });

    // Largest/most-populated albums first — mirrors how the online feed's
    // own sections are ordered by relevance, not arrival order.
    sections.sort((a, b) => b.songs.length.compareTo(a.songs.length));

    if (leftovers.isNotEmpty) {
      sections.add(SongSection(title: 'Device Songs', songs: leftovers));
    }

    return Future.value(sections);
  }

  static String _cleanTitle(String raw) {
    return raw
        .replaceAll(RegExp(r'\.(mp3|m4a|flac|wav|aac|ogg)$',
            caseSensitive: false), '')
        .replaceAll(RegExp(r'^\d+[.\-_\s]+'), '')
        .trim();
  }

  static String _cleanArtist(String? raw) {
    if (raw == null || raw.isEmpty || raw == '<unknown>') return 'Unknown';
    return raw.trim();
  }
}
