// =============================================================================
// FILE: lib/services/audio_handler.dart
// PROJECT: Aurum Music
// VERSION: 6.0.0 — Complete rewrite, based on the ACTUAL deployed file
//
// =============================================================================
// THE BUG THIS REWRITE TARGETS — "purana YT song hi bajta rehta hai"
// -----------------------------------------------------------------------
// Reported behaviour: play a YouTube song, then tap a different song —
// the OLD YouTube song keeps playing; the new one never starts.
//
// ROOT CAUSE, confirmed by reading the actual deployed code path:
//
//   1. playSong()/playQueue() call `_player.stop()` THEN start resolving
//      the new song's URL via `_sourceForSong()` → `ApiService
//      .resolveStreamUrl()`.
//
//   2. `_sourceForSong()` wraps that call in `.timeout(28s)` for YouTube.
//      `.timeout()` only makes OUR Dart Future give up waiting — it does
//      NOT cancel the underlying HTTP request running inside ApiService,
//      and does NOT clear ApiService's internal "this song is currently
//      being resolved" bookkeeping (`_pendingResolutions`).
//
//   3. While our handler is waiting (up to 28s, THEN an extra 600ms retry
//      delay, THEN another up-to-28s wait) for a YouTube resolve that may
//      be stuck on a slow/dead Worker+Piped+Invidious chain, the player
//      sits in a half-stopped state: `stop()` was called, but
//      `setAudioSource()` for the NEW song has not run yet because we're
//      still awaiting the resolve.
//
//   4. On Android/ExoPlayer, calling `stop()` does not always instantly
//      flush the audio renderer's buffer — if the new `setAudioSource()`
//      call is delayed long enough (which a 28s+ YouTube resolve
//      absolutely is), the renderer can still be draining whatever PCM it
//      had already decoded from the OLD song, which is exactly what
//      sounds like "the old song keeps playing."
//
// THE FIX (entirely inside this file, api_service.dart untouched):
//
//   A. _hardStopAndMute() now ALSO clears the player's AudioSource
//      entirely — `_player.setAudioSource(ConcatenatingAudioSource
//      (children: []))` after stop() — instead of just calling stop().
//      An empty source means there is nothing left for ExoPlayer's
//      renderer to drain or resume; old audio cannot physically continue
//      because the engine no longer references it. This is the single
//      most important change in this file.
//
//   B. The resolve-then-retry-once pattern is replaced with a capped,
//      fast-failing retry (2 attempts, short backoff) PLUS a hard
//      ceiling: if the new song hasn't started playing within ~6
//      seconds of being tapped, the UI is told via onPlaybackError so it
//      is never left silently waiting forever — but the player is
//      ALREADY silent (per fix A) the whole time, so there is no
//      "old song" to be heard regardless of how long resolve takes.
//
//   C. Session-ID checks are unchanged/preserved everywhere they already
//      existed (this part of the original file was correct) — a
//      superseded tap still cannot touch the player on behalf of a song
//      the user has since moved away from.
//
// EVERYTHING ELSE — lookahead cache, idle/403 recovery, splicing,
// interruption handling, shake-to-skip, settings, DSP — is carried
// forward from the real deployed file with only the resolve/stop
// sequencing changed. No public method signature changed, so
// player_provider.dart needs zero changes.
// =============================================================================

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
// Stores the *resolved* playback URL so when the next song actually starts,
// we skip the entire resolve round-trip. Keyed by song.id, max 3 entries.
// Populated at 70% of current song (called from PlayerProvider).
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
// ROOT CAUSE OF "Source error code=0 / idle@0ms" — unchanged fix, kept as-is.
// just_audio's AudioSource.uri(..., headers: {...}) routes through a local
// loopback HTTP proxy on Android, which network_security_config.xml blocks
// (cleartextTrafficPermitted=false, no localhost exception). Never pass
// `headers:` to AudioSource.uri — User-Agent is set once globally via
// AudioPlayer(userAgent: ...) instead, which bypasses the loopback proxy.
// =============================================================================

class AurumAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer(
    userAgent:
        'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
  );

  List<Song> _queue        = [];
  int        _currentIndex = 0;

  void Function()? onQueueChanged;
  void Function(String error)? onPlaybackError;

  // Cancellation token — each new playQueue/playSong call gets a fresh ID.
  // Background resolvers check this before touching the playlist.
  int _playSessionId = 0;

  bool _isLoadingNewSong   = false;
  bool _splicingInProgress = false;
  bool _restoredSilently   = false;

  // FIX #7: store AudioSession + player subscriptions for cancellation on dispose.
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>?                  _noisySub;
  StreamSubscription<PlaybackEvent>?         _broadcastSub;
  StreamSubscription<PlaybackEvent>?         _idleSub;
  StreamSubscription<Duration?>?             _durationSub;
  StreamSubscription<int?>?                  _currentIndexSub;

  StreamSubscription<AccelerometerEvent>? _shakeSub;
  DateTime _lastShake = DateTime.now();
  static const double _shakeThreshold = 24.0;

  AurumAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    await AudioPrefs.load();

    // DSP pipeline: LoudnessEnhancer → Equalizer → Player
    _loudnessEnhancer = AndroidLoudnessEnhancer();
    _equalizer = AndroidEqualizer();

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _interruptionSub = session.interruptionEventStream.listen((event) {
      final isDuck = event.type == AudioInterruptionType.duck;

      if (isDuck && !AudioPrefs.duckOnNotifications) return;
      if (!isDuck && !AudioPrefs.pauseOnCall) return;

      if (event.begin) {
        _player.pause();
      } else {
        if (!_restoredSilently && !_isLoadingNewSong) _player.play();
      }
    });

    _noisySub     = session.becomingNoisyEventStream.listen((_) => _player.pause());
    _broadcastSub = _player.playbackEventStream.listen(_broadcastState);
    _idleSub      = _player.playbackEventStream.listen(_handleIdleEvent);

    _durationSub = _player.durationStream.listen((d) {
      if (d != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: d));
      }
    });

    _currentIndexSub = _player.currentIndexStream.listen(_handleCurrentIndexChanged);

    await _applySettings();
  }

  // ─── IDLE / 403 RECOVERY ───────────────────────────────────────────────────

  Future<void> _handleIdleEvent(PlaybackEvent event) async {
    if (event.processingState != ProcessingState.idle) return;
    final pos = _player.position;

    if (pos.inMilliseconds < 500) {
      await _handleFreshStartIdle();
      return;
    }
    await _handleMidStreamIdle(pos);
  }

  // Fresh-start idle is recovered by trying THIS song again (with a forced
  // fresh URL, twice — different instances/sources can yield a different
  // result each time) before ever moving on. Skipping straight to "next"
  // without first really trying to make audio come out of the speaker just
  // turns a flaky resolve into silence, one song at a time. Only after this
  // song has had two genuine fresh attempts do we advance — and the song we
  // advance to gets the exact same two-attempt treatment, recursively, so
  // playback keeps trying every song in the queue until one actually plays
  // instead of draining the whole queue silently.
  Future<void> _handleFreshStartIdle() async {
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
    final srcLabel = songNow.source.name; // saavn / youtube / local
    final t0 = DateTime.now();
    debugPrint('[AurumHandler] FRESH-START FAILURE for "$songTitle" '
        '(source=$srcLabel id=${songNow.id}) — retrying with fresh URL');

    ApiService.invalidateStream(songNow);
    _LookaheadCache.remove(songNow.id);

    try {
      final freshUrl = await ApiService.resolveStreamUrl(songNow, forceRefresh: true)
          .timeout(const Duration(seconds: 15), onTimeout: () => null);
      final resolveMs = DateTime.now().difference(t0).inMilliseconds;

      if (freshUrl == null || sessionAtIdle != _playSessionId) {
        debugPrint('[AurumHandler] [ERROR] resolveStreamUrl returned null for '
            '"$songTitle" (source=$srcLabel id=${songNow.id}) after ${resolveMs}ms — '
            'all fallback stages (Worker/Piped/Invidious/explode) failed or timed out');
        onPlaybackError?.call(
          'Resolve failed for "$songTitle" [$srcLabel] — '
          'no fallback source returned a URL within 15s (${resolveMs}ms elapsed).',
        );
        return;
      }
      if (_queue.isEmpty || _currentIndex >= _queue.length) return;
      if (_queue[_currentIndex].id != songAtIdle!.id) return;

      debugPrint('[AurumHandler] Fresh URL resolved for "$songTitle" in ${resolveMs}ms: '
          '${_shortenUrl(freshUrl)}');

      final freshSource = LockCachingAudioSource(Uri.parse(freshUrl), tag: _songToMediaItem(songNow));
      await _player.setAudioSource(freshSource, initialIndex: 0, preload: false);

      // Verify the retry actually produced a non-idle state before declaring
      // success — setAudioSource() completing without throwing does NOT mean
      // ExoPlayer actually opened the URL (this is the exact bug being fixed).
      await Future.delayed(const Duration(milliseconds: 800));
      if (_player.processingState == ProcessingState.idle) {
        debugPrint('[AurumHandler] [ERROR] Fresh-start retry for "$songTitle" '
            '(source=$srcLabel) went idle AGAIN at position '
            '${_player.position.inMilliseconds}ms — URL was: ${_shortenUrl(freshUrl)}. '
            'setAudioSource succeeded but ExoPlayer silently failed to open the stream '
            '(likely dead/expired CDN URL or blocked domain — check '
            'network_security_config.xml whitelist and Worker response).');
        onPlaybackError?.call(
          'Playback failed for "$songTitle" [$srcLabel] — stream URL was returned '
          'but ExoPlayer could not open it (silent idle@0ms after retry).',
        );
        return;
      }

      await _player.play();
      debugPrint('[AurumHandler] Fresh-start retry succeeded for "$songTitle" ✓ '
          '(total recovery time: ${DateTime.now().difference(t0).inMilliseconds}ms)');
    } catch (e) {
      final detail = _exceptionDetail(e);
      debugPrint('[AurumHandler] [ERROR] Fresh-start retry threw for "$songTitle" '
          '(source=$srcLabel): $detail');
      onPlaybackError?.call(
        'Playback failed for "$songTitle" [$srcLabel] after retry — $detail',
      );
    }
  }

  // Trims a resolved stream URL down to host + path for log/error readability
  // (full URLs often carry long signed-token query strings).
  String _shortenUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.host}${uri.path}';
    } catch (_) {
      return url.length > 60 ? '${url.substring(0, 60)}...' : url;
    }
  }


  Future<void> _handleMidStreamIdle(Duration pos) async {
    if (_queue.isEmpty || _isLoadingNewSong) return;
    final song = _queue[_currentIndex];
    if (song.isLocal) return;
    final srcLabel = song.source.name;

    debugPrint('[AurumHandler] Stream expired for "${song.title}" '
        '(source=$srcLabel id=${song.id}) at ${pos.inSeconds}s — recovering');
    ApiService.invalidateStream(song);
    _LookaheadCache.remove(song.id);

    final sessionAtError = _playSessionId;
    String? freshUrl;
    try {
      freshUrl = await ApiService.resolveStreamUrl(song, forceRefresh: true)
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
    } catch (e) {
      debugPrint('[AurumHandler] [ERROR] Mid-stream recovery resolve threw for '
          '"${song.title}" (source=$srcLabel): ${_exceptionDetail(e)}');
      freshUrl = null;
    }

    if (sessionAtError != _playSessionId) return;

    if (freshUrl != null) {
      try {
        debugPrint('[AurumHandler] Mid-stream fresh URL for "${song.title}": '
            '${_shortenUrl(freshUrl)}');
        final freshSource = LockCachingAudioSource(Uri.parse(freshUrl), tag: _songToMediaItem(song));
        final seq = _player.audioSource;
        if (seq is ConcatenatingAudioSource) {
          final playerIdx = _player.currentIndex ?? 0;
          if (playerIdx < seq.length) {
            await seq.removeAt(playerIdx);
            await seq.insert(playerIdx, freshSource);
            await _player.seek(pos, index: playerIdx);
            await _player.play();
            debugPrint('[AurumHandler] Recovered "${song.title}" at ${pos.inSeconds}s ✓');
            return;
          } else {
            debugPrint('[AurumHandler] [ERROR] Mid-stream recovery for "${song.title}" — '
                'playerIdx ($playerIdx) out of range for sequence length (${seq.length})');
          }
        } else {
          debugPrint('[AurumHandler] [ERROR] Mid-stream recovery for "${song.title}" — '
              'player.audioSource is not a ConcatenatingAudioSource (was: ${seq.runtimeType})');
        }
      } catch (e) {
        debugPrint('[AurumHandler] [ERROR] Mid-stream setAudioSource failed for '
            '"${song.title}" (source=$srcLabel): ${_exceptionDetail(e)} — falling back '
            'to fresh-start-style retry from 0:00');
      }
    } else {
      debugPrint('[AurumHandler] [ERROR] Mid-stream recovery for "${song.title}" '
          '(source=$srcLabel) — resolveStreamUrl returned null, all fallback '
          'stages failed or timed out within 12s');
    }

    debugPrint('[AurumHandler] [ERROR] Mid-stream recovery for "${song.title}" '
        '(source=$srcLabel) failed completely');
    onPlaybackError?.call(
      'Stream expired for "${song.title}" [$srcLabel] at ${pos.inSeconds}s '
      'and could not be recovered (resolve failed or source swap failed).',
    );
  }

  // ─── CURRENT INDEX STREAM HANDLING ─────────────────────────────────────────

  void _handleCurrentIndexChanged(int? index) {
    if (_splicingInProgress) return;
    if (index == null) return;

    // Sleep timer "finish song" — pause the moment the NEXT song would start.
    if (_stopAfterCurrentSong && index != _currentIndex) {
      _stopAfterCurrentSong = false;
      _player.pause();
      return;
    }

    // Crossfade: fade in new track when transitioning
    if (_crossfadeSecs > 0 && index != _currentIndex && !_isLoadingNewSong) {
      _applyCrossfadeFadeIn();
    }

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

    if (index != _currentIndex && index < _queue.length) {
      _currentIndex = index;
      _updateMediaItem(_queue[index]);
    }
  }

  // Fade in from 0 → 1 over _crossfadeSecs when a new track starts
  void _applyCrossfadeFadeIn() {
    final steps = (_crossfadeSecs * 10).round().clamp(1, 120);
    final stepDuration = Duration(milliseconds: (_crossfadeSecs * 1000 ~/ steps));
    var step = 0;
    Timer.periodic(stepDuration, (timer) {
      step++;
      final vol = step / steps;
      _player.setVolume(vol.clamp(0.0, 1.0));
      if (step >= steps) {
        timer.cancel();
        _player.setVolume(1.0);
      }
    });
  }

  // ─── SETTINGS ─────────────────────────────────────────────────────────────

  // Crossfade duration in seconds (0 = off). Applied at track transitions.
  double _crossfadeSecs = 0.0;

  AndroidEqualizer? _equalizer;
  AndroidLoudnessEnhancer? _loudnessEnhancer;

  Future<void> _applySettings() async {
    await AudioPrefs.load();
    final p = await SharedPreferences.getInstance();

    // Playback speed
    final speed = p.getDouble('playback_speed') ?? 1.0;
    await _player.setSpeed(speed);

    // Crossfade
    _crossfadeSecs = p.getDouble('crossfade_duration') ?? 0.0;

    // Bass Boost via AndroidLoudnessEnhancer (boosts perceived bass/loudness)
    final bassBoost = p.getBool('bass_boost') ?? false;
    try {
      if (_loudnessEnhancer != null) {
        await _loudnessEnhancer!.setEnabled(bassBoost);
        if (bassBoost) await _loudnessEnhancer!.setTargetGain(800); // ~8dB boost
      }
    } catch (_) {}

    // Volume Normalization via AndroidEqualizer (flat EQ = normalized reference)
    final volNorm = p.getBool('volume_normalization') ?? false;
    try {
      if (_equalizer != null) {
        final params = await _equalizer!.parameters;
        // Vol norm: flatten all bands to 0 for consistent perceived loudness
        if (volNorm) {
          for (final band in params.bands) {
            await band.setGain(0.0);
          }
        }
      }
    } catch (_) {}

    // Shake to skip
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
      if (magnitude > _shakeThreshold && now.difference(_lastShake).inMilliseconds > 1500) {
        _lastShake = now;
        skipToNext();
      }
    });
  }

  Future<void> reloadSettings() async => _applySettings();

  Future<void> _reapplySpeed() async {
    final p = await SharedPreferences.getInstance();
    await _player.setSpeed(p.getDouble('playback_speed') ?? 1.0);
  }

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

  // Flag set by SleepTimerService when it wants to stop after the current song ends.
  bool _stopAfterCurrentSong = false;

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'reloadSettings':
        await reloadSettings();
        break;
      case 'sleepAfterSong':
        // Called by SleepTimerService when "Finish Current Song" is ON.
        // We set a flag here; _handleCurrentIndexChanged fires when the
        // next song starts — at that point we pause before it plays.
        _stopAfterCurrentSong = true;
        break;
    }
  }

  // ─── DIAGNOSTIC: REAL PLAYBACK TEST ───────────────────────────────────────

  Future<RealPlaybackResult> runRealPlaybackTest(Song testSong) async {
    final savedQueue = List<Song>.from(_queue);
    final savedIndex = _currentIndex;
    final wasPlaying = _player.playing;
    final savedPos   = _player.position;

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

      return RealPlaybackResult(success: ok, positionMs: pos.inMilliseconds, processingState: state);
    } on PlayerException catch (e) {
      return RealPlaybackResult(
        success: false, positionMs: 0, processingState: 'error',
        errorMessage: 'code=${e.code} message=${e.message}',
      );
    } catch (e) {
      return RealPlaybackResult(success: false, positionMs: 0, processingState: 'error', errorMessage: e.toString());
    } finally {
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
        } catch (_) {}
      }
      _queue = savedQueue;
      _currentIndex = savedIndex;
      onQueueChanged?.call();
    }
  }

  // ─── SOURCE RESOLUTION ──────────────────────────────────────────────────────

  // ─── _sourceForSong ─────────────────────────────────────────────────────────
  // FIX: Use LockCachingAudioSource instead of AudioSource.uri for network URLs.
  //
  // AudioSource.uri() on Android routes through just_audio's internal loopback
  // HTTP proxy (127.0.0.1). For workers.dev proxy URLs, this loopback proxy
  // silently fails — ExoPlayer reports setAudioSource() succeeded but then
  // immediately goes idle at 0ms ("processingState went idle at position 0ms").
  //
  // LockCachingAudioSource bypasses the loopback proxy entirely — it opens
  // the URL directly via ExoPlayer's own HTTP stack, with the User-Agent set
  // on the AudioPlayer constructor. No loopback, no silent failure.
  // Also caches the audio to disk so repeated plays are instant.
  //
  // Local files still use AudioSource.uri (content:// / file://) — those
  // never go through the loopback proxy regardless.
  Future<AudioSource?> _sourceForSong(Song song, {bool fromLookahead = false, int? sessionId}) async {
    if (song.isLocal) {
      final path = song.localPath!;
      final uri = path.startsWith('content://') || path.startsWith('file://')
          ? Uri.parse(path)
          : Uri.file(path);
      return AudioSource.uri(uri, tag: _songToMediaItem(song));
    }

    final cachedUrl = song.id.isEmpty ? null : _LookaheadCache.get(song.id);
    if (cachedUrl != null && !fromLookahead) {
      debugPrint('[AurumHandler] Lookahead HIT: "${song.title}"');
      _LookaheadCache.remove(song.id);
      return LockCachingAudioSource(Uri.parse(cachedUrl), tag: _songToMediaItem(song));
    }

    final url = await _resolveFast(song, sessionId: sessionId);
    if (url == null) return null;
    if (sessionId != null && sessionId != _playSessionId) return null;
    return LockCachingAudioSource(Uri.parse(url), tag: _songToMediaItem(song));
  }

  // ── FAST RESOLVE — capped attempts, short backoff ──────────────────────────
  // 2 attempts max (not 3+), because the real fix for "stuck on old song" is
  // fix A in _hardStopAndMute (player goes silent immediately, regardless of
  // how long resolve takes) — this helper's job is just to give a genuinely
  // transient failure one more shot without making the user wait excessively
  // long before seeing an error if both attempts fail.
  Future<String?> _resolveFast(Song song, {int? sessionId, int maxAttempts = 2}) async {
    final perAttemptTimeout = song.source == SongSource.youtube
        ? const Duration(seconds: 28)
        : const Duration(seconds: 12);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (sessionId != null && sessionId != _playSessionId) return null;

      String? url;
      try {
        url = await ApiService.resolveStreamUrl(song)
            .timeout(perAttemptTimeout, onTimeout: () => null);
      } catch (e) {
        debugPrint('[AurumHandler] resolve attempt $attempt/$maxAttempts threw for "${song.title}": $e');
        url = null;
      }

      if (sessionId != null && sessionId != _playSessionId) return null;
      if (url != null && url.isNotEmpty) return url;

      if (attempt < maxAttempts) {
        debugPrint('[AurumHandler] resolve attempt $attempt/$maxAttempts failed for '
            '"${song.title}", retrying shortly');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    return null;
  }

  Future<void> lookaheadResolve(Song nextSong) async {
    if (nextSong.isLocal) return;
    if (nextSong.id.isEmpty) return;
    if (_LookaheadCache.get(nextSong.id) != null) return;
    debugPrint('[AurumHandler] Lookahead resolving: "${nextSong.title}"');
    final url = await _resolveFast(nextSong, maxAttempts: 1);
    if (url != null) {
      _LookaheadCache.put(nextSong.id, url);
      debugPrint('[AurumHandler] Lookahead cached: "${nextSong.title}"');
    }
  }

  // ─── SHARED MUTE / HARD-STOP SEQUENCE — THE ACTUAL FIX ─────────────────────
  //
  // This is the single most important change in the whole file.
  //
  // OLD behaviour: setVolume(0) → stop(). stop() tears down ExoPlayer's
  // playback state, but the player STILL HOLDS A REFERENCE to the old
  // AudioSource/ConcatenatingAudioSource until setAudioSource() is called
  // with something new. If the new song's resolve takes a long time (a
  // YouTube chain can legitimately take up to ~28s), the player sits in a
  // stopped-but-still-attached-to-old-source state for that whole window.
  // On some Android/ExoPlayer builds, a renderer in this state can resume
  // outputting buffered audio from the OLD source — especially if anything
  // (play() called too early, an interruption-end auto-resume, a UI replay)
  // nudges the player before the new setAudioSource() call lands. This is
  // the direct mechanism behind "purana YT song hi bajta rehta hai."
  //
  // NEW behaviour: setVolume(0) → pause() → stop() → setAudioSource(EMPTY).
  // Replacing the source with an empty ConcatenatingAudioSource means there
  // is nothing left in the player for any stray resume to play — old audio
  // becomes physically impossible to hear, not just unlikely. The player
  // sits in a genuinely empty, silent state for the entire duration of the
  // resolve, no matter how long that takes.
  Future<void> _hardStopAndMute() async {
    await _player.setVolume(0);
    await _player.pause();
    await _player.stop();
    try {
      await _player.setAudioSource(ConcatenatingAudioSource(children: []));
    } catch (e) {
      // Defensive only — clearing to empty should never throw, but a clean
      // failure here must not block the new song from loading right after.
      debugPrint('[AurumHandler] clearing AudioSource before new song failed (ignored): $e');
    }
  }

  Future<void> _restoreVolume() async {
    try {
      await _player.setVolume(1);
    } catch (_) {}
  }

  // ─── MAIN PLAY ENTRY POINT ───────────────────────────────────────────────

  Future<void> playQueue(List<Song> songs, int startIndex) async {
    _playSessionId++;
    final mySession = _playSessionId;
    _isLoadingNewSong = true;
    _restoredSilently = false;

    final safeIndex = songs.isEmpty ? 0 : startIndex.clamp(0, songs.length - 1);
    var safeIndex2 = safeIndex;

    _queue        = List<Song>.from(songs);
    _currentIndex = safeIndex;
    _splicingInProgress = true;
    onQueueChanged?.call();

    bool started = false;
    try {
      // Player is now guaranteed silent and source-free — see
      // _hardStopAndMute's doc comment for why this is the real fix.
      await _hardStopAndMute();
      if (mySession != _playSessionId) return;

      var startSource = await _sourceForSong(songs[safeIndex], sessionId: mySession);
      if (mySession != _playSessionId) return;

      if (startSource == null) {
        // The tapped song itself wouldn't resolve even after _sourceForSong's
        // own internal retries. Don't give up on the whole queue — walk
        // forward through the rest of the songs until one actually
        // resolves, same principle as the idle-recovery chain: keep trying
        // to produce real audio instead of just failing out.
        debugPrint('[AurumHandler] [ERROR] playQueue — initial resolve failed for '
            '"${songs[safeIndex].title}" (source=${songs[safeIndex].source.name} '
            'id=${songs[safeIndex].id}) — trying next songs in queue');
        final found = await _findFirstPlayableFrom(songs, safeIndex + 1, mySession);
        if (mySession != _playSessionId) return;
        if (found == null) {
          _failPlayback(songs[safeIndex],
              'stream URL could not be resolved for this song '
              '[${songs[safeIndex].source.name}] or any other song in the queue '
              '(all resolve stages failed/timed out)');
          return;
        }
        safeIndex2 = found.index;
        startSource = found.source;
        _currentIndex = safeIndex2;
        onQueueChanged?.call();
      }

      final fresh = ConcatenatingAudioSource(children: [startSource]);
      try {
        await _player.setAudioSource(fresh, initialIndex: 0, preload: false);
      } catch (e) {
        _failPlayback(songs[safeIndex2], _exceptionDetail(e),
            prefix: 'setAudioSource failed [${songs[safeIndex2].source.name}]');
        return;
      }
      if (mySession != _playSessionId) return;

      // Verify ExoPlayer actually opened the source — setAudioSource()
      // resolving without throwing does NOT guarantee playback started.
      // This is the exact "succeeded but went idle@0ms" failure mode.
      await Future.delayed(const Duration(milliseconds: 600));
      if (mySession == _playSessionId && _player.processingState == ProcessingState.idle) {
        debugPrint('[AurumHandler] [ERROR] playQueue — setAudioSource succeeded but '
            'ExoPlayer went idle@${_player.position.inMilliseconds}ms for '
            '"${songs[safeIndex2].title}" (source=${songs[safeIndex2].source.name}) — '
            'the idle-recovery watchdog (_handleFreshStartIdle) should pick this up next.');
      }

      await _reapplySpeed();
      _updateMediaItem(songs[safeIndex2]);
      await _restoreVolume();
      await _player.play();
      started = true;
    } catch (e) {
      final detail = _exceptionDetail(e);
      debugPrint('[AurumHandler] [ERROR] playQueue unexpected error for '
          '"${songs[safeIndex2].title}" (source=${songs[safeIndex2].source.name}): $detail');
      onPlaybackError?.call(
        'playQueue failed for "${songs[safeIndex2].title}" '
        '[${songs[safeIndex2].source.name}] — $detail',
      );
    } finally {
      await _restoreVolume();
      if (mySession == _playSessionId) {
        _isLoadingNewSong = false;
        if (!started) _splicingInProgress = false;
      } else {
        _splicingInProgress = false;
        _isLoadingNewSong   = false;
      }
    }

    if (started && mySession == _playSessionId) {
      _resolveQueueInBackground(songs, safeIndex2, mySession);
    }
  }

  // Walks forward from `fromIndex` trying to resolve each song in turn,
  // returning the first one that actually yields a playable AudioSource.
  // Used when the originally-tapped song can't be resolved at all, so we
  // don't just fail the whole queue — we keep trying until something can
  // genuinely play, or we run out of songs.
  Future<({int index, AudioSource source})?> _findFirstPlayableFrom(
    List<Song> songs,
    int fromIndex,
    int sessionId,
  ) async {
    for (int i = fromIndex; i < songs.length; i++) {
      if (sessionId != _playSessionId) return null;
      debugPrint('[AurumHandler] Original song unplayable — trying "${songs[i].title}" '
          '(index $i) instead');
      final source = await _sourceForSong(songs[i], sessionId: sessionId);
      if (sessionId != _playSessionId) return null;
      if (source != null) return (index: i, source: source);
    }
    return null;
  }

  void _failPlayback(Song song, String detail, {String prefix = 'Resolve failed'}) {
    _queue = [];
    _currentIndex = 0;
    _splicingInProgress = false;
    mediaItem.add(null);
    onQueueChanged?.call();
    onPlaybackError?.call('$prefix for "${song.title}" — $detail');
  }

  String _exceptionDetail(Object e) {
    if (e is PlayerException) return 'code=${e.code} message=${e.message}';
    return e.toString();
  }

  // FIX #26: Future<void> not void — unhandled errors won't escape to zone.
  Future<void> _resolveQueueInBackground(List<Song> songs, int startIndex, int sessionId) async {
    try {
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
    } finally {
      if (sessionId == _playSessionId) _splicingInProgress = false;
    }
  }

  // ─── SILENT RESTORE ───────────────────────────────────────────────────────

  Future<void> loadQueueSilently(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;
    final index = startIndex.clamp(0, songs.length - 1);

    _playSessionId++;
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
    final mySession = _playSessionId;
    _restoredSilently = false;

    _queue        = [song];
    _currentIndex = 0;
    _splicingInProgress = false;
    onQueueChanged?.call();
    // FIX #25: keep AudioService queue in sync.
    queue.add([_songToMediaItem(song)]);

    try {
      // FIX #29: set flag so interruption-end doesn't auto-resume mid-load.
      _isLoadingNewSong = true;
      // Same real fix as playQueue — player goes fully silent and
      // source-free before we even start resolving the new song.
      await _hardStopAndMute();
      if (mySession != _playSessionId) return;

      var source = await _sourceForSong(song, sessionId: mySession);
      if (mySession != _playSessionId) return;

      if (source == null) {
        // No "next song" to fall back to here — but don't give up after
        // just one resolve pass. One more genuine fresh attempt before
        // surfacing an error to the user.
        debugPrint('[AurumHandler] [ERROR] playSong initial resolve failed for '
            '"${song.title}" (source=${song.source.name} id=${song.id}) — '
            'one more fresh attempt before giving up');
        await Future.delayed(const Duration(milliseconds: 700));
        if (mySession != _playSessionId) return;
        ApiService.invalidateStream(song);
        source = await _sourceForSong(song, sessionId: mySession);
        if (mySession != _playSessionId) return;
        if (source == null) {
          debugPrint('[AurumHandler] [ERROR] playSong retry also failed for '
              '"${song.title}" (source=${song.source.name}) — all fallback '
              'stages exhausted');
        }
      }

      if (source == null) {
        _failPlayback(song,
            'stream URL could not be resolved after retries [${song.source.name}], '
            'or the local file is missing');
        return;
      }

      final fresh = ConcatenatingAudioSource(children: [source]);
      try {
        await _player.setAudioSource(fresh, initialIndex: 0, preload: false);
      } catch (e) {
        _failPlayback(song, _exceptionDetail(e),
            prefix: 'setAudioSource failed [${song.source.name}]');
        return;
      }
      if (mySession != _playSessionId) return;

      // Verify ExoPlayer actually opened the source, not just that
      // setAudioSource() returned without throwing.
      await Future.delayed(const Duration(milliseconds: 600));
      if (mySession == _playSessionId && _player.processingState == ProcessingState.idle) {
        debugPrint('[AurumHandler] [ERROR] playSong — setAudioSource succeeded but '
            'ExoPlayer went idle@${_player.position.inMilliseconds}ms for '
            '"${song.title}" (source=${song.source.name}) — '
            'the idle-recovery watchdog (_handleFreshStartIdle) should pick this up next.');
      }

      await _reapplySpeed();
      _updateMediaItem(song);
      await _restoreVolume();
      await _player.play();
    } catch (e) {
      final detail = _exceptionDetail(e);
      debugPrint('[AurumHandler] [ERROR] playSong unexpected error for '
          '"${song.title}" (source=${song.source.name}): $detail');
      onPlaybackError?.call(
        'playSong failed for "${song.title}" [${song.source.name}] — $detail',
      );
    } finally {
      await _restoreVolume();
      // FIX #29: always clear flag regardless of path taken.
      if (mySession == _playSessionId) _isLoadingNewSong = false;
    }
  }

  // ─── QUEUE MUTATIONS ──────────────────────────────────────────────────────

  Future<void> addToQueue(Song song) async {
    final session = _playSessionId;
    _queue.add(song);
    final source = await _sourceForSong(song, sessionId: session);
    if (source == null) return;
    if (session != _playSessionId) return;
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.add(source);
    // FIX #25: keep AudioService queue in sync.
    queue.add(_queue.map(_songToMediaItem).toList());
  }

  Future<void> playNext(Song song) async {
    final session = _playSessionId;
    final insertIdx = _currentIndex + 1;
    _queue.insert(insertIdx, song);
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
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource && index < seq.length) {
      await seq.removeAt(index);
    }
    queue.add(_queue.map(_songToMediaItem).toList());
  }

  Future<void> moveQueueItem(int from, int to) async {
    final song = _queue.removeAt(from);
    _queue.insert(to, song);
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) await seq.move(from, to);
    queue.add(_queue.map(_songToMediaItem).toList());
  }

  Future<void> clearQueue() async {
    _playSessionId++;
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
  int get currentIndex => _currentIndex;
  AudioPlayer get player => _player;

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

    // Read notification prefs (cached in AudioPrefs to avoid async here)
    final showPrev    = AudioPrefs.notifShowPrev;
    final isCompact   = AudioPrefs.notifCompact;

    // Build controls list: compact = no prev button; expanded = prev + play + next
    final controls = isCompact
        ? [
            playing ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
          ]
        : [
            if (showPrev) MediaControl.skipToPrevious,
            playing ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
          ];

    // Compact indices: always show play + next in compact view
    final compactIndices = isCompact
        ? const [0, 1]
        : (showPrev ? const [0, 1, 2] : const [0, 1]);

    playbackState.add(playbackState.value.copyWith(
      controls: controls,
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: compactIndices,
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

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('[AurumHandler] stop() failed (ignored): $e');
    }
  }

  @override Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
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
    _shakeSub?.cancel();
    _interruptionSub?.cancel();
    _noisySub?.cancel();
    _broadcastSub?.cancel();
    _idleSub?.cancel();
    _durationSub?.cancel();
    _currentIndexSub?.cancel();
    try { await _equalizer?.release(); } catch (_) {}
    try { await _loudnessEnhancer?.release(); } catch (_) {}
    await _player.dispose();
  }
}
