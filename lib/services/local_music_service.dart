import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import '../models/song.dart';

class LocalMusicService {
  static Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.storage.request();
      if (status.isDenied) {
        final audio = await Permission.audio.request();
        return audio.isGranted;
      }
      return status.isGranted;
    }
    return false;
  }

  static Future<bool> hasPermission() async {
    if (Platform.isAndroid) {
      final storage = await Permission.storage.status;
      if (storage.isGranted) return true;
      final audio = await Permission.audio.status;
      return audio.isGranted;
    }
    return false;
  }

  static Future<List<Song>> scanLibrary() async {
    final songs = <Song>[];
    final dirs = [
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Downloads',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Audio',
    ];
    for (final dirPath in dirs) {
      try {
        final dir = Directory(dirPath);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            final path = entity.path.toLowerCase();
            if (path.endsWith('.mp3') || path.endsWith('.m4a') ||
                path.endsWith('.flac') || path.endsWith('.wav') ||
                path.endsWith('.aac') || path.endsWith('.ogg')) {
              final name = entity.path.split('/').last
                  .replaceAll(RegExp(r'\.(mp3|m4a|flac|wav|aac|ogg)$',
                      caseSensitive: false), '');
              final hashCode = entity.path.hashCode.abs();
              songs.add(Song(
                id: 'local_$hashCode',
                title: name,
                artist: 'Unknown',
                album: dirPath.split('/').last,
                artworkUrl: 'content://media/external/audio/albumart/$hashCode',
                localPath: entity.path,
              ));
            }
          }
        }
      } catch (_) {
        continue;
      }
    }
    return songs;
  }

  static Future<List<SongSection>> scanLibrarySections() async {
    final songs = await scanLibrary();
    if (songs.isEmpty) return [];
    return [SongSection(title: 'Device Songs', songs: songs)];
  }
}
