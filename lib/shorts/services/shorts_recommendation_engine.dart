import '../models/short_item.dart';
import '../models/shorts_catalog.dart';
import '../services/itunes_shorts_api.dart';
import '../services/shorts_prefs.dart';

/// Builds ranked batches of ShortItems from selected languages +
/// categories, mixing familiar picks with discovery, avoiding
/// duplicate previews and back-to-back same-artist runs.
///
/// Fully deterministic — no Random() anywhere. Term rotation uses a
/// running counter (not shuffle), and item ranking is pure weighted
/// scoring from real signals (likes, replays, artist affinity, skip
/// history). Same inputs always produce the same ordering.
///
/// Completely independent from the main Aurum recommendation_engine —
/// no shared state, no shared queue/history.
class ShortsRecommendationEngine {
  // Query hints that bias iTunes' relevance ranking toward older vs
  // newer catalog entries. Appended alongside the language name so
  // e.g. "bhojpuri" alone (which skews toward whatever's currently
  // popular) becomes "bhojpuri classic hits" / "bhojpuri new 2026".
  static const List<String> _eraHints = [
    'new',
    'latest',
    'classic',
    'old is gold',
    'evergreen',
    'top hits',
  ];

  // Advances deterministically each time fetchBatch() runs, so
  // successive batches rotate through different category/era
  // combinations instead of always hitting the same 3 first-in-list
  // terms — without using any randomness. Rotation, not chance.
  int _batchCounter = 0;

  /// Fast path for the very first paint: fetch just enough from the
  /// primary language to get something on screen instantly, instead
  /// of waiting on the full multi-language, multi-era batch. The
  /// full fetchBatch() still runs right after for the real feed.
  Future<List<ShortItem>> fetchFirstPaint({
    required List<String> languages,
    required List<String> categories,
  }) async {
    if (languages.isEmpty || categories.isEmpty) return const [];
    final lang = languages.first;
    final country = ShortsCatalog.languageToCountry[lang] ?? 'IN';
    final cat = categories.first;
    final hint = ShortsCatalog.categories[cat] ?? cat.toLowerCase();

    final items = await ItunesShortsApi.search(
      term: '$lang $hint',
      country: country,
      limit: 8,
    );
    return items.map((i) => i.copyWithLanguage(lang)).toList();
  }

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
    final replayCounts = await ShortsPrefs.getReplayCounts();

    final myBatch = _batchCounter++;

    // ── Deterministic term rotation ─────────────────────────────
    // Instead of shuffling categories/eras, rotate through them
    // using the batch counter as an offset. Every call picks a
    // different, predictable slice — batch 0 uses categories
    // [0,1,2], batch 1 uses [1,2,3], etc. — so repeated fetches
    // don't loop the same 3 terms forever, and there's zero chance
    // involved anywhere in term selection.
    final catList = categories.toList();
    final pickedCats = List<String>.generate(
      catList.length < 3 ? catList.length : 3,
      (i) => catList[(myBatch + i) % catList.length],
    );
    final pickedEras = List<String>.generate(
      3,
      (i) => _eraHints[(myBatch + i) % _eraHints.length],
    );

    final perLanguageFutures = languages.take(3).map((lang) async {
      final country = ShortsCatalog.languageToCountry[lang] ?? 'IN';
      final terms = <String>[
        for (final cat in pickedCats)
          '$lang ${ShortsCatalog.categories[cat] ?? cat.toLowerCase()}',
        for (final era in pickedEras) '$lang $era songs',
      ];

      final items = await ItunesShortsApi.searchMany(
        terms: terms,
        country: country,
        limitPerTerm: 20,
      );
      return items.map((i) => i.copyWithLanguage(lang)).toList();
    }).toList();

    final perLanguageResults = await Future.wait(perLanguageFutures);

    // ── De-duplicate ─────────────────────────────────────────────
    final seen = <String>{};
    final perLanguageDeduped = <List<ShortItem>>[];
    for (final list in perLanguageResults) {
      final deduped = <ShortItem>[];
      for (final item in list) {
        if (excludeKeys.contains(item.dedupeKey)) continue;
        if (skipped.contains(item.id)) continue;
        if (seen.contains(item.dedupeKey)) continue;
        seen.add(item.dedupeKey);
        deduped.add(item);
      }

      // ── Pure weighted scoring — no randomness ──────────────────
      // liked song      → +50  (strongest signal: explicit intent)
      // replay count    → +8 per replay, capped at +40 (repeat listens)
      // artist affinity → +2 per past play of this artist, capped +20
      // iTunes' own relevance order is preserved as a final tiebreak
      // via stable sort (original index used as the last-resort key),
      // so results never feel arbitrarily reordered when scores tie.
      final originalIndex = <String, int>{
        for (var i = 0; i < deduped.length; i++) deduped[i].id: i,
      };
      deduped.sort((a, b) {
        final scoreA = _score(a, liked, artistFreq, replayCounts);
        final scoreB = _score(b, liked, artistFreq, replayCounts);
        if (scoreA != scoreB) return scoreB.compareTo(scoreA);
        // Tiebreak: preserve iTunes' original relevance order.
        return (originalIndex[a.id] ?? 0).compareTo(originalIndex[b.id] ?? 0);
      });
      perLanguageDeduped.add(deduped);
    }

    // ── Round-robin merge across languages ──────────────────────
    // Prevents one language (usually whichever returns the most
    // results) from dominating the feed — cycles through each
    // selected language in turn so a 3-language pick actually shows
    // all 3, evenly, rather than 40 Hindi songs before a single
    // Bhojpuri one. Deterministic list order, no shuffling.
    final merged = <ShortItem>[];
    var anyLeft = true;
    var cursor = 0;
    while (anyLeft && merged.length < targetCount * 2) {
      anyLeft = false;
      for (final list in perLanguageDeduped) {
        if (cursor < list.length) {
          merged.add(list[cursor]);
          anyLeft = true;
        }
      }
      cursor++;
    }

    final interleaved = _avoidConsecutiveArtists(merged);
    return interleaved.take(targetCount).toList();
  }

  int _score(
    ShortItem item,
    Set<String> liked,
    Map<String, int> artistFreq,
    Map<String, int> replayCounts,
  ) {
    var score = 0;
    if (liked.contains(item.id)) score += 50;
    final replays = replayCounts[item.id] ?? 0;
    score += (replays * 8).clamp(0, 40);
    final plays = artistFreq[item.artist] ?? 0;
    score += (plays * 2).clamp(0, 20);
    return score;
  }

  /// Greedy re-ordering: never place two consecutive items from the
  /// same artist if an alternative exists further down the list.
  /// Deterministic — always picks the first valid alternative, not a
  /// random one.
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
