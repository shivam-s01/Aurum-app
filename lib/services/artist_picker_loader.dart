// =============================================================================
// FILE: lib/services/artist_picker_loader.dart
// DESCRIPTION: Onboarding + Settings dono ke artist picker ka SHARED logic.
//   Pehle har jagah sirf free-text genre search tha (kabhi random/chhote
//   artists, top artists ki guarantee nahi, aur naam se search hi nahi tha).
//   Ab:
//     1. Curated TOP artists (country ke) pehle — real photo + id ke saath
//     2. Uske baad genre-wise search results (round-robin), dedup
//     3. Naam se live search (top result exact/prefix match pehle)
//   Sab timeouts ke saath — weak network pe bhi picker kabhi atakta nahi.
// =============================================================================

import 'api_service.dart';
import 'user_region.dart';

class ArtistPickerLoader {
  ArtistPickerLoader._();

  static String _key(String n) => n.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Curated top artists (resolved) + genre results merged, max [cap].
  /// [genreBuckets]: har genre query ke results (already fetched by caller).
  static Future<List<ArtistSimple>> buildInitialList({
    required List<List<ArtistSimple>> genreBuckets,
    required bool includeSaavn,
    int cap = 60,
    int curatedCount = 18,
  }) async {
    List<ArtistSimple> curated = const [];
    try {
      curated = await ApiService.resolveCuratedArtists(
        UserRegion.topArtistsForPicker(),
        max: curatedCount,
        includeSaavn: includeSaavn,
      ).timeout(const Duration(seconds: 6), onTimeout: () => <ArtistSimple>[]);
    } catch (_) {}

    final merged = <ArtistSimple>[];
    final seen = <String>{};

    void add(ArtistSimple a) {
      if (a.name.isEmpty) return;
      if (seen.add(_key(a.name))) merged.add(a);
    }

    // 1) curated top artists pehle (country ke sabse bade naam)
    for (final a in curated) {
      add(a);
    }

    // 2) genre buckets round-robin
    var col = 0;
    var added = true;
    while (added && merged.length < cap) {
      added = false;
      for (final b in genreBuckets) {
        if (col < b.length) {
          add(b[col]);
          added = true;
        }
      }
      col++;
    }
    return merged.take(cap).toList();
  }

  /// Live naam-search (debounce caller karta hai).
  static Future<List<ArtistSimple>> search(String query) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    try {
      await UserRegion.load();
      return await ApiService.searchArtistsByName(
        q,
        limit: 15,
        includeSaavn: UserRegion.code == 'IN',
      );
    } catch (_) {
      return const [];
    }
  }
}
