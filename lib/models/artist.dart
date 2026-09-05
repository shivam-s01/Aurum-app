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

/// A simplified "related artist" entry — for the "Fans might also like"
/// row. Always sourced from YouTube Music's own related-artists carousel
/// on the browse response (never guessed/derived client-side), so it only
/// ever contains artists YouTube itself considers genuinely related to
/// this one.
class RelatedArtist {
  final String id; // channelId, so tapping opens ArtistScreen the normal way
  final String name;
  final String imageUrl;

  RelatedArtist({
    required this.id,
    required this.name,
    required this.imageUrl,
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
  // NEW ("Fans might also like" — YT Music parity): populated only from
  // YT Music browse's own "Fans might also like" carousel (see
  // _fetchArtistFromYtMusicBrowse) — empty for every other path
  // (uploads-walk merge, Saavn fallback), never backfilled with a guess,
  // so ArtistScreen simply hides the row rather than showing something
  // awkward/unrelated when this is empty.
  final List<RelatedArtist> relatedArtists;

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
    this.relatedArtists = const [],
  });
}
