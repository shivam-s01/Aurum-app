import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// "Not interested" / "Don't recommend artist" ka chhota persistent store.
/// Sirf Quick Picks ke liye use hota hai; SharedPreferences me save hota hai.
class QuickPicksFilter {
  QuickPicksFilter._();

  static const _kSongs = 'qp_hidden_songs';
  static const _kArtists = 'qp_hidden_artists';
  static const _maxSongs = 500;
  static const _maxArtists = 200;

  // LinkedHashSet (default) => insertion order, purane entries pehle trim.
  static final Set<String> _songs = <String>{};
  static final Set<String> _artists = <String>{};
  static Future<void>? _loading;

  // Credit string ("A & B", "A feat. B", "A x B", "A, B") me se primary
  // artist. '/' sirf spaces ke saath split hota hai taaki "AC/DC" na toote.
  static final RegExp _artistSplit = RegExp(
    r'\s*(?:,|&|\+|;|\s/\s|\bfeat\b\.?|\bft\b\.?|\bfeaturing\b|\s[xX]\s)\s*',
    caseSensitive: false,
  );

  static String _primaryArtist(String raw) => raw
      .split(_artistSplit)
      .first
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ');

  /// UI ke liye: primary artist ka display naam ("" agar na mile).
  static String primaryArtistName(String raw) =>
      raw.split(_artistSplit).first.trim();

  /// "Don't recommend artist" sirf tab jab real artist naam ho.
  static bool canHideArtist(String raw) {
    final k = _primaryArtist(raw);
    return k.isNotEmpty && k != 'unknown' && k != 'unknown artist';
  }

  /// Ek hi baar disk se load hota hai (concurrent calls same future share
  /// karti hain). Memory me jo pehle se add ho chuka ho use preserve karta
  /// hai taaki order aur latest choice kabhi na khoye.
  static Future<void> load() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    try {
      final p = await SharedPreferences.getInstance();
      final memSongs = _songs.toList();
      final memArtists = _artists.toList();
      _songs
        ..clear()
        ..addAll(p.getStringList(_kSongs) ?? const <String>[])
        ..addAll(memSongs);
      _artists
        ..clear()
        ..addAll(p.getStringList(_kArtists) ?? const <String>[])
        ..addAll(memArtists);
      _trim();
    } catch (_) {}
  }

  static void _trim() {
    while (_songs.length > _maxSongs) {
      _songs.remove(_songs.first);
    }
    while (_artists.length > _maxArtists) {
      _artists.remove(_artists.first);
    }
  }

  static Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kSongs, _songs.toList());
      await p.setStringList(_kArtists, _artists.toList());
    } catch (_) {}
  }

  static bool isHidden(Song s) =>
      _songs.contains(s.id) ||
      (_artists.isNotEmpty && _artists.contains(_primaryArtist(s.artist)));

  static List<Song> apply(List<Song> songs) =>
      _songs.isEmpty && _artists.isEmpty
          ? songs
          : songs.where((s) => !isHidden(s)).toList();

  // Set me change SYNC hota hai (await se pehle) taaki turant isHidden()
  // sahi jawab de; disk me save uske baad hota hai.
  static Future<void> hideSong(Song s) async {
    if (s.id.isEmpty) return;
    _songs.remove(s.id); // dobara add => sabse naya entry
    _songs.add(s.id);
    _trim();
    await load();
    await _persist();
  }

  static Future<void> hideArtist(String artist) async {
    if (!canHideArtist(artist)) return;
    final k = _primaryArtist(artist);
    _artists.remove(k);
    _artists.add(k);
    _trim();
    await load();
    await _persist();
  }

  /// Undo ke liye.
  static Future<void> unhideSong(Song s) async {
    _songs.remove(s.id);
    await load();
    _songs.remove(s.id);
    await _persist();
  }

  static Future<void> unhideArtist(String artist) async {
    final k = _primaryArtist(artist);
    _artists.remove(k);
    await load();
    _artists.remove(k);
    await _persist();
  }
}
