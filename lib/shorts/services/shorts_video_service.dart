import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Result of a successful video-clip resolution for a Shorts item.
class ShortsVideoResult {
  final String streamUrl; // direct muxed googlevideo.com playback URL (video+audio, audio ignored)
  final String youtubeId;

  const ShortsVideoResult({
    required this.streamUrl,
    required this.youtubeId,
  });
}

/// Fully isolated VISUAL-ONLY video pipeline for the Shorts feed.
///
/// Purely additive: the iTunes 30s preview remains the ONLY audio
/// source (owned by ShortsFeedController's just_audio player). This
/// service only ever supplies a muted background video clip layered
/// under the existing UI, matched to the same song by title+artist.
/// Never touches playback, queue, or audio state.
///
/// Two-stage resolve per item:
///   1. title+artist -> YouTube video id (youtube_explode_dart search)
///   2. video id -> muxed stream URL (aurum-shorts-video worker)
/// Both stages are cached in-memory and de-duped so re-visiting a
/// card (swipe back) or preloading upcoming cards is instant/cheap.
class ShortsVideoService {
  ShortsVideoService._();

  static final YoutubeExplode _yt = YoutubeExplode();

  static const _worker = 'https://aurum-shorts-video.krish908090.workers.dev';
  static const _resolveTimeout = Duration(seconds: 15);
  static const _searchTimeout = Duration(seconds: 8);

  // dedupeKey (artist::title) -> resolved youtube video id (null = not found)
  static final Map<String, String?> _idCache = {};
  // youtube video id -> resolved muxed stream result (null = failed)
  static final Map<String, ShortsVideoResult?> _clipCache = {};
  // in-flight de-dupe so rapid swipes don't fire duplicate requests.
  static final Map<String, Future<ShortsVideoResult?>> _inFlight = {};

  /// Full pipeline: song identity -> muted muxed video stream.
  /// Fails soft (returns null) at every stage — caller keeps showing
  /// the static artwork if this doesn't resolve in time or at all.
  static Future<ShortsVideoResult?> resolveForSong({
    required String dedupeKey,
    required String title,
    required String artist,
  }) async {
    final existingFuture = _inFlight[dedupeKey];
    if (existingFuture != null) return existingFuture;

    final future = _resolvePipeline(dedupeKey, title, artist);
    _inFlight[dedupeKey] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(dedupeKey);
    }
  }

  static Future<ShortsVideoResult?> _resolvePipeline(
    String dedupeKey,
    String title,
    String artist,
  ) async {
    final videoId = await _resolveVideoId(dedupeKey, title, artist);
    if (videoId == null) return null;

    if (_clipCache.containsKey(videoId)) {
      return _clipCache[videoId];
    }
    final result = await _resolveStream(videoId);
    _clipCache[videoId] = result;
    return result;
  }

  static Future<String?> _resolveVideoId(
    String dedupeKey,
    String title,
    String artist,
  ) async {
    if (_idCache.containsKey(dedupeKey)) return _idCache[dedupeKey];

    try {
      final query = '$artist $title';
      final results = await _yt.search
          .search(query)
          .timeout(_searchTimeout);
      final candidates = results.whereType<Video>().toList();

      final best = _pickBestMatch(candidates, title: title, artist: artist);
      final id = best?.id.value;
      _idCache[dedupeKey] = id;
      return id;
    } catch (_) {
      _idCache[dedupeKey] = null;
      return null;
    }
  }

  /// Scores search results and returns the best official/clean match,
  /// or null if nothing clears the bar. This is what keeps the feed
  /// from ever showing a reaction video, a fan lyric edit, a full
  /// concert, or a random unrelated clip under a song — for a paid
  /// product that mismatch reads as broken, not charming.
  static Video? _pickBestMatch(
    List<Video> candidates, {
    required String title,
    required String artist,
  }) {
    final normTitle = _normalize(title);
    final normArtist = _normalize(artist);

    Video? best;
    int bestScore = -1;

    for (final v in candidates) {
      // Hard filters — auto-disqualify, no partial credit.
      if (v.duration == null) continue;
      final secs = v.duration!.inSeconds;
      if (secs < 45 || secs > 600) continue; // too short to be a real clip, or a full mix/concert

      final normVTitle = _normalize(v.title);
      final normAuthor = _normalize(v.author);

      // Title must contain the song title reasonably intact —
      // filters out unrelated videos search sometimes surfaces.
      if (!normVTitle.contains(normTitle) && !_looseContains(normVTitle, normTitle)) {
        continue;
      }

      if (_isJunkTitle(normVTitle)) continue;

      int score = 0;

      // Strongest signal: uploader name matches the artist, or is
      // their "- Topic" auto-generated channel (YouTube/labels
      // generate these directly from official releases — as close
      // to "verified official audio/video" as search exposes).
      if (normAuthor == '$normArtist topic' || normAuthor.contains('$normArtist - topic')) {
        score += 100;
      } else if (normAuthor.contains(normArtist) || normArtist.contains(normAuthor)) {
        score += 60;
      }

      // Uploader/title language suggesting an official upload.
      if (normVTitle.contains('official video') || normVTitle.contains('official music video')) {
        score += 40;
      } else if (normVTitle.contains('official audio')) {
        score += 25;
      } else if (normVTitle.contains('official')) {
        score += 15;
      }

      // Exact title match (not just contains) is a good sign of the
      // real upload rather than a remix/cover with extra words.
      if (normVTitle == normTitle || normVTitle == '$normArtist $normTitle') {
        score += 20;
      }

      // Penalize things that ARE real videos but the wrong flavor
      // for a background clip — covers, live, lyric-only edits.
      if (normVTitle.contains('cover')) score -= 50;
      if (normVTitle.contains('live') || normVTitle.contains('concert')) score -= 40;
      if (normVTitle.contains('reaction')) score -= 100;
      if (normVTitle.contains('lyric')) score -= 10; // lyric videos are visually boring but not wrong — light penalty only
      if (normVTitle.contains('8d audio') || normVTitle.contains('slowed') || normVTitle.contains('sped up')) {
        score -= 80; // audio-edit reuploads, near-certain visual mismatch
      }

      // Mild view-count-adjacent trust signal: engagement isn't
      // exposed on the lightweight search result, so channel-name
      // signals above carry the actual weight here.

      if (score > bestScore) {
        bestScore = score;
        best = v;
      }
    }

    // Require a minimum bar — below this we'd rather show no video
    // than a shaky guess. Falls back to static artwork in the UI.
    if (bestScore < 15) return null;
    return best;
  }

  static bool _isJunkTitle(String normTitle) {
    const junkMarkers = [
      'trailer',
      'interview',
      'behind the scenes',
      'making of',
      'full album',
      'compilation',
      'mashup',
      'ringtone',
      'karaoke',
      'instrumental only',
      'type beat',
    ];
    return junkMarkers.any(normTitle.contains);
  }

  static String _normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Word-overlap fallback for cases where exact substring match
  /// fails due to minor punctuation/ordering differences, e.g. title
  /// "Song Name (feat. X)" vs video title "Song Name ft X".
  static bool _looseContains(String haystack, String needle) {
    final needleWords = needle.split(' ').where((w) => w.length > 2).toSet();
    if (needleWords.isEmpty) return false;
    final haystackWords = haystack.split(' ').toSet();
    final overlap = needleWords.intersection(haystackWords).length;
    return overlap / needleWords.length >= 0.7;
  }

  static Future<ShortsVideoResult?> _resolveStream(String youtubeId) async {
    try {
      final uri = Uri.parse('$_worker/api/video-resolve').replace(
        queryParameters: {
          'id': youtubeId,
          // Cap requested quality — this feed is a small muted
          // background layer, never full-screen focal video, so
          // there's no reason to pull 1080p and burn data/battery
          // decoding it. Worker falls back to its own default if it
          // doesn't understand the param, so this is safe either way.
          'maxQuality': '480p',
        },
      );
      final res = await http.get(uri).timeout(_resolveTimeout);
      if (res.statusCode != 200) return null;

      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      if (decoded['success'] != true) return null;

      final url = decoded['url'] as String?;
      if (url == null || url.isEmpty) return null;

      return ShortsVideoResult(
        streamUrl: url,
        youtubeId: (decoded['videoId'] ?? youtubeId) as String,
      );
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Drops cached entries — exposed for memory pressure handling.
  static void clearCache() {
    _idCache.clear();
    _clipCache.clear();
  }
}
