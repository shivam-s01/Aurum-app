import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/song.dart';

class LocalMusicService {
  static const _channel = MethodChannel('com.aurum.music/media_store');

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
    if (Platform.isAndroid) {
      final hasAudio = await Permission.audio.isGranted;
      final hasStorage = await Permission.storage.isGranted;
      if (!hasAudio && !hasStorage) {
        await requestPermission();
      }
    }

    try {
      final List<dynamic> raw =
          await _channel.invokeMethod('getSongs') ?? [];

      return raw.map((item) {
        final map = Map<String, dynamic>.from(item as Map);
        return Song(
          id: map['id']?.toString() ?? '',
          title: _cleanTitle(map['title']?.toString() ?? ''),
          artist: _cleanArtist(map['artist']?.toString()),
          album: map['album']?.toString() ?? '',
          artworkUrl: map['artworkUrl']?.toString() ?? '',
          localPath: map['localPath']?.toString() ?? map['contentUri']?.toString() ?? '',
          duration: map['duration'] is int ? map['duration'] as int : null,
        );
      }).where((s) => s.id.isNotEmpty).toList();
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
        .replaceAll(RegExp(r'^\d+[\.\-_\s]+'), '')
        .trim();
  }

  static String _cleanArtist(String? raw) {
    if (raw == null || raw.isEmpty || raw == '<unknown>') return 'Unknown';
    return raw.trim();
  }
}
