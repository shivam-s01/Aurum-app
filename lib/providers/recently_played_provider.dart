import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/song.dart';
import '../utils/constants.dart';

// =============================================================================
// RecentlyPlayedProvider
//
// WHAT IT DOES:
//   - Saves every song the user plays into a Hive box (newest first).
//   - Keeps at most `recentlyPlayedLimit` entries (oldest auto-removed).
//   - Exposes `history` for the Library screen's "Recently Played" list.
//   - Exposes `topArtists()` — used by ApiService.fetchHome() to build the
//     "Made For You" home sections. Home screen never shows raw history,
//     only artist-based recommendation sections.
// =============================================================================
class RecentlyPlayedProvider extends ChangeNotifier {
  static const _boxName = AppConstants.boxRecentlyPlayed;
  late Box<Map> _box;
  List<Song> _history = [];

  // Newest-first list, for the Library screen.
  List<Song> get history => List.unmodifiable(_history);

  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
    _history = _box.values
        .map((m) => Song.fromJson(Map<String, dynamic>.from(m)))
        .toList()
        .reversed
        .toList();
    notifyListeners();
  }

  // Call this whenever a song starts playing.
  //
  // FIX 1: Local songs (source == local) are skipped — their "artist" field
  // is often unreliable/missing, and running a Saavn search for a local
  // artist's name in topArtists() would just waste an API call for nothing.
  // Local play history can still be tracked separately via LibraryProvider
  // if needed — this provider is specifically for online recommendations.
  //
  // FIX 2: We strip `streamUrl` before persisting. Saavn/YouTube stream URLs
  // expire after ~50 min (see ApiService._streamTtl) and are never read back
  // from history — keeping them in Hive is just dead weight.
  Future<void> addPlay(Song song) async {
    if (song.source == SongSource.local) return;

    // Avoid duplicate back-to-back entries (e.g. user replays same song).
    _history.removeWhere((s) => s.id == song.id);

    final entry = song.streamUrl == null
        ? song
        : Song(
            id: song.id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            artworkUrl: song.artworkUrl,
            streamUrl: null,
            duration: song.duration,
            language: song.language,
            year: song.year,
            localPath: song.localPath,
            source: song.source,
          );
    _history.insert(0, entry);

    // Trim to limit.
    if (_history.length > AppConstants.recentlyPlayedLimit) {
      _history = _history.sublist(0, AppConstants.recentlyPlayedLimit);
    }

    // Persist: clear + rewrite keeps Hive box in sync with in-memory order.
    // List is small (max 50), so this is cheap and avoids key-ordering bugs.
    await _box.clear();
    for (final s in _history.reversed) {
      await _box.put(s.id, s.toJson());
    }

    notifyListeners();
  }

  // Returns up to `count` most-listened artist names, ranked by play
  // frequency (ties broken by recency). Used to build "Made For You"
  // home sections. Empty list if no history yet (cold start).
  //
  // FIX 3: "Unknown" artist (Song's fallback when no artist data exists)
  // is excluded — searching Saavn for "Unknown hits" returns junk results.
  List<String> topArtists({int count = 2}) {
    if (_history.isEmpty) return [];

    final freq = <String, int>{};
    for (final song in _history) {
      final artist = song.artist.trim();
      if (artist.isEmpty || artist.toLowerCase() == 'unknown') continue;
      freq[artist] = (freq[artist] ?? 0) + 1;
    }

    final sorted = freq.keys.toList()
      ..sort((a, b) => freq[b]!.compareTo(freq[a]!));

    return sorted.take(count).toList();
  }
}
