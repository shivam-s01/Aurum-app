import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/song.dart';

class LocalMusicService {
  static final _query = OnAudioQuery();

  static Future<bool> hasPermission() async {
    if (await Permission.audio.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    return false;
  }

  static Future<bool> requestPermission() async {
    final granted = await _query.permissionsRequest();
    if (granted) return true;
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  static Future<List<Song>> scanLibrary() async {
    try {
      final songs = await _query.querySongs(
        sortType: SongSortType.DATE_ADDED,
        orderType: OrderType.DESC_OR_GREATER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      return songs
          .where((s) => s.duration != null && s.duration! > 30000)
          .map(_toSong)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<SongSection>> scanLibrarySections() async {
    try {
      final songs = await scanLibrary();
      if (songs.isEmpty) return [];
      final sections = <String, List<Song>>{};
      for (final s in songs) {
        final album = s.album.isEmpty ? 'Unknown Album' : s.album;
        sections.putIfAbsent(album, () => []).add(s);
      }
      return sections.entries
          .map((e) => SongSection(title: e.key, songs: e.value))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Song _toSong(SongModel s) {
    return Song(
      id: 'local_${s.id}',
      title: s.title,
      artist: s.artist ?? 'Unknown',
      album: s.album ?? '',
      artworkUrl: '',
      duration: s.duration != null ? (s.duration! / 1000).round() : null,
      localPath: s.data,
    );
  }
}
