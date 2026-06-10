import 'package:flutter/services.dart';
import '../models/song.dart';

/// Fetches local songs from Android MediaStore via MethodChannel.
/// Returns a list of [Song] with title, artist, album, duration & artwork URI.
class LocalMusicService {
  static const _channel = MethodChannel('com.aurum.music/media_store');

  /// Scan device for music files.
  /// Returns an empty list on error (permission denied, etc.).
  static Future<List<Song>> getSongs() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('getSongs');
      if (raw == null) return [];

      return raw
          .cast<Map<dynamic, dynamic>>()
          .map((m) => _songFromMap(Map<String, dynamic>.from(m)))
          .toList();
    } on PlatformException catch (e) {
      // Permission denied or MediaStore unavailable
      debugPrint('[LocalMusicService] getSongs error: ${e.message}');
      return [];
    } catch (e) {
      debugPrint('[LocalMusicService] unexpected error: $e');
      return [];
    }
  }

  static Song _songFromMap(Map<String, dynamic> m) {
    // Duration comes from MediaStore as milliseconds (String)
    final durMs = int.tryParse(m['duration']?.toString() ?? '0') ?? 0;

    // Artwork: content URI supplied by MainActivity
    final artwork = (m['artwork'] as String?) ?? '';

    // Clean up "unknown" placeholders that MediaStore sometimes emits
    String artist = (m['artist'] as String?) ?? '';
    if (artist.isEmpty || artist == '<unknown>') artist = 'Unknown Artist';

    String title = (m['title'] as String?) ?? '';
    if (title.isEmpty) title = 'Unknown Title';

    return Song(
      id: m['id']?.toString() ?? '',
      title: title,
      artist: artist,
      album: (m['album'] as String?) ?? '',
      artworkUrl: artwork,
      // Local songs have no stream URL — audio_handler uses localPath instead
      streamUrl: '',
      localPath: (m['path'] as String?) ?? '',
      duration: Duration(milliseconds: durMs),
      isLocal: true,
    );
  }
}

// Tiny debug helper — import 'package:flutter/foundation.dart' not needed
// when the file already imports services.dart (which re-exports foundation).
void debugPrint(String msg) {
  assert(() {
    // ignore: avoid_print
    print(msg);
    return true;
  }());
}
