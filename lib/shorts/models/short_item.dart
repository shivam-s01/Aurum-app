/// Independent data model for the Shorts feed.
/// Deliberately NOT reusing the existing `Song` model — Shorts sources
/// only 30s iTunes previews and must never leak into the main
/// Aurum queue/player state.
class ShortItem {
  final String id; // iTunes trackId as string
  final String title;
  final String artist;
  final String album;
  final String artworkUrl; // upgraded to high-res (see fromItunesJson)
  final String previewUrl; // 30s m4a preview
  final int durationMs; // preview length, NOT full song length
  final String? language; // inferred/tagged locally, iTunes has no field
  final String? primaryGenre;
  final String? releaseDate; // ISO date string from iTunes
  final String country;

  const ShortItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.artworkUrl,
    required this.previewUrl,
    required this.durationMs,
    required this.country,
    this.language,
    this.primaryGenre,
    this.releaseDate,
  });

  /// Unique key used for de-duplication across pages/sessions.
  /// artist+title catches iTunes returning the same song under
  /// different storefronts/track IDs.
  String get dedupeKey =>
      '${artist.trim().toLowerCase()}::${title.trim().toLowerCase()}';

  factory ShortItem.fromItunesJson(Map<String, dynamic> json) {
    // iTunes gives artworkUrl100 — swap to a much higher res for
    // full-bleed vertical display (Reels-style).
    String artwork = (json['artworkUrl100'] ?? '') as String;
    if (artwork.isNotEmpty) {
      artwork = artwork.replaceAll('100x100bb', '600x600bb');
    }

    return ShortItem(
      id: (json['trackId'] ?? json['collectionId'] ?? '').toString(),
      title: (json['trackName'] ?? 'Unknown') as String,
      artist: (json['artistName'] ?? 'Unknown Artist') as String,
      album: (json['collectionName'] ?? '') as String,
      artworkUrl: artwork,
      previewUrl: (json['previewUrl'] ?? '') as String,
      durationMs: (json['trackTimeMillis'] ?? 30000) as int,
      country: (json['country'] ?? '') as String,
      primaryGenre: json['primaryGenreName'] as String?,
      releaseDate: json['releaseDate'] as String?,
    );
  }

  bool get isPlayable => previewUrl.isNotEmpty && id.isNotEmpty;

  Map<String, dynamic> toCacheJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'artworkUrl': artworkUrl,
        'previewUrl': previewUrl,
        'durationMs': durationMs,
        'language': language,
        'primaryGenre': primaryGenre,
        'releaseDate': releaseDate,
        'country': country,
      };

  factory ShortItem.fromCacheJson(Map<String, dynamic> json) => ShortItem(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String,
        artworkUrl: json['artworkUrl'] as String,
        previewUrl: json['previewUrl'] as String,
        durationMs: json['durationMs'] as int,
        language: json['language'] as String?,
        primaryGenre: json['primaryGenre'] as String?,
        releaseDate: json['releaseDate'] as String?,
        country: json['country'] as String,
      );

  ShortItem copyWithLanguage(String? lang) => ShortItem(
        id: id,
        title: title,
        artist: artist,
        album: album,
        artworkUrl: artworkUrl,
        previewUrl: previewUrl,
        durationMs: durationMs,
        country: country,
        language: lang,
        primaryGenre: primaryGenre,
        releaseDate: releaseDate,
      );
}
