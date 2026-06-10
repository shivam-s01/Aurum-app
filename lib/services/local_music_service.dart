import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import '../models/song.dart';

class LocalMusicService {
  static Future<bool> hasPermission() async {
    if (await Permission.audio.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    return false;
  }

  static Future<bool> requestPermission() async {
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  static Future<List<Song>> scanLibrary() async {
    try {
      final dirs = [
        '/storage/emulated/0/Music',
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Downloads',
      ];
      final songs = <Song>[];
      for (final dirPath in dirs) {
        final dir = Directory(dirPath);
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            final path = entity.path;
            if (path.endsWith('.mp3') || path.endsWith('.m4a') || path.endsWith('.flac') || path.endsWith('.wav')) {
              final name = path.split('/').last.replaceAll(RegExp(r'\.(mp3|m4a|flac|wav)$'), '');
              songs.add(Song(
                id: 'local_${path.hashCode}',
                title: name,
                artist: 'Unknown',
                album: dirPath.split('/').last,
                artworkUrl: '',
                localPath: path,
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
