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

      return raw.map((item) {
        final map = Map<String, dynamic>.from(item as Map);
        final contentUri = map['contentUri']?.toString() ?? '';
        final dataPath   = map['localPath']?.toString() ?? '';
        // Prefer the raw file path over content:// — just_audio/ExoPlayer
        // plays MediaStore file paths far more reliably than generic
        // content:// URIs, which can silently fail to produce audio on
        // some Android versions/devices despite resolving fine for artwork.
        final resolvedPath = dataPath.isNotEmpty ? dataPath : contentUri;

        return Song(
          id: map['id']?.toString() ?? '',
          title: _cleanTitle(map['title']?.toString() ?? ''),
          artist: _cleanArtist(map['artist']?.toString()),
          album: map['album']?.toString() ?? '',
          artworkUrl: map['artworkUrl']?.toString() ?? '',
          localPath: resolvedPath,
          duration: map['duration'] is int ? map['duration'] as int : null,
          source: SongSource.local,
        );
      }).where((s) => s.id.isNotEmpty && s.localPath!.isNotEmpty).toList();
    } on PlatformException catch (_) {
      return [];
    }
  }

  static Future<List<SongSection>> scanLibrarySections() async {
    final songs = await scanLibrary();
    if (songs.isEmpty) return [];
    return [SongSection(title: 'Device Songs', songs: songs)];
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
