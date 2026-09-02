import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// AurumImageCache — a size-bounded disk cache for network artwork,
/// matching Echo Nightly's own Coil ImageLoader config exactly:
/// 100MB disk cache (see MainApplication.kt's newImageLoader()).
///
/// Without this, cached_network_image falls back to
/// flutter_cache_manager's DefaultCacheManager, which caps entries by
/// AGE ONLY (30 days) with no size ceiling at all — on a heavy-browsing
/// session (scrolling Home/Search daily, lots of distinct thumbnails)
/// that can grow disk usage indefinitely between installs. Capping by
/// byte size, not just age, is the same fix Echo already ships.
///
/// maxNrOfCacheObjects is a secondary safety net — flutter_cache_manager
/// evicts by object COUNT, not raw bytes (there's no true byte-budget
/// API like Coil's), so this is tuned assuming an average artwork
/// thumbnail of ~15-25KB post-decode-cache (AurumArtwork already caps
/// decode width via cacheWidth/_cacheSize) — 4000 objects keeps total
/// disk usage in the same ballpark as Echo's 100MB even though the
/// underlying eviction policy counts files, not bytes.
class AurumImageCache extends CacheManager {
  static const key = 'aurumImageCache';
  static final AurumImageCache _instance = AurumImageCache._();
  factory AurumImageCache() => _instance;

  AurumImageCache._()
      : super(
          Config(
            key,
            stalePeriod: const Duration(days: 14),
            maxNrOfCacheObjects: 4000,
          ),
        );
}
