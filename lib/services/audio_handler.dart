import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'api_service.dart';
import 'audio_prefs.dart';

// =============================================================================
// LOOKAHEAD STREAM CACHE
// Separate from ApiService's stream cache — this one stores the *resolved*
// AudioSource headers token so when the next song actually starts, we skip
// the entire resolve round-trip. Keyed by song.id, max 3 entries.
// Populated at 70% of current song. Cleared on song change.
// =============================================================================
class _LookaheadCache {
  static final Map<String, String> _urls = {};
  static const int _max = 3;

  static void put(String songId, String url) {
    if (_urls.length >= _max) {
      _urls.remove(_urls.keys.first);
    }
    _urls[songId] = url;
  }

  static String? get(String songId) => _urls[songId];

  static void remove(String songId) => _urls.remove(songId);

  static void clear() => _urls.clear();
}

// =============================================================================
// PRODUCTION STREAMING HEADERS
// Injected on every AudioSource.uri call.
// - User-Agent: matches Android Chrome — prevents throttling by CDNs
//   that rate-limit generic/bot UA strings (JioSaavn CDN does this).
// - Range: open-ended range header signals byte-serving support to the
//   CDN, enabling ExoPlayer's internal partial-content fetching which
//   is faster than chunked transfer for audio.
// - Connection: Keep-Alive: reuses the TCP connection across the stream
//   lifecycle — eliminates repeated TLS handshake overhead (~100-200ms
//   on low-end devices with slow CDNs).
// - Accept-Encoding: identity — tells the CDN not to gzip/deflate the
//   audio stream; ExoPlayer doesn't benefit from compression on binary
//   audio and the encode/decode overhead wastes CPU on old phones.
// =============================================================================
const Map<String, String> _kStreamHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 11; Pixel 4) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  // NOTE: do NOT set 'Range', 'Connection', or 'Accept-Encoding' here.
  // ExoPlayer's own HTTP data source manages Range (per-chunk seeking),
  // Connection (keep-alive pooling), and Accept-Encoding internally.
  // Overriding any of these caused a generic ExoPlaybackException
  // "Source error" (code=0) — confirmed via curl that the CDN itself
  // returns a perfectly valid 206 Partial Content with no special
  // headers required. Only User-Agent is actually needed.
};

class AurumAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player   = AudioPlayer();
  final _playlist = ConcatenatingAudioSource(children: []);

  List<Song> _queue        = [];
  int        _currentIndex = 0;

  // Fired synchronously the instant _queue/_currentIndex change — lets
  // PlayerProvider notify the UI immediately (new "now playing" song,
  // equalizer icon, mini-player) without waiting for currentIndexStream,
  // which only fires once just_audio finishes loading the resolved source.
  void Function()? onQueueChanged;

  // Fired with the exact error string whenever a real playback attempt
  // (playSong/playQueue) fails to actually start sound — lets the UI show
  // it immediately (SnackBar/Dialog) instead of it only living in
  // debugPrint, which is invisible on a release APK with no logcat access.
  void Function(String error)? onPlaybackError;

  // Cancellation token — each new playQueue/playSong call gets a fresh ID.
  // Background resolvers check this before touching the playlist.
  int _playSessionId = 0;

  // Prevent concurrent playQueue calls from racing each other.
  bool _isLoadingNewSong = false;

  // True while _resolveQueueInBackground is still splicing songs into the
  // live ConcatenatingAudioSource. During this window the player's own
  // internal sequence index does NOT correspond 1:1 with `_currentIndex`
  // (which tracks position within the full `_queue`), because the player
  // starts with just one song and grows toward the full queue size. The
  // currentIndexStream listener below must ignore index updates while this
  // is true, otherwise it stomps `_currentIndex` with a stale/mismatched
  // value and the UI appears to jump to a different song mid-playback.
  bool _splicingInProgress = false;
  bool _restoredSilently = false; // set by loadQueueSilently, cleared on explicit play — prevents interruption-end from auto-playing restored queue

  StreamSubscription<AccelerometerEvent>? _shakeSub;
  DateTime _lastShake = DateTime.now();
  static const double _shakeThreshold = 15.0;

  AurumAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    // Restore Player & Audio settings (Stream Quality, Data Saver, call /
    // notification interruption behaviour) BEFORE the audio session is
    // wired up — so the very first interruption event already respects them.
    await AudioPrefs.load();

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // ---------------------------------------------------------------------
    // Interruption handling — driven by Settings → Player & Audio →
    // Behaviour:
    //
    //   • AudioInterruptionType.pause → typically a phone call or another
    //     media app taking over.
    //       - AudioPrefs.pauseOnCall == true  (default): pause, and resume
    //         automatically once the interruption ends.
    //       - AudioPrefs.pauseOnCall == false: ignored entirely — playback
    //         keeps going through calls wherever the OS allows it.
    //
    //   • AudioInterruptionType.duck → a short transient sound (e.g. a
    //     notification chime).
    //       - AudioPrefs.duckOnNotifications == false (default): IGNORED —
    //         song volume does NOT drop and playback does NOT pause for
    //         notifications.
    //       - true: pause briefly and resume after, like other apps do.
    // ---------------------------------------------------------------------
    session.interruptionEventStream.listen((event) {
      final isDuck = event.type == AudioInterruptionType.duck;

      if (isDuck && !AudioPrefs.duckOnNotifications) {
        return; // Notification sound — ignore, keep playing at full volume.
      }
      if (!isDuck && !AudioPrefs.pauseOnCall) {
        return; // Phone call / other app — ignore, keep playing.
      }

      if (event.begin) {
        _player.pause();
      } else {
        // Don't auto-resume if this was a silently-restored queue (app reopen).
        // Only resume if the user had explicitly started playback themselves.
        if (!_restoredSilently) _player.play();
      }
    });

    session.becomingNoisyEventStream.listen((_) => _player.pause());

    // Broadcast state to audio_service (notification, lock screen)
    _player.playbackEventStream.listen(_broadcastState);

    // ── 403 / Expired stream recovery ────────────────────────────────────────
    // JioSaavn CDN URLs expire ~50min. YouTube signed URLs expire faster.
    // If song is paused long and resumed, ExoPlayer hits HTTP 403 → processingState
    // goes idle mid-stream. We detect this, force-refresh the URL, rebuild
    // AudioSource at same seek position, and resume. Zero user interaction needed.
    _player.playbackEventStream.listen((event) async {
      if (event.processingState != ProcessingState.idle) return;
      final pos = _player.position;
      if (pos.inMilliseconds < 500) {
        // Fresh-start failure (not an expired-URL case) — log it so it's
        // visible instead of silently doing nothing. This state previously
        // had zero observability: play() looked like it succeeded
        // (isPlaying stayed true) while the engine sat in idle forever.
        final songTitle = _queue.isNotEmpty && _currentIndex < _queue.length
            ? _queue[_currentIndex].title : "?";
        debugPrint('[AurumHandler] FRESH-START FAILURE: processingState=idle '
            'at pos=${pos.inMilliseconds}ms, queue=${_queue.length}, '
            'loading=$_isLoadingNewSong, song=$songTitle');
        if (!_isLoadingNewSong && _queue.isNotEmpty) {
          onPlaybackError?.call('Silent fresh-start failure for "$songTitle" — '
              'setAudioSource appeared to succeed but processingState went '
              'idle at position 0ms (no exception thrown). last event: '
              '${event.processingState}');
        }
        return;
      }
      if (_queue.isEmpty || _isLoadingNewSong) return;

      final song = _queue[_currentIndex];
      if (song.isLocal) return;

      debugPrint('[AurumHandler] Stream expired for "${song.title}" at ${pos.inSeconds}s — recovering');
      ApiService.invalidateStream(song);
      _LookaheadCache.remove(song.id);

      final sessionAtError = _playSessionId;
      try {
        final freshUrl = await ApiService.resolveStreamUrl(song, forceRefresh: true)
            .timeout(const Duration(seconds: 12), onTimeout: () => null);
        if (freshUrl == null || sessionAtError != _playSessionId) return;

        final freshSource = AudioSource.uri(
          Uri.parse(freshUrl),
          tag: _songToMediaItem(song),
          headers: _kStreamHeaders,
        );
        final seq = _player.audioSource;
        if (seq is ConcatenatingAudioSource) {
          final playerIdx = _player.currentIndex ?? 0;
          if (playerIdx < seq.length) {
            await seq.removeAt(playerIdx);
            await seq.insert(playerIdx, freshSource);
            await _player.seek(pos, index: playerIdx);
            await _player.play();
            debugPrint('[AurumHandler] Recovered "${song.title}" at ${pos.inSeconds}s ✓');
          }
        }
      } catch (e) {
        debugPrint('[AurumHandler] Recovery failed: $e');
      }
    });
    _player.durationStream.listen((d) {
      if (d != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: d));
      }
    });

    _player.currentIndexStream.listen((index) {
      // FIX: while songs are still being spliced into the live player
      // sequence (playQueue's background prepend/append phase), the
      // player's own index is NOT the same coordinate space as
      // `_currentIndex` (queue position) — trusting it here caused the
      // displayed "now playing" song to jump around on its own.
      if (_splicingInProgress) return;
      if (index == null) return;

      // FIX (notification metadata mismatch): right after splicing ends,
      // a stray currentIndexStream event can fire with an index that no
      // longer matches `_queue`'s current contents (queue mutated on a
      // background isolate boundary vs this stream's delivery timing).
      // Trusting `_queue[index]` blindly here was painting the WRONG
      // song's title/artist/art into the lockscreen/notification while
      // the correct audio kept playing underneath.
      //
      // The player's own current AudioSource tag is the ground truth —
      // it's the exact MediaItem we attached via `_songToMediaItem` when
      // the source was created, so it can never be out of sync with what
      // is actually sounding.
      final sequence = _player.sequence;
      final inSourceRange = sequence != null && index < sequence.length;
      final tag = inSourceRange ? sequence[index].tag : null;

      if (tag is MediaItem) {
        if (mediaItem.value?.id != tag.id) {
          mediaItem.add(tag);
        }
        if (index != _currentIndex && index < _queue.length) {
          _currentIndex = index;
        }
        return;
      }

      // Fallback: no usable source tag yet, use queue if indices align.
      if (index != _currentIndex && index < _queue.length) {
        _currentIndex = index;
        _updateMediaItem(_queue[index]);
      }
    });

    await _applySettings();
  }

  Future<void> _applySettings() async {
    await AudioPrefs.load();
    final p = await SharedPreferences.getInstance();
    final speed = p.getDouble('playback_speed') ?? 1.0;
    await _player.setSpeed(speed);
    final shakeEnabled = p.getBool('shake_to_skip') ?? false;
    _updateShakeListener(shakeEnabled);
  }

  void _updateShakeListener(bool enabled) {
    _shakeSub?.cancel();
    _shakeSub = null;
    if (!enabled) return;
    _shakeSub = accelerometerEventStream().listen((event) {
      final magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      final now = DateTime.now();
      if (magnitude > _shakeThreshold && now.difference(_lastShake).inMilliseconds > 1000) {
        _lastShake = now;
        skipToNext();
      }
    });
  }

  Future<void> reloadSettings() async => _applySettings();

  @override
  Future<void> onTaskRemoved() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool('stop_on_swipe') ?? false) {
      await stop();
      await clearQueue();
    }
  }

  @override
  Future<void> onNotificationDeleted() async => stop();

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'reloadSettings') await reloadSettings();
  }

  // ─── DIAGNOSTIC: REAL PLAYBACK TEST (via the live handler/player) ────────
  // Used by api_service.dart's debugPlaybackPath() so the diagnostic
  // popup tests the SAME code path real taps use — _sourceForSong(),
  // the shared _player instance, preload:false — instead of a throwaway
  // AudioPlayer with different settings (see api_service.dart comment for
  // why that distinction mattered: a throwaway-player pass/fail told us
  // nothing about whether normal in-app playback actually worked).
  //
  // Saves/restores the user's real queue+position so this test never
  // disrupts whatever they were actually listening to. If nothing was
  // playing, simply stops afterward.
  Future<RealPlaybackResult> runRealPlaybackTest(Song testSong) async {
    // Snapshot what the user actually had going on, so we can restore it.
    final savedQueue   = List<Song>.from(_queue);
    final savedIndex   = _currentIndex;
    final wasPlaying   = _player.playing;
    final savedPos     = _player.position;

    try {
      final source = await _sourceForSong(testSong);
      if (source == null) {
        return const RealPlaybackResult(
          success: false,
          positionMs: 0,
          processingState: 'n/a',
          errorMessage: '_sourceForSong returned null (resolve failed)',
        );
      }

      final testPlaylist = ConcatenatingAudioSource(children: [source]);
      await _player.setAudioSource(testPlaylist, initialIndex: 0, preload: false);
      await _player.play();
      await Future.delayed(const Duration(seconds: 2));

      final pos   = _player.position;
      final state = _player.processingState.toString();
      final ok    = pos.inMilliseconds > 200;

      return RealPlaybackResult(
        success: ok,
        positionMs: pos.inMilliseconds,
        processingState: state,
      );
    } on PlayerException catch (e) {
      return RealPlaybackResult(
        success: false,
        positionMs: 0,
        processingState: 'error',
        errorMessage: 'code=${e.code} message=${e.message}',
      );
    } catch (e) {
      return RealPlaybackResult(
        success: false,
        positionMs: 0,
        processingState: 'error',
        errorMessage: e.toString(),
      );
    } finally {
      // Restore whatever the user actually had playing before this test.
      await _player.stop();
      if (savedQueue.isNotEmpty) {
        try {
          final restoreSource = await _sourceForSong(savedQueue[savedIndex]);
          if (restoreSource != null) {
            final restored = ConcatenatingAudioSource(children: [restoreSource]);
            await _player.setAudioSource(restored, initialIndex: 0, preload: false);
            await _player.seek(savedPos);
            if (wasPlaying) await _player.play();
          }
        } catch (_) {
          // Best-effort restore — if it fails, user can just hit play again.
        }
      }
      _queue = savedQueue;
      _currentIndex = savedIndex;
      onQueueChanged?.call();
    }
  }

  Future<AudioSource?> _sourceForSong(Song song, {bool fromLookahead = false}) async {
    if (song.isLocal) {
      final path = song.localPath!;
      final uri = path.startsWith('content://') || path.startsWith('file://')
          ? Uri.parse(path)
          : Uri.file(path);
      return AudioSource.uri(uri, tag: _songToMediaItem(song));
    }

    // Check lookahead cache first — populated at 70% of previous song
    final cachedUrl = _LookaheadCache.get(song.id);
    if (cachedUrl != null && !fromLookahead) {
      debugPrint('[AurumHandler] Lookahead HIT: "${song.title}"');
      _LookaheadCache.remove(song.id);
      return AudioSource.uri(
        Uri.parse(cachedUrl),
        tag: _songToMediaItem(song),
        headers: _kStreamHeaders,
      );
    }

    String? url;
    try {
      url = await ApiService.resolveStreamUrl(song)
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
    } catch (e) {
      debugPrint('[AurumHandler] resolveStreamUrl threw: \$e');
      return null;
    }
    if (url == null) return null;
    return AudioSource.uri(
      Uri.parse(url),
      tag: _songToMediaItem(song),
      headers: _kStreamHeaders,
    );
  }

  // ── Lookahead resolve — called at 70% of current song from PlayerProvider ──
  // Resolves next song URL in background and stores in _LookaheadCache.
  // If URL is already in ApiService's stream cache, this is near-instant.
  Future<void> lookaheadResolve(Song nextSong) async {
    if (nextSong.isLocal) return;
    if (_LookaheadCache.get(nextSong.id) != null) return; // already cached
    try {
      debugPrint('[AurumHandler] Lookahead resolving: "${nextSong.title}"');
      final url = await ApiService.resolveStreamUrl(nextSong)
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (url != null) {
        _LookaheadCache.put(nextSong.id, url);
        debugPrint('[AurumHandler] Lookahead cached: "${nextSong.title}"');
      }
    } catch (e) {
      debugPrint('[AurumHandler] Lookahead failed: $e');
    }
  }

  Future<void> _reapplySpeed() async {
    final p = await SharedPreferences.getInstance();
    await _player.setSpeed(p.getDouble('playback_speed') ?? 1.0);
  }

  // ─── MAIN PLAY ENTRY POINT ───────────────────────────────────────────────
  //
  // Strategy:
  //   1. Bump session ID — cancels any in-flight background resolver immediately.
  //   2. Stop player hard — guarantees old audio dies before new starts.
  //   3. Resolve only the clicked song URL (fast).
  //   4. Build a fresh ConcatenatingAudioSource with just that one song.
  //   5. setAudioSource → play → done. UI responds instantly.
  //   6. Background: resolve remaining songs and splice them in safely,
  //      always checking session ID so a subsequent tap cancels this work.

  Future<void> playQueue(List<Song> songs, int startIndex) async {
    // Debounce rapid taps — if already loading, cancel previous and take over
    _playSessionId++;
    final mySession = _playSessionId;
    _isLoadingNewSong = true;
    _restoredSilently = false; // user explicitly triggered playback

    // Set queue/index synchronously, before any async gap, so currentSong
    // reflects the tapped song the instant this function is called — the
    // UI doesn't have to wait for stop()/resolve() to see the new "now
    // playing" state.
    //
    // FIX: _currentIndex must match startIndex's position in `_queue`
    // (the full, original-order list) from the very first frame.
    // The player's OWN ConcatenatingAudioSource starts with just one
    // song at player-index 0 (see below), which is a SEPARATE notion
    // of "index" from this one — _currentIndex tracks position within
    // `_queue`/`songs`, not within the live player sequence. Setting
    // this to 0 unconditionally caused currentSong to point at the
    // wrong song whenever startIndex > 0 (i.e. any tap that wasn't the
    // first item in a playlist), and the desync only "resolved itself"
    // once the background prepend loop finished — which looked like
    // the song randomly changing mid-playback.
    _queue        = List<Song>.from(songs);
    _currentIndex = startIndex;
    _splicingInProgress = true; // raised until background splice finishes
    onQueueChanged?.call();

    try {
      // 1. Mute FIRST — `_player.setVolume(0)` is synchronous on the audio
      // sink and is genuinely instant. `_player.stop()` below is NOT: on
      // just_audio/ExoPlayer, stop() is handled on a native handler thread
      // and can take a noticeable beat to actually silence the output —
      // during that beat the OLD song kept audibly playing for a moment
      // (loading spinner showing, but old audio still bleeding through).
      // Muting first guarantees true zero-latency silence on every tap,
      // regardless of how long stop()/resolve() actually take.
      await _player.setVolume(0);

      // 2. Hard stop — old song's engine state is torn down
      await _player.stop();

      // Check if superseded by an even newer tap
      if (mySession != _playSessionId) { await _player.setVolume(1); _splicingInProgress = false; return; }

      // 3. Resolve clicked song
      final startSource = await _sourceForSong(songs[startIndex]);
      if (mySession != _playSessionId) { await _player.setVolume(1); _splicingInProgress = false; return; }
      if (startSource == null) {
        // Resolve failed — clear queue/notification so the UI doesn't keep
        // showing a song that never actually started playing.
        _queue = [];
        _currentIndex = 0;
        mediaItem.add(null);
        onQueueChanged?.call();
        onPlaybackError?.call('Resolve failed for "${songs[startIndex].title}" — '
            '_sourceForSong returned null (stream URL could not be resolved)');
        await _player.setVolume(1);
        _splicingInProgress = false;
        return;
      }

      // 4. Fresh single-song playlist — no placeholders, no auto-skip
      // preload:false prevents setAudioSource from hanging when the stream
      // URL is slow/unreachable — just_audio will buffer on demand instead.
      final fresh = ConcatenatingAudioSource(children: [startSource]);
      try {
        await _player.setAudioSource(fresh, initialIndex: 0, preload: false);
      } catch (e) {
        debugPrint('[AurumHandler] setAudioSource failed: $e'); // FIX: now works via flutter/foundation.dart
        final detail = e is PlayerException
            ? 'code=${e.code} message=${e.message}'
            : e.toString();
        onPlaybackError?.call('playQueue setAudioSource failed for '
            '"${songs[startIndex].title}": $detail');
        await _player.setVolume(1);
        _splicingInProgress = false;
        return;
      }
      if (mySession != _playSessionId) { await _player.setVolume(1); _splicingInProgress = false; return; }

      await _reapplySpeed();
      _updateMediaItem(songs[startIndex]);
      await _player.setVolume(1); // restore volume BEFORE play — avoids silent-start race
      await _player.play();

    } finally {
      if (mySession == _playSessionId) {
        _isLoadingNewSong = false;
      } else {
        // Superseded by a newer tap — ensure flag never stays stuck true
        _splicingInProgress = false;
        _isLoadingNewSong   = false;
      }
    }

    // 4. Background: build full queue without blocking playback
    _resolveQueueInBackground(songs, startIndex, mySession);
  }

  // Resolves all other songs and splices them into the live playlist.
  // Checks session ID at every async boundary — if user tapped a new song,
  // this entire routine exits silently without touching the player.
  void _resolveQueueInBackground(
      List<Song> songs, int startIndex, int sessionId) async {
    // FIX: outer try/finally ensures _splicingInProgress is ALWAYS cleared
    // even if an unhandled exception escapes the append or prepend loops.
    // Previously only the prepend loop had a finally, so a crash in the
    // append loop would leave the flag stuck true forever — causing
    // currentIndexStream to be ignored indefinitely and the UI to freeze.
    try {
      // --- Songs AFTER startIndex (append) ---
      for (int i = startIndex + 1; i < songs.length; i++) {
        if (sessionId != _playSessionId) return;
        try {
          final source = await _sourceForSong(songs[i]);
          if (sessionId != _playSessionId) return;
          if (source != null) {
            final seq = _player.audioSource;
            if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
              await seq.add(source);
            }
          }
        } catch (_) {}
      }

      // --- Songs BEFORE startIndex (prepend one by one, adjust index) ---
      // We insert in reverse so final order is correct.
      //
      // FIX: _currentIndex tracks position within `_queue` (already correct,
      // set to startIndex in playQueue) and must NOT be mutated here. What
      // actually shifts is the LIVE player's ConcatenatingAudioSource index
      // (it started with just one song at player-position 0), so we track
      // that separately as `playerIndex` and use it only for the seek call
      // that keeps just_audio's currentIndexStream pointed at the right
      // (still-playing) item while songs are spliced in before it.
      int playerIndex = 0;
      for (int i = startIndex - 1; i >= 0; i--) {
        if (sessionId != _playSessionId) return;
        try {
          final source = await _sourceForSong(songs[i]);
          if (sessionId != _playSessionId) return;
          if (source != null) {
            final seq = _player.audioSource;
            if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
              await seq.insert(0, source);
              playerIndex++;
              // Seek to same position in same song (player index shifted by 1)
              await _player.seek(_player.position, index: playerIndex);
            }
          }
        } catch (_) {}
      }
    } finally {
      // FIX: this finally now wraps BOTH loops (append + prepend).
      // Only the still-active session may lower the flag — a superseded
      // session must never clear a newer session's in-progress splice.
      if (sessionId == _playSessionId) _splicingInProgress = false;
    }
  }

  // ─── SILENT RESTORE (app reopened — show last queue, do NOT auto-play) ───
  // Used by main_shell's _restoreQueueIfNeeded. Unlike playQueue/playSong,
  // this never touches AudioSource/network/the player engine — it only
  // populates _queue/_currentIndex and the mediaItem/queue notifiers so the
  // UI and notification show the last session, fully paused/idle until the
  // user explicitly taps play.
  Future<void> loadQueueSilently(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;
    final index = startIndex.clamp(0, songs.length - 1);

    _playSessionId++; // invalidate any in-flight resolve from a previous session
    _splicingInProgress = false;
    _queue        = List<Song>.from(songs);
    _currentIndex = index;

    queue.add(_queue.map(_songToMediaItem).toList());
    _updateMediaItem(_queue[index]);
    onQueueChanged?.call();
    _restoredSilently = true; // prevent interruption-end from auto-playing
    // Deliberately no setAudioSource / no play() — nothing starts sounding.
  }

  // ─── SINGLE SONG (no queue context) ──────────────────────────────────────

  Future<void> playSong(Song song) async {
    _playSessionId++;
    final mySession = _playSessionId;
    _restoredSilently = false; // user explicitly triggered playback

    _queue        = [song];
    _currentIndex = 0;
    _splicingInProgress = false; // single-song queue, no splice phase
    onQueueChanged?.call();

    // Mute first — see playQueue for why stop() alone isn't instant enough.
    await _player.setVolume(0);
    await _player.stop();
    if (mySession != _playSessionId) { await _player.setVolume(1); return; }

    final source = await _sourceForSong(song);
    if (mySession != _playSessionId) { await _player.setVolume(1); return; }
    if (source == null) {
      // Resolve failed — don't leave the UI pointing at a song that never
      // actually started. Clear queue/notification so mini-player & full
      // player reflect reality instead of showing a "ghost" song.
      _queue = [];
      _currentIndex = 0;
      mediaItem.add(null);
      onQueueChanged?.call();
      onPlaybackError?.call('Resolve failed for "${song.title}" — '
          '_sourceForSong returned null (stream URL could not be resolved)');
      await _player.setVolume(1);
      return;
    }

    final fresh = ConcatenatingAudioSource(children: [source]);
    try {
      await _player.setAudioSource(fresh, initialIndex: 0, preload: false);
    } catch (e) {
      debugPrint('[AurumHandler] playSong setAudioSource failed: $e'); // FIX: now works via flutter/foundation.dart
      final detail = e is PlayerException
          ? 'code=${e.code} message=${e.message}'
          : e.toString();
      onPlaybackError?.call('playSong setAudioSource failed for '
          '"${song.title}": $detail');
      await _player.setVolume(1);
      return;
    }
    if (mySession != _playSessionId) { await _player.setVolume(1); return; }

    await _reapplySpeed();
    _updateMediaItem(song);
    await _player.setVolume(1); // restore volume BEFORE play
    await _player.play();
  }

  // ─── QUEUE MUTATIONS ──────────────────────────────────────────────────────

  Future<void> addToQueue(Song song) async {
    _queue.add(song);
    final source = await _sourceForSong(song);
    if (source == null) return;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.add(source);
  }

  Future<void> playNext(Song song) async {
    final insertIdx = _currentIndex + 1;
    _queue.insert(insertIdx, song);
    final source = await _sourceForSong(song);
    if (source == null) return;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.insert(insertIdx, source);
  }

  Future<void> removeFromQueue(int index) async {
    if (index >= _queue.length) return;
    _queue.removeAt(index);
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource && index < seq.length) {
      await seq.removeAt(index);
    }
  }

  Future<void> moveQueueItem(int from, int to) async {
    final song = _queue.removeAt(from);
    _queue.insert(to, song);
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.move(from, to);
  }

  Future<void> clearQueue() async {
    _playSessionId++; // cancel any background work
    _queue        = [];
    _currentIndex = 0;
    _splicingInProgress = false;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.clear();
    mediaItem.add(null);
  }

  // ─── GETTERS ──────────────────────────────────────────────────────────────

  List<Song> get currentQueue  => List.unmodifiable(_queue);
  Song?      get currentSong   => _queue.isNotEmpty ? _queue[_currentIndex] : null;
  int        get currentIndex  => _currentIndex;
  AudioPlayer get player       => _player;

  // ─── MEDIA ITEM ───────────────────────────────────────────────────────────

  void _updateMediaItem(Song song) => mediaItem.add(_songToMediaItem(song));

  MediaItem _songToMediaItem(Song song) => MediaItem(
        id:      song.id,
        title:   song.title,
        artist:  song.artist,
        album:   song.album,
        artUri:  song.artworkUrl.isNotEmpty ? Uri.parse(song.artworkUrl) : null,
        duration: song.duration != null ? Duration(seconds: song.duration!) : null,
      );

  // ─── PLAYBACK STATE BROADCAST ─────────────────────────────────────────────

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: {
        ProcessingState.idle:      AudioProcessingState.idle,
        ProcessingState.loading:   AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready:     AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing:          playing,
      updatePosition:   _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed:            _player.speed,
      queueIndex:       _currentIndex,
    ));
  }

  // ─── TRANSPORT CONTROLS ───────────────────────────────────────────────────

  @override Future<void> play() { _restoredSilently = false; return _player.play(); }
  @override Future<void> pause() => _player.pause();
  @override Future<void> stop()  => _player.stop();
  @override Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_currentIndex < _queue.length - 1) {
      await _player.seekToNext();
    } else if (_player.loopMode == LoopMode.all && _queue.isNotEmpty) {
      // Last song + repeat all → jump back to first
      await _player.seek(Duration.zero, index: 0);
      await _player.play();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
    } else if (_currentIndex > 0) {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _player.seek(Duration.zero, index: index);
    await _player.play();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        await _player.setLoopMode(LoopMode.off);
        break;
      case AudioServiceRepeatMode.one:
        await _player.setLoopMode(LoopMode.one);
        break;
      case AudioServiceRepeatMode.all:
        await _player.setLoopMode(LoopMode.all);
        break;
      default:
        break;
    }
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode != AudioServiceShuffleMode.none;
    await _player.setShuffleModeEnabled(enabled);
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  Future<void> disposeHandler() async {
    _shakeSub?.cancel();
    await _player.dispose();
  }
}
