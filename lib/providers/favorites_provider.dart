import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/song.dart';

class FavoritesProvider extends ChangeNotifier {
  static const _boxName = 'aurum_favorites';
  late Box<Map> _box;
  List<Song> _favorites = [];
  bool _isLoading = true;

  List<Song> get favorites => List.unmodifiable(_favorites);
  bool get isLoading => _isLoading;
  bool isFavorite(String id) => _favorites.any((s) => s.id == id);

  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
    _favorites = _box.values
        .map((m) => Song.fromJson(Map<String, dynamic>.from(m)))
        .toList()
        .reversed
        .toList();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> toggleFavorite(Song song) async {
    if (isFavorite(song.id)) {
      await _remove(song.id);
    } else {
      await _add(song);
    }
  }

  Future<void> _add(Song song) async {
    await _box.put(song.id, song.toJson());
    _favorites.insert(0, song);
    notifyListeners();
  }

  Future<void> _remove(String id) async {
    await _box.delete(id);
    _favorites.removeWhere((s) => s.id == id);
    notifyListeners();
  }
}
