import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'api_service.dart';

/// Cold-start home feed cache (Spotify-style "show what we last had
/// instantly, refresh in the background").
///
/// WHY THIS EXISTS: previously HomeScreen's initState() called
/// _loadOnline()/_loadArtists() with zero disk persistence anywhere —
/// every single cold app start (and every hot-reload of HomeScreen's
/// State) started from a completely empty `_onlineSections`/`_homeArtists`
/// list and showed shimmer/loading placeholders for the entire home feed
/// until the network round-trip (fetchHomeStreaming, up to a 25s timeout)
/// resolved. On a slow connection, or the very common case of a user
/// opening the app just to glance at something and closing it again
/// moments later, that meant staring at a placeholder-only home screen for
/// however long the network took — every single time, no matter how many
/// times the app had already successfully loaded before.
///
/// FIX: after every successful `_loadOnline()`/`_loadArtists()` fetch, the
/// resulting sections/artists are written here to SharedPreferences (small
/// JSON blobs — song lists this size are a few KB, well within normal
/// SharedPreferences usage elsewhere in this app, e.g. RecommendationEngine).
/// On the NEXT cold start, HomeScreen reads this cache synchronously-fast
/// (SharedPreferences.getInstance() resolves near-instantly, no network
/// involved) and renders it immediately as the initial state — the user
/// sees last session's home feed the instant the screen builds, with zero
/// perceptible loading delay, while the real fetch continues in the
/// background exactly as before and silently replaces the cached content
/// the moment fresh data arrives. If the cache is empty (genuine first-ever
/// launch) or unreadable, behavior falls back to exactly what it was
/// before this fix — a normal loading state until the fetch resolves.
///
/// FRESHNESS GUARANTEE ("premium, never stale" requirement): this cache
/// exists purely to cover the few seconds between app open and the network
/// fetch landing — it is NOT a substitute for real data and must never be
/// mistaken for one. [loadSections]/[loadArtists] enforce [maxFreshAge]
/// (15 minutes) internally: a cache older than that is treated exactly
/// like no cache at all and simply isn't returned, so a stale/day-old
/// playlist can never silently pass itself off as "today's" home feed —
/// callers don't need to remember to check staleness themselves, it's
/// impossible to accidentally read stale data through this API. The 25s
/// network fetch timeout guarantees a genuinely fresh batch always lands
/// well within that 15-minute window on any working connection, so in
/// practice this ceiling only ever matters for the "app was force-closed
/// mid-load" or "genuinely offline for a while" edge cases — the common
/// path (open app, see cache, fresh data silently arrives 1-3s later) is
/// unaffected by this ceiling.
class HomeFeedCache {
  static const _sectionsKey = 'home_feed_cache_sections_v1';
  static const _artistsKey = 'home_feed_cache_artists_v1';
  static const _savedAtKey = 'home_feed_cache_saved_at_ms';
  static const _artistsSavedAtKey = 'home_feed_cache_artists_saved_at_ms';

  // A cache older than this is indistinguishable from no cache at all —
  // enforced inside loadSections/loadArtists themselves, not left to
  // callers to remember to check. 15 minutes comfortably covers "user
  // force-closed the app mid-fetch and reopened a bit later" while still
  // guaranteeing nothing that could read as "yesterday's playlist" or
  // stale/off-brand content ever reaches the screen — the premium-app bar
  // here is that a returning user never has reason to suspect what they're
  // seeing isn't current.
  static const Duration maxFreshAge = Duration(minutes: 15);

  static Future<void> saveSections(List<SongSection> sections) async {
    if (sections.isEmpty) return; // never overwrite a good cache with nothing
    // Guard against caching a visibly broken/partial batch — a section
    // with no songs at all isn't something a returning user should see
    // flash on screen before being replaced; only cache sections that
    // actually have content, same bar real display logic already applies.
    final usable = sections.where((s) => s.songs.isNotEmpty).toList();
    if (usable.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(usable.map((s) => s.toJson()).toList());
      await prefs.setString(_sectionsKey, encoded);
      await prefs.setInt(_savedAtKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // Best-effort — a failed cache write just means the next cold start
      // falls back to the normal loading state, same as before this fix.
    }
  }

  static Future<List<SongSection>> loadSections() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedAtMs = prefs.getInt(_savedAtKey);
      if (savedAtMs == null) return [];
      final age = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(savedAtMs));
      // FRESHNESS GUARANTEE: a stale cache is treated as if it doesn't
      // exist — see the class doc comment above. This is what makes "the
      // user always gets fresh content" and "cold start is instant" both
      // true at once: instant applies only to genuinely recent data,
      // never to something old enough to feel stale or off.
      if (age > maxFreshAge) return [];
      final raw = prefs.getString(_sectionsKey);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => SongSection.fromJson(e as Map<String, dynamic>))
          // Defensive: a section that round-tripped with no songs (should
          // be impossible given the save-side guard above, but a future
          // format change or partial write shouldn't be able to put an
          // empty shelf on screen either) is dropped rather than shown.
          .where((s) => s.songs.isNotEmpty)
          .toList();
    } catch (_) {
      // Corrupt/incompatible cache (e.g. a future model-shape change) —
      // treat exactly like an empty cache rather than crashing home screen.
      return [];
    }
  }

  static Future<void> saveArtists(List<ArtistSimple> artists) async {
    if (artists.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(artists
          .map((a) => {'id': a.id, 'name': a.name, 'imageUrl': a.imageUrl})
          .toList());
      await prefs.setString(_artistsKey, encoded);
      await prefs.setInt(
          _artistsSavedAtKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
    }
  }

  static Future<List<ArtistSimple>> loadArtists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedAtMs = prefs.getInt(_artistsSavedAtKey);
      if (savedAtMs == null) return [];
      final age = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(savedAtMs));
      if (age > maxFreshAge) return []; // same freshness guarantee as sections
      final raw = prefs.getString(_artistsKey);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => ArtistSimple(
                id: e['id'] as String,
                name: e['name'] as String,
                imageUrl: e['imageUrl'] as String,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
