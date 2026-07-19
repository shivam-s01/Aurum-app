import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/short_item.dart';
import '../models/shorts_catalog.dart';

/// iTunes Search API client for the Shorts feed — replaces the old
/// YouTube-native pipeline entirely. No search-then-resolve step: the
/// iTunes `previewUrl` field IS the playable 30-second AAC clip, so
/// there is nothing between "discovery" and "playable URL" that can
/// fail. This is what makes Shorts as reliable as the free/no-auth
/// iTunes Search API itself — no scraping, no per-video match/resolve
/// chain, no Worker dependency.
///
/// STRICT CATEGORY SCOPING: every query is built from exactly one
/// active category (+ optional language) — matches the existing
/// single-category-feed requirement.
///
/// PAGINATION for unlimited scroll: iTunes Search has no continuation
/// token, so we page via `offset` — each call for the same
/// (category, language) key asks for the next `limit`-sized slice
/// further into the result set, tracked per key so repeated calls
/// never re-fetch the same page.
class ItunesShortsApi {
  ItunesShortsApi._();

  static const _base = 'https://itunes.apple.com/search';
  static const _searchTimeout = Duration(seconds: 8);

  // key: "category::language" -> next offset to fetch from.
  static final Map<String, int> _offsets = {};
  // Guards against two overlapping fetches for the same key racing.
  static final Map<String, Future<List<ShortItem>>> _inFlight = {};

  static String _cursorKey(String category, String? language) =>
      '$category::${language ?? ''}';

  /// Builds the search term. Anchors to a real seed artist for the
  /// active language when one exists (see
  /// ShortsCatalog.languageSeedArtists) — plain-text genre/language
  /// words alone skew heavily toward mainstream Hindi/Bollywood
  /// results under the IN storefront regardless of intent, but a real
  /// artist name is a much stronger relevance signal.
  static String _buildTerm(String category, String? language, int seedIndex) {
    final hint = ShortsCatalog.categories[category] ?? category.toLowerCase();
    if (language != null && language.isNotEmpty) {
      final seeds = ShortsCatalog.languageSeedArtists[language];
      if (seeds != null && seeds.isNotEmpty) {
        final artist = seeds[seedIndex % seeds.length];
        return '$artist $hint';
      }
      return '$language $hint';
    }
    return hint;
  }

  // BUGFIX: this used to fall back to 'IN' whenever no language was
  // selected — so a plain category like "Rock" or "K-Pop" (no
  // language attached) was always searched against the India
  // storefront, which skews iTunes' relevance ranking toward
  // Bollywood/Hindi results regardless of the actual genre. 'US' is
  // the correct neutral default: it's iTunes' largest, most complete
  // catalog and isn't skewed toward any one regional genre.
  static String _country(String? language) =>
      ShortsCatalog.languageToCountry[language] ?? 'US';

  /// Fetches the next page of results for [category] (+ optional
  /// [language]). Safe to call repeatedly — advances the offset each
  /// time rather than re-fetching the same slice.
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
    final offset = _offsets[key] ?? 0;
    // Rotate through seed artists across pages so consecutive pages
    // don't all hammer the exact same artist — gives natural variety
    // over an unlimited scroll session.
    final seedIndex = offset ~/ limit;
    final term = _buildTerm(category, language, seedIndex);
    final country = _country(language);

    final uri = Uri.parse(_base).replace(queryParameters: {
      'term': term,
      'media': 'music',
      'entity': 'song',
      'country': country,
      'limit': '$limit',
      'offset': '$offset',
    });

    try {
      final resp = await http.get(uri).timeout(_searchTimeout);
      if (resp.statusCode != 200) return const [];

      final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final results = (body['results'] as List?) ?? const [];
      if (results.isEmpty) {
        // BUGFIX: not advancing the offset here meant a caller that
        // retries on an empty page (e.g. infinite-scroll hitting a thin
        // result set) would re-send the EXACT same offset/seedIndex and
        // get the exact same empty response every time — a permanent
        // stuck point partway through a category's catalog, not just a
        // thin patch it scrolls past. Advancing by `limit` here means the
        // very next call naturally lands on a new offset (and therefore,
        // via seedIndex = offset ~/ limit, a new rotated seed artist),
        // so scrolling actually recovers instead of hanging forever.
        _offsets[key] = offset + limit;
        return const [];
      }

      _offsets[key] = offset + limit;

      final items = results
          .whereType<Map<String, dynamic>>()
          .map((r) => _toShortItem(r, category))
          .where((s) => s.isPlayable)
          .toList();

      // Language sanity check — catches iTunes returning off-language
      // (usually Hindi) results despite a language-scoped query.
      final hints = language != null
          ? ShortsCatalog.languageTitleHints[language]
          : null;
      if (hints == null || hints.isEmpty) return items;

      // Only filter if the hint list is non-empty AND filtering
      // wouldn't wipe the page — otherwise a thin catalog for that
      // language would return nothing at all rather than best-effort
      // results.
      final filtered = items
          .where((i) => hints.any((h) =>
              i.title.toLowerCase().contains(h) ||
              i.artist.toLowerCase().contains(h)))
          .toList();
      return filtered.isNotEmpty ? filtered : items;
    } on TimeoutException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  static final RegExp _artworkSizePattern =
      RegExp(r'\d+x\d+(bb)?\.(jpg|png)');

  static ShortItem _toShortItem(Map<String, dynamic> r, String category) {
    final trackId = (r['trackId'] ?? '').toString();
    final title = (r['trackName'] ?? '').toString().trim();
    final artist = (r['artistName'] ?? '').toString().trim();
    final previewUrl = (r['previewUrl'] ?? '').toString();
    final art100 = (r['artworkUrl100'] ?? '').toString();
    // Upsize iTunes artwork — the 100x100 URL supports arbitrary
    // resolution substitution (e.g. .../100x100bb.jpg -> 600x600bb.jpg).
    final artwork = art100.replaceAll(_artworkSizePattern, '600x600bb.jpg');

    return ShortItem(
      trackId: trackId,
      title: title,
      artist: artist,
      artworkUrl: artwork.isNotEmpty ? artwork : art100,
      previewUrl: previewUrl,
      category: category,
    );
  }

  /// Resets the pagination offset for a given category/language —
  /// used on explicit pull-to-refresh.
  static void resetCursor(String category, String? language) {
    _offsets.remove(_cursorKey(category, language));
  }

  static void resetAllCursors() {
    _offsets.clear();
  }
}
