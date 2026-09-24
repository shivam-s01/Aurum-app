import 'package:flutter/foundation.dart';
import '../models/song.dart';

/// Codec label (OPUS / AAC / MP3 / VORBIS) for the currently playing song.
///  - YouTube: the app's real resolver (YoutubeInnertube.resolve(), see
///    android/.../YoutubeInnertube.kt + Id3ArtworkWriter.kt) picks the
///    highest-bitrate audio stream with no container filter — on the
///    overwhelming majority of videos that's itag 251 (WebM/Opus), so
///    'OPUS' is shown immediately instead of re-resolving the manifest a
///    second time just for display. (A second, independent lookup via
///    youtube_explode_dart's public manifest endpoint was tried here
///    before, but that call is routinely blocked/empty on-device — same
///    reason actual playback goes through the app's own Worker/native
///    resolver instead of that package — so the chip sat stuck on the
///    "Astra" fallback even though the real stream was Opus the entire
///    time.)
///  - Saavn: AAC (Saavn serves AAC).
///  - Local: from the file extension (only when it maps to one of the labels).
class StreamQualityStore extends ChangeNotifier {
  StreamQualityStore._();
  static final StreamQualityStore instance = StreamQualityStore._();

  /// Returns the codec label for [song], or null if it can't be determined
  /// (falls back to "Astra" in the chip).
  String? codecFor(Song song) {
    if (song.isLocal) return _codecForPath(song.localPath);
    switch (song.source) {
      case SongSource.saavn:
        return 'AAC';
      case SongSource.youtube:
        // Matches what YoutubeInnertube.resolve() actually serves for
        // playback — see comment above.
        return 'OPUS';
      case SongSource.local:
        return _codecForPath(song.localPath);
    }
  }

  /// True when the codec is unknown for [song] -> chip falls back to
  /// "Astra". Only reachable for local files with an unrecognised
  /// extension now that YouTube always resolves to 'OPUS' above.
  bool showFallback(Song song) => codecFor(song) == null;

  static String? _codecForPath(String? path) {
    if (path == null) return null;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    switch (path.substring(dot + 1).toLowerCase()) {
      case 'opus':
        return 'OPUS';
      case 'm4a':
      case 'aac':
        return 'AAC';
      case 'mp3':
        return 'MP3';
      default:
        return null;
    }
  }
}
