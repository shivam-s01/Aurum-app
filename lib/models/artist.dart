import 'song.dart';

/// A simplified album/playlist entry shown on an artist's page.
class ArtistAlbum {
  final String id;
  final String name;
  final String artworkUrl;
  final String? year;
  final String type; // "album" or "playlist"

  ArtistAlbum({
    required this.id,
    required this.name,
    required this.artworkUrl,
    this.year,
    this.type = 'album',
  });
}

class Artist {
  final String id;
  final String name;
  final String imageUrl;
  final int followerCount;
  final bool isVerified;
  final String bio;
  final List<Song> topSongs;
  final List<ArtistAlbum> topAlbums;
  final List<ArtistAlbum> singles;

  Artist({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.followerCount,
    required this.isVerified,
    required this.bio,
    required this.topSongs,
    required this.topAlbums,
    required this.singles,
  });
}
