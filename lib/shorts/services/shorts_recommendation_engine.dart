import '../models/short_item.dart';
import '../services/shorts_prefs.dart';
import '../services/itunes_shorts_api.dart';

/// Builds ranked batches of ShortItems for the Shorts feed —
/// single-category-strict, iTunes-sourced.
///
/// Always operates on exactly ONE active category (+ optional
/// language) at a time. There is no blending across categories — a
/// feed opened under "Sad" only ever surfaces "Sad" results, matching
/// the premium single-category-feed requirement. Switching category is
/// a full feed replacement (see ShortsFeedController), not a blend.
///
/// Discovery itself (search + pagination) is fully delegated to
/// ItunesShortsApi, which owns a forward-advancing offset per
/// category — this is what guarantees unlimited, non-repeating
/// scroll: every call for the same category returns results further
/// into the iTunes result set, never page 1 again.
///
/// This engine's own job is just re-ranking what comes back using
/// real local signals (likes, replays, artist affinity) — no
/// randomness, pure deterministic weighted scoring.
class ShortsRecommendationEngine {
  /// Fetches the very first small batch for instant first paint.
  Future<List<ShortItem>> fetchFirstPaint({
    required String category,
    String? language,
  }) async {
    if (category.isEmpty) return const [];
    final items = await ItunesShortsApi.fetchNextPage(
      category: category,
      language: language,
      limit: 8,
    );
    return _rank(await _applyLocalSignals(items));
  }

  /// Fetches the next page for the active category — always further
  /// into the result set than the previous call, never repeating.
  Future<List<ShortItem>> fetchBatch({
    required String category,
    String? language,
    Set<String> excludeKeys = const {},
    int targetCount = 15,
  }) async {
    if (category.isEmpty) return const [];

    // Pull a couple of pages if the first one is thin after filtering
    // out anything already shown (defensive — ItunesShortsApi's
    // cursor already avoids repeats, but a video could still get
    // excluded for other reasons, e.g. previously skipped).
    final collected = <ShortItem>[];
    var attempts = 0;
    while (collected.length < targetCount && attempts < 3) {
      final page = await ItunesShortsApi.fetchNextPage(
        category: category,
        language: language,
        limit: targetCount,
      );
      if (page.isEmpty) break;
      for (final item in page) {
        if (excludeKeys.contains(item.dedupeKey)) continue;
        collected.add(item);
      }
      attempts++;
    }

    final ranked = _rank(await _applyLocalSignals(collected));
    return ranked.take(targetCount).toList();
  }

  Future<List<_ScoredItem>> _applyLocalSignals(List<ShortItem> items) async {
    final liked = await ShortsPrefs.getLiked();
    final skipped = await ShortsPrefs.getSkipped();
    final artistFreq = await ShortsPrefs.getArtistFreq();
    final replayCounts = await ShortsPrefs.getReplayCounts();

    return items
        .where((i) => !skipped.contains(i.trackId))
        .map((i) => _ScoredItem(
              i,
              _score(i, liked, artistFreq, replayCounts),
            ))
        .toList();
  }

  List<ShortItem> _rank(List<_ScoredItem> scored) {
    final indexed = <String, int>{
      for (var i = 0; i < scored.length; i++) scored[i].item.trackId: i,
    };
    final sorted = List<_ScoredItem>.from(scored)
      ..sort((a, b) {
        if (a.score != b.score) return b.score.compareTo(a.score);
        return (indexed[a.item.trackId] ?? 0)
            .compareTo(indexed[b.item.trackId] ?? 0);
      });
    return _avoidConsecutiveArtists(sorted.map((s) => s.item).toList());
  }

  int _score(
    ShortItem item,
    Set<String> liked,
    Map<String, int> artistFreq,
    Map<String, int> replayCounts,
  ) {
    var score = 0;
    if (liked.contains(item.trackId)) score += 50;
    final replays = replayCounts[item.trackId] ?? 0;
    score += (replays * 8).clamp(0, 40);
    final plays = artistFreq[item.artist] ?? 0;
    score += (plays * 2).clamp(0, 20);
    return score;
  }

  /// Greedy re-ordering: never place two consecutive items from the
  /// same artist/channel if an alternative exists further down.
  /// Deterministic — always picks the first valid alternative.
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

class _ScoredItem {
  final ShortItem item;
  final int score;
  const _ScoredItem(this.item, this.score);
}
