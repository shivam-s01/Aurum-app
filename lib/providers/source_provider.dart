import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MusicSource { online, offline }

class SourceProvider extends ChangeNotifier {
  static const _key = 'music_source';
  MusicSource _source = MusicSource.online;

  MusicSource get source => _source;
  bool get isOnline => _source == MusicSource.online;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved == 'offline') {
      _source = MusicSource.offline;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    _source = isOnline ? MusicSource.offline : MusicSource.online;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, isOnline ? 'online' : 'offline');
    notifyListeners();
  }
}
