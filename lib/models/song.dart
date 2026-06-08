class Song {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String artworkUrl;
  final String? streamUrl;
  final int? duration; // in seconds
  final String? language;
  final String? year;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.artworkUrl,
    this.streamUrl,
    this.duration,
    this.language,
    this.year,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: (json['trackId'] ?? json['id'] ?? json['song_id'] ?? '').toString(),
      title: _clean((json['trackName'] ?? json['title'] ?? json['song'] ?? 'Unknown').toString()),
      artist: _clean((json['artistName'] ?? json['primary_artists'] ?? json['artist'] ?? json['singers'] ?? 'Unknown').toString()),
      album: _clean((json['collectionName'] ?? json['album'] ?? '').toString()),
      artworkUrl: _resolveArtwork(json),
      streamUrl: json['stream_url'] ?? json['media_url'] ?? json['previewUrl'],
      duration: _parseDuration(json['trackTimeMillis'] != null ? (json['trackTimeMillis'] / 1000).round() : json['duration']),
      language: json['primaryGenreName'] ?? json['language'],
      year: json['releaseDate']?.toString().substring(0, 4) ?? json['year']?.toString(),
    );
  }

  static String _clean(String s) {
    // Remove HTML entities
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  static String _resolveArtwork(Map<String, dynamic> json) {
    if (json['artworkUrl100'] != null) {
      return json['artworkUrl100'].toString().replaceAll('100x100bb', '600x600bb').replaceAll('100x100', '600x600');
    }
    // Priority: image array > artwork > image (500px preferred)
    if (json['image'] is List) {
      final images = json['image'] as List;
      final hq = images.lastWhere(
        (img) => img['quality']?.contains('500') == true,
        orElse: () => images.isNotEmpty ? images.last : null,
      );
      if (hq != null) return hq['link'] ?? hq['url'] ?? '';
    }
    final raw = json['artwork'] ?? json['image'] ?? json['thumbnail'] ?? '';
    if (raw is String) {
      return raw.replaceAll('150x150', '500x500').replaceAll('50x50', '500x500');
    }
    return '';
  }

  static int? _parseDuration(dynamic d) {
    if (d == null) return null;
    if (d is int) return d;
    if (d is String) return int.tryParse(d);
    return null;
  }

  String get durationString {
    if (duration == null) return '';
    final m = duration! ~/ 60;
    final s = duration! % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'artworkUrl': artworkUrl,
    'streamUrl': streamUrl,
    'duration': duration,
    'language': language,
    'year': year,
  };

  Song copyWith({String? streamUrl}) => Song(
    id: id,
    title: title,
    artist: artist,
    album: album,
    artworkUrl: artworkUrl,
    streamUrl: streamUrl ?? this.streamUrl,
    duration: duration,
    language: language,
    year: year,
  );
}

class SongSection {
  final String title;
  final List<Song> songs;
  SongSection({required this.title, required this.songs});
}
