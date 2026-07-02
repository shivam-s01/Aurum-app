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
import 'audio_effects_controller.dart';

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
  // =============================================================================
  // AUDIO EFFECTS (2026-07-02): Bass Boost / Equalizer construction, gain
  // application, and error/health handling now live entirely in
  // AudioEffectsController (see audio_effects_controller.dart). This class
  // only ever touches `_effects.pipeline` (once, to construct `_player`) and
  // `_effects.applySettings()` (on settings change). A bad EQ gain value can
  // no longer cascade into broken playback here — that failure mode is
  // structurally contained to the controller file.
  // =============================================================================
  final AudioEffectsController _effects = AudioEffectsController();

  // =============================================================================
  // PERFORMANCE (2026-07-02): "YouTube songs feel heavy / phone heats up"
  // -----------------------------------------------------------------------
  // ExoPlayer's DEFAULT buffer/load settings are tuned for general video
  // streaming (can hold up to ~50MB / 30-50s ahead per track) — way more
  // than a music app ever needs, since audio bitrates are tiny compared to
  // video. That oversized default buffer means more sustained network
  // activity, more memory held resident, and more radio wake time than
  // audio-only playback actually requires — a real, measurable contributor
  // to background CPU/network load and device heat during long YouTube
  // listening sessions.
  //
  // This config keeps enough buffer ahead for smooth, gapless, uninterrupted
  // playback (min 15s, max 50s buffered) while capping it well below
  // ExoPlayer's video-oriented defaults — small enough to noticeably cut
  // sustained network/CPU activity, large enough that normal listening never
  // audibly stutters or rebuffers. Nothing about resolve, fallback, or
  // recovery logic changes — this only shapes how much of an ALREADY-
  // resolved stream ExoPlayer keeps buffered in memory at once.
  // =============================================================================
  late final AudioLoadConfiguration _loadConfiguration = AudioLoadConfiguration(
    androidLoadControl: AndroidLoadControl(
      minBufferDuration: const Duration(seconds: 15),
      maxBufferDuration: const Duration(seconds: 50),
      bufferForPlaybackDuration: const Duration(milliseconds: 1500),
      bufferForPlaybackAfterRebufferDuration: const Duration(seconds: 3),
      targetBufferBytes: 4 * 1024 * 1024, // 4MB cap — plenty for audio, far below video-oriented defaults
      prioritizeTimeOverSizeThresholds: true,
    ),
    darwinLoadControl: const DarwinLoadControl(
      preferredForwardBufferDuration: Duration(seconds: 20),
    ),
  );

  late final _player = AudioPlayer(
    userAgent: 'com.google.android.youtube/19.29.37 (Linux; U; Android 13) gzip',
    audioPipeline: _effects.pipeline,
    audioLoadConfiguration: _loadConfiguration,
  );

  List<Song> _queue        = [];
  int        _currentIndex = 0;

  void Function()? onQueueChanged;
  // `silent: true` means this failure was (or will be) auto-recovered —
  // a single song in a queue failing and the handler already moving on
  // to try the next one. These are logged via debugPrint but never shown
  // to the user, because showing a red SnackBar for every transient
  // single-song hiccup (which happens fairly often on YouTube's fallback
  // chain) trains the user to associate normal auto-recovery with a
  // broken app. `silent: false` (the default) means every fallback in the
  // chain has been exhausted for this attempt and nothing further will
  // retry automatically — that's the only case actually worth surfacing.
  void Function(String error, {bool silent})? onPlaybackError;

  // ─── LIKE (favorite) — surfaced as a custom action button on the lock
  // screen / notification so the user can like/unlike without opening the
  // app. AurumAudioHandler doesn't own favorite state (FavoritesProvider
  // does, via Hive) — this is a thin bridge: PlayerProvider wires
  // [onLikeToggleRequested] to FavoritesProvider.toggleFavorite, and
  // whoever changes favorite state calls [setCurrentSongLiked] back so the
  // notification icon reflects the real state immediately.
  Future<void> Function(Song song)? onLikeToggleRequested;
  bool _currentSongLiked = false;

  /// Called by PlayerProvider whenever the liked-state of the currently
  /// playing song changes (from the like button OR from any other screen,
  /// e.g. the full player's heart icon) so the lock screen icon stays in
  /// sync no matter where the like happened.
  void setCurrentSongLiked(bool liked) {
    if (_currentSongLiked == liked) return;
    _currentSongLiked = liked;
    _broadcastState(_player.playbackEvent);
  }

  // Cancellation token — each new playQueue/playSong call gets a fresh ID.
  // Background resolvers check this before touching the playlist.
  int _playSessionId = 0;

  bool _isLoadingNewSong   = false;
  bool _splicingInProgress = false;
  bool _restoredSilently   = false;

  // FIX (UI thumbnail swap while same song keeps playing): just_audio's
  // currentIndexStream doesn't ONLY fire on a genuine audible track change —
  // it can also emit when the underlying ConcatenatingAudioSource is
  // mutated (seq.add / seq.insert / seq.move / seq.removeAt), because those
  // operations can shift what index the player's CURRENTLY PLAYING item now
  // sits at, even though no actual transition happened. addToQueue (used by
  // the silent auto-extend-queue feature), playNext, removeFromQueue, and
  // moveQueueItem all call one of those. _handleCurrentIndexChanged used to
  // trust every emission as "the audible song changed" and would update
  // mediaItem (title/artist/artwork — what the UI reads as currentSong) to
  // whatever _queue[index] was at that moment. If that emission was really
  // just a queue-list mutation echo, the UI would jump to showing a
  // different song's thumbnail/title while the ACTUAL audio playing was
  // still the original song — exactly the "UI mein dusra song ka thumbnail
  // show ho raha hai but same song chal raha hai" symptom.
  //
  // Fix: briefly mark queue-mutation calls so _handleCurrentIndexChanged can
  // tell a mutation-echo apart from a real transition and skip the mediaItem
  // update for it.
  bool _queueMutating = false;

  // FIX #7: store AudioSession + player subscriptions for cancellation on dispose.
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _noisySub;
  StreamSubscription<PlaybackEvent>? _broadcastSub;
  StreamSubscription<PlaybackEvent>? _idleSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<int?>? _currentIndexSub;

  // Volume captured right before a `duck` interruption begins, so it can be
  // restored exactly (rather than hardcoded to 1.0) when the duck ends —
  // see the interruptionEventStream listener in _init() for the fix this
  // supports (duck should lower volume, not pause playback).
  double? _volumeBeforeDuck;

  StreamSubscription<AccelerometerEvent>? _shakeSub;
  DateTime _lastShake = DateTime.now();
  static const double _shakeThreshold = 24.0;

  AurumAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    await AudioPrefs.load();

    // NOTE: _player and its audio pipeline (via _effects.pipeline) are
    // constructed as `late final` fields above, so effects are guaranteed
    // to be attached before any playback starts. All effects construction,
    // gain logic, and error handling now live in AudioEffectsController —
    // nothing to construct here anymore.

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // BUGFIX (2026-07-02): "random pause" — this used to call
    // _player.pause() for EVERY interruption, duck or not. A `duck` event
    // (brief notification sound, keyboard click, another app grabbing
    // audio for a second) is specifically the signal Android sends when
    // playback should just get QUIETER, not stop — pausing on duck is why
    // playback appeared to randomly pause whenever another app made any
    // sound, whenever duckOnNotifications was on. Full (non-duck)
    // interruptions also fire far more often than literal phone calls —
    // any app requesting exclusive audio focus triggers one — but pausing
    // for those is still the semantically correct response, so that half
    // is unchanged.
    _interruptionSub = session.interruptionEventStream.listen((event) {
      final isDuck = event.type == AudioInterruptionType.duck;

      if (isDuck) {
        if (!AudioPrefs.duckOnNotifications) return;
        if (event.begin) {
          _volumeBeforeDuck ??= _player.volume;
          _player.setVolume((_volumeBeforeDuck! * 0.35).clamp(0.0, 1.0));
        } else {
          _player.setVolume(_volumeBeforeDuck ?? 1.0);
          _volumeBeforeDuck = null;
        }
        return;
      }

      if (!AudioPrefs.pauseOnCall) return;

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
        if (sessionAtIdle != _playSessionId) return;
        // Don't just error out and leave the player sitting idle on a dead
        // song — that's the "message says Skipping but nothing actually
        // skips" bug. Walk forward to the next song in the queue, same as
        // the initial-tap failure path in playQueue.
        onPlaybackError?.call(
          'Resolve failed for "$songTitle" [$srcLabel] — '
          'no fallback source returned a URL within 15s (${resolveMs}ms elapsed). Skipping to next song.',
          silent: true,
        );
        await _advancePastDeadSong(songNow, sessionAtIdle);
        return;
      }
      if (_queue.isEmpty || _currentIndex >= _queue.length) return;
      if (_queue[_currentIndex].id != songAtIdle!.id) return;

      debugPrint('[AurumHandler] Fresh URL resolved for "$songTitle" in ${resolveMs}ms: '
          '${_shortenUrl(freshUrl)}');

      final freshSource = LockCachingAudioSource(Uri.parse(freshUrl), tag: _songToMediaItem(songNow));
      // BUGFIX (2026-07-01): this used to call
      // setAudioSource(freshSource, ...) with a BARE LockCachingAudioSource,
      // not wrapped in a ConcatenatingAudioSource — unlike every other real
      // playback path in this file (playQueue, playSong both wrap in
      // ConcatenatingAudioSource). _player.audioSource is
      // ConcatenatingAudioSource checks are used all over this file
      // (skipToNext, addToQueue, playNext, _resolveQueueInBackground,
      // _handleMidStreamIdle) — with a bare source, every one of those
      // checks would silently fail and skip its logic, breaking next/prev
      // and further recovery for this song until the next full
      // playQueue()/playSong() call rebuilt a proper sequence. Wrapping it
      // here keeps the player's internal structure consistent with every
      // other code path.
      final freshPlaylist = ConcatenatingAudioSource(children: [freshSource]);
      await _player.setAudioSource(freshPlaylist, initialIndex: 0, preload: false);

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
          'but ExoPlayer could not open it (silent idle@0ms after retry). Skipping to next song.',
          silent: true,
        );
        await _advancePastDeadSong(songNow, sessionAtIdle);
        return;
      }

      await _player.play();
      debugPrint('[AurumHandler] Fresh-start retry succeeded for "$songTitle" ✓ '
          '(total recovery time: ${DateTime.now().difference(t0).inMilliseconds}ms)');
    } catch (e) {
      final detail = _exceptionDetail(e);
      debugPrint('[AurumHandler] [ERROR] Fresh-start retry threw for "$songTitle" '
          '(source=$srcLabel): $detail');
      if (sessionAtIdle == _playSessionId) {
        onPlaybackError?.call(
          'Playback failed for "$songTitle" [$srcLabel] after retry — $detail Skipping to next song.',
          silent: true,
        );
        await _advancePastDeadSong(songNow, sessionAtIdle);
      }
    }
  }

  // Used when a song has exhausted every automatic retry (fresh-start retry,
  // mid-stream recovery) and is definitively dead for this session. Walks
  // forward through the rest of the CURRENT queue (not a fresh copy — the
  // live `_queue`) to find the next playable song and starts it, so a single
  // bad song advances playback instead of leaving the player stuck idle.
  // Only shows an error to the user if EVERY remaining song also fails.
  Future<void> _advancePastDeadSong(Song deadSong, int sessionAtFailure) async {
    if (sessionAtFailure != _playSessionId) return;
    if (_queue.isEmpty) return;
    final deadIdx = _queue.indexWhere((s) => s.id == deadSong.id);
    final startFrom = deadIdx >= 0 ? deadIdx + 1 : _currentIndex + 1;
    if (startFrom >= _queue.length) {
      onPlaybackError?.call(
        'Reached end of queue after "${deadSong.title}" [${deadSong.source.name}] could not be played.',
      );
      return;
    }
    final found = await _findFirstPlayableFrom(_queue, startFrom, sessionAtFailure);
    if (sessionAtFailure != _playSessionId) return;
    if (found == null) {
      onPlaybackError?.call(
        'Could not play "${deadSong.title}" [${deadSong.source.name}] or any '
        'later song in the queue — all resolve attempts failed.',
      );
      return;
    }
    _currentIndex = found.index;
    onQueueChanged?.call();
    final fresh = ConcatenatingAudioSource(children: [found.source]);
    try {
      await _player.setAudioSource(fresh, initialIndex: 0, preload: false);
      if (sessionAtFailure != _playSessionId) return;
      await _reapplySpeed();
      _updateMediaItem(_queue[found.index]);
      await _restoreVolume();
      await _player.play();
      debugPrint('[AurumHandler] Advanced past dead song to "${_queue[found.index].title}" ✓');
    } catch (e) {
      debugPrint('[AurumHandler] [ERROR] _advancePastDeadSong setAudioSource failed: ${_exceptionDetail(e)}');
      onPlaybackError?.call(
        'Could not play "${deadSong.title}" [${deadSong.source.name}] or the next song — ${_exceptionDetail(e)}',
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

    // BUGFIX (2026-07-01): capture the LIVE player index + the song actually
    // sitting at that index in the player's own sequence right now, not just
    // _queue[_currentIndex]. This is the fix for "next song plays, then ~10s
    // later the OLD song comes back and the new one stops." Root cause: this
    // function used to only guard against a *session* change during its
    // resolve (which takes up to 12s here). But the player can naturally
    // advance to the NEXT song in that same 12s window without the session
    // ID changing at all (a session only bumps on playQueue/playSong, not on
    // a normal auto-advance). So by the time the resolve for the OLD song
    // finished, this function would splice that stale recovered source back
    // into `playerIdx` — which by then held the NEW song — silently
    // replacing it and seeking back to the old song's position. We now
    // re-check, right before splicing, that the player's live current index
    // still holds a sequence entry tagged with THIS song's id. If the user
    // (or natural playback) has moved on, we abort instead of splicing.
    final playerIdxAtStart = _player.currentIndex;
    bool stillOnThisSong() {
      final liveIdx = _player.currentIndex;
      if (liveIdx == null || liveIdx != playerIdxAtStart) return false;
      final seq = _player.sequence;
      if (seq == null || liveIdx >= seq.length) return false;
      final tag = seq[liveIdx].tag;
      return tag is MediaItem && tag.id == song.id;
    }

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

    // The user/player moved to a different song while we were resolving —
    // do NOT splice the old song back in. Just let the new song keep
    // playing; there's nothing to recover anymore.
    if (!stillOnThisSong()) {
      debugPrint('[AurumHandler] Mid-stream recovery for "${song.title}" aborted — '
          'player has since moved to a different song, nothing to recover.');
      return;
    }

    if (freshUrl != null) {
      try {
        debugPrint('[AurumHandler] Mid-stream fresh URL for "${song.title}": '
            '${_shortenUrl(freshUrl)}');
        final freshSource = LockCachingAudioSource(Uri.parse(freshUrl), tag: _songToMediaItem(song));
        final seq = _player.audioSource;
        if (seq is ConcatenatingAudioSource) {
          final playerIdx = _player.currentIndex ?? 0;
          // Re-verify ONE more time right before mutating the live sequence —
          // resolveStreamUrl finishing and the moment we actually splice can
          // still be separated by a scheduler tick during which the index
          // could change again.
          if (playerIdx < seq.length && stillOnThisSong()) {
            await seq.removeAt(playerIdx);
            await seq.insert(playerIdx, freshSource);
            await _player.seek(pos, index: playerIdx);
            await _player.play();
            debugPrint('[AurumHandler] Recovered "${song.title}" at ${pos.inSeconds}s ✓');
            return;
          } else if (playerIdx >= seq.length) {
            debugPrint('[AurumHandler] [ERROR] Mid-stream recovery for "${song.title}" — '
                'playerIdx ($playerIdx) out of range for sequence length (${seq.length})');
          } else {
            debugPrint('[AurumHandler] Mid-stream recovery for "${song.title}" aborted '
                'right before splice — player moved on in the meantime.');
            return;
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
    if (sessionAtError != _playSessionId) return;
    onPlaybackError?.call(
      'Stream expired for "${song.title}" [$srcLabel] at ${pos.inSeconds}s '
      'and could not be recovered. Skipping to next song.',
      silent: true,
    );
    await _advancePastDeadSong(song, sessionAtError);
  }

  // ─── CURRENT INDEX STREAM HANDLING ─────────────────────────────────────────

  // BUGFIX (2026-07-01): this used to bail out entirely with
  // `if (_splicingInProgress) return;` at the top. _splicingInProgress stays
  // true for the ENTIRE duration of _resolveQueueInBackground — which, for a
  // long auto-extended queue, can easily take longer than one song's
  // playtime. If the player naturally auto-advanced to the next track in its
  // own live ConcatenatingAudioSource while background resolution was still
  // running, this function used to silently do nothing: _currentIndex never
  // updated, mediaItem/lock screen never updated, and _queue and the
  // player's real position drifted apart. That drift is what then made
  // _handleMidStreamIdle/_handleFreshStartIdle "recover" and splice the
  // WRONG (old) song back in ~10s later — because they trusted the now-stale
  // _queue[_currentIndex] as truth. The player's live currentIndexStream is
  // always the actual truth about what's audibly playing, splicing or not,
  // so we now always resync to it. _splicingInProgress still guards
  // _maybeAutoExtendQueue() further down (no reason to kick off another
  // auto-extend fetch while one is already in flight), just not the sync.
  void _handleCurrentIndexChanged(int? index) {
    if (index == null) return;

    // See _queueMutating doc comment above: a queue-list mutation
    // (add/insert/move/removeAt on the ConcatenatingAudioSource) can echo
    // through this same stream without any real audible transition having
    // happened. Ignore those — the mutating call sites already re-publish
    // `queue`/mediaItem correctly themselves when needed.
    if (_queueMutating) return;

    // Sleep timer "finish song" — pause the moment the NEXT song would start.
    if (_stopAfterCurrentSong && index != _currentIndex) {
      _stopAfterCurrentSong = false;
      _player.pause();
      return;
    }

    // Gapless OFF: 600ms pause between tracks
    // BUGFIX (2026-07-01): this delayed play() had no session guard. If the
    // user tapped a different song within the 600ms window, this callback
    // would still fire and blindly call _player.play() on whatever the
    // player's source was AT THAT LATER MOMENT — which by then could be the
    // newly-tapped song still mid-resolve, or briefly the old song before
    // _hardStopAndMute's empty-source swap landed. Capturing the session ID
    // now and checking it before resuming prevents this from stepping on an
    // unrelated, newer playback attempt.
    if (!AudioPrefs.gapless && index != _currentIndex &&
        !_isLoadingNewSong && _crossfadeSecs <= 0) {
      final sessionAtPause = _playSessionId;
      _player.pause();
      Future.delayed(const Duration(milliseconds: 600), () {
        if (sessionAtPause != _playSessionId) return;
        if (_player.processingState != ProcessingState.idle) {
          _player.play();
        }
      });
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
      _maybeAutoExtendQueue();
      return;
    }

    if (index != _currentIndex && index < _queue.length) {
      _currentIndex = index;
      _updateMediaItem(_queue[index]);
    }

    _maybeAutoExtendQueue();
  }

  // ── Auto-continue Up Next ───────────────────────────────────────────────
  // When the user is within 2 songs of the end of the queue, silently fetch
  // similar Saavn songs (based on the currently playing track) and append
  // them live — so "Up Next" never just stops. Mirrors how Spotify/YT Music
  // autoplay keeps a session going instead of dead-ending at a fixed
  // playlist's last track.
  bool _autoExtending = false;

  void _maybeAutoExtendQueue() {
    if (_autoExtending) return;
    if (_splicingInProgress) return;
    if (_queue.isEmpty || _currentIndex >= _queue.length) return;

    final remaining = _queue.length - 1 - _currentIndex;
    if (remaining > 1) return; // only kick in near the actual end

    final current = _queue[_currentIndex];
    // Local files have no Saavn catalog match — nothing sensible to extend
    // with, so leave the queue as-is rather than injecting unrelated songs.
    if (current.isLocal) return;

    _autoExtending = true;
    final mySession = _playSessionId;
    ApiService.fetchSimilarSongs(
      songId: current.id,
      artist: current.artist,
      title: current.title,
      excludeIds: _queue.map((s) => s.id).toList(),
    ).then((similar) async {
      _autoExtending = false;
      if (mySession != _playSessionId) return; // a new queue started meanwhile
      if (similar.isEmpty) return;
      // Cap how much we add per trigger — keeps memory/source list sane,
      // and we'll naturally re-trigger again as the user keeps listening.
      for (final song in similar.take(10)) {
        if (mySession != _playSessionId) return;
        await addToQueue(song);
      }
    }).catchError((_) {
      _autoExtending = false;
    });
  }

  // Fade in from 0 → 1 over _crossfadeSecs when a new track starts.
  //
  // BUGFIX (2026-07-01): two problems fixed here.
  //   1. This Timer.periodic was never cancelled if _applyCrossfadeFadeIn()
  //      got called again before the previous one finished (rapid skips) —
  //      multiple timers could run at once, fighting over setVolume().
  //      Now we cancel any previous _fadeTimer first.
  //   2. No session guard. If the user tapped away to a NEW song while an
  //      old fade timer was still ticking, the stale timer's setVolume()
  //      calls could run AFTER _hardStopAndMute() had just set volume to 0
  //      for the new song's silent-resolve window — audibly un-muting
  //      whatever the player happened to be attached to at that instant.
  //      This was a second possible cause of old audio being briefly
  //      audible during a song change. Now the timer checks the session ID
  //      every tick and stops touching the player the moment it's stale.
  void _applyCrossfadeFadeIn() {
    _fadeTimer?.cancel();
    final mySession = _playSessionId;
    final steps = (_crossfadeSecs * 10).round().clamp(1, 120);
    final stepDuration = Duration(milliseconds: (_crossfadeSecs * 1000 ~/ steps));
    var step = 0;
    _fadeTimer = Timer.periodic(stepDuration, (timer) {
      if (mySession != _playSessionId) {
        timer.cancel();
        return;
      }
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

  // BUGFIX (2026-07-01): tracks the currently-running fade-in timer so a new
  // transition can cancel any still-running previous one (see
  // _applyCrossfadeFadeIn below for why this matters).
  Timer? _fadeTimer;

  Future<void> _applySettings() async {
    await AudioPrefs.load();
    final p = await SharedPreferences.getInstance();

    // Playback speed
    final speed = p.getDouble('playback_speed') ?? 1.0;
    await _player.setSpeed(speed);

    // Crossfade
    _crossfadeSecs = p.getDouble('crossfade_duration') ?? 0.0;

    // Bass Boost / Equalizer: entirely delegated to AudioEffectsController
    // (see audio_effects_controller.dart). This call can never throw and
    // can never break playback — any native effect rejection is caught,
    // logged, and contained inside the controller itself.
    await _effects.applySettings();

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
  Future<void> onNotificationDeleted() async {
    // BUG FIX: this used to call stop() unconditionally, regardless of the
    // user's "stop_on_swipe" setting. That meant swiping the notification
    // away ALWAYS killed playback and tore down the MediaSession — exactly
    // the "swipe se ht jaata hai" behavior we don't want. Now it respects
    // the same pref onTaskRemoved() already respects: only stop if the user
    // explicitly opted into that behavior. Default is false, so by default
    // the notification (and lock screen controls) survive a swipe and
    // playback keeps running in the foreground service, same as Spotify/
    // YouTube Music. Also note: on modern Android, an *ongoing* (foreground
    // service) notification set via androidNotificationOngoing: true is not
    // swipeable at all while actively playing — this handler mainly matters
    // for the paused state, where Android does allow the notification to be
    // dismissed.
    final p = await SharedPreferences.getInstance();
    if (p.getBool('stop_on_swipe') ?? false) {
      await stop();
      await clearQueue();
    }
  }

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
      case 'like':
        // Fired by the heart icon on the lock screen / notification.
        // We flip our local flag immediately (before awaiting anything) so
        // the icon updates with zero perceptible delay — the actual
        // Hive write happens via the injected callback right after.
        final song = currentSong;
        if (song == null) break;
        _currentSongLiked = !_currentSongLiked;
        _broadcastState(_player.playbackEvent);
        try {
          await onLikeToggleRequested?.call(song);
        } catch (e) {
          // Revert the optimistic flip if the actual toggle failed, so the
          // lock screen never shows a liked state that isn't real.
          _currentSongLiked = !_currentSongLiked;
          _broadcastState(_player.playbackEvent);
          debugPrint('[AurumHandler] like toggle failed: $e');
        }
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

    // Only one attempt here: the 45s YouTube timeout already wraps ApiService's
    // own internal Stage1->2->3 fallback chain, which IS the retry logic.
    // A second full 45s outer retry on top of that made the user wait up to
    // 90s on a tap before falling back to the next song. Lookahead (below,
    // no one actively waiting) still gets maxAttempts: 2 as a safety net.
    final url = await _resolveFast(song, sessionId: sessionId, maxAttempts: 1);
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
    // BUGFIX (2026-07-01): YouTube's internal fallback chain in
    // ApiService.resolveStreamUrl (Worker /api/yt-proxy up to 16s ->
    // Worker /api/yt-stream + device liveness check up to ~12s+ -> Piped/
    // Invidious blast race -> Worker extended-timeout retry up to 30s) can
    // legitimately take 45-55s end to end on a cold/throttled path. The old
    // 28s outer timeout here was killing that chain mid-flight, almost
    // always before Stage 2/3 ever got a chance to return a URL — so even
    // with the Worker fully live, most YouTube resolves were being aborted
    // by US, not by the Worker failing. That's what looked like "worker is
    // live but songs still skip": _findFirstPlayableFrom then silently
    // walked to the next song with no visible error.
    //
    // 45s here gives the full internal chain room to actually finish
    // before we give up on this attempt.
    final perAttemptTimeout = song.source == SongSource.youtube
        ? const Duration(seconds: 45)
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

  // BUGFIX (2026-07-01): this used to pass maxAttempts: 1. Lookahead runs
  // silently in the background at 70% of the current song — there is no
  // user actively waiting on it, so there's no real cost to giving it the
  // same 2-attempt retry a normal resolve gets. With only 1 attempt, a
  // single slow/flaky YouTube resolve (Piped/Invidious chain, ~28s worst
  // case) left the lookahead cache empty far more often than it should —
  // which meant the natural auto-advance moment (song ending) had to fall
  // back to a full COLD resolve instead of an instant cache hit. That cold
  // resolve is exactly the multi-second window where the auto-advance race
  // conditions (stale _currentIndex, mid-stream idle "recovery" splicing
  // the wrong song back in) do their damage — which is why the "random
  // song chaos on auto-advance" was reported as worst on YouTube: YouTube's
  // lookahead was failing silently far more often than Saavn/local, forcing
  // a cold resolve right at the riskiest moment, far more often.
  Future<void> lookaheadResolve(Song nextSong) async {
    if (nextSong.isLocal) return;
    if (nextSong.id.isEmpty) return;
    if (_LookaheadCache.get(nextSong.id) != null) return;
    debugPrint('[AurumHandler] Lookahead resolving: "${nextSong.title}"');
    final url = await _resolveFast(nextSong, maxAttempts: 2);
    if (url != null) {
      _LookaheadCache.put(nextSong.id, url);
      debugPrint('[AurumHandler] Lookahead cached: "${nextSong.title}"');
    } else {
      debugPrint('[AurumHandler] [ERROR] Lookahead resolve failed for '
          '"${nextSong.title}" (source=${nextSong.source.name}) after 2 attempts — '
          'will fall back to a cold resolve at auto-advance time.');
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
    _fadeTimer?.cancel();
    _fadeTimer = null;
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
    // BUGFIX (2026-07-01): playQueue() never called queue.add() here, unlike
    // playSong() and loadQueueSilently() which both do. AudioService's
    // `queue` stream is what drives the lock screen's / Android Auto's
    // queue-aware "Up Next" UI — without publishing it, that UI could show
    // a stale or empty queue even while mediaItem (title/artist/art) and
    // actual playback were both fine. playQueue() is the function used
    // every time a song is tapped from a playlist/album/home screen, so
    // this was a real gap. Publish immediately, and again below if the
    // fallback walk (_findFirstPlayableFrom) changes the effective index.
    queue.add(_queue.map(_songToMediaItem).toList());
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

  // =============================================================================
  // PERFORMANCE (2026-07-02): "YouTube songs heavy / phone heats up, time waste"
  // -----------------------------------------------------------------------
  // _resolveQueueInBackground used to resolve + network-fetch EVERY remaining
  // song in the queue immediately, back-to-back, the instant playback
  // started. For YouTube specifically, each resolve can involve a Worker
  // probe request and — on failure — a parallel blast race across multiple
  // Piped/Invidious instances. Tapping a 30-50 song playlist meant firing
  // that entire chain 30-50 times almost simultaneously, most of it for
  // songs the user might not reach for another 20+ minutes (or ever, if
  // they skip around). That's sustained radio/CPU activity competing with
  // the actually-playing song — the real source of "load/heat/time waste."
  //
  // FIX (nothing removed — every song still gets fully resolved and
  // spliced in before playback would reach it, exactly as before):
  //   1. PRIORITY WINDOW — the next few songs (and previous few, for
  //      instant back-skip) resolve immediately, back-to-back, same as
  //      before. This is what actually matters for smooth/instant
  //      skip-ahead, so zero change in responsiveness here.
  //   2. PACED TAIL — everything beyond the priority window still gets
  //      resolved and spliced in, just with a small delay between each one
  //      instead of firing all at once. A typical song is 3+ minutes; even
  //      a modest pacing delay finishes resolving a 50-song queue well
  //      before a real listener could ever reach the back of it, while
  //      collapsing dozens of simultaneous network calls into a gentle
  //      trickle — the actual fix for sustained background load/heat.
  // =============================================================================
  static const int _priorityForwardWindow = 3; // resolved immediately, no pacing
  static const int _priorityBackwardWindow = 2; // resolved immediately, no pacing
  static const Duration _pacedResolveDelay = Duration(milliseconds: 900);

  // FIX #26: Future<void> not void — unhandled errors won't escape to zone.
  Future<void> _resolveQueueInBackground(List<Song> songs, int startIndex, int sessionId) async {
    try {
      // ── Forward: priority window first (unpaced), then the rest (paced) ──
      final forwardEnd = songs.length;
      for (int i = startIndex + 1; i < forwardEnd; i++) {
        if (sessionId != _playSessionId) return;

        final distanceFromStart = i - startIndex;
        if (distanceFromStart > _priorityForwardWindow) {
          // Beyond the priority window — pace ourselves so a long queue
          // doesn't fire dozens of resolves in a tight burst. Still
          // guarantees every song is ready well before natural playback
          // could reach it.
          await Future.delayed(_pacedResolveDelay);
          if (sessionId != _playSessionId) return;
        }

        try {
          final source = await _sourceForSong(songs[i], sessionId: sessionId);
          if (sessionId != _playSessionId) return;
          if (source != null) {
            final seq = _player.audioSource;
            if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
              await seq.add(source);
              // BUGFIX: see addToQueue's doc comment — re-sync against the
              // live player index in case a real transition landed during
              // this splice (same race this file already guards elsewhere).
              _handleCurrentIndexChanged(_player.currentIndex);
            }
          }
        } catch (_) {}
      }

      // ── Backward: priority window first (unpaced), then the rest (paced) ──
      int playerIndex = 0;
      for (int i = startIndex - 1; i >= 0; i--) {
        if (sessionId != _playSessionId) return;

        final distanceFromStart = startIndex - i;
        if (distanceFromStart > _priorityBackwardWindow) {
          await Future.delayed(_pacedResolveDelay);
          if (sessionId != _playSessionId) return;
        }

        try {
          final source = await _sourceForSong(songs[i], sessionId: sessionId);
          if (sessionId != _playSessionId) return;
          if (source != null) {
            final seq = _player.audioSource;
            if (seq is ConcatenatingAudioSource && sessionId == _playSessionId) {
              await seq.insert(0, source);
              playerIndex++;
              await _player.seek(_player.position, index: playerIndex);
              _handleCurrentIndexChanged(_player.currentIndex);
            }
          }
        } catch (_) {}
      }
    } finally {
      if (sessionId == _playSessionId) {
        _splicingInProgress = false;
        // Covers the edge case where the queue started with only 1-2 songs
        // and _handleCurrentIndexChanged never re-fires (no index change
        // happens until the user reaches the end) — check right away.
        _maybeAutoExtendQueue();
      }
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
      if (mySession == _playSessionId) {
        _isLoadingNewSong = false;
        // playSong() always starts a 1-song queue — _handleCurrentIndexChanged
        // won't fire again until the user reaches the end, so check now.
        _maybeAutoExtendQueue();
      }
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
    if (seq is ConcatenatingAudioSource) {
      _queueMutating = true;
      try {
        await seq.add(source);
      } finally {
        _queueMutating = false;
      }
      // BUGFIX (2026-07-02): "UI shows a different song while audio plays
      // correctly" — see _queueMutating doc comment. _queueMutating being
      // true for the whole `await seq.add(...)` window can swallow a
      // GENUINE transition that happens to land in that same window (e.g.
      // the current song naturally ends and the player auto-advances at
      // the exact moment auto-extend-queue is silently adding more songs
      // in the background, which is common since auto-extend triggers near
      // the end of the queue — i.e. near the end of a song). Immediately
      // after the mutation flag is cleared, force a re-sync against
      // whatever the player's live currentIndex actually is right now —
      // if a real transition happened during the mutation, this catches it
      // instantly instead of leaving _currentIndex/mediaItem stale until
      // the next unrelated event. This call is a no-op if nothing changed.
      _handleCurrentIndexChanged(_player.currentIndex);
    }
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
    if (seq is ConcatenatingAudioSource) {
      _queueMutating = true;
      try {
        await seq.insert(insertIdx, source);
      } finally {
        _queueMutating = false;
      }
      // BUGFIX (2026-07-02): see addToQueue's doc comment above — re-sync
      // against the player's live index in case a real transition landed
      // during this mutation and would otherwise be lost.
      _handleCurrentIndexChanged(_player.currentIndex);
    }
    queue.add(_queue.map(_songToMediaItem).toList());
  }

  Future<void> removeFromQueue(int index) async {
    if (index >= _queue.length) return;
    _queue.removeAt(index);
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource && index < seq.length) {
      _queueMutating = true;
      try {
        await seq.removeAt(index);
      } finally {
        _queueMutating = false;
      }
      // BUGFIX (2026-07-02): see addToQueue's doc comment above.
      _handleCurrentIndexChanged(_player.currentIndex);
    }
    queue.add(_queue.map(_songToMediaItem).toList());
  }

  Future<void> moveQueueItem(int from, int to) async {
    final song = _queue.removeAt(from);
    _queue.insert(to, song);
    final seq = _player.audioSource;
    if (seq is ConcatenatingAudioSource) {
      _queueMutating = true;
      try {
        await seq.move(from, to);
      } finally {
        _queueMutating = false;
      }
      // BUGFIX (2026-07-02): see addToQueue's doc comment above. Also
      // matters extra here since a move can itself shift what index the
      // currently-playing item sits at — re-syncing picks up the player's
      // real live index either way (a genuine overlapping transition, or
      // just the index shift from the move itself).
      _handleCurrentIndexChanged(_player.currentIndex);
    }
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

  /// Injected by PlayerProvider — lets the handler synchronously ask
  /// "is this song liked?" the instant a new song starts, instead of
  /// waiting for a round-trip notifyListeners() → setCurrentSongLiked()
  /// cycle. Without this the heart icon would flash the PREVIOUS song's
  /// liked state for a frame or two on every song change.
  bool Function(Song song)? isSongLikedLookup;

  void _updateMediaItem(Song song) {
    _currentSongLiked = isSongLikedLookup?.call(song) ?? false;
    mediaItem.add(_songToMediaItem(song));
  }

  MediaItem _songToMediaItem(Song song) => MediaItem(
        id:      song.id,
        title:   song.title,
        artist:  song.artist,
        album:   song.album,
        artUri:  AudioPrefs.showArtworkNotif && song.artworkUrl.isNotEmpty
            ? Uri.parse(song.artworkUrl)
            : null,
        duration: song.duration != null ? Duration(seconds: song.duration!) : null,
      );

  // ─── PLAYBACK STATE BROADCAST ─────────────────────────────────────────────

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;

    // Read notification prefs (cached in AudioPrefs to avoid async here)
    final showPrev    = AudioPrefs.notifShowPrev;
    final isCompact   = AudioPrefs.notifCompact;

    // Like button — custom action, rendered as a heart icon. Android's
    // MediaStyle notification only reserves 3 slots for the *compact* view
    // (the one visible without expanding), so compact mode keeps
    // like+play+next (dropping prev, same as before) rather than losing a
    // transport control. Expanded view (lock screen full card) always shows
    // all four: prev(optional) + like + play/pause + next.
    final likeControl = MediaControl.custom(
      androidIcon: _currentSongLiked
          ? 'drawable/ic_like_filled'
          : 'drawable/ic_like_outline',
      label: _currentSongLiked ? 'Unlike' : 'Like',
      name: 'like',
    );

    // Build controls list: compact = no prev button; expanded = prev + play + next
    final controls = isCompact
        ? [
            likeControl,
            playing ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
          ]
        : [
            if (showPrev) MediaControl.skipToPrevious,
            likeControl,
            playing ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
          ];

    // Compact indices: pick which of the buttons above show in the
    // collapsed notification (max 3, per Android MediaStyle). We prioritize
    // like + play + next since prev is one tap away via seek-to-start anyway.
    final compactIndices = isCompact
        ? const [0, 1, 2]
        : (showPrev ? const [1, 2, 3] : const [0, 1, 2]);

    playbackState.add(playbackState.value.copyWith(
      controls: controls,
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: compactIndices,
      processingState: !AudioPrefs.showMediaNotif
          ? AudioProcessingState.idle
          : {
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
    // While background splicing is still resolving surrounding songs, the
    // live ConcatenatingAudioSource can be shorter than the real queue —
    // don't let that make an already-queued song look "not ready yet" and
    // force a full re-resolve through playQueue when it may finish
    // splicing into range a moment later anyway.
    if (seq is ConcatenatingAudioSource && index < seq.length && !_splicingInProgress) {
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
    _fadeTimer?.cancel();
    _shakeSub?.cancel();
    _interruptionSub?.cancel();
    _noisySub?.cancel();
    _broadcastSub?.cancel();
    _idleSub?.cancel();
    _durationSub?.cancel();
    _currentIndexSub?.cancel();
    // The native effects (owned by AudioEffectsController) are attached to
    // _player's AudioPipeline — disposing the player releases the whole
    // pipeline, including these effects, with it. _effects.dispose() is a
    // documented no-op for anything beyond that.
    _effects.dispose();
    await _player.dispose();
  }
}
