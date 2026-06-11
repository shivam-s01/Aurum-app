import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../models/song.dart';

class LocalMusicService {
  static final _audioQuery = OnAudioQuery();

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
    try {
      final deviceSongs = await _audioQuery.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      for (final s in deviceSongs) {
        if (s.duration != null && s.duration! > 30000) {
          songs.add(Song(
            id: 'local_${s.id}',
            title: s.title,
            artist: s.artist ?? 'Unknown',
            album: s.album ?? '',
            artworkUrl: 'content://media/external/audio/albumart/${s.albumId}',
            localPath: s.data,
          ));
        }
      }
    } catch (_) {}
    return songs;
  }

  static Future<List<SongSection>> scanLibrarySections() async {
    final songs = await scanLibrary();
    if (songs.isEmpty) return [];
    return [SongSection(title: 'Device Songs', songs: songs)];
  }
}
