import 'song.dart';

/// Where an Artist's profile data (image/bio/follower count) came from.
enum ArtistSource { youtube, saavn }

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
  // NEW (YouTube-primary artist page): which source this profile's
  // image/bio/followerCount actually came from — lets ArtistScreen show a
  // "via YouTube"/"via JioSaavn" style badge if desired. Defaults to
  // youtube since that's now the primary path; fetchArtist() sets this
  // explicitly on every return.
  final ArtistSource source;
  // NEW: wide channel-banner image (YouTube channels only). Null for
  // Saavn-sourced profiles — UI falls back to imageUrl-only layout when null.
  final String? bannerUrl;

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
    this.source = ArtistSource.youtube,
    this.bannerUrl,
  });
}
