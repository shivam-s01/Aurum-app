import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yte;
import '../models/song.dart';

/// Codec label (OPUS / AAC / MP3 / VORBIS) for the currently playing song.
///  - YouTube: read from YouTube's own audio stream manifest (real codec).
///  - Saavn: AAC (Saavn serves AAC).
///  - Local: from the file extension (only when it maps to one of the labels).
class StreamQualityStore extends ChangeNotifier {
  StreamQualityStore._();
  static final StreamQualityStore instance = StreamQualityStore._();

  final LinkedHashMap<String, String> _youtubeCodec = LinkedHashMap();
  final Set<String> _pending = <String>{};
  // videoId -> when the last full attempt (3 tries) failed. Drives the
  // "Astra" fallback label and a 45s cool-down before a silent background retry.
  final Map<String, DateTime> _failedAt = <String, DateTime>{};

  /// True when the codec could not be determined for [song] (lookup failed,
  /// or the source has no known label) -> the chip falls back to "Astra".
  /// False while a first lookup is still in flight (chip shows only the wave).
  bool showFallback(Song song) {
    if (song.isLocal || song.source != SongSource.youtube) {
      return codecFor(song) == null;
    }
    return !_youtubeCodec.containsKey(song.id) && _failedAt.containsKey(song.id);
  }

  /// Returns the codec label for [song], or null while unknown.
  String? codecFor(Song song) {
    if (song.isLocal) return _codecForPath(song.localPath);
    switch (song.source) {
      case SongSource.saavn:
        return 'AAC';
      case SongSource.youtube:
        final known = _youtubeCodec[song.id];
        if (known == null) unawaited(_resolveYoutube(song.id));
        return known;
      case SongSource.local:
        return _codecForPath(song.localPath);
    }
  }

  Future<void> _resolveYoutube(String videoId) async {
    if (videoId.isEmpty ||
        _youtubeCodec.containsKey(videoId) ||
        _pending.contains(videoId)) {
      return;
    }
    final failedAt = _failedAt[videoId];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(seconds: 45)) {
      return;
    }
    _pending.add(videoId);
    String? label;
    try {
      // Up to 3 tries with a FRESH client each time (a stale/blocked client
      // is the usual reason for a one-off failure) and a short backoff.
      for (var attempt = 0; attempt < 3 && label == null; attempt++) {
        final yt = yte.YoutubeExplode();
        try {
          final manifest = await yt.videos.streamsClient
              .getManifest(videoId)
              .timeout(const Duration(seconds: 12));
          // Same preference the player follows: Opus (itag 251) when YouTube
          // offers it, otherwise the highest-bitrate audio stream.
          var hasOpus = false;
          String? best;
          var bestBps = -1;
          for (final s in manifest.audioOnly) {
            final l = _labelFromCodec(s.audioCodec);
            if (l == null) continue;
            if (l == 'OPUS') hasOpus = true;
            final bps = s.bitrate.bitsPerSecond;
            if (bps > bestBps) {
              bestBps = bps;
              best = l;
            }
          }
          label = hasOpus ? 'OPUS' : best;
        } catch (_) {
          label = null;
        } finally {
          yt.close();
        }
        if (label == null && attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 700 * (attempt + 1)));
        }
      }
    } finally {
      _pending.remove(videoId);
    }

    if (label != null) {
      _failedAt.remove(videoId);
      _youtubeCodec[videoId] = label;
      while (_youtubeCodec.length > 200) {
        _youtubeCodec.remove(_youtubeCodec.keys.first);
      }
      notifyListeners();
    } else {
      final firstFailure = !_failedAt.containsKey(videoId);
      if (_failedAt.length > 300) _failedAt.clear();
      _failedAt[videoId] = DateTime.now();
      if (firstFailure) notifyListeners(); // chip switches to "Astra"
    }
  }

  static String? _labelFromCodec(String codec) {
    final c = codec.toLowerCase();
    if (c.contains('opus')) return 'OPUS';
    if (c.contains('mp4a') || c.contains('aac')) return 'AAC';
    if (c.contains('vorbis')) return 'VORBIS';
    if (c.contains('mp3') || c.contains('mpeg')) return 'MP3';
    return null;
  }

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
