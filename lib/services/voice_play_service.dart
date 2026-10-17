import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../main.dart' show navigatorKey;
import '../models/song.dart';
import '../providers/favorites_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../screens/library_screen.dart' show PlaylistsScreen, PlaylistDetailScreen;
import '../utils/aurum_transitions.dart' show AurumPageRoute;
import '../utils/devanagari_transliterator.dart';
import '../widgets/aurum_snack.dart';
import 'api_service.dart';
import 'recommendation_engine.dart';

/// Handles "open Astra Music and play <x>" from Gemini / Google Assistant.
/// Native side: VoiceBridge.kt / MainActivity / AurumMediaSessionService.
///
/// The native side hands over either a plain string ("liked songs") or a JSON
/// payload {focus, q, title, artist, album, genre, playlist}. Like YouTube
/// Music, this layer tells apart:
///   song      "play Kesariya by Arijit Singh"   -> that song, then radio
///   artist    "play Arijit Singh" / "Arijit ke gaane" -> artist's songs
///   album     "play Aashiqui 2 album"           -> the album/movie songs
///   mood      "play sad songs" / "90s hits"     -> a mood/genre mix
///   library   "my liked songs" / "<my playlist>" -> your own library
///   generic   "play some music" / "kuch bhi bajao" -> shuffled liked songs
/// and understands English, Hinglish and Devanagari phrasing.
class VoicePlayService {
  VoicePlayService._();
  static const _ch = MethodChannel('com.aurum.music/voice');
  static bool _started = false;
  static bool _coldStart = true;
  static String _lastQ = '';
  static DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Latest voice command wins: a newer command cancels an older, still-loading one.
  static int _gen = 0;

  static Future<void> init() async {
    if (_started) return;
    _started = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'voicePlay') {
        unawaited(_play(call.arguments as String? ?? ''));
      }
      return null;
    });
    try {
      final pending = await _ch.invokeMethod<String>('getPending');
      if (pending != null && pending.isNotEmpty) unawaited(_play(pending));
    } catch (_) {}
  }

  // ───────────────────────────── main flow ─────────────────────────────

  static Future<void> _play(String payload) async {
    final p = payload.trim();
    if (p.isEmpty) return;
    final now = DateTime.now();
    if (p == _lastQ && now.difference(_lastAt) < const Duration(seconds: 4)) return;
    _lastQ = p;
    _lastAt = now;
    final gen = ++_gen;

    final it = _parse(p);

    // Cold start: wait for the widget tree (max ~15s).
    for (var i = 0; i < 60 && navigatorKey.currentContext == null; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (gen != _gen) return;
    if (navigatorKey.currentContext == null) return;

    try {
      // Start the network search NOW so it overlaps with provider loading and
      // the audio-engine settle delay below (this used to run strictly after).
      Future<List<Song>>? fetched;
      if (it.needsNetwork) fetched = _fetchFor(it);

      if (it.needsLibrary) await _waitForLibrary(4000);
      if (gen != _gen) return;

      if (_coldStart) {
        _coldStart = false;
        await Future.delayed(const Duration(milliseconds: 1200)); // let audio engine settle
        if (gen != _gen) return;
      }

      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;
      final player = ctx.read<PlayerProvider>();
      final favs = ctx.read<FavoritesProvider>().favorites;
      final playlists = ctx.read<PlaylistProvider>().playlists;

      // 1. "my playlists" -> open the playlists screen
      if (it.libKey == 'playlists' || it.libKey == 'all playlists') {
        navigatorKey.currentState?.push(AurumPageRoute(builder: (_) => const PlaylistsScreen()));
        return;
      }

      // 2. "liked songs" / "favourites"
      if (it.liked) {
        if (favs.isNotEmpty) {
          await _playCurated(player, favs, shuffle: it.shuffle);
          return;
        }
        await _playTrending(player, gen);
        return;
      }

      // 3. "play some music" -> a shuffled mix of the user's liked songs
      if (it.generic) {
        if (favs.isNotEmpty) {
          await _playCurated(player, favs, shuffle: true);
          return;
        }
        await _playTrending(player, gen);
        return;
      }

      // 4. one of the user's own playlists (library first, like YT Music).
      //    Unstructured text must match the name exactly unless the user said
      //    "playlist" — so a song called "Hit Me" never hijacks a playlist "Hit".
      if (it.focus == _Focus.playlist || it.focus == _Focus.any) {
        final key = _norm(it.libKey);
        if (key.isNotEmpty) {
          for (final pl in playlists) {
            final n = _norm(pl.name);
            if (pl.songs.isEmpty || n.isEmpty) continue;
            final exact = n == key;
            final loose = n.length >= 3 && (n.contains(key) || key.contains(n));
            if (exact || ((it.focus == _Focus.playlist || it.saidPlaylist) && loose)) {
              navigatorKey.currentState?.push(
                  AurumPageRoute(builder: (_) => PlaylistDetailScreen(playlistId: pl.id)));
              await _playCurated(player, List<Song>.of(pl.songs), shuffle: it.shuffle);
              return;
            }
          }
        }
      }

      // 5. catalog search (song / artist / album / mood)
      final list = await (fetched ??= _fetchFor(it));
      if (gen != _gen) return;
      if (list.isEmpty) {
        _notFound(it.label);
        return;
      }

      if (it.collection) {
        await _playCurated(player, list, shuffle: it.shuffle);
        return;
      }

      // Plain "arijit singh": if the top results are all BY that artist and
      // none is a song with that name, it is an artist request.
      if (it.focus == _Focus.any && it.artist.isEmpty && _looksLikeArtistQuery(it.text, list)) {
        await _playCurated(player, _byArtist(list, it.text), shuffle: it.shuffle);
        return;
      }

      // A single song: best match (title + artist aware), then radio.
      final idx = _bestIndex(list, it.title, it.artist);
      await player.playSong(list[idx], queue: list, index: idx);
    } catch (_) {}
  }

  static Future<void> _playCurated(PlayerProvider player, List<Song> songs,
      {bool shuffle = false}) async {
    if (songs.isEmpty) return;
    final q = List<Song>.of(songs);
    if (shuffle) q.shuffle(math.Random());
    await player.playSong(q.first, queue: q, index: 0, curatedQueue: true);
  }

  static Future<void> _playTrending(PlayerProvider player, int gen) async {
    final list = await _firstNonEmpty(
        const ['trending hindi songs', 'top hindi songs'], limit: 30);
    if (gen != _gen) return;
    if (list.isEmpty) {
      _notFound('music');
      return;
    }
    await _playCurated(player, list);
  }

  static Future<void> _waitForLibrary(int maxMs) async {
    for (var waited = 0; waited < maxMs; waited += 250) {
      final c = navigatorKey.currentContext;
      if (c == null) return;
      try {
        if (!c.read<FavoritesProvider>().isLoading && !c.read<PlaylistProvider>().isLoading) return;
      } catch (_) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  static void _notFound(String what) {
    final c = navigatorKey.currentContext;
    if (c == null) return;
    try {
      AurumSnack.show(c, 'Couldn\'t find "$what"', duration: const Duration(seconds: 3));
    } catch (_) {}
  }

  // ───────────────────────────── fetching ─────────────────────────────

  static Future<List<Song>> _fetchFor(_VoiceIntent it) async {
    try {
      if (it.collection) return await _collection(it);
      return await _firstNonEmpty(it.queries, limit: 20);
    } catch (_) {
      return const <Song>[];
    }
  }

  /// Fast path first (quickSearch: capped, cached, 4-9s timeouts), full search
  /// engine only as a fallback.
  static Future<List<Song>> _candidates(String q, {int limit = 20}) async {
    try {
      final quick = await ApiService.quickSearch(q, limit: limit);
      if (quick.isNotEmpty) return quick;
    } catch (_) {}
    try {
      final r = await ApiService.search(q).timeout(const Duration(seconds: 12));
      return r.direct.isNotEmpty ? r.direct : r.all;
    } catch (_) {
      return const <Song>[];
    }
  }

  static Future<List<Song>> _firstNonEmpty(List<String> queries, {int limit = 20}) async {
    final seen = <String>{};
    for (final q in queries) {
      final t = q.trim();
      if (t.isEmpty || !seen.add(t.toLowerCase())) continue;
      final r = await _candidates(t, limit: limit);
      if (r.isNotEmpty) return r;
    }
    return const <Song>[];
  }

  /// YT Music song search WITHOUT the relevance scorer. The scorer demands that
  /// query words appear in a song's title/artist, which is right for "type a
  /// song name" but wipes out mood/album queries ("hindi sad songs"): no single
  /// song is titled that. Quality filters stay; relevance is YT Music's own.
  static Future<List<Song>> _rawSongs(String q, {int limit = 40}) async {
    try {
      final raw = await ApiService.searchYtRaw(q, limit: limit)
          .timeout(const Duration(seconds: 12));
      final wantsVariant = RecommendationEngine.isInherentVariant(q);
      final out = <Song>[];
      for (final s in raw) {
        if (!RecommendationEngine.isSearchQuality(s)) continue;
        if (RecommendationEngine.isNonMusicContent(s)) continue;
        if (RecommendationEngine.isLowQualityUpload(s.title)) continue;
        if (!wantsVariant && RecommendationEngine.isInherentVariant(s.title)) continue;
        if (out.any((o) => o.id == s.id ||
            RecommendationEngine.isSameSongSmart(o.title, s.title))) {
          continue;
        }
        out.add(s);
      }
      return out;
    } catch (_) {
      return const <Song>[];
    }
  }

  static Future<List<Song>> _collection(_VoiceIntent it) async {
    final list = <Song>[];
    final seen = <String>{};
    void addAll(Iterable<Song> src) {
      for (final s in src) {
        if (seen.add(s.id)) list.add(s);
      }
    }

    // Artist: the scored search ranks exact artist-name matches first (the same
    // list the in-app search shows for that name).
    if (it.focus == _Focus.artist) {
      addAll(await _firstNonEmpty(it.queries, limit: 40));
    }
    // Everything else (and thin artist results): raw YT Music song search.
    if (list.length < 15) {
      for (final q in it.rawQueries) {
        if (q.trim().isEmpty) continue;
        addAll(await _rawSongs(q, limit: 40));
        if (list.length >= 25) break;
      }
    }
    // Last resort: the scored engine (also pulls related songs).
    if (list.length < 5) {
      for (final q in it.queries) {
        if (q.trim().isEmpty) continue;
        try {
          final r = await ApiService.search(q).timeout(const Duration(seconds: 12));
          addAll(r.all);
          if (list.length >= 15) break;
        } catch (_) {}
      }
    }
    return it.artist.isNotEmpty ? _byArtist(list, it.artist) : list;
  }

  // ───────────────────────────── ranking ─────────────────────────────

  static final RegExp _nonWordRe = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);
  static final RegExp _wsRe = RegExp(r'\s+');

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(_nonWordRe, ' ').replaceAll(_wsRe, ' ').trim();

  static List<String> _tokens(String s) =>
      _norm(s).split(' ').where((t) => t.isNotEmpty).toList();

  static bool _artistMatches(Song s, List<String> artistTokens) {
    if (artistTokens.isEmpty) return true;
    final a = _norm(s.artist);
    for (final t in artistTokens) {
      if (t.length > 2 && !a.contains(t)) return false;
    }
    return true;
  }

  /// Songs by [artist] first (engine order kept). With >=5 matches only those.
  static List<Song> _byArtist(List<Song> list, String artist) {
    final tk = _tokens(artist);
    if (tk.isEmpty) return list;
    final matched = <Song>[];
    final rest = <Song>[];
    for (final s in list) {
      (_artistMatches(s, tk) ? matched : rest).add(s);
    }
    if (matched.isEmpty) return list;
    return matched.length >= 5 ? matched : [...matched, ...rest];
  }

  static bool _looksLikeArtistQuery(String q, List<Song> list) {
    final qt = _tokens(q);
    if (qt.isEmpty || qt.length > 4 || list.length < 2) return false;
    final qn = _norm(q);
    var artistHits = 0;
    for (final s in list.take(3)) {
      if (_norm(s.title).contains(qn)) return false; // a song with that name exists
      final a = _norm(s.artist);
      if (qt.every((w) => a.contains(w))) artistHits++;
    }
    return artistHits >= 2;
  }

  /// Picks the best of the first results using title/artist hints; the search
  /// engine's own ordering is the tie-breaker.
  static int _bestIndex(List<Song> list, String title, String artist) {
    if (list.isEmpty) return 0;
    final tt = _tokens(title);
    final at = _tokens(artist);
    if (tt.isEmpty && at.isEmpty) return 0;
    final n = math.min(list.length, 10);
    var best = 0;
    var bestScore = -1.0;
    for (var i = 0; i < n; i++) {
      final st = _norm(list[i].title);
      final sa = _norm(list[i].artist);
      var score = (n - i) * 0.5;
      for (final t in tt) {
        if (t.length > 1 && st.contains(t)) score += 2;
      }
      for (final a in at) {
        if (a.length > 1 && sa.contains(a)) score += 3;
      }
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

  // ───────────────────────────── parsing ─────────────────────────────

  static final RegExp _likedRe = RegExp(
      r'\bliked\b|\bfavou?rites?\b|my likes|pasand|पसंद|फेवरेट|फ़ेवरेट',
      caseSensitive: false);
  static final RegExp _playlistWordRe =
      RegExp(r'\bplaylist\b|प्लेलिस्ट', caseSensitive: false);
  static final RegExp _libWordsRe =
      RegExp(r'\b(my|the|playlist|play|mera|meri|mere)\b', caseSensitive: false);

  static final RegExp _leadAstraRe = RegExp(
      r'^(?:open\s+|launch\s+)?astra(?:\s+music)?\s+(?:and\s+|then\s+|me\s+|mein\s+|par\s+|pe\s+)?',
      caseSensitive: false);
  static final RegExp _leadPlayRe = RegExp(
      r'^(?:(?:can|could|would|will)\s+you\s+)?(?:(?:please|plz|pls|kindly)\s+)?(play|shuffle|put\s+on)\b\s*(?:(?:me|for\s+me)\s+)?(?:(?:please|plz|pls)\s+)?',
      caseSensitive: false);
  static final RegExp _leadHiRe = RegExp(r'^(?:प्ले|चलाओ|बजाओ|सुनाओ|लगाओ)\s+');
  static final RegExp _shuffleAnyRe =
      RegExp(r'\b(?:on\s+)?shuffle(?:d)?\b', caseSensitive: false);

  static final RegExp _tailAstraRe = RegExp(
      r'\s+(?:(?:on|in|using|with|par|pe|mein|me)\s+)?astra(?:\s+music)?(?:\s+app)?$',
      caseSensitive: false);
  static final RegExp _tailVerbRe = RegExp(
      r'\s+(?:chalao|chala\s?do|chalado|chalaiye|bajao|baja\s?do|bajado|bajaiye|sunao|suna\s?do|sunado|sunaiye|lagao|laga\s?do|lagado|play\s?kar(?:o|do|na)?|kar\s?do|kardo|चलाओ|चला\s?दो|बजाओ|बजा\s?दो|सुनाओ|सुना\s?दो|लगाओ|लगा\s?दो|प्ले(?:\s?करो)?|चलाइए|बजाइए)$',
      caseSensitive: false);
  static final RegExp _tailPoliteRe =
      RegExp(r'\s+(?:please|plz|pls|for\s+me|zara)$', caseSensitive: false);
  static final RegExp _tailPluralRe = RegExp(
      r'\s+(?:songs|gaane|gane|hits|tracks|tracklist|playlist|mix|radio|music|गाने|गीत|म्यूजिक|संगीत)$',
      caseSensitive: false);
  static final RegExp _tailSingleRe =
      RegExp(r'\s+(?:song|gaana|gana|gaanaa|track|गाना)$', caseSensitive: false);
  static final RegExp _possRe = RegExp(r'\s+(?:ke|ki|ka|के|की|का)$', caseSensitive: false);
  static final RegExp _songsByRe = RegExp(
      r'^(?:(?:songs?|music|hits|tracks?|top\s+songs?|top\s+hits|old\s+songs?)\s+(?:by|of|from)|best\s+of|top\s+10\s+of)\s+(.+)$',
      caseSensitive: false);
  static final RegExp _titleByRe =
      RegExp(r'^(.+?)\s+by\s+(.+)$', caseSensitive: false);
  static final RegExp _punctRe = RegExp(r'[।!?,;:"“”]+');

  static const Set<String> _genericWords = {
    'some', 'any', 'anything', 'something', 'random', 'kuch', 'koi', 'bhi', 'ek',
    'music', 'song', 'songs', 'gaana', 'gaane', 'gana', 'gane', 'mera', 'meri',
    'mere', 'my', 'me', 'mujhe', 'suno', 'a', 'the', 'good', 'acha', 'achha',
  };

  static const Set<String> _moodWords = {
    'sad', 'romantic', 'romance', 'party', 'workout', 'gym', 'chill', 'relax',
    'relaxing', 'study', 'sleep', 'focus', 'happy', 'love', 'retro', 'old', 'new',
    'latest', 'trending', 'top', 'best', 'hit', 'hits', 'devotional', 'bhajan',
    'ghazal', 'sufi', 'wedding', 'travel', 'driving', 'road', 'motivational',
    'breakup', 'dance', 'rain', 'monsoon', 'peaceful', 'emotional', 'heartbreak',
    'friendship', 'birthday', 'bhakti', 'kids', 'instrumental', 'rap', 'pop',
    'rock', 'hiphop', 'indie', 'classical', 'jazz', 'edm', 'country', 'mood',
    'purane', 'puraane', 'purana', 'naye', 'naya', '60s', '70s', '80s', '90s',
    '2000s', '2010s', 'lofi', 'morning', 'night', 'evening', 'bollywood',
    'punjabi', 'hindi', 'english', 'tamil', 'telugu', 'marathi', 'bengali',
    'gujarati', 'kannada', 'malayalam', 'bhojpuri', 'haryanvi', 'urdu',
  };

  static const Set<String> _langWords = {
    'hindi', 'english', 'punjabi', 'tamil', 'telugu', 'bengali', 'marathi',
    'gujarati', 'kannada', 'malayalam', 'bhojpuri', 'haryanvi', 'urdu',
    'bollywood', 'korean', 'kpop', 'spanish',
  };

  static bool _hasWord(String text, Set<String> words) =>
      _tokens(text).any(words.contains);

  /// Strips the spoken command wrapper ("can you play ... on Astra Music",
  /// "... chalao", "... bajao please") and reports plural/singular/shuffle.
  static _Cleaned _clean(String raw) {
    var s = raw.replaceAll(_punctRe, ' ').replaceAll(_wsRe, ' ').trim();
    var shuffle = false;
    if (s.isEmpty) return const _Cleaned('', false, false, false);

    s = s.replaceFirst(_leadAstraRe, '');
    final lead = _leadPlayRe.firstMatch(s);
    if (lead != null) {
      if ((lead.group(1) ?? '').toLowerCase().startsWith('shuffle')) shuffle = true;
      s = s.substring(lead.end);
    }
    s = s.replaceFirst(_leadHiRe, '');
    if (_shuffleAnyRe.hasMatch(s)) {
      shuffle = true;
      s = s.replaceAll(_shuffleAnyRe, ' ');
    }
    s = s.replaceAll(_wsRe, ' ').trim();

    for (var i = 0; i < 5; i++) {
      final before = s;
      s = s
          .replaceFirst(_tailAstraRe, '')
          .replaceFirst(_tailVerbRe, '')
          .replaceFirst(_tailPoliteRe, '')
          .trim();
      if (s == before) break;
    }

    var plural = false;
    var single = false;
    if (_tailPluralRe.hasMatch(s)) {
      plural = true;
      s = s.replaceFirst(_tailPluralRe, '').trim();
    } else if (_tailSingleRe.hasMatch(s)) {
      single = true;
      s = s.replaceFirst(_tailSingleRe, '').trim();
    }
    return _Cleaned(s, plural, single, shuffle);
  }

  static String _moodQuery(String g) {
    final t = g.trim();
    var q = t;
    if (!_hasWord(t, _langWords)) q = 'hindi $q';
    if (!RegExp(r'\b(songs|hits|music|mix|playlist)\b', caseSensitive: false).hasMatch(t)) {
      q = '$q songs';
    }
    return q;
  }

  /// Devanagari queries: try the romanised form first (YT titles are mostly
  /// Latin and the relevance scorer compares Latin text), then the original.
  static List<String> _withRoman(List<String> qs) {
    final out = <String>[];
    for (final q in qs) {
      if (q.trim().isEmpty) continue;
      try {
        if (DevanagariTransliterator.containsDevanagari(q)) {
          final r = DevanagariTransliterator.transliterate(q).trim();
          if (r.isNotEmpty) out.add(r);
        }
      } catch (_) {}
      out.add(q);
    }
    return out;
  }

  static _VoiceIntent _parse(String payload) {
    final it = _VoiceIntent();
    var raw = payload.trim();
    var focus = _Focus.any;
    var title = '', artist = '', album = '', genre = '', playlist = '';

    if (raw.startsWith('{')) {
      try {
        final m = jsonDecode(raw);
        if (m is Map) {
          String s(String k) => (m[k] ?? '').toString().trim();
          raw = s('q');
          title = s('title');
          artist = s('artist');
          album = s('album');
          genre = s('genre');
          playlist = s('playlist');
          switch (s('focus')) {
            case 'song':
              focus = _Focus.song;
              break;
            case 'artist':
              focus = _Focus.artist;
              break;
            case 'album':
              focus = _Focus.album;
              break;
            case 'playlist':
              focus = _Focus.playlist;
              break;
            case 'genre':
              focus = _Focus.genre;
              break;
          }
        }
      } catch (_) {}
    }

    final structured = title.isNotEmpty ||
        artist.isNotEmpty ||
        album.isNotEmpty ||
        genre.isNotEmpty ||
        playlist.isNotEmpty;

    final lowerAll = '$raw $playlist'.toLowerCase();
    it.saidPlaylist = _playlistWordRe.hasMatch(lowerAll);
    it.liked = _likedRe.hasMatch(lowerAll);

    final c = _clean(raw.isNotEmpty ? raw : (title.isNotEmpty ? title : artist));
    it.shuffle = c.shuffle;
    var text = c.text;

    // Extras present but the assistant left the focus open -> infer it.
    if (focus == _Focus.any) {
      if (title.isNotEmpty) {
        focus = _Focus.song;
      } else if (playlist.isNotEmpty) {
        focus = _Focus.playlist;
      } else if (album.isNotEmpty) {
        focus = _Focus.album;
      } else if (artist.isNotEmpty) {
        focus = _Focus.artist;
      } else if (genre.isNotEmpty) {
        focus = _Focus.genre;
      }
    }

    // Focus known but its field empty -> the free text is that field.
    switch (focus) {
      case _Focus.artist:
        if (artist.isEmpty) artist = text;
        break;
      case _Focus.album:
        if (album.isEmpty) album = text;
        break;
      case _Focus.genre:
        if (genre.isEmpty) genre = text;
        break;
      case _Focus.playlist:
        if (playlist.isEmpty) playlist = text;
        break;
      case _Focus.song:
        if (title.isEmpty) title = text;
        break;
      case _Focus.any:
        break;
    }

    // Free text only (no focus, no extras): work out what was asked.
    if (focus == _Focus.any && !structured && !it.liked) {
      final generic = text.isEmpty || _tokens(text).every(_genericWords.contains);
      if (generic) {
        it.generic = true;
      } else {
        final by = _songsByRe.firstMatch(text);
        if (it.saidPlaylist) {
          // "play my gym playlist" -> the user's playlist, even if "gym" is a mood word
          playlist = text;
          focus = _Focus.playlist;
        } else if (by != null) {
          artist = by.group(1)!.trim();
          focus = _Focus.artist;
        } else if ((c.plural || c.single) && _possRe.hasMatch(text)) {
          // "arijit singh ke gaane" / "kishore kumar ka gaana"
          artist = text.replaceFirst(_possRe, '').trim();
          focus = _Focus.artist;
        } else if (c.plural) {
          if (_hasWord(text, _moodWords)) {
            genre = text;
            focus = _Focus.genre;
          } else {
            artist = text; // "arijit singh songs"
            focus = _Focus.artist;
          }
        } else {
          final tb = _titleByRe.firstMatch(text);
          if (tb != null) {
            title = tb.group(1)!.trim();
            artist = tb.group(2)!.trim();
            focus = _Focus.song;
          }
        }
      }
    }

    it.focus = focus;
    it.text = text;
    it.title = title;
    it.artist = artist;
    it.album = album;
    it.genre = genre;
    it.playlist = playlist;
    it.collection = focus == _Focus.artist ||
        focus == _Focus.album ||
        focus == _Focus.genre ||
        focus == _Focus.playlist;

    // Library lookup key ("my gym playlist" -> "gym"; "my playlists" -> "playlists").
    final libSrc = playlist.isNotEmpty ? playlist : text;
    it.libKey = libSrc
        .toLowerCase()
        .replaceAll(_libWordsRe, ' ')
        .replaceAll(_wsRe, ' ')
        .trim();

    // Catalog queries, best first. `qs` feeds the scored search (songs/artists);
    // `raw` feeds the unscored YT Music search (collections).
    final qs = <String>[];
    final raw2 = <String>[];
    switch (focus) {
      case _Focus.song:
        if (title.isNotEmpty && artist.isNotEmpty) qs.add('$title $artist');
        if (title.isNotEmpty) qs.add(title);
        if (text.isNotEmpty) qs.add(text);
        break;
      case _Focus.any:
        if (text.isNotEmpty) qs.add(text);
        break;
      case _Focus.artist:
        qs.add(artist);
        qs.add('$artist songs');
        raw2.add('$artist songs');
        break;
      case _Focus.album:
        qs.add('$album songs');
        if (artist.isNotEmpty) qs.add('$album $artist');
        raw2.add('$album all songs');
        raw2.add('$album songs');
        break;
      case _Focus.genre:
        qs.add(_moodQuery(genre));
        raw2.add(_moodQuery(genre));
        break;
      case _Focus.playlist:
        final pq = _moodQuery(it.libKey.isNotEmpty ? it.libKey : playlist);
        qs.add(pq);
        raw2.add(pq);
        break;
    }
    it.rawQueries = _withRoman(raw2);
    it.queries = _withRoman(qs);
    return it;
  }
}

enum _Focus { any, song, artist, album, playlist, genre }

class _Cleaned {
  final String text;
  final bool plural; // "songs / gaane / hits / music" -> a collection was asked
  final bool single; // "song / gaana"
  final bool shuffle;
  const _Cleaned(this.text, this.plural, this.single, this.shuffle);
}

class _VoiceIntent {
  _Focus focus = _Focus.any;
  String text = '';
  String title = '';
  String artist = '';
  String album = '';
  String genre = '';
  String playlist = '';
  String libKey = '';
  List<String> queries = const <String>[];
  List<String> rawQueries = const <String>[];
  bool liked = false;
  bool shuffle = false;
  bool generic = false;
  bool collection = false;
  bool saidPlaylist = false;

  bool get needsLibrary => liked || generic || focus == _Focus.playlist || focus == _Focus.any;
  bool get needsNetwork => !liked && !generic && focus != _Focus.playlist;

  String get label {
    if (title.isNotEmpty) return artist.isNotEmpty ? '$title – $artist' : title;
    if (album.isNotEmpty) return album;
    if (artist.isNotEmpty) return artist;
    if (genre.isNotEmpty) return genre;
    if (playlist.isNotEmpty) return playlist;
    return text;
  }
}
