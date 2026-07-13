import 'dart:math';
import '../models/short_item.dart';
import '../models/shorts_catalog.dart';
import '../services/itunes_shorts_api.dart';
import '../services/shorts_prefs.dart';

/// Builds ranked batches of ShortItems from selected languages +
/// categories, mixing familiar picks with discovery, avoiding
/// duplicate previews and back-to-back same-artist runs.
///
/// Completely independent from the main Aurum recommendation_engine —
/// no shared state, no shared queue/history.
class ShortsRecommendationEngine {
  final _rng = Random();

  /// Fetches a fresh batch. [excludeKeys] is the running de-dupe set
  /// (dedupeKey) already shown this session — engine will keep
  /// fetching wider terms until it has enough new items or gives up.
  Future<List<ShortItem>> fetchBatch({
    required List<String> languages,
    required List<String> categories,
    required Set<String> excludeKeys,
    int targetCount = 15,
  }) async {
    if (languages.isEmpty || categories.isEmpty) return const [];

    final liked = await ShortsPrefs.getLiked();
    final skipped = await ShortsPrefs.getSkipped();
    final artistFreq = await ShortsPrefs.getArtistFreq();

    // Build a term list: language x random category subset, plus a
    // "discovery" language/category pair not necessarily top-ranked.
    final terms = <String>[];
    final country =
        ShortsCatalog.languageToCountry[languages.first] ?? 'US';

    final shuffledCats = List<String>.from(categories)..shuffle(_rng);
    for (final cat in shuffledCats.take(4)) {
      final hint = ShortsCatalog.categories[cat] ?? cat.toLowerCase();
      terms.add(hint);
    }
    // Discovery term: a category the user didn't pick, low weight.
    final unpicked = ShortsCatalog.categories.keys
        .where((c) => !categories.contains(c))
        .toList()
      ..shuffle(_rng);
    if (unpicked.isNotEmpty) {
      terms.add(ShortsCatalog.categories[unpicked.first]!);
    }

    final rawResults = <ShortItem>[];
    for (final lang in languages.take(3)) {
      final langCountry = ShortsCatalog.languageToCountry[lang] ?? country;
      final items = await ItunesShortsApi.searchMany(
        terms: terms,
        country: langCountry,
        limitPerTerm: 20,
      );
      rawResults.addAll(items.map((i) => i.copyWithLanguage(lang)));
    }

    // De-duplicate by dedupeKey, drop already-shown/skipped.
    final seen = <String>{};
    final deduped = <ShortItem>[];
    for (final item in rawResults) {
      if (excludeKeys.contains(item.dedupeKey)) continue;
      if (skipped.contains(item.id)) continue;
      if (seen.contains(item.dedupeKey)) continue;
      seen.add(item.dedupeKey);
      deduped.add(item);
    }

    // Score: liked-artist affinity boost, mild randomization for
    // discovery, then interleave to avoid same-artist runs.
    deduped.sort((a, b) {
      final scoreA = (artistFreq[a.artist] ?? 0) +
          (liked.contains(a.id) ? 5 : 0) +
          _rng.nextDouble();
      final scoreB = (artistFreq[b.artist] ?? 0) +
          (liked.contains(b.id) ? 5 : 0) +
          _rng.nextDouble();
      return scoreB.compareTo(scoreA);
    });

    final interleaved = _avoidConsecutiveArtists(deduped);
    return interleaved.take(targetCount).toList();
  }

  /// Greedy re-ordering: never place two consecutive items from the
  /// same artist if an alternative exists further down the list.
  List<ShortItem> _avoidConsecutiveArtists(List<ShortItem> items) {
    if (items.length <= 2) return items;
    final pool = List<ShortItem>.from(items);
    final result = <ShortItem>[];

    while (pool.isNotEmpty) {
      final lastArtist = result.isNotEmpty ? result.last.artist : null;
      int pickIndex = pool.indexWhere((i) => i.artist != lastArtist);
      if (pickIndex == -1) pickIndex = 0; // no alternative, forced repeat
      result.add(pool.removeAt(pickIndex));
    }
    return result;
  }
}
