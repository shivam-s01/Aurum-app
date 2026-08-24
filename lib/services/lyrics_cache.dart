// =============================================================================
// FILE: lib/services/lyrics_cache.dart
// Extracted from api_service.dart to shrink that file and isolate lyrics
// caching as its own small, single-purpose unit — same pattern as
// lightweight_stream_cache.dart. Bounded, oldest-first eviction (unchanged
// behavior from the original inline version).
// =============================================================================

import '../models/lyrics.dart';

class LyricsCache {
  static const int maxSize = 200;

  static final Map<String, String> _plain = {};
  static final Map<String, LyricsResult> _synced = {};

  static String? getPlain(String key) => _plain[key];

  static void setPlain(String key, String lyrics) {
    if (_plain.length > maxSize) {
      _plain.remove(_plain.keys.first);
    }
    _plain[key] = lyrics;
  }

  static LyricsResult? getSynced(String key) => _synced[key];

  static void setSynced(String key, LyricsResult result) {
    if (_synced.length > maxSize) {
      _synced.remove(_synced.keys.first);
    }
    _synced[key] = result;
  }

  static bool hasPlain(String key) => _plain.containsKey(key);
  static bool hasSynced(String key) => _synced.containsKey(key);

  static int get plainSize => _plain.length;
  static int get syncedSize => _synced.length;

  static void clear() {
    _plain.clear();
    _synced.clear();
  }
}
