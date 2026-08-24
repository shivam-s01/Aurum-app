// ============================================================================
// FILE: lib/services/lightweight_stream_cache.dart
// VERSION: 1.0 - Lightweight circular cache for YouTube URLs
// PURPOSE: Fix heating, lag, and memory bloat
// OPTIMIZATION: Max 30 URLs, auto-cleanup, ~3KB vs 500KB
// ============================================================================

import 'dart:collection';

class StreamCacheEntry {
  final String url;
  final DateTime createdAt;
  static const Duration defaultTtl = Duration(hours: 2);

  StreamCacheEntry(this.url) : createdAt = DateTime.now();

  bool get isExpired => DateTime.now().difference(createdAt) > defaultTtl;
}

/// Lightweight circular cache for YouTube stream URLs
/// Keeps maximum 30 URLs, automatically removes oldest when full
/// Result: ~3KB memory vs 500KB+ unbounded cache
class LightweightStreamCache {
  static const int maxSize = 30; // Small = lightweight
  
  final _cache = LinkedHashMap<String, StreamCacheEntry>();

  /// Get URL if exists and not expired
  String? get(String cacheKey) {
    final entry = _cache[cacheKey];
    
    if (entry == null) return null;
    
    // Remove if expired
    if (entry.isExpired) {
      _cache.remove(cacheKey);
      return null;
    }
    
    // Move to end (most recently used = LRU)
    _cache.remove(cacheKey);
    _cache[cacheKey] = entry;
    
    return entry.url;
  }

  /// Set URL + auto-cleanup if over limit
  void set(String cacheKey, String url) {
    // If exists, remove old entry to refresh timestamp
    if (_cache.containsKey(cacheKey)) {
      _cache.remove(cacheKey);
    }

    // If cache full, remove oldest (first entry in LinkedHashMap = LRU)
    while (_cache.length >= maxSize) {
      final oldestKey = _cache.keys.first;
      _cache.remove(oldestKey);
    }

    // Add new entry
    _cache[cacheKey] = StreamCacheEntry(url);
  }

  /// Invalidate specific URL
  void invalidate(String cacheKey) {
    _cache.remove(cacheKey);
  }

  /// Clear all cache
  void clear() {
    _cache.clear();
  }

  /// Get current size for debugging
  int get size => _cache.length;

  /// Number of entries currently cached (alias used by callers/diagnostics)
  int get length => _cache.length;

  /// Remove entries matching a predicate (key, entry)
  void removeWhere(bool Function(String key, StreamCacheEntry entry) test) {
    _cache.removeWhere(test);
  }

  /// Get cache stats
  Map<String, dynamic> getStats() {
    int expiredCount = 0;
    for (final entry in _cache.values) {
      if (entry.isExpired) expiredCount++;
    }
    return {
      'totalEntries': _cache.length,
      'expiredEntries': expiredCount,
      'maxSize': maxSize,
      'memoryEstimate': '~${_cache.length * 150} bytes',
    };
  }

  /// Auto-cleanup expired entries (call periodically)
  void cleanup() {
    _cache.removeWhere((_, entry) => entry.isExpired);
  }
}
