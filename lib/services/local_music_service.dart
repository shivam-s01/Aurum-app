import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/song.dart';

class LocalMusicService {
  static final OnAudioQuery _query = OnAudioQuery();

  /// Request storage/audio permission.
  static Future<bool> requestPermission() async {
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  /// Check without prompting.
  static Future<bool> hasPermission() async {
    if (await Permission.audio.isGranted) return true;
    return Permission.storage.isGranted;
  }

  /// Scan device and return all songs.
  static Future<List<Song>> scanLibrary() async {
    final granted = await requestPermission();
    if (!granted) return [];

    final audioFiles = await _query.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );

    return audioFiles
        .where((s) =>
            s.isMusic == true &&
            s.duration != null &&
            s.duration! > 30000 && // skip clips under 30s
            s.data.isNotEmpty)
        .map(_toSong)
        .toList();
  }

  /// Scan and return grouped sections for LibraryScreen.
  static Future<List<SongSection>> scanLibrarySections() async {
    final songs = await scanLibrary();
    if (songs.isEmpty) return [];

    final sections = <SongSection>[
      SongSection(title: '🎵 All Songs', songs: songs),
    ];

    // Group by album (top 5 with 2+ songs)
    final albumMap = <String, List<Song>>{};
    for (final song in songs) {
      if (song.album.isNotEmpty && song.album != 'Unknown') {
        albumMap.putIfAbsent(song.album, () => []).add(song);
      }
    }
    final topAlbums = albumMap.entries
        .where((e) => e.value.length >= 2)
        .toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    for (final entry in topAlbums.take(5)) {
      sections.add(SongSection(title: '💿 ${entry.key}', songs: entry.value));
    }

    return sections;
  }

  static Song _toSong(SongModel s) => Song(
        id: 'local_${s.id}',
        title: s.title ?? s.displayName,
        artist: s.artist ?? 'Unknown Artist',
        album: s.album ?? '',
        artworkUrl: '',
        streamUrl: null,
        duration: s.duration != null ? (s.duration! / 1000).round() : null,
        localPath: s.data,
      );
}
