import 'package:flutter/foundation.dart';
import '../models/song.dart';
import '../services/local_music_service.dart';

enum LibraryStatus { idle, loading, loaded, noPermission, empty }

class LibraryProvider extends ChangeNotifier {
  LibraryStatus _status = LibraryStatus.idle;
  List<Song> _allSongs = [];
  List<SongSection> _sections = [];
  String _searchQuery = '';

  LibraryStatus get status => _status;
  List<SongSection> get sections => _sections;
  List<Song> get allSongs => _allSongs;
  bool get hasLoaded => _status == LibraryStatus.loaded || _status == LibraryStatus.empty;

  List<Song> get filteredSongs {
    if (_searchQuery.isEmpty) return _allSongs;
    final q = _searchQuery.toLowerCase();
    return _allSongs
        .where((s) =>
            s.title.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q) ||
            s.album.toLowerCase().contains(q))
        .toList();
  }

  Future<void> load() async {
    if (_status == LibraryStatus.loading) return;
    _status = LibraryStatus.loading;
    notifyListeners();

    try {
      final hasPermission = await LocalMusicService.hasPermission();
      if (!hasPermission) {
        final granted = await LocalMusicService.requestPermission();
        if (!granted) {
          _status = LibraryStatus.noPermission;
          notifyListeners();
          return;
        }
      }

      final songs = await LocalMusicService.scanLibrary();
      final sections = await LocalMusicService.scanLibrarySections();

      _allSongs = songs;
      _sections = sections;
      _status = songs.isEmpty ? LibraryStatus.empty : LibraryStatus.loaded;
      notifyListeners();
    } catch (_) {
      // FIX: any unexpected error during the offline scan (native channel
      // hiccup, malformed MediaStore row, etc.) used to propagate uncaught
      // and crash the whole widget tree to a white screen the moment the
      // user toggled to Offline. Now it degrades gracefully to "empty"
      // instead of taking down the app.
      _allSongs = [];
      _sections = [];
      _status = LibraryStatus.empty;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    _status = LibraryStatus.idle;
    await load();
  }

  void setSearch(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  void clearSearch() {
    _searchQuery = '';
    notifyListeners();
  }
}
