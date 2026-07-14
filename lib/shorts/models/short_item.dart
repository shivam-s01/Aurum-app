/// Independent data model for the Shorts feed — v2, YouTube-native.
///
/// Deliberately NOT reusing the existing `Song` model, and deliberately
/// NOT the old iTunes-preview shape either. A ShortItem now represents
/// a single YouTube video: one muxed stream is the ONLY source for
/// both audio and video on a card — no more dual-source (iTunes audio
/// + muted YT video) split. This keeps the Shorts feed a fully
/// self-contained module with its own identity, never leaking into
/// the main Aurum queue/player state.
class ShortItem {
  final String videoId; // YouTube video id — primary identity
  final String title;
  final String artist; // YouTube channel/author name
  final String artworkUrl; // YouTube thumbnail (high-res)
  final int durationSecs; // real full video duration, from YouTube
  final String category; // the ShortsCatalog category this came from

  const ShortItem({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.artworkUrl,
    required this.durationSecs,
    required this.category,
  });

  /// Unique key used for de-duplication across pages/sessions.
  /// videoId is already globally unique, so this is a direct pass
  /// through — kept as a named getter so callers (feed controller,
  /// recommendation/search layers) don't care about the underlying
  /// identity field name if it ever changes again.
  String get dedupeKey => videoId;

  bool get isPlayable => videoId.isNotEmpty;

  Map<String, dynamic> toCacheJson() => {
        'videoId': videoId,
        'title': title,
        'artist': artist,
        'artworkUrl': artworkUrl,
        'durationSecs': durationSecs,
        'category': category,
      };

  factory ShortItem.fromCacheJson(Map<String, dynamic> json) => ShortItem(
        videoId: json['videoId'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        artworkUrl: json['artworkUrl'] as String,
        durationSecs: (json['durationSecs'] ?? 0) as int,
        category: (json['category'] ?? '') as String,
      );
}
