import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/short_item.dart';

/// Thin, isolated client for the official iTunes Search API.
/// No auth, no scraping — only documented public endpoints.
/// https://itunes.apple.com/search
class ItunesShortsApi {
  ItunesShortsApi._();

  static const _base = 'https://itunes.apple.com/search';
  static const _timeout = Duration(seconds: 8);

  /// Fetches a page of song previews matching [term] in the given
  /// [country] storefront. [offset] is emulated client-side since
  /// iTunes search doesn't support true pagination — we over-fetch
  /// with [limit] and the caller advances through results using a
  /// widened/varied term on repeat calls (see ShortsFeedController).
  static Future<List<ShortItem>> search({
    required String term,
    required String country,
    int limit = 50,
  }) async {
    final uri = Uri.parse(_base).replace(queryParameters: {
      'term': term,
      'country': country,
      'media': 'music',
      'entity': 'song',
      'limit': '$limit',
    });

    try {
      final res = await http.get(uri).timeout(_timeout);
      if (res.statusCode != 200) return const [];

      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final results = (decoded['results'] as List?) ?? const [];

      return results
          .cast<Map<String, dynamic>>()
          .map(ShortItem.fromItunesJson)
          .where((s) => s.isPlayable)
          .toList();
    } on TimeoutException {
      return const [];
    } catch (_) {
      // Network hiccup / malformed response — fail soft, caller
      // handles empty result by trying next term or retrying later.
      return const [];
    }
  }

  /// Convenience: fan out several search terms in parallel and merge.
  /// Used by the recommendation engine to mix category + language +
  /// discovery terms in a single feed-refill pass.
  static Future<List<ShortItem>> searchMany({
    required List<String> terms,
    required String country,
    int limitPerTerm = 25,
  }) async {
    final futures = terms.map(
      (t) => search(term: t, country: country, limit: limitPerTerm),
    );
    final results = await Future.wait(futures);
    return results.expand((list) => list).toList();
  }
}
