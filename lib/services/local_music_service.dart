import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/song.dart';

class LocalMusicService {
  static const _channel = MethodChannel('com.aurum.music/media_store');

  static Future<bool> requestPermission() async {
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  static Future<bool> hasPermission() async {
    if (await Permission.audio.isGranted) return true;
    return Permission.storage.isGranted;
  }

  static Future<List<Song>> scanLibrary() async {
    final granted = await requestPermission();
    if (!granted) return [];
    try {
      final List<dynamic> result = await _channel.invokeMethod('getSongs');
      final songs = result
          .cast<Map<dynamic, dynamic>>()
          .map((m) => _toSong(Map<String, dynamic>.from(m)))
          .where((s) => s.localPath != null && s.localPath!.isNotEmpty)
          .toList();
      songs.sort((a, b) => a.title.compareTo(b.title));
      return songs;
    } catch (e) {
      return _fallbackScan();
    }
  }

  static Future<List<Song>> _fallbackScan() async {
    final songs = <Song>[];
    final dirs = [
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Downloads',
    ];
    for (final dirPath in dirs) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;
      try {
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            final path = entity.path.toLowerCase();
            if (path.endsWith('.mp3') || path.endsWith('.flac') ||
                path.endsWith('.m4a') || path.endsWith('.aac') ||
                path.endsWith('.ogg') || path.endsWith('.wav')) {
              final stat = await entity.stat();
              if (stat.size < 500000) continue;
              final name = entity.uri.pathSegments.last;
              final title = name
                  .replaceAll(RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav)$', caseSensitive: false), '')
                  .replaceAll('_', ' ')
                  .trim();
              songs.add(Song(
                id: 'local_${entity.path.hashCode.abs()}',
                title: title.isEmpty ? name : title,
                artist: 'Unknown Artist',
                album: dirPath.split('/').last,
                artworkUrl: '',
                localPath: entity.path,
              ));
            }
          }
        }
      } catch (_) {}
    }
    songs.sort((a, b) => a.title.compareTo(b.title));
    return songs;
  }

  static Future<List<SongSection>> scanLibrarySections() async {
    final songs = await scanLibrary();
    if (songs.isEmpty) return [];
    final sections = <SongSection>[
      SongSection(title: '🎵 All Songs', songs: songs),
    ];
    final albumMap = <String, List<Song>>{};
    for (final song in songs) {
      if (song.album.isNotEmpty) {
        albumMap.putIfAbsent(song.album, () => []).add(song);
      }
    }
    final topAlbums = albumMap.entries.where((e) => e.value.length >= 2).toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final entry in topAlbums.take(5)) {
      sections.add(SongSection(title: '💿 ${entry.key}', songs: entry.value));
    }
    return sections;
  }

  static Song _toSong(Map<String, dynamic> m) => Song(
        id: 'local_${m['id'] ?? m['path'].hashCode.abs()}',
        title: m['title'] ?? 'Unknown',
        artist: m['artist'] ?? 'Unknown Artist',
        album: m['album'] ?? '',
        artworkUrl: m['artwork'] ?? '',
        duration: m['duration'] != null
            ? (int.tryParse(m['duration'].toString()) ?? 0) ~/ 1000
            : null,
        localPath: m['path'] ?? m['data'] ?? '',
      );
}
