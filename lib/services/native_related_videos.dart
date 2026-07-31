import 'package:flutter/services.dart';

/// A single YouTube "related video" entry — YouTube's own recommendation
/// graph for a given video ID, as surfaced by NewPipeExtractor's
/// StreamExtractor.relatedItems on the native side (see
/// YoutubeInnertube.kt's getRelated()).
class YtRelatedVideo {
  final String videoId;
  final String title;
  final String uploaderName;
  final int durationSecs;
  final int? viewCount;

  const YtRelatedVideo({
    required this.videoId,
    required this.title,
    required this.uploaderName,
    required this.durationSecs,
    this.viewCount,
  });
}

/// Bridge for YouTube's own related-videos graph — kept in its own file
/// (own MethodChannel, no shared state, no import of api_service.dart or
/// native_engine_bridge.dart) since this is a pure network lookup used as
/// one more signal source for getAutoQueue, completely independent of
/// whatever is currently playing or queued.
class NativeRelatedVideos {
  static const MethodChannel _channel = MethodChannel('com.aurum.music/related_videos');

  /// Returns YouTube's related videos for [videoId], or an empty list on
  /// any failure (network, extraction, page-format change, etc.) — this
  /// never throws, matching every other best-effort signal in
  /// getAutoQueue's signal chain, so a failure here just means this
  /// particular signal contributed nothing, not a broken queue build.
  static Future<List<YtRelatedVideo>> getRelated(String videoId) async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>(
        'getRelated',
        {'videoId': videoId},
      ).timeout(const Duration(seconds: 8), onTimeout: () => <Object?>[]);
      if (result == null) return [];
      return result
          .whereType<Map<Object?, Object?>>()
          .map((m) {
            final rawViews = (m['viewCount'] as num?)?.toInt();
            return YtRelatedVideo(
              videoId: m['videoId'] as String? ?? '',
              title: m['title'] as String? ?? '',
              uploaderName: m['uploaderName'] as String? ?? '',
              durationSecs: (m['durationSecs'] as num?)?.toInt() ?? 0,
              // Kotlin side sends -1 for "NewPipeExtractor couldn't parse
              // a view count for this item" — convert to null here so it
              // matches Song.viewCount's existing null-means-unavailable
              // convention used by RecommendationEngine.isPremiumQuality.
              viewCount: (rawViews != null && rawViews >= 0) ? rawViews : null,
            );
          })
          .where((v) => v.videoId.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
