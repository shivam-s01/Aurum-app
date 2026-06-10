import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import '../models/song.dart';

class LocalMusicService {
  /// Returns true if audio/storage permission already granted
  static Future<bool> hasPermission() async {
    if (Platform.isAndroid) {
      // Android 13+ uses READ_MEDIA_AUDIO
      if (await Permission.audio.isGranted) return true;
      // Android 12 and below uses READ_EXTERNAL_STORAGE
      if (await Permission.storage.isGranted) return true;
    }
    return false;
  }

  /// Requests all needed permissions: audio/storage + notifications
  /// Returns true only if audio/storage is granted (notification is best-effort)
  static Future<bool> requestPermission() async {
    // Request notification permission (Android 13+) — best effort, don't block on it
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }

    if (Platform.isAndroid) {
      // Try READ_MEDIA_AUDIO first (Android 13+)
      PermissionStatus audio = await Permission.audio.request();
      if (audio.isGranted) return true;

      // Fallback to READ_EXTERNAL_STORAGE (Android 12-)
      PermissionStatus storage = await Permission.storage.request();
      if (storage.isGranted) return true;

      // If permanently denied, open settings
      if (audio.isPermanentlyDenied || storage.isPermanentlyDenied) {
        await openAppSettings();
      }
      return false;
    }
    return false;
  }

  static Future<List<Song>> scanLibrary() async {
    try {
      final songs = <Song>[];
      final dirs = [
        '/storage/emulated/0/Music',
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Downloads',
        '/storage/emulated/0/WhatsApp/Media/WhatsApp Audio',
      ];
      for (final dirPath in dirs) {
        final dir = Directory(dirPath);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: false)) {
          if (entity is File) {
            final path = entity.path.toLowerCase();
            if (path.endsWith('.mp3') ||
                path.endsWith('.m4a') ||
                path.endsWith('.flac') ||
                path.endsWith('.wav') ||
                path.endsWith('.aac') ||
                path.endsWith('.ogg')) {
              final name = entity.path
                  .split('/')
                  .last
                  .replaceAll(
                      RegExp(r'\.(mp3|m4a|flac|wav|aac|ogg)$',
                          caseSensitive: false),
                      '');
              songs.add(Song(
                id: 'local_${entity.path.hashCode}',
                title: name,
                artist: 'Unknown',
                album: dirPath.split('/').last,
                artworkUrl: '',
                localPath: entity.path,
              ));
            }
          }
        }
      }
      return songs;
    } catch (_) {
      return [];
    }
  }

  static Future<List<SongSection>> scanLibrarySections() async {
    final songs = await scanLibrary();
    if (songs.isEmpty) return [];
    return [SongSection(title: 'Device Songs', songs: songs)];
  }
}
