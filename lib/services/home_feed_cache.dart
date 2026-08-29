import 'dart:convert';
import 'package:flutter/foundation.dart';
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
/// FRESHNESS GUARANTEE ("100 songs, category-wise, top-grade, instant
/// open, auto-refresh every 10 hours — not on every single app open"):
/// cold start reads this cache and paints it instantly (near-0ms,
/// SharedPreferences, no network) instead of showing shimmer while a
/// fresh fetch runs. [loadSections]/[loadArtists] enforce [maxFreshAge]
/// (10 hours) internally: once a cache is older than that, it's treated
/// exactly like no cache exists and a real background fetch runs instead
/// — callers don't need to remember to check staleness themselves. A
/// manual pull-to-refresh bypasses this entirely (home_screen.dart's
/// RefreshIndicator calls _loadOnline() directly, which never reads this
/// cache), so the user can always force a real refresh on demand
/// regardless of how fresh the last cache still is.
/// Runs on a background isolate via compute() — see loadSections() below
/// for why this was pulled out of the main isolate for LARGE payloads.
/// Must be a top-level function (not a closure/instance method) for
/// compute() to send it across the isolate boundary.
List<SongSection> _decodeSections(String raw) {
  final decoded = jsonDecode(raw) as List;
  return decoded
      .map((e) => SongSection.fromJson(e as Map<String, dynamic>))
      // Defensive: a section that round-tripped with no songs (should be
      // impossible given the save-side guard in saveSections, but a future
      // format change or partial write shouldn't be able to put an empty
      // shelf on screen either) is dropped rather than shown.
      .where((s) => s.songs.isNotEmpty)
      .toList();
}

// PERF: compute() itself isn't free — spinning up a background isolate has
// its own fixed cost (isolate spawn + message-passing serialization), which
// on a weak/2GB-RAM device can run 10-30ms+. For the common case (a modest
// cache — a handful of home sections, maybe 60-150 songs total, well under
// this threshold) that spawn cost is actually MORE overhead than just
// decoding inline ever was — inline JSON decode of a small string is
// microseconds, nowhere near enough to drop a frame. compute() is only
// worth paying for once the payload is large enough that an inline decode
// would itself risk blocking a frame during the splash/cold-start window.
// 40 KB of JSON is comfortably past that point (multiple sections' worth
// of full song metadata) while staying well under what a normal cache
// actually reaches in practice — this keeps the common path as light and
// fast as inline decode always was, and only pays the isolate cost on the
// rarer large-cache case where it's actually a net win.
const int _computeThresholdBytes = 40 * 1024;

/// Top-level counterpart to _decodeSections — same compute()-eligibility
/// reasoning applies to the write path (saveSections runs after every
/// background feed refresh, which can land while the user is actively
/// scrolling Home; a large jsonEncode inline right then is exactly the
/// kind of single-frame jank that reads as "stutter while scrolling").
String _encodeSections(List<Map<String, dynamic>> sectionsJson) =>
    jsonEncode(sectionsJson);

/// Top-level decode for the artists cache — same compute()-eligibility
/// reasoning as _decodeSections above. Previously loadArtists() ran this
/// jsonDecode()+map() unconditionally inline, with none of the size-gated
/// compute() dispatch _decodeSections/loadSections already had — so a
/// large artists cache (a long "followed/home artists" list building up
/// over many sessions) could still block the UI isolate during the exact
/// splash-animation window loadSections() was already fixed for, and read
/// as the same "splash skipped / frozen open" symptom via this second,
/// previously-unguarded path.
List<ArtistSimple> _decodeArtists(String raw) {
  final decoded = jsonDecode(raw) as List;
  return decoded
      .map((e) => ArtistSimple(
            id: e['id'] as String,
            name: e['name'] as String,
            imageUrl: e['imageUrl'] as String,
          ))
      .toList();
}

class HomeFeedCache {
  static const _sectionsKey = 'home_feed_cache_sections_v1';
  static const _artistsKey = 'home_feed_cache_artists_v1';
  static const _savedAtKey = 'home_feed_cache_saved_at_ms';
  static const _artistsSavedAtKey = 'home_feed_cache_artists_saved_at_ms';

  // A cache older than this is indistinguishable from no cache at all —
  // enforced inside loadSections/loadArtists themselves, not left to
  // callers to remember to check. 10 hours per explicit product
  // requirement: the home feed should show the SAME 100-per-category
  // songs, instantly, for the whole day between opens — it should not
  // silently reshuffle/refetch just because the user closed and reopened
  // the app a few minutes later. A real background refresh only kicks in
  // once this window has genuinely elapsed; a manual pull-to-refresh
  // (see RefreshIndicator in home_screen.dart) always bypasses this cache
  // entirely and forces a real fetch regardless of age.
  static const Duration maxFreshAge = Duration(hours: 10);

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
      final sectionsJson = usable.map((s) => s.toJson()).toList();
      // Size-aware, same reasoning as loadSections()'s decode dispatch —
      // .toJson() itself (building the plain Map list) is cheap regardless
      // of size, so only the actual string-encode step is size-gated here.
      // A rough pre-check on section/song count avoids fully building the
      // list twice just to measure it: encode inline unless there's
      // clearly enough data for it to matter.
      final approxSongCount =
          usable.fold<int>(0, (sum, s) => sum + s.songs.length);
      final encoded = approxSongCount > 200
          ? await compute(_encodeSections, sectionsJson)
          : _encodeSections(sectionsJson);
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
      // PERF FIX ("app freezes right after opening, splash looks skipped"):
      // this used to run jsonDecode() + SongSection.fromJson() for every
      // song in every cached section directly here, on the UI isolate,
      // inside HomeScreen.initState() — i.e. the exact same frame window
      // splash_screen.dart's AnimationController needs to keep ticking
      // smoothly at 60fps (widget.child, which contains HomeScreen, is
      // deliberately mounted underneath the splash from frame 1 — see that
      // file's comment). A cache with many sections/songs made this decode
      // heavy enough to drop enough frames that the splash animation read
      // as "skipped" (it was still running, just too janky/fast-forwarded
      // to see) and the whole UI felt frozen.
      //
      // Size-aware dispatch: only hand this off to compute() (a real
      // background isolate) once the payload is big enough that decoding
      // it inline would risk blocking a frame — see _computeThresholdBytes
      // above for why. A typical/small cache decodes inline, which is both
      // simpler and actually faster than paying an isolate-spawn cost for
      // a few KB of JSON — keeping the common case as lightweight as
      // possible instead of unconditionally paying isolate overhead.
      if (raw.length < _computeThresholdBytes) {
        return _decodeSections(raw);
      }
      return compute(_decodeSections, raw);
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
      // PERF FIX — same "splash skipped / frozen open" issue loadSections()
      // was already fixed for (see _decodeArtists doc comment above): only
      // hand this off to a real background isolate once the payload is
      // large enough that decoding it inline would risk blocking a frame;
      // a typical/small artists list decodes inline, which is both simpler
      // and faster than paying isolate-spawn overhead for a few KB of JSON.
      if (raw.length < _computeThresholdBytes) {
        return _decodeArtists(raw);
      }
      return compute(_decodeArtists, raw);
    } catch (_) {
      return [];
    }
  }
}
