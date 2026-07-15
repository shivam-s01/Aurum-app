/// Independent data model for the Shorts feed — v3, iTunes-native.
///
/// A ShortItem now represents an iTunes Search API track result. The
/// `previewUrl` IS the playable 30-second AAC clip — no search/match/
/// resolve step needed anywhere downstream, unlike the old YouTube
/// pipeline (title+artist -> search -> best-match -> resolve stream
/// URL). This is what makes playback reliable: the URL that goes
/// straight into ExoPlayer is the exact URL iTunes gave us, nothing
/// in between can fail.
class ShortItem {
  final String trackId; // iTunes trackId — primary identity
  final String title;
  final String artist;
  final String artworkUrl; // iTunes artwork, upsized from artworkUrl100
  final String previewUrl; // iTunes 30-second AAC preview — directly playable
  final int durationSecs; // always 30 — kept for UI/progress-bar compatibility
  final String category; // the ShortsCatalog category this came from

  const ShortItem({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.artworkUrl,
    required this.previewUrl,
    required this.category,
    this.durationSecs = 30,
  });

  /// Unique key used for de-duplication across pages/sessions.
  String get dedupeKey => trackId;

  bool get isPlayable => trackId.isNotEmpty && previewUrl.isNotEmpty;

  Map<String, dynamic> toCacheJson() => {
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'artworkUrl': artworkUrl,
        'previewUrl': previewUrl,
        'durationSecs': durationSecs,
        'category': category,
      };

  factory ShortItem.fromCacheJson(Map<String, dynamic> json) => ShortItem(
        trackId: json['trackId'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        artworkUrl: json['artworkUrl'] as String,
        previewUrl: json['previewUrl'] as String,
        durationSecs: (json['durationSecs'] ?? 30) as int,
        category: (json['category'] ?? '') as String,
      );
}
