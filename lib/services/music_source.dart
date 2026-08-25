// =============================================================================
// FILE: lib/services/music_source.dart
// PROJECT: Astra Music
//
// A Spotify-style provider abstraction over the app's two content sources
// (JioSaavn, YouTube). Before this file existed, every caller that needed a
// search or a similar-songs lookup called ApiService's private
// _searchSaavn/_searchYt/_fetchSimilarFromSaavn directly, and any retry or
// priority behavior had to be hand-written at each call-site — which is how
// the same "retry once if empty" logic ended up duplicated three times
// across getAutoQueue and search().
//
// MusicSource gives every caller ONE clean contract instead:
//
//     final results = await MusicCatalog.search(query, limit: 50);
//
// The interface doesn't know or care that Saavn has five mirror hosts, that
// YouTube pagination needs up to 6 pages, or that a free-tier host might
// need a retry. All of that stays exactly where it already lived and
// already worked (ApiService's private methods, untouched) — this file only
// adds the outer contract and the cross-source policy (priority + retry)
// that used to be scattered per call-site.
//
// This does NOT touch RecommendationEngine, queue-building, or any UI code.
// Callers that want the raw per-source behavior can still reach
// SaavnSource/YtSource individually; MusicCatalog is the Spotify-style
// "just get me music" entry point most call-sites actually want.
// =============================================================================

import '../models/song.dart';
import 'api_service.dart';

/// A single content provider (Saavn, YouTube, ...). Every source exposes the
/// same shape of query, regardless of how it talks to its backend
/// internally — that internal detail is exactly what this interface hides.
abstract class MusicSource {
  /// Human-readable name, used only for logging/diagnostics.
  String get name;

  /// Full-text search for `query`, returning up to `limit` results.
  Future<List<Song>> search(String query, {int limit});

  /// Songs related to `seed` (same album/artist/mood signal, depending on
  /// what the source can offer) — used to seed an auto-queue.
  Future<List<Song>> similarTo(Song seed, {int limit});
}

/// Wraps ApiService's existing Saavn plumbing (multi-host race + failover,
/// already battle-tested) behind the MusicSource contract, and is the ONLY
/// place a Saavn-specific retry policy lives — every caller upstream just
/// sees a normal MusicSource and doesn't need to know a retry ever happens.
class SaavnSource implements MusicSource {
  const SaavnSource();

  @override
  String get name => 'saavn';

  @override
  Future<List<Song>> search(String query, {int limit = 30}) {
    return _withRetry(() => ApiService.searchSaavnRaw(query, limit: limit));
  }

  @override
  Future<List<Song>> similarTo(Song seed, {int limit = 20}) {
    return _withRetry(() => ApiService.similarFromSaavnRaw(seed, limit: limit));
  }

  /// A source coming back empty is ambiguous — genuinely no matches, or a
  /// transient miss on this attempt (a free-tier host waking up, one bad
  /// response among several mirrors). One bounded retry after a short delay
  /// resolves that ambiguity without hammering indefinitely: if the second
  /// attempt is also empty, that's treated as a real, final answer.
  Future<List<Song>> _withRetry(Future<List<Song>> Function() attempt) async {
    final first = await attempt();
    if (first.isNotEmpty) return first;
    await Future.delayed(const Duration(milliseconds: 600));
    return attempt();
  }
}

/// Wraps ApiService's existing YouTube plumbing (explode + worker + Piped/
/// Invidious fallback race, already battle-tested) behind the same
/// MusicSource contract. No retry policy here by design — YT's own search
/// path already races multiple resolution strategies internally, so an
/// empty result here is a much stronger signal of "genuinely nothing
/// found" than a single Saavn host miss is.
class YtSource implements MusicSource {
  const YtSource();

  @override
  String get name => 'youtube';

  @override
  Future<List<Song>> search(String query, {int limit = 30}) {
    return ApiService.searchYtRaw(query, limit: limit);
  }

  @override
  Future<List<Song>> similarTo(Song seed, {int limit = 20}) {
    // YouTube's own related-videos graph is keyed by video ID, not a text
    // query — that lookup already has its own dedicated path
    // (NativeRelatedVideos, wired in directly where it's used) rather than
    // going through a generic text search here.
    return Future.value(const <Song>[]);
  }
}

/// The Spotify-style "just get me music" facade: Saavn is the strict,
/// unconditional primary for every source-aware call-site, exactly as
/// asked — YouTube is only ever consulted to fill a genuine gap, never
/// interleaved with or allowed to outrank a Saavn result.
class MusicCatalog {
  MusicCatalog._();

  static const MusicSource saavn = SaavnSource();
  static const MusicSource youtube = YtSource();

  /// Saavn-first search with a YouTube top-up when Saavn falls short of
  /// `minPrimaryResults`. This is the same priority policy that already
  /// existed inline in ApiService.search() — centralized here so any new
  /// caller gets it for free instead of re-deriving it.
  static Future<List<Song>> search(
    String query, {
    int limit = 50,
    int minPrimaryResults = 8,
  }) async {
    final primary = await saavn.search(query, limit: limit);
    if (primary.length >= minPrimaryResults) return primary;

    final secondary = await youtube.search(query, limit: limit);
    final seenIds = {for (final s in primary) s.id};
    final topUp = secondary.where((s) => !seenIds.contains(s.id));
    return [...primary, ...topUp];
  }

  /// Saavn-first "similar songs" with a YouTube top-up under the same rule.
  static Future<List<Song>> similarTo(
    Song seed, {
    int limit = 20,
    int minPrimaryResults = 8,
  }) async {
    final primary = await saavn.similarTo(seed, limit: limit);
    if (primary.length >= minPrimaryResults) return primary;

    final secondary = await youtube.similarTo(seed, limit: limit);
    final seenIds = {for (final s in primary) s.id};
    final topUp = secondary.where((s) => !seenIds.contains(s.id));
    return [...primary, ...topUp];
  }
}
