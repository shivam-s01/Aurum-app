import 'dart:async';
import 'dart:io';
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
// Separate from ApiService's stream cache — stores the *resolved* stream URL
// so when the next song actually starts, we skip the entire resolve round-trip.
// Keyed by song.id, max 3 entries. Populated at 70% of current song.
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
// ROOT CAUSE OF "Source error code=0 / idle@0ms" — FIXED
// -----------------------------------------------------------------------
// On Android, just_audio's AudioSource.uri(..., headers: {...}) does NOT
// pass headers straight to ExoPlayer's HTTP data source. Instead it spins
// up a local loopback HTTP proxy (127.0.0.1) inside the app process.
//
// Our network_security_config.xml blocks cleartext to 127.0.0.1 — silently
// breaking every AudioSource built with a `headers:` map.
//
// FIX: never pass `headers:` to AudioSource.uri. The User-Agent is set
// once globally via AudioPlayer(userAgent: ...) which goes straight to
// ExoPlayer's DefaultHttpDataSource.Factory with no loopback proxy.
// =============================================================================

class AurumAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  // Single live player — `late final` restored (was incorrectly changed to
  // `late` mutable for the dual-player swap, which is now removed entirely).
  // See URL-ONLY PRELOAD section below for the correct fast-path architecture.
  late final AudioPlayer _player;

  // ── DSP ──────────────────────────────────────────────────────────────────
  AndroidEqualizer?        _eq;
  AndroidLoudnessEnhancer? _loudness;
  bool _eqReady = false;

  List<Song> _queue        = [];
  int        _currentIndex = 0;

  // Fired synchronously the instant _queue/_currentIndex change.
  void Function()? onQueueChanged;

  // Fired with the exact error string whenever a real playback attempt fails.
  void Function(String error)? onPlaybackError;

  // Cancellation token — each new playQueue/playSong call gets a fresh ID.
  int _playSessionId = 0;

  // Debounce rapid currentIndexStream events during song transitions.
  Timer? _indexDebounce;
  int?   _lastProcessedIndex;

  // Prevent concurrent playQueue calls from racing each other.
  bool _isLoadingNewSong = false;

  // True while _resolveQueueInBackground is still splicing songs.
  bool _splicingInProgress = false;

  // Set by loadQueueSilently — prevents interruption-end from auto-playing.
  bool _restoredSilently = false;

  // =============================================================================
  // URL-ONLY PRELOAD (replaces broken dual-player swap architecture)
  // -----------------------------------------------------------------------
  // The previous dual-player swap had fundamental, unfixable problems:
  //
  //   • setAudioSource() on the promoted player destroys all preload buffering.
  //     Buffered state lives in the native ExoPlayer instance and is NOT
  //     transferable. Calling setAudioSource() again — even with the same Dart
  //     AudioSource object — causes the native side to rebuild the MediaSource
  //     from scratch, making the preload a no-op.
  //
  //   • ConcatenatingAudioSource wrapping also re-prepares the native
  //     MediaSource, destroying buffering for the same reason.
  //
  //   • _nextPlayer had no DSP AudioPipeline — EQ/loudness silently stopped
  //     working after the first swap because the promoted player had no
  //     AndroidEqualizer or AndroidLoudnessEnhancer attached.
  //
  //   • Two ExoPlayer instances in the same process competed for AudioFocus,
  //     causing the live _player to receive AUDIOFOCUS_LOSS_TRANSIENT when
  //     _nextPlayer finished preloading, randomly pausing playback.
  //
  //   • AudioSession interruption/noisy subscriptions were anonymous — never
  //     stored, never cancelled. They leaked for the lifetime of the process.
  //
  //   • _nextPlayer.dispose() without stop() first could crash native ExoPlayer
  //     on some Android API levels when called during buffering.
  //
  // CORRECT ARCHITECTURE: resolve the next song's stream URL in background
  // and store it in _LookaheadCache. When skipToNext() fires, _sourceForSong()
  // gets a near-instant cache hit — playQueue() skips the 5-28s network
  // resolve and calls setAudioSource() immediately with the pre-resolved URL.
  // ExoPlayer starts buffering on setAudioSource(), so the perceived gap is
  // near-zero. No second AudioPlayer, no DSP detachment, no AudioFocus fight.
  // =============================================================================
  int     _preloadSessionId = 0;
  String? _preloadedSongId; // which song.id was last successfully URL-preloaded

  // AudioSession stream subscriptions — stored for cancellation on dispose.
  // FIX #7: were anonymous (leaked forever) previously.
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>?                  _noisySub;

  StreamSubscription<AccelerometerEvent>? _shakeSub;
  DateTime _lastShake = DateTime.now();
  // 24.0 avoids false positives from footstep impact while walking.
  static const double _shakeThreshold = 24.0;

  // Player stream subscriptions.
  StreamSubscription<PlaybackEvent>? _broadcastSub;
  StreamSubscription<PlaybackEvent>? _recoverySub;
  StreamSubscription<Duration?>?     _durationSub;
  StreamSubscription<int?>?          _currentIndexSub;

  AurumAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    // ── DSP pipeline setup ────────────────────────────────────────────────
    // Try to wire up Equalizer + LoudnessEnhancer via AudioPipeline.
    // Falls back to a plain AudioPlayer on older Android / emulators.
    try {
      _eq       = AndroidEqualizer();
      _loudness = AndroidLoudnessEnhancer();
      _player   = AudioPlayer(
        userAgent: 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
        audioPipeline: AudioPipeline(
          androidAudioEffects: [_loudness!, _eq!],
        ),
      );
      _eqReady = true;
    } catch (_) {
      _player = AudioPlayer(
        userAgent: 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
      );
      _eqReady = false;
    }

    await AudioPrefs.load();

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // FIX #7: store AudioSession subscriptions so they are cancelled on dispose.
    // Previously were anonymous — leaked for the process lifetime.
    _interruptionSub = session.interruptionEventStream.listen((event) {
      final isDuck = event.type == AudioInterruptionType.duck;

      if (isDuck && !AudioPrefs.duckOnNotifications) return;
      if (!isDuck && !AudioPrefs.pauseOnCall) return;

      if (event.begin) {
        _player.pause();
      } else {
        // FIX #24/#29: _isLoadingNewSong now set by both playQueue AND playSong
        // so this guard correctly blocks auto-resume during all load paths.
        if (!_restoredSilently && !_isLoadingNewSong) _player.play();
      }
    });

    _noisySub = session.becomingNoisyEventStream.listen((_) => _player.pause());

    _bindPlayerListeners();
    await _applySettings();
  }

  // ─── PLAYER LISTENERS ─────────────────────────────────────────────────────

  void _bindPlayerListeners() {
    _broadcastSub?.cancel();
    _recoverySub?.cancel();
    _durationSub?.cancel();
    _currentIndexSub?.cancel();

    // Broadcast state to audio_service (notification, lock screen).
    _broadcastSub = _player.playbackEventStream.listen(_broadcastState);

    // ── 403 / Expired stream recovery ────────────────────────────────────
    // JioSaavn CDN URLs expire ~50min. YouTube signed URLs expire faster.
    // Detects idle@>500ms, force-refreshes the URL, rebuilds AudioSource,
    // resumes at exact position.
    _recoverySub = _player.playbackEventStream.listen((event) async {
      if (event.processingState != ProcessingState.idle) return;
      final pos = _player.position;
      if (pos.inMilliseconds < 500) {
        // idle@~0ms is also a normal transient during AudioSource swaps.
        // Debounce 1200ms and only treat as real failure if still stuck.
        final songAtIdle = _queue.isNotEmpty && _currentIndex < _queue.length
            ? _queue[_currentIndex] : null;
        final sessionAtIdle = _playSessionId;

        await Future.delayed(const Duration(milliseconds: 1200));

        if (sessionAtIdle != _playSessionId) return;
        if (_isLoadingNewSong) return;
        if (_queue.isEmpty || _currentIndex >= _queue.length) return;
        final songNow = _queue[_currentIndex];
        if (songAtIdle == null || songNow.id != songAtIdle.id) return;
        if (_player.processingState != ProcessingState.idle) return;
        if (_player.position.inMilliseconds >= 500) return;

        final songTitle = songNow.title;
        debugPrint('[AurumHandler] FRESH-START FAILURE: processingState=idle '
            'at pos=${_player.position.inMilliseconds}ms, song=$songTitle');
        onPlaybackError?.call('Silent fresh-start failure for "$songTitle" — '
            'processingState went idle at position 0ms');
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

    _durationSub = _player.durationStream.listen((d) {
      if (d != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: d));
      }
    });

    _currentIndexSub = _player.currentIndexStream.listen((index) {
      if (index == null) return;

      // Capture session synchronously — the debounce timer checks a snapshot,
      // not the live value, avoiding the splice/timer race.
      final session = _playSessionId;

      _indexDebounce?.cancel();
      _indexDebounce = Timer(const Duration(milliseconds: 120), () {
        if (session != _playSessionId) return;
        if (_splicingInProgress) return;
        if (index == _lastProcessedIndex) return;
        _lastProcessedIndex = index;

        final sequence = _player.sequence;
        final inSourceRange = sequence != null && index < sequence.length;
        final tag = inSourceRange ? sequence[index].tag : null;

        if (tag is MediaItem) {
          if (mediaItem.value?.id != tag.id) {
            mediaItem.add(tag);
          }
          final queueIdx = _queue.indexWhere((s) => s.id == tag.id);
          if (queueIdx != -1 && queueIdx != _currentIndex) {
            _currentIndex = queueIdx;
          }
          return;
        }

        if (index != _currentIndex && index < _queue.length) {
          _currentIndex = index;
          _updateMediaItem(_queue[index]);
        }
      });
    });
  }

  Future<void> _applySettings() async {
    await AudioPrefs.load();
    final p = await SharedPreferences.getInstance();

    final speed = p.getDouble('playback_speed') ?? 1.0;
    await _player.setSpeed(speed);

    final shakeEnabled = p.getBool('shake_to_skip') ?? false;
    _updateShakeListener(shakeEnabled);

    if (!_eqReady) return;

    final bassBoost = p.getBool('bass_boost') ?? false;
    await _applyBassBoost(bassBoost);

    final volNorm = p.getBool('volume_normalization') ?? false;
    await _applyVolumeNorm(volNorm);

    await _applyEqBands(p);
  }

  Future<void> _applyBassBoost(bool enabled) async {
    if (!_eqReady || _eq == null) return;
    try {
      final params = await _eq!.parameters;
      final bands  = params.bands;
      final gainDb = enabled ? 6.0 : 0.0;
      for (int i = 0; i < bands.length && i < 3; i++) {
        await bands[i].setGain(gainDb);
      }
    } catch (_) {}
  }

  Future<void> _applyVolumeNorm(bool enabled) async {
    if (_loudness == null) return;
    try {
      await _loudness!.setEnabled(enabled);
      if (enabled) await _loudness!.setTargetGain(-14);
    } catch (_) {}
  }

  Future<void> _applyEqBands(SharedPreferences p) async {
    if (!_eqReady || _eq == null) return;
    try {
      bool hasCustom = false;
      for (int i = 0; i < 10; i++) {
        if ((p.getDouble('eq_band_$i') ?? 0.0) != 0.0) {
          hasCustom = true;
          break;
        }
      }
      if (!hasCustom) return;
      final params = await _eq!.parameters;
      final bands  = params.bands;
      for (int i = 0; i < bands.length && i < 10; i++) {
        await bands[i].setGain(p.getDouble('eq_band_$i') ?? 0.0);
      }
      await _eq!.setEnabled(true);
    } catch (_) {}
  }

  /// Called by EqualizerScreen / settings toggles to immediately apply DSP changes.
  Future<void> applyDsp() async => _applySettings();

  /// Expose EQ instance for EqualizerScreen slider access.
  AndroidEqualizer? get equalizer => _eqReady ? _eq : null;

  void _updateShakeListener(bool enabled) {
    _shakeSub?.cancel();
    _shakeSub = null;
    if (!enabled) return;
    _shakeSub = accelerometerEventStream().listen((event) {
      final magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      final now = DateTime.now();
      if (magnitude > _shakeThreshold && now.difference(_lastShake).inMilliseconds > 1500) {
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

  // ─── DIAGNOSTIC: REAL PLAYBACK TEST ──────────────────────────────────────

  Future<RealPlaybackResult> runRealPlaybackTest(Song testSong) async {
    final savedQueue   = List<Song>.from(_queue);
    final savedIndex   = _currentIndex;
    final wasPlaying   = _player.playing;
    final savedPos     = _player.position;
    // FIX #27: capture session before async work so the restore doesn't
    // stomp a newer user-initiated playback that started during the test.
    final savedSession = _playSessionId;

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
      // FIX #27: session guard — only restore if user didn't tap something new.
      if (savedSession == _playSessionId) {
        await _player.stop();
        if (savedQueue.isNotEmpty) {
          try {
            final restoreSource = await _sourceForSong(savedQueue[savedIndex]);
            if (restoreSource != null && savedSession == _playSessionId) {
              final restored = ConcatenatingAudioSource(children: [restoreSource]);
              await _player.setAudioSource(restored, initialIndex: 0, preload: false);
              await _player.seek(savedPos);
              if (wasPlaying) await _player.play();
            }
          } catch (_) {}
        }
        _queue = savedQueue;
        _currentIndex = savedIndex;
        onQueueChanged?.call();
      }
    }
  }

  // ─── SOURCE RESOLUTION ────────────────────────────────────────────────────

  Future<AudioSource?> _sourceForSong(Song song, {bool fromLookahead = false, int? sessionId}) async {
    if (song.isLocal) {
      try {
        final path = song.localPath!;
        final isUriString =
            path.startsWith('content://') || path.startsWith('file://');

        if (!isUriString) {
          final exists = await File(path).exists();
          if (!exists) {
            debugPrint('[AurumHandler] Local file missing: $path');
            return null;
          }
        }

        final uri = isUriString ? Uri.parse(path) : Uri.file(path);
        return AudioSource.uri(uri, tag: _songToMediaItem(song));
      } catch (e) {
        debugPrint('[AurumHandler] Failed to build local AudioSource: $e');
        return null;
      }
    }

    // Check lookahead cache. Skip for id:'' to avoid cross-song collisions.
    final cachedUrl = song.id.isEmpty ? null : _LookaheadCache.get(song.id);
    if (cachedUrl != null && !fromLookahead) {
      debugPrint('[AurumHandler] Lookahead HIT: "${song.title}"');
      _LookaheadCache.remove(song.id);
      return AudioSource.uri(Uri.parse(cachedUrl), tag: _songToMediaItem(song));
    }

    // YouTube chains through up to 4 fallback stages — needs more headroom.
    final resolveTimeout = song.source == SongSource.youtube
        ? const Duration(seconds: 28)
        : const Duration(seconds: 12);

    String? url;
    try {
      url = await ApiService.resolveStreamUrl(song)
          .timeout(resolveTimeout, onTimeout: () => null);
    } catch (e) {
      debugPrint('[AurumHandler] resolveStreamUrl threw: $e');
      return null;
    }
    if (url == null) return null;
    // FIX #14: session check always applied when sessionId provided —
    // including from preload-path callers.
    if (sessionId != null && sessionId != _playSessionId) return null;
    return AudioSource.uri(Uri.parse(url), tag: _songToMediaItem(song));
  }

  // ─── LOOKAHEAD RESOLVE ────────────────────────────────────────────────────
  // Called at 70% of current song from PlayerProvider.

  Future<void> lookaheadResolve(Song nextSong) async {
    // Also kick the URL-only preload path in parallel.
    _preloadNextSongUrl(nextSong);

    if (nextSong.isLocal) return;
    if (nextSong.id.isEmpty) return;
    if (_LookaheadCache.get(nextSong.id) != null) return;
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

  // ─── URL-ONLY PRELOAD ────────────────────────────────────────────────────
  // Resolves the next song's stream URL in background and stores it in
  // _LookaheadCache. When skipToNext() fires, _sourceForSong() gets a cache
  // hit and returns immediately — no network round trip needed.

  Future<void> _preloadNextSongUrl(Song? nextSong) async {
    if (nextSong == null) return;
    if (nextSong.isLocal) return; // local files resolve instantly, no preload needed
    if (nextSong.id.isEmpty) return;
    if (nextSong.id == _preloadedSongId) return; // already in cache

    final mySession = ++_preloadSessionId;
    _preloadedSongId = null;

    try {
      final url = await ApiService.resolveStreamUrl(nextSong)
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      if (mySession != _preloadSessionId) return;
      if (url == null) return;

      _LookaheadCache.put(nextSong.id, url);
      _preloadedSongId = nextSong.id;
      debugPrint('[AurumHandler] URL preload ready: "${nextSong.title}"');
    } catch (e) {
      debugPrint('[AurumHandler] URL preload failed (ignored): $e');
    }
  }

  void _kickOffUrlPreloadForUpcomingSong() {
    if (_queue.isEmpty) return;
    final nextIdx = _currentIndex + 1;
    if (nextIdx >= _queue.length) return;
    _preloadNextSongUrl(_queue[nextIdx]);
  }

  // Invalidate preload state if the song at _currentIndex+1 changed.
  void _invalidatePreloadIfStale() {
    if (_preloadedSongId == null) return;
    final nextIdx = _currentIndex + 1;
    final stillValid = nextIdx >= 0 &&
        nextIdx < _queue.length &&
        _queue[nextIdx].id == _preloadedSongId;
    if (!stillValid) {
      _preloadedSongId = null;
    }
  }

  Future<void> _reapplySpeed() async {
    final p = await SharedPreferences.getInstance();
    await _player.setSpeed(p.getDouble('playback_speed') ?? 1.0);
  }

  // ─── MAIN PLAY ENTRY POINT ───────────────────────────────────────────────

  Future<void> playQueue(List<Song> songs, int startIndex) async {
    _playSessionId++;
    _lastProcessedIndex = null;
    final mySession = _playSessionId;
    _isLoadingNewSong = true;
    _restoredSilently = false;

    // FIX #13: cancel in-flight URL preload on new play.
    _preloadSessionId++;
    _preloadedSongId = null;

    final safeIndex = songs.isEmpty
        ? 0
        : startIndex.clamp(0, songs.length - 1);
    _queue        = List<Song>.from(songs);
    _currentIndex = safeIndex;
    _splicingInProgress = true;
    onQueueChanged?.call();

    // FIX #25: keep AudioService queue BehaviorSubject in sync so lock-screen
    // queue display and assistant "next/previous" commands work correctly.
    queue.add(_queue.map(_songToMediaItem).toList());

    try {
      // 1. Mute first — setVolume(0) is synchronous on the audio sink.
      await _player.setVolume(0);

      // 2. pause() flushes ExoPlayer's buffered PCM frames immediately,
      //    then stop() tears down the engine state (ghost-audio fix).
      await _player.pause();
      await _player.stop();
      await Future.microtask(() {});

      if (mySession != _playSessionId) { await _player.setVolume(1); _splicingInProgress = false; return; }

      // 3. Resolve the clicked song. If URL preload already stored the URL
      //    in _LookaheadCache, this returns near-instantly.
      var startSource = await _sourceForSong(songs[safeIndex], sessionId: mySession);
      if (mySession != _playSessionId) { await _player.setVolume(1); _splicingInProgress = false; return; }
      if (startSource == null) {
        debugPrint('[AurumHandler] playQueue resolve failed, retrying once: "${songs[safeIndex].title}"');
        await Future.delayed(const Duration(milliseconds: 600));
        if (mySession != _playSessionId) { await _player.setVolume(1); _splicingInProgress = false; return; }
        startSource = await _sourceForSong(songs[safeIndex], sessionId: mySession);
        if (mySession != _playSessionId) { await _player.setVolume(1); _splicingInProgress = false; return; }
      }
      if (startSource == null) {
        _queue = [];
        _currentIndex = 0;
        mediaItem.add(null);
        queue.add([]);
        onQueueChanged?.call();
        onPlaybackError?.call('Resolve failed for "${songs[safeIndex].title}" — '
            'stream URL could not be resolved');
        await _player.setVolume(1);
        _splicingInProgress = false;
        return;
      }

      // 4. Fresh single-song playlist. preload:false avoids blocking on
      //    slow/unreachable URLs.
      final fresh = ConcatenatingAudioSource(children: [startSource]);
      try {
        await _player.setAudioSource(fresh, initialIndex: 0, preload: false);
      } catch (e) {
        debugPrint('[AurumHandler] setAudioSource failed: $e');
        final detail = e is PlayerException
            ? 'code=${e.code} message=${e.message}'
            : e.toString();
        onPlaybackError?.call('playQueue setAudioSource failed for '
            '"${songs[safeIndex].title}": $detail');
        await _player.setVolume(1);
        _splicingInProgress = false;
        return;
      }
      if (mySession != _playSessionId) { await _player.setVolume(1); _splicingInProgress = false; return; }

      await _reapplySpeed();
      _updateMediaItem(songs[safeIndex]);
      await _player.setVolume(1); // restore volume BEFORE play
      await _player.play();

      // Kick off URL preload for the next song so skipToNext() is instant.
      _kickOffUrlPreloadForUpcomingSong();

    } catch (e) {
      debugPrint('[AurumHandler] playQueue unexpected error: $e');
      onPlaybackError?.call('playQueue failed for "${songs[safeIndex].title}": $e');
      try { await _player.setVolume(1); } catch (_) {}
      _splicingInProgress = false;
    } finally {
      if (mySession == _playSessionId) {
        _isLoadingNewSong = false;
      } else {
        _splicingInProgress = false;
        _isLoadingNewSong   = false;
      }
    }
    _resolveQueueInBackground(songs, safeIndex, mySession);
  }

  // Resolves remaining songs and splices into the live ConcatenatingAudioSource.
  // FIX #26: Future<void> (not void) so unhandled errors don't escape to zone.
  Future<void> _resolveQueueInBackground(
      List<Song> songs, int startIndex, int sessionId) async {
    try {
      // --- Songs AFTER startIndex (append) ---
      for (int i = startIndex + 1; i < songs.length; i++) {
        if (sessionId != _playSessionId) return;
        try {
          final source = await _sourceForSong(songs[i], sessionId: sessionId);
          if (sessionId != _playSessionId) return;
          if (source != null) {
            final seq = _player.audioSource;
            if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
              await seq.add(source);
            }
          }
        } catch (_) {}
      }

      // --- Songs BEFORE startIndex (prepend in reverse, track playerIndex) ---
      int playerIndex = 0;
      for (int i = startIndex - 1; i >= 0; i--) {
        if (sessionId != _playSessionId) return;
        try {
          final source = await _sourceForSong(songs[i], sessionId: sessionId);
          if (sessionId != _playSessionId) return;
          if (source != null) {
            final seq = _player.audioSource;
            if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
              await seq.insert(0, source);
              playerIndex++;
              await _player.seek(_player.position, index: playerIndex);
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[AurumHandler] _resolveQueueInBackground unexpected error: $e');
    } finally {
      if (sessionId == _playSessionId) _splicingInProgress = false;
    }
  }

  // ─── SILENT RESTORE ───────────────────────────────────────────────────────

  Future<void> loadQueueSilently(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;
    final index = startIndex.clamp(0, songs.length - 1);

    _playSessionId++;
    // FIX #13: also cancel preload on silent restore.
    _preloadSessionId++;
    _preloadedSongId = null;
    _splicingInProgress = false;
    _queue        = List<Song>.from(songs);
    _currentIndex = index;

    queue.add(_queue.map(_songToMediaItem).toList());
    _updateMediaItem(_queue[index]);
    onQueueChanged?.call();
    _restoredSilently = true;
  }

  // ─── SINGLE SONG ──────────────────────────────────────────────────────────

  Future<void> playSong(Song song) async {
    _playSessionId++;
    _lastProcessedIndex = null;
    final mySession = _playSessionId;
    _restoredSilently = false;

    // FIX #13: cancel in-flight preload.
    _preloadSessionId++;
    _preloadedSongId = null;

    _queue        = [song];
    _currentIndex = 0;
    _splicingInProgress = false;
    onQueueChanged?.call();
    queue.add([_songToMediaItem(song)]);

    try {
      // FIX #29: set _isLoadingNewSong here too — previously only playQueue
      // set this flag, so interruption-end could auto-resume during playSong's
      // setAudioSource() load window.
      _isLoadingNewSong = true;

      await _player.setVolume(0);
      await _player.pause();
      await _player.stop();
      await Future.microtask(() {});
      if (mySession != _playSessionId) { await _player.setVolume(1); return; }

      var source = await _sourceForSong(song);
      if (mySession != _playSessionId) { await _player.setVolume(1); return; }
      if (source == null) {
        debugPrint('[AurumHandler] playSong resolve failed, retrying once: "${song.title}"');
        await Future.delayed(const Duration(milliseconds: 600));
        if (mySession != _playSessionId) { await _player.setVolume(1); return; }
        source = await _sourceForSong(song);
        if (mySession != _playSessionId) { await _player.setVolume(1); return; }
      }
      if (source == null) {
        _queue = [];
        _currentIndex = 0;
        mediaItem.add(null);
        queue.add([]);
        onQueueChanged?.call();
        onPlaybackError?.call('Resolve failed for "${song.title}" — '
            'stream URL could not be resolved, or the local file is missing');
        await _player.setVolume(1);
        return;
      }

      final fresh = ConcatenatingAudioSource(children: [source]);
      try {
        await _player.setAudioSource(fresh, initialIndex: 0, preload: false);
      } catch (e) {
        debugPrint('[AurumHandler] playSong setAudioSource failed: $e');
        final detail = e is PlayerException
            ? 'code=${e.code} message=${e.message}'
            : e.toString();
        onPlaybackError?.call('playSong setAudioSource failed for "${song.title}": $detail');
        await _player.setVolume(1);
        return;
      }
      if (mySession != _playSessionId) { await _player.setVolume(1); return; }

      await _reapplySpeed();
      _updateMediaItem(song);
      await _player.setVolume(1);
      await _player.play();
    } catch (e) {
      debugPrint('[AurumHandler] playSong unexpected error: $e');
      onPlaybackError?.call('playSong failed for "${song.title}": $e');
      try { await _player.setVolume(1); } catch (_) {}
    } finally {
      // FIX #29: always clear in finally regardless of path taken.
      if (mySession == _playSessionId) _isLoadingNewSong = false;
    }
  }

  // ─── QUEUE MUTATIONS ──────────────────────────────────────────────────────

  Future<void> addToQueue(Song song) async {
    final session = _playSessionId;
    _queue.add(song);
    // FIX #12: addToQueue now invalidates stale preload (was missing previously).
    _invalidatePreloadIfStale();
    final source = await _sourceForSong(song, sessionId: session);
    if (source == null) return;
    if (session != _playSessionId) return;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.add(source);
    // FIX #25: keep AudioService queue in sync after mutation.
    queue.add(_queue.map(_songToMediaItem).toList());
  }

  Future<void> playNext(Song song) async {
    final session = _playSessionId;
    final insertIdx = _currentIndex + 1;
    _queue.insert(insertIdx, song);
    _invalidatePreloadIfStale();
    final source = await _sourceForSong(song, sessionId: session);
    if (source == null) return;
    if (session != _playSessionId) return;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.insert(insertIdx, source);
    queue.add(_queue.map(_songToMediaItem).toList());
  }

  Future<void> removeFromQueue(int index) async {
    if (index >= _queue.length) return;
    _queue.removeAt(index);
    _invalidatePreloadIfStale();
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource && index < seq.length) {
      await seq.removeAt(index);
    }
    queue.add(_queue.map(_songToMediaItem).toList());
  }

  Future<void> moveQueueItem(int from, int to) async {
    final song = _queue.removeAt(from);
    _queue.insert(to, song);
    _invalidatePreloadIfStale();
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.move(from, to);
    queue.add(_queue.map(_songToMediaItem).toList());
  }

  Future<void> clearQueue() async {
    _playSessionId++;
    _preloadSessionId++;
    _preloadedSongId = null;
    _queue        = [];
    _currentIndex = 0;
    _splicingInProgress = false;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.clear();
    mediaItem.add(null);
    queue.add([]);
  }

  // ─── GETTERS ──────────────────────────────────────────────────────────────

  List<Song> get currentQueue => List.unmodifiable(_queue);

  Song? get currentSong {
    if (_queue.isEmpty || _currentIndex < 0 || _currentIndex >= _queue.length) {
      return null;
    }
    return _queue[_currentIndex];
  }
  int         get currentIndex => _currentIndex;
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
    // FIX #30: null-safe fallback instead of `!` force-unwrap — future
    // just_audio versions adding new ProcessingState values won't crash here.
    final ps = {
      ProcessingState.idle:      AudioProcessingState.idle,
      ProcessingState.loading:   AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering,
      ProcessingState.ready:     AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    }[_player.processingState] ?? AudioProcessingState.idle;

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
      processingState:  ps,
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

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('[Aurum] _player.stop() failed (ignored): $e');
    }
  }

  @override Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    // URL-only preload means _LookaheadCache already has the next song's URL.
    // playQueue() → _sourceForSong() gets a cache hit → near-instant start.
    final seq     = _player.sequence;
    final liveLen = seq?.length ?? 0;
    final livePos = _player.currentIndex ?? 0;

    if (livePos < liveLen - 1) {
      await _player.seekToNext();
      await _player.play();
    } else if (_player.loopMode == LoopMode.all && liveLen > 0) {
      await _player.seek(Duration.zero, index: 0);
      await _player.play();
    } else if (!_splicingInProgress && _currentIndex < _queue.length - 1) {
      // Live sequence exhausted but queue has more — recover via playQueue.
      await playQueue(_queue, _currentIndex + 1);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
    } else {
      final livePos = _player.currentIndex ?? 0;
      if (livePos > 0) {
        await _player.seekToPrevious();
      } else if (_currentIndex > 0) {
        await playQueue(_queue, _currentIndex - 1);
      }
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource && index < seq.length) {
      await _player.seek(Duration.zero, index: index);
      await _player.play();
    } else if (index < _queue.length) {
      await playQueue(_queue, index);
    }
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
    _indexDebounce?.cancel();
    _shakeSub?.cancel();
    _broadcastSub?.cancel();
    _recoverySub?.cancel();
    _durationSub?.cancel();
    _currentIndexSub?.cancel();
    // FIX #7: cancel AudioSession subscriptions — were leaked previously.
    _interruptionSub?.cancel();
    _noisySub?.cancel();
    await _player.dispose();
  }
}

// ─── RESULT TYPE ──────────────────────────────────────────────────────────────

class RealPlaybackResult {
  final bool    success;
  final int     positionMs;
  final String  processingState;
  final String? errorMessage;

  const RealPlaybackResult({
    required this.success,
    required this.positionMs,
    required this.processingState,
    this.errorMessage,
  });
}
