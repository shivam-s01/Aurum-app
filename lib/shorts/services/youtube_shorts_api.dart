import 'dart:async';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/short_item.dart';
import '../models/shorts_catalog.dart';

/// Isolated YouTube-native search client for the Shorts feed.
///
/// Replaces the old ItunesShortsApi entirely — the Shorts feed now
/// sources both discovery (search) and playback (audio+video, via
/// ShortsVideoService/the aurum-shorts-video Worker) from the same
/// single provider: YouTube. No iTunes calls anywhere in this module
/// anymore.
///
/// STRICT CATEGORY SCOPING: every query is built from exactly one
/// active category (+ optional language) — never blended with other
/// categories — so a feed opened under "Sad" only ever pulls "Sad"
/// results, matching the single-category-at-a-time premium-feed
/// requirement.
///
/// TRUE PAGINATION for unlimited scroll: each YoutubeExplode
/// SearchList carries its own continuation, fetched via
/// `list.nextPage()`. We keep one live SearchList per (category,
/// language) key so repeated calls advance forward through fresh
/// results instead of ever re-issuing page 1 of the same query — this
/// is what actually fixes "same songs every refresh": there's no
/// deterministic re-seeding to run into anymore, each call for a
/// given key is guaranteed to be further into the result set than the
/// last.
class YoutubeShortsApi {
  YoutubeShortsApi._();

  static final YoutubeExplode _yt = YoutubeExplode();
  static const _searchTimeout = Duration(seconds: 8);

  // key: "category::language" -> live paginated search cursor.
  static final Map<String, SearchList?> _cursors = {};
  // Guards against two overlapping fetches for the same key racing
  // and both calling nextPage() off the same cursor.
  static final Map<String, Future<List<ShortItem>>> _inFlight = {};

  static String _cursorKey(String category, String? language) =>
      '$category::${language ?? ''}';

  static String _buildQuery(String category, String? language) {
    final hint = ShortsCatalog.categories[category] ?? category.toLowerCase();
    final lang = (language != null && language.isNotEmpty) ? '$language ' : '';
    return '$lang$hint songs';
  }

  /// Fetches the next page of results for [category] (+ optional
  /// [language]). Safe to call repeatedly — advances the underlying
  /// cursor each time rather than re-fetching page 1. Returns an
  /// empty list only when YouTube truly has no more continuation
  /// (rare) or on a network failure.
  static Future<List<ShortItem>> fetchNextPage({
    required String category,
    String? language,
    int limit = 20,
  }) async {
    final key = _cursorKey(category, language);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _fetchNextPageInternal(key, category, language, limit);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  static Future<List<ShortItem>> _fetchNextPageInternal(
    String key,
    String category,
    String? language,
    int limit,
  ) async {
    try {
      SearchList? cursor = _cursors[key];

      if (cursor == null) {
        final query = _buildQuery(category, language);
        cursor = await _yt.search.search(query).timeout(_searchTimeout);
      } else {
        final more = await cursor.nextPage().timeout(_searchTimeout);
        if (more == null) {
          // Cursor exhausted — reset so a future call starts a fresh
          // search rather than getting stuck returning nothing
          // forever. With how large YouTube's result set is for any
          // real category term this should be very rare in practice.
          _cursors[key] = null;
          return const [];
        }
        cursor = more;
      }

      _cursors[key] = cursor;

      return cursor
          .whereType<Video>()
          .take(limit)
          .map((v) => _toShortItem(v, category))
          .where((s) => s.isPlayable)
          .toList();
    } on TimeoutException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  static ShortItem _toShortItem(Video v, String category) => ShortItem(
        videoId: v.id.value,
        title: _cleanText(v.title),
        artist: _cleanText(v.author),
        artworkUrl: _bestThumbnail(v),
        durationSecs: v.duration?.inSeconds ?? 0,
        category: category,
      );

  static String _bestThumbnail(Video v) {
    final thumbs = v.thumbnails;
    return thumbs.maxResUrl.isNotEmpty
        ? thumbs.maxResUrl
        : (thumbs.highResUrl.isNotEmpty
            ? thumbs.highResUrl
            : thumbs.standardResUrl);
  }

  static String _cleanText(String s) => s.trim();

  /// Resets the pagination cursor for a given category/language —
  /// used when the user explicitly pulls-to-refresh and actually
  /// wants to start over from the top, as opposed to normal
  /// infinite-scroll advancing.
  static void resetCursor(String category, String? language) {
    _cursors.remove(_cursorKey(category, language));
  }

  static void resetAllCursors() {
    _cursors.clear();
  }
}
