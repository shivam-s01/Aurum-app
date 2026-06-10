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

  static Future<List<Song>> scanLibrary() async => [];
  static Future<List<SongSection>> scanLibrarySections() async => [];
}
