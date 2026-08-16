// =============================================================================
// FILE: lib/providers/player_provider.dart
// PROJECT: Aurum Music
// VERSION: 3.0.0 — Native engine switch (NativeAudioEngine / Kotlin+Media3)
//
// WHAT CHANGED IN v3:
//   🔁 Backing engine swapped: AurumAudioHandler (just_audio) → NativeAudioEngine
//      (MethodChannel/EventChannel facade over AurumAudioEngine.kt).
//   🔁 All transport/queue calls now go through NativeAudioEngine's method
//      surface (playQueue, playSong, addToQueue, removeFromQueue,
//      moveQueueItem, clearQueue, play, pause, stop, seek, skipToNext,
//      skipToPrevious, skipToQueueItem, setRepeatMode, setShuffleMode,
//      setCurrentSongLiked).
//   🔁 Position/duration/buffered/playing/processingState/loop/shuffle/
//      currentIndex/currentSong/queue are all derived from a single
//      NativeAudioEngine.stateStream subscription instead of five separate
//      just_audio streams.
//   🔁 onPlaybackError is wired from NativeAudioEngine.errorStream instead of
//      a handler callback.
//   🔁 Since the native side only echoes back song IDs (queueIds /
//      currentSongId) rather than full Song objects, this provider now
//      keeps a local `_queue` mirror (List<Song>) updated on every call
//      that changes the queue, and reconciles it against queueIds whenever
//      state arrives (covers native-side reordering/removal we didn't
//      initiate directly, e.g. an internal auto-advance).
//
// BACKWARD COMPATIBILITY:
//   - All existing getters unchanged (position, duration, buffered,
//     loopMode, shuffle, currentSong, queue, currentIndex, hasSong, etc.)
//   - All existing public methods unchanged in name/signature
//   - `playNext`, `loadQueueSilently`, and `runRealPlaybackTest` had no
//     NativeAudioEngine equivalent as of this bridge version — they're
//     adapted below (see inline notes) rather than silently dropped, since
//     UI call sites still call them. (`lookaheadResolve` was later removed
//     entirely — see the LOOKAHEAD PRELOAD note in _onPosition — its result
//     was discarded natively and never fed back into playback.)
//   - No breaking API changes for callers of PlayerProvider.
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../models/lyrics.dart';
import '../services/native_engine_bridge.dart';
import '../services/api_service.dart';
import '../services/audio_prefs.dart';
import '../services/recommendation_engine.dart';
import '../utils/artwork_palette_cache.dart';
import 'recently_played_provider.dart';
import 'favorites_provider.dart';

// NOTE: LoopMode is still sourced from just_audio (`off`/`one`/`all`) purely
// as a shared value type — full_player_screen.dart imports the same enum
// directly and compares against `player.loopMode`. No just_audio Player is
// constructed anywhere in this file; only the enum is reused so the UI
// layer needs no changes for this engine swap.

class PlayerProvider extends ChangeNotifier with WidgetsBindingObserver {
  final NativeAudioEngine        _engine;
  final RecentlyPlayedProvider? _recentlyPlayed;
  FavoritesProvider? _favorites;

  // Injected from main.dart once FavoritesProvider exists (created earlier
  // in the provider tree; PlayerProvider's constructor doesn't take a
  // BuildContext). Re-wires the like bridge + listens for external
  // like/unlike (e.g. tapping the heart in the full player) so the lock
  // screen icon stays correct no matter where the like happened.
  void updateFavorites(FavoritesProvider favorites) {
    if (identical(_favorites, favorites)) return;
    _favoritesSub?.cancel();
    _favorites = favorites;

    _isSongLikedLookup = (song) => favorites.isFavorite(song.id);
    _onLikeToggleRequested = (song) => favorites.toggleFavorite(song);

    // Keep the lock screen heart in sync if the user likes/unlikes the
    // current song from anywhere else in the app (full player, library, etc).
    _favoritesSub = _FavoritesListener(favorites, () {
      final song = currentSong;
      if (song != null) {
        _engine.setCurrentSongLiked(favorites.isFavorite(song.id));
      }
    });

    // Sync immediately for whatever's already playing.
    final song = currentSong;
    if (song != null) {
      _engine.setCurrentSongLiked(favorites.isFavorite(song.id));
    }
  }

  // Replaces AurumAudioHandler.isSongLikedLookup / onLikeToggleRequested.
  // Now backed by a real reverse channel: AurumMediaSessionService (lock
  // screen / notification heart tap) → AurumAudioEngine.triggerLikeToggle()
  // → AurumEngineChannelHandler → NativeAudioEngine.onLikeToggleRequested
  // (native_engine_bridge.dart) → wired here → FavoritesProvider →
  // setCurrentSongLiked() pushes the authoritative result back to native.
  bool Function(Song song)? _isSongLikedLookup;
  Future<void> Function(Song song)? _onLikeToggleRequested;

  _FavoritesListener? _favoritesSub;

  // Exposes the underlying engine for screens that need it directly
  // (Sleep Timer, Equalizer) rather than re-routing every call through
  // PlayerProvider just to avoid a single getter.
  NativeAudioEngine get handler => _engine;
  NativeAudioEngine get engine => _engine;

  bool     _isPlaying      = false;
  bool     _isLoading      = false;
  // Mirrors NativeEngineState.resolveTakingLong — true while the current
  // song is still actively being retried by the native no-auto-skip
  // resolve policy (see AurumAudioEngine.resolveWithPatience), for longer
  // than a normal connection should need. Never a signal to change songs
  // by itself; onResolveTakingLong below is purely a "check your
  // connection" UI hint, wired in main.dart.
  bool     _resolveTakingLong = false;
  Duration _position       = Duration.zero;
  Duration _duration       = Duration.zero;
  Duration _buffered       = Duration.zero;
  LoopMode _loopMode       = LoopMode.off;
  bool     _shuffle        = false;
  bool     _showFullPlayer = false;

  // FIX ("full player UI stuck at 00:00 while audio genuinely plays in
  // background — notification/lock-screen show the correct playing
  // state, only the in-app seek bar is frozen"): the native position
  // ticker (AurumAudioEngine.startPositionTicker) polls on a 1s
  // Dispatchers.Main coroutine delay — a main-thread-tied timer that
  // some OEM battery managers (this was reported on a realme/ColorOS
  // device) are known to throttle or deprioritize once there's no
  // foreground Activity, even though the Service itself and actual
  // ExoPlayer playback keep running completely normally (which is
  // exactly why the notification — driven independently by Media3, not
  // by this ticker — stayed correct while Dart's mirrored position sat
  // stale). Rather than trying to fight OEM Doze/battery-throttling
  // heuristics from the native side, this local Dart ticker makes the
  // in-app UI self-sufficient: while _isPlaying is true, it advances
  // _position by 500ms locally and notifies listeners, entirely
  // independent of whether a fresh native push has arrived recently.
  // Every genuine _onEngineState event (native pushState(), which still
  // fires reliably on song-change/seek/buffering/etc. even if the 1s
  // ticker itself gets throttled) remains authoritative and simply
  // overwrites/resyncs _position — so this can never drift permanently,
  // only smooths the seconds between real updates and, critically,
  // guarantees the seek bar is never simply stuck at zero.
  Timer? _localPositionTicker;

  // FIX (root cause of the permanent "stuck UI, audio plays fine"
  // symptom — confirmed via on-device debug overlay: expectedSongId ==
  // currentSongId, so the switch WAS confirmed, but isPlaying stayed
  // false / isLoading stayed true forever with no further state events
  // arriving at all): this used to call _engine.forceStateResync(), a
  // method that never existed anywhere on NativeAudioEngine — there was
  // no way to ask the native engine to re-push its current state, only
  // the push-based EventChannel stream (native_engine_bridge.dart
  // _stateSub) which relies on ExoPlayer's own Player.Listener callbacks
  // (onIsPlayingChanged/onPlaybackStateChanged) firing to trigger
  // pushState(). If ExoPlayer ever coalesces or drops one of those
  // callbacks internally — it really is playing, it just doesn't refire
  // the callback — nothing in the app could ever recover, since no
  // native "pull current state" existed at all.
  //
  // Real fix has three parts: (1) native_engine_bridge.dart's _stateSub
  // now has an onError handler so a malformed event can't silently kill
  // the whole listener either. (2) AurumAudioEngine.kt's existing
  // refreshState() (previously only used internally for cast handoff) is
  // now exposed over the MethodChannel as "refreshState", and
  // NativeAudioEngine.refreshState() in native_engine_bridge.dart calls
  // it — this re-reads ExoPlayer's live state directly and re-emits a
  // fresh NativeEngineState, which is the genuine fix for the dropped-
  // callback case. (3) the watchdog below calls that real resync first;
  // only if the UI is STILL stuck a few seconds after asking the native
  // side to refresh does it fall back to force-clearing the flag locally
  // (covering the case where the state stream itself is the thing that's
  // dead, not just one missed callback).
  Timer? _loadingWatchdog;
  bool _refreshRequestedForCurrentStuck = false;

  void _startLoadingWatchdog() {
    // FIX (same battery-drain family as _localPositionTicker below): this
    // was only ever cancelled in dispose(), so once _isLoading went true
    // even once, it ran every 2s for the rest of the app's process
    // lifetime — screen off, backgrounded, didn't matter. Cheap per-tick,
    // but "cheap x forever x background" is still real background CPU
    // wake-ups Android's battery stats count against the app. Gate it
    // behind foreground the same way; a stuck-loading state that started
    // in the foreground will correctly resume being watched the moment
    // the app is foregrounded again via didChangeAppLifecycleState.
    if (!_isAppInForeground) return;
    _loadingWatchdog ??= Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_isLoading) {
        _refreshRequestedForCurrentStuck = false;
        return;
      }
      final setAt = _expectedSongIdSetAt;
      if (setAt == null) return;
      final stuckFor = DateTime.now().difference(setAt);
      // First give playSong()'s own 8s engine-call timeout a chance to
      // run its course, then ask the native engine to re-push its real
      // state once.
      if (stuckFor > const Duration(seconds: 6) && !_refreshRequestedForCurrentStuck) {
        _refreshRequestedForCurrentStuck = true;
        _engine.refreshState();
      }
      // If asking for a real resync didn't clear it either, the state
      // stream itself is likely dead — last-resort local clear so the UI
      // at least stops looking permanently broken.
      if (stuckFor > const Duration(seconds: 10)) {
        _isLoading = false;
        _expectedSongId = null;
        _expectedSongIdSetAt = null;
        _refreshRequestedForCurrentStuck = false;
        notifyListeners();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resuming the app is exactly when a dropped-callback freeze would
    // otherwise go unnoticed the longest (user was away, came back to a
    // frozen player). Always worth asking the native engine to re-push
    // its real state here, regardless of how long it's been stuck —
    // cheap, non-destructive, and the fastest path to recovery.
    if (state == AppLifecycleState.resumed) {
      _engine.refreshState();
      _isAppInForeground = true;
      // Ticker was intentionally stopped while backgrounded (see below) —
      // resume it now if we're still actually playing, so the seek bar
      // interpolation is live again the instant the player screen is
      // visible instead of waiting for the next native position event.
      if (_isPlaying) _startLocalPositionTicker();
      if (_isLoading) _startLoadingWatchdog();
      return;
    }
    // FIX (battery drain: this ticker was firing every 500ms — 2x/sec,
    // ~7200 times/hr — completely unconditionally on _isPlaying, with NO
    // regard for whether the app was even in the foreground. Each tick
    // calls notifyListeners(), which rebuilds every widget subscribed to
    // PlayerProvider. On a phone with the screen off / app backgrounded,
    // nothing was ever visibly consuming that seek-bar interpolation —
    // it exists purely so the seek bar looks smooth on the full player
    // screen — yet it kept running full-speed in the background for as
    // long as playback continued, which for a music app can be hours.
    // That's what showed up as disproportionate "background" battery/CPU
    // usage in Android's battery stats despite low actual screen-on time.
    // Stopping it here (paused/inactive/detached) costs nothing: the real
    // position still updates correctly from native player-state events
    // (onPositionDiscontinuity, periodic native ticks that already exist
    // in AurumAudioEngine), this local ticker only smooths the UI between
    // those events for the seek bar the user can currently see.
    _isAppInForeground = false;
    _stopLocalPositionTicker();
    _loadingWatchdog?.cancel();
    _loadingWatchdog = null;
  }


  // Tracks whether the app is currently in the foreground. Starts true —
  // by the time PlayerProvider exists the app is already visible (this
  // isn't constructed from a background isolate), and the very first
  // didChangeAppLifecycleState callback will correct it if that's ever
  // not the case.
  bool _isAppInForeground = true;

  void _startLocalPositionTicker() {
    if (!_isAppInForeground) return;
    if (_localPositionTicker?.isActive == true) return;
    _localPositionTicker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!_isPlaying) return;
      final next = _position + const Duration(milliseconds: 500);
      // Never let the local interpolation run past the known duration —
      // the next real native event (song-end/auto-advance) will correct
      // this properly; this just avoids a visibly wrong "position >
      // duration" state for the ~1s window before that event arrives.
      _position = (_duration > Duration.zero && next > _duration) ? _duration : next;
      notifyListeners();
    });
  }

  void _stopLocalPositionTicker() {
    _localPositionTicker?.cancel();
    _localPositionTicker = null;
  }

  bool _isBuildingInitialQueue = false;
  // Lets the Queue UI show "finding songs for you" instead of a blank Up
  // Next while the background build below is still in flight — a user
  // isn't going to wait 10-15s staring at an empty list before assuming
  // the app is broken, so the UI needs to say *something* is happening.
  bool get isBuildingQueue => _isBuildingInitialQueue;
  bool _isAutoExtendingQueue = false;
  Timer? _indexDebounce;
  int?   _lastHandledIndex;

  // FIX (100-song rapid-fire skip stability): skipNext()/skipPrev() used to
  // fire a brand-new _engine.skipToNext()/skipToPrevious() MethodChannel
  // call — each with its own independent 4s timeout — on EVERY single tap,
  // with no coalescing. The _uiPlaySession/_expectedSongId machinery already
  // keeps the UI/state CORRECT under that load (that's what actually fixed
  // the "audio changes, UI frozen" bug), but correctness isn't the same as
  // stability at volume: spamming the skip button 100 times in a few
  // seconds queues up 100 stacked native round-trips, each independently
  // racing/timing out, hammering the platform channel and (on a phone) the
  // battery/CPU for zero user-visible benefit — the user only ever cares
  // about where they land after they stop tapping, not that every
  // intermediate tap round-tripped to native individually.
  //
  // Fix: the optimistic index math + _expectedSongId/_expectedSongIdSetAt
  // guess still updates INSTANTLY on every tap (UI feels exactly as
  // responsive as before — title/artwork/progress bar snap immediately).
  // Only the actual native call is debounced: rapid taps reset a short
  // timer, and just ONE _engine.skipToQueueItem() call actually fires once
  // taps settle, jumping straight to the final resolved index in one shot
  // instead of one native call per intermediate tap.
  Timer? _skipDebounce;
  int? _skipDebounceTargetIndex; // resolved queue index once taps settle
  static const Duration _skipDebounceWindow = Duration(milliseconds: 180);

  // Local mirror of the native queue. The native side only reports back
  // `queueIds` (List<String>) + `currentSongId` in its state stream, not
  // full Song objects, so we keep the actual Song list here — pushed to
  // whenever we call playQueue/playSong/addToQueue/removeFromQueue/
  // moveQueueItem/clearQueue — and reconcile it against `queueIds` on every
  // incoming state event so any native-only mutation (auto-advance past
  // the end, internal cleanup, etc.) can't leave this mirror stale.
  List<Song> _queue = [];
  int _currentIndex = 0;
  Song? _currentSong;

  // Spotify-style auto-resume on reconnect: when SourceProvider stops an
  // online stream because connectivity genuinely dropped (see main.dart's
  // onSourceChanged), it records what was playing and where here. If/when
  // connectivity comes back, onReconnected (also wired in main.dart) uses
  // this to pick the exact same song back up at the exact position it was
  // cut off, instead of leaving it dead until the user notices and taps
  // play again. Cleared the moment it's consumed (or superseded by any
  // other playback change) so a later, unrelated reconnect doesn't replay
  // a song the user has since moved away from.
  Song? _interruptedByNetworkSong;
  Duration _interruptedByNetworkPosition = Duration.zero;

  /// Called by SourceProvider.onSourceChanged right before it stops an
  /// online stream due to a genuine connectivity drop. Captures enough to
  /// resume seamlessly if/when the connection comes back.
  void markInterruptedByNetworkLoss() {
    if (_currentSong == null || (_currentSong?.isLocal ?? true)) return;
    _interruptedByNetworkSong = _currentSong;
    _interruptedByNetworkPosition = _position;
  }

  /// Called by SourceProvider.onReconnected once connectivity genuinely
  /// comes back. Resumes whatever was interrupted, at the exact position
  /// it stopped at — a no-op if nothing was actually interrupted (e.g.
  /// the buffer carried playback through, or nothing was playing at all),
  /// so this is always safe to call on every reconnect.
  Future<void> resumeAfterReconnect() async {
    final song = _interruptedByNetworkSong;
    if (song == null) return;
    final pos = _interruptedByNetworkPosition;
    _interruptedByNetworkSong = null;
    _interruptedByNetworkPosition = Duration.zero;
    try {
      await playSong(song, queue: _queue.isNotEmpty ? _queue : null,
          index: _queue.isNotEmpty ? _currentIndex : null);
      if (pos > Duration.zero) {
        await seekTo(pos);
      }
    } catch (e) {
      debugPrint('[Aurum] resumeAfterReconnect failed: $e');
    }
  }

  // BUGFIX (2026-07-02): "click kiya kuch aur, play kuch aur ho gaya".
  // playSong() below is async and NOT awaited by most call sites (song
  // tiles fire-and-forget it on tap). If the user taps song B while song
  // A's playSong() is still awaiting _engine.playQueue()/playSong() or
  // _buildInitialSmartQueue() is still running in the background, A's
  // in-flight work would previously keep running with no way to know a
  // newer tap had superseded it — _buildInitialSmartQueue in particular
  // would keep calling _engine.addToQueue() with SONG A's recommendations
  // even after the user had already moved on to song B, silently
  // appending the wrong songs into what is now B's queue. This counter is
  // bumped on every playSong() call; anything from an older call checks it
  // before touching the queue and bails out if it's been superseded.
  int _uiPlaySession = 0;

  // FIX — "wrong song's UI shows for ~4 seconds after tapping a new song,
  // then snaps to the right one." Root cause: playSong() sets _currentSong
  // optimistically the instant you tap, but the native engine (Kotlin/
  // Media3 side) takes a moment to actually switch tracks. In that window,
  // _onEngineState can still receive one or more *stale* state events from
  // the engine that describe the PREVIOUS song (or, on a fresh app start
  // before the engine has settled, the first song in the queue) — and it
  // was unconditionally trusting state.currentSongId, overwriting the
  // correct optimistic song back to the wrong one until the engine's
  // genuinely-new state event finally arrived.
  //
  // Fix: track which song id we're expecting next. While an expectation is
  // active, ignore engine state updates that report a different song — the
  // optimistic value from playSong() wins until the engine actually catches
  // up and reports the same id, at which point the expectation clears and
  // normal reconciliation resumes.
  String? _expectedSongId;
  // FIX (permanent UI freeze after rapid/spam skip — "audio changes in
  // background, UI stuck on old song, only a manual tap fixes it"):
  // _expectedSongId had no expiry. Under rapid repeated skip taps, each
  // tap overwrites _expectedSongId with its own guess (see skipNext/
  // skipPrev), but the native engine commonly coalesces/drops rapid
  // successive skip calls — so the engine can settle on an EARLIER song
  // than the LAST tap guessed. When that happens, the real state event
  // reports an id that will never equal the last-set _expectedSongId, so
  // isConfirmedSwitch in _onEngineState stays false forever: every future
  // event — including ones correctly describing what's actually
  // playing — gets treated as "stale" and dropped, freezing the UI on
  // the last optimistic guess permanently while audio keeps changing
  // underneath it. Recording when the current expectation was SET lets
  // _onEngineState give up on an unconfirmed guess after a short window
  // and fall back to trusting the engine's real reported state, instead
  // of waiting forever for a confirmation that will never come.
  DateTime? _expectedSongIdSetAt;
  static const Duration _expectedSongIdTimeout = Duration(seconds: 3);

  // FIX (see playQueue/playSong timeout doc comment in native_engine_bridge.
  // dart): surfaces to the UI when a play attempt genuinely failed or timed
  // out (native call hung / stream never resolved), instead of the app
  // just sitting there with a stale loading state and no explanation.
  // Screens can watch this to show a retry snackbar/toast.
  String? _playbackError;
  String? get playbackError => _playbackError;
  // The song that failed, captured alongside _playbackError, so a retry
  // action (SnackBar button) has something concrete to replay — without
  // this there was no way to actually act on "Tap to retry" wording.
  Song? _lastFailedSong;
  Song? get lastFailedSong => _lastFailedSong;
  void clearPlaybackError() {
    _playbackError = null;
    _lastFailedSong = null;
    notifyListeners();
  }

  // Last error reported by NativeAudioEngine.errorStream — exposed so the
  // UI (home_screen.dart) can show it via SnackBar the instant a real
  // playSong/playQueue attempt fails, without needing logcat/adb access.
  String? _lastPlaybackError;
  String? get lastPlaybackError => _lastPlaybackError;

  // Fired every time a new playback error comes in, even if the message
  // text is identical to the previous one (so repeated taps on the same
  // broken song each show a fresh SnackBar instead of being deduped away).
  // `silent` mirrors NativeAudioEngine.PlaybackErrorEvent.silent — true
  // means this was auto-recovered (single song skipped, playback
  // continues) and should only be logged, not shown to the user.
  void Function(String error, {bool silent})? onPlaybackError;

  // Fired once when the current song's resolve first crosses into
  // "taking longer than a normal connection should need" (edge-
  // triggered off _resolveTakingLong flipping false→true) — never on
  // every subsequent state tick while it stays stuck, so this doesn't
  // spam the UI with repeat snackbars for one ongoing episode. This is
  // purely an informational "check your connection" hint: playback is
  // NOT stopped and no song change happens because of this — the native
  // engine keeps retrying the same song in the background regardless
  // (see AurumAudioEngine's no-auto-skip resolve policy). Wired in
  // main.dart.
  void Function()? onResolveTakingLong;

  // ── Phase 4: Skip limit for free users ───────────────────────────────────
  // Free users get 6 skips per hour. Resets automatically after 60 min.
  static const int _kFreeSkipLimit = 6;
  static const Duration _kSkipWindow = Duration(hours: 1);
  static const String _kSkipsUsedPrefKey = 'free_skip_count';
  static const String _kSkipWindowStartPrefKey = 'free_skip_window_start_ms';

  int _skipsUsed = 0;
  DateTime _skipWindowStart = DateTime.now();
  // LOOPHOLE: _skipsUsed/_skipWindowStart were purely in-memory fields,
  // initialized fresh every time PlayerProvider is constructed — i.e.
  // every app cold start. Since the provider lives only as long as the
  // app process, a free user who used up all 6 skips could simply
  // force-close and reopen the app to instantly reset the counter and
  // get 6 more, completely bypassing the hourly limit this feature exists
  // to enforce. Persisting both values to SharedPreferences (already used
  // throughout AudioPrefs for exactly this kind of durable state) closes
  // that gap — the count and window now survive app restarts, and only
  // genuinely expire after a real hour has passed, not "however long
  // until the user thinks to relaunch."
  bool _skipStatePersistLoaded = false;

  // Started immediately in the constructor, well before the UI can even
  // render a skip button for a human to tap — SharedPreferences.getInstance()
  // resolving before that point is effectively guaranteed in practice, so
  // this stays fire-and-forget rather than making every skipNext() call
  // await it, which would reintroduce exactly the kind of tap-to-response
  // latency this file spent this whole session removing, for a race that
  // isn't realistically reachable by a human tapping skip.
  Future<void> _loadPersistedSkipState() async {
    if (_skipStatePersistLoaded) return;
    _skipStatePersistLoaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final storedCount = p.getInt(_kSkipsUsedPrefKey);
      final storedWindowStartMs = p.getInt(_kSkipWindowStartPrefKey);
      if (storedCount != null && storedWindowStartMs != null) {
        // FIX — this used to unconditionally overwrite _skipsUsed with
        // storedCount. SharedPreferences.getInstance() is awaited here,
        // and this whole method is fire-and-forget from the constructor
        // (not awaited by callers) — so on a slow cold start it's
        // genuinely possible for the user to tap skip (bumping
        // _skipsUsed from its in-memory default of 0 via _recordSkip())
        // BEFORE this resolves. The old unconditional overwrite would
        // then discard that just-recorded skip entirely, silently
        // granting a free skip that should have counted against the
        // hourly limit — a real (if narrow) bypass of the free-tier
        // gate. Merging instead of overwriting means any skip recorded
        // in that race window is preserved on top of the persisted
        // count rather than being clobbered.
        _skipsUsed = _skipsUsed > 0 ? (_skipsUsed + storedCount) : storedCount;
        _skipWindowStart = DateTime.fromMillisecondsSinceEpoch(storedWindowStartMs);
        _resetWindowIfExpired();
        _persistSkipState();
        notifyListeners();
      }
    } catch (_) {
      // Best-effort — if SharedPreferences genuinely fails, fall back to
      // the in-memory defaults already set above rather than crashing.
    }
  }

  Future<void> _persistSkipState() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kSkipsUsedPrefKey, _skipsUsed);
      await p.setInt(_kSkipWindowStartPrefKey, _skipWindowStart.millisecondsSinceEpoch);
    } catch (_) {
      // Best-effort — a failed write just means this session's skip count
      // won't survive a restart; it doesn't affect the current session's
      // in-memory enforcement, which already happened above.
    }
  }

  // Unlimited Skips is login-gated, not payment-gated (see PremiumGate
  // call sites in full_player_screen.dart) — only signing in with Google
  // lifts the limit. AudioPrefs.isPremium is intentionally NOT checked
  // here anymore; High Bitrate remains the only payment-gated feature.

  /// How many skips remain for free users this hour. Returns null if
  /// signed in (unlimited).
  int? get freeSkipsRemaining {
    if (AudioPrefs.isSignedIn) return null; // unlimited
    _resetWindowIfExpired();
    return (_kFreeSkipLimit - _skipsUsed).clamp(0, _kFreeSkipLimit);
  }

  bool get skipLimitReached {
    if (AudioPrefs.isSignedIn) return false;
    _resetWindowIfExpired();
    return _skipsUsed >= _kFreeSkipLimit;
  }

  void _resetWindowIfExpired() {
    if (DateTime.now().difference(_skipWindowStart) >= _kSkipWindow) {
      _skipsUsed = 0;
      _skipWindowStart = DateTime.now();
      _persistSkipState();
    }
  }

  void _recordSkip() {
    if (!AudioPrefs.isSignedIn) {
      _resetWindowIfExpired();
      _skipsUsed++;
      _persistSkipState();
      notifyListeners();
    }
  }

  // ── Behavior tracking state ────────────────────────────────────────────────
  // Used to fire one-shot events per song (completion/skip/replay).
  Song?   _lastTrackedSong;       // song currently being tracked
  bool    _completionFired = false; // 80%+ fired for current song?
  bool    _earlySkipArmed  = false; // true when position < 15s
  bool    _replayArmed     = false; // true when position near 0 after non-start

  // Subscriptions — cancelled on dispose (memory leak prevention)
  final List<StreamSubscription<dynamic>> _subs = [];

  // ---------------------------------------------------------------------------
  // CONSTRUCTOR
  //
  // [recentlyPlayedProvider] is optional for backward compat — if null,
  // behavior tracking calls are silently skipped.
  // ---------------------------------------------------------------------------
  PlayerProvider(this._engine, {RecentlyPlayedProvider? recentlyPlayedProvider})
      : _recentlyPlayed = recentlyPlayedProvider {
    _loadPersistedSkipState();

    // FIX ("full player UI stuck at 00:00 while audio genuinely plays in
    // background"): the native position ticker can silently die when
    // MainActivity is torn down/recreated (OEM battery throttling, recents
    // kill) while a song keeps playing — nothing naturally restarts it
    // since onIsPlayingChanged only fires on a genuine transition. Forcing
    // a resync every time the app comes back to the foreground self-heals
    // that, regardless of which exact link broke.
    WidgetsBinding.instance.addObserver(this);

    _subs.add(_engine.errorStream.listen((event) {
      _lastPlaybackError = event.message;
      onPlaybackError?.call(event.message, silent: event.silent);
      notifyListeners();
    }));

    _subs.add(_engine.stateStream.listen(_onEngineState));

    // See _loadingWatchdog doc comment above didChangeAppLifecycleState:
    // pure-Dart safety net for the "stuck UI, audio plays fine" bug —
    // force-clears isLoading if no confirming state event arrives for far
    // longer than any real load should take.
    _startLoadingWatchdog();

    // Lock screen / notification heart tap → resolve songId against our
    // local queue mirror → FavoritesProvider.toggleFavorite() (via
    // updateFavorites' _onLikeToggleRequested) → push the authoritative
    // result back to native so the icon reflects the persisted state.
    _engine.onLikeToggleRequested = (songId) async {
      Song? song;
      for (final s in _queue) {
        if (s.id == songId) { song = s; break; }
      }
      song ??= (_currentSong?.id == songId) ? _currentSong : null;
      if (song == null) return;
      await _onLikeToggleRequested?.call(song);
      final liked = _isSongLikedLookup?.call(song) ?? false;
      await _engine.setCurrentSongLiked(liked);
    };
  }

  // ---------------------------------------------------------------------------
  // SECTION: NATIVE STATE DERIVATION
  //
  // Single funnel for everything NativeAudioEngine reports. Replaces the
  // five separate just_audio stream listeners (playing/position/duration/
  // buffered/processingState) plus loopMode/shuffleModeEnabled/
  // currentIndex from the old AurumAudioHandler-backed provider.
  // ---------------------------------------------------------------------------
  void _onEngineState(NativeEngineState state) {
    // FIX (permanent UI freeze after rapid/spam skip): see the
    // _expectedSongIdSetAt doc comment on the field declaration above for
    // the full mechanism. If the current optimistic guess has gone
    // unconfirmed for longer than _expectedSongIdTimeout, give up on it
    // here — BEFORE any of the staleness guards below run — so a guess
    // that will never be confirmed (engine coalesced/dropped the tap it
    // belonged to and settled on a different song instead) can't keep
    // rejecting every subsequent real state event forever. This is a
    // last-resort safety net: the normal id-match path in isConfirmedSwitch
    // below still wins whenever the engine genuinely does confirm the
    // expected song, so this only ever fires for the actually-stuck case.
    if (_expectedSongId != null &&
        _expectedSongIdSetAt != null &&
        DateTime.now().difference(_expectedSongIdSetAt!) > _expectedSongIdTimeout) {
      _expectedSongId = null;
      _expectedSongIdSetAt = null;
    }
    _isPlaying = state.playing;
    if (_isPlaying) {
      _startLocalPositionTicker();
    } else {
      _stopLocalPositionTicker();
    }
    // BUG: _isLoading was assigned here unconditionally, BEFORE the
    // isConfirmedSwitch guard further down that protects _currentSong from
    // stale/in-flight events describing the OLD song while a new song is
    // expected (_expectedSongId). A stale event landing in that window
    // still described the old, already-playing song's processingState
    // ('ready'/not loading), so _isLoading flipped false for a beat, then
    // true again once a genuinely new event arrived, then false again once
    // the new song was actually ready — a visible loading-spinner flicker
    // right after every tap. Applying the same "while an expectation is
    // pending, ignore anything that isn't the expected song" rule here
    // keeps isLoading from being clobbered by events that aren't actually
    // about the song the UI is currently expecting.
    final isStaleForLoading =
        _expectedSongId != null && state.currentSongId != _expectedSongId;
    if (!isStaleForLoading) {
      _isLoading = state.processingState == 'loading' ||
          state.processingState == 'buffering';
    }
    _buffered  = state.bufferedPosition;
    if (state.duration != null) _duration = state.duration!;

    // Edge-triggered: only fire the "check your connection" callback the
    // moment this flips from not-stuck to stuck, not on every tick while
    // it stays true — a resolve that's still retrying pushes fresh state
    // repeatedly (position/buffered ticks etc.), and re-notifying on each
    // one would spam a fresh SnackBar every second or two.
    if (state.resolveTakingLong && !_resolveTakingLong) {
      onResolveTakingLong?.call();
    }
    _resolveTakingLong = state.resolveTakingLong;

    // Reconcile the local queue mirror against queueIds. If the lengths and
    // order already match by ID, nothing to do — this keeps us from
    // rebuilding _queue (and losing any richer Song fields we already have,
    // like artworkUrl) on every single state tick, since queueIds is sent
    // on every position update too.
    // BUG: this reconciliation ran unconditionally, BEFORE the
    // isConfirmedSwitch guard below that protects _currentSong (and now
    // _isLoading) from stale/in-flight events describing the OLD song
    // while a new song/queue is expected. playSong() sets _queue
    // optimistically to the NEW queue the instant the user taps, then
    // calls _engine.playQueue() — but the native side can still emit one
    // more state event describing its OLD queueIds before it's caught up.
    // Since that ran through here unguarded, it silently overwrote the
    // freshly-set optimistic _queue with the stale old one — and because
    // _reconcileQueue's `byId` lookup is built from whatever _queue
    // already holds at call time, any song from the NEW optimistic queue
    // whose ID isn't in the stale `ids` list gets permanently dropped,
    // not just temporarily masked. Applying the same "ignore anything not
    // about the expected song" rule here prevents the optimistic queue
    // from being clobbered/corrupted by a stale pre-switch event.
    final isStaleForQueue =
        _expectedSongId != null && !state.queueIds.contains(_expectedSongId);
    if (!isStaleForQueue && !_queueMatchesIds(state.queueIds)) {
      _queue = _reconcileQueue(state.queueIds);
    }

    final newIndex = state.currentIndex ?? _currentIndex;
    Song? resolvedSong;
    if (state.currentSongId != null) {
      for (final s in _queue) {
        if (s.id == state.currentSongId) {
          resolvedSong = s;
          break;
        }
      }
      // Native says a song is playing but our local mirror doesn't have it
      // yet (auto-extend/splice race) — build a minimal stand-in so the UI
      // still reflects the change instead of showing the stale song.
      //
      // FIX: source used to be hardcoded to SongSource.saavn regardless
      // of what was actually playing. If this stand-in briefly stood in
      // for a YouTube or local/downloaded song, that wrong source could
      // feed into downstream source-gated logic (e.g. `if (current.source
      // == SongSource.local) return;` in auto-extend, or lyrics/stream
      // lookups keyed off source) and misclassify it, if anything read
      // this stand-in's source before the real Song object arrived.
      // Preserve the previous song's source when this stand-in happens to
      // be describing the same id we already knew about; only fall back
      // to the saavn default (matches Song's own constructor default) for
      // a genuinely never-seen id.
      resolvedSong ??= Song(
        id: state.currentSongId!,
        title: _currentSong?.id == state.currentSongId ? _currentSong!.title : '',
        artist: _currentSong?.id == state.currentSongId ? _currentSong!.artist : '',
        album: '',
        artworkUrl: '',
        source: _currentSong?.id == state.currentSongId
            ? _currentSong!.source
            : SongSource.saavn,
      );
    }
    // FIX (permanent artwork/title/background mismatch after auto-advance):
    // when the engine is mid-transition between tracks it can emit a state
    // event with currentSongId == null (nothing attached yet). This isn't
    // only a manual-skip thing — it also happens on plain auto-advance
    // (current song ends, engine moves to the next one on its own), where
    // _expectedSongId is NOT set, so the isConfirmedSwitch guard further
    // below never even engages to protect us here.
    //
    // Before this fix, a null currentSongId fell through to
    // `_queue[newIndex]` — but newIndex can *also* still be stale in this
    // exact same window (state.currentIndex is frequently null too, so
    // newIndex silently reused the OLD _currentIndex). That combination
    // could resolve to the wrong song and get accepted as authoritative
    // with nothing left to catch it, since no expectation was pending to
    // reject it — this is the "title/artwork/background frozen on the
    // previous song, permanently, not just for a beat" bug reported after
    // next/auto-advance.
    //
    // Fix: a genuinely null currentSongId from the engine is never treated
    // as "use the index instead" — it just means "no new information this
    // tick", so we keep showing whatever _currentSong already was and wait
    // for a later event that actually reports a real id.
    resolvedSong ??= (state.currentSongId != null &&
            _queue.isNotEmpty &&
            newIndex >= 0 &&
            newIndex < _queue.length)
        ? _queue[newIndex]
        : _currentSong;

    // FIX (see _expectedSongId doc comment above): if we're still waiting
    // on the engine to confirm a just-tapped song, ignore ANY state event
    // that doesn't definitively confirm we've switched — that's a stale/
    // in-flight event from before the engine switched tracks.
    //
    // BUGFIX (2026-07): "UI shows the OLD song for a few seconds after
    // tapping a new one, even though audio is already playing the new
    // song correctly." The previous version of this guard only caught
    // state events reporting a DIFFERENT, NON-NULL currentSongId. But
    // while the engine is mid-switch it can also emit events with
    // currentSongId == null (no track attached yet) or with a
    // currentSongId that isn't in `_queue` yet because the queue mirror
    // is still reconciling against the OLD queueIds. Neither of those
    // tripped the old guard, so execution fell through to `resolvedSong`,
    // whose final fallback (line ~320) is `_queue[newIndex]` — still
    // pointing at the OLD song at that moment. That silently overwrote
    // the correct optimistic `_currentSong` (the newly-tapped song) back
    // to the previous one, and stayed wrong until the engine finally sent
    // an event whose currentSongId truly matched `_expectedSongId`.
    //
    // Fix: while an expectation is pending, only accept a state event as
    // authoritative if it actually reports the expected song id. Anything
    // else — null id, a different id, or an id that resolved to nothing
    // in the queue — is treated as stale and skipped, so the optimistic
    // value from playSong() keeps winning until the engine genuinely
    // catches up.
    final isConfirmedSwitch =
        _expectedSongId == null || state.currentSongId == _expectedSongId;
    if (!isConfirmedSwitch) {
      // Still apply the parts of `state` that are safe regardless of which
      // song they're about (buffering/duration/etc. were already set
      // above) — just skip clobbering _currentSong/_currentIndex this tick.
      notifyListeners();
      return;
    }
    if (_expectedSongId != null && state.currentSongId == _expectedSongId) {
      _expectedSongId = null; // engine has caught up — resume normal tracking
      _expectedSongIdSetAt = null;
    }

    final _prevSongIdForPaletteWarm = _currentSong?.id;
    _currentSong = resolvedSong;
    _currentIndex = newIndex;

    // Warm the artwork palette cache as soon as a song becomes current —
    // not when the user happens to open the full player screen. Full
    // player previously only kicked off palette extraction (a full image
    // decode) on its own initState/song-change, which meant the first
    // open (or any cache miss) showed the hardcoded dark-navy default
    // background for a beat before morphing to the real artwork colors.
    // Doing it here means by the time the user actually taps into the
    // full player, extraction has almost always already finished —
    // same cache _extractColor() already checks, just started earlier.
    if (_currentSong != null &&
        _currentSong!.id != _prevSongIdForPaletteWarm &&
        _currentSong!.artworkUrl.isNotEmpty) {
      ArtworkPaletteCache.warm(_currentSong!.artworkUrl);
    }

    // Mini player reappear rules (moved here from MiniPlayer's State — see
    // the doc comment on _miniPlayerDismissed above for why). A dismiss
    // should not permanently hide the mini player for the rest of the
    // session: switching to a different song, or resuming playback on the
    // same song that was dismissed, both bring it back — matching every
    // other music app's "swipe away = dismiss this one instance" behavior
    // rather than "swipe away = never show again".
    if (_miniPlayerDismissed) {
      final differentSongStarted =
          _currentSong != null && _currentSong!.id != _miniPlayerDismissedSongId;
      final sameSongResumed = _currentSong != null &&
          _currentSong!.id == _miniPlayerDismissedSongId &&
          state.playing;
      if (differentSongStarted || sameSongResumed) {
        _miniPlayerDismissed = false;
        _miniPlayerDismissedSongId = null;
      }
    }

    // position handling shares the same behavior-tracking hooks the old
    // positionStream listener had.
    _onPosition(state.position);

    // Song-change detection (replaces currentIndexStream + 150ms debounce).
    if (state.currentIndex != null && state.currentIndex != _lastHandledIndex) {
      _indexDebounce?.cancel();
      final idx = state.currentIndex!;
      _indexDebounce = Timer(const Duration(milliseconds: 150), () {
        if (idx == _lastHandledIndex) return;
        _lastHandledIndex = idx;
        _onSongChanged(idx);
        _maybeExtendQueue(idx);
      });
    }

    notifyListeners();
  }

  bool _queueMatchesIds(List<String> ids) {
    if (_queue.length != ids.length) return false;
    for (var i = 0; i < ids.length; i++) {
      if (_queue[i].id != ids[i]) return false;
    }
    return true;
  }

  /// Rebuilds `_queue` in the order given by `ids`, reusing existing Song
  /// objects from the current mirror where possible (so artwork/metadata
  /// already fetched isn't thrown away just because native reordered or
  /// trimmed the queue).
  List<Song> _reconcileQueue(List<String> ids) {
    final byId = {for (final s in _queue) s.id: s};
    return ids.map((id) => byId[id]).whereType<Song>().toList();
  }

  // ---------------------------------------------------------------------------
  // SECTION: BEHAVIOR TRACKING
  //
  // Fires signals into RecentlyPlayedProvider which forwards to
  // RecommendationEngine. All signals are one-shot per song play.
  //
  // SIGNALS:
  //   SKIP   — user skips before 15 seconds (strong negative)
  //   COMPLETE — user reaches 80%+ of song (strong positive)
  //   REPLAY — user seeks back to start after already playing (strong positive)
  // ---------------------------------------------------------------------------

  void _onSongChanged(int index) {
    final q = _queue;
    if (q.isEmpty || index >= q.length) return;
    final song = q[index];

    // Reset all tracking state for new song
    _lastTrackedSong  = song;
    _completionFired  = false;
    _earlySkipArmed   = song.source != SongSource.local; // arm for online songs
    _replayArmed      = false;

    // History: save here — once the native engine has actually confirmed
    // and settled on this song (post 150ms debounce, see caller) — not on
    // tap. Previously `addPlay()` was fired straight from the UI tap
    // handler, before playback was confirmed; if the stream failed to
    // resolve (dead JioSaavn link, YouTube fallback exhausted, etc.) a
    // "played" entry still landed in History for a song that never
    // actually played. This is the single source of truth: it only fires
    // once per real song-change, matching exactly what the user heard.
    _rp?.addPlay(song);

    // Push liked-state for the new current song to the native session icon.
    final liked = _isSongLikedLookup?.call(song) ?? false;
    _engine.setCurrentSongLiked(liked);

    // Fire Worker /api/prewarm for the next 3-5 upcoming YT songs. Piggybacks
    // on the 150ms index-settle debounce above (see _onEngineState), so rapid
    // skips only trigger one prewarm burst for the index the user actually
    // lands on — not one per intermediate skip.
    _prewarmUpcoming(index);
  }

  // Next 3-5 upcoming YouTube songs — fire-and-forget Worker prewarm so the
  // stream is likely already KV-cached by the time the user reaches them.
  // ApiService.prewarmYtStream has its own per-session dedup (_prewarmedIds)
  // and skips songs whose URL is already locally cached, so calling this
  // repeatedly as the queue advances is cheap and safe.
  static const int _prewarmWindow = 5;

  void _prewarmUpcoming(int fromIndex) {
    final q = _queue;
    if (q.isEmpty) return;
    final end = (fromIndex + 1 + _prewarmWindow).clamp(0, q.length);
    for (var i = fromIndex + 1; i < end; i++) {
      ApiService.prewarmYtStream(q[i]);
    }
  }

  void _onPosition(Duration pos) {
    // NOTE: previously kept a `prevPosition = _position` local here for a
    // replay-detection check that compared prevPosition against the new
    // position — that check was removed (see REPLAY detection comment
    // below) in favor of a current-position-only check, which made this
    // variable dead. Removed to avoid an unused-variable lint warning.
    _position = pos;

    final song = _lastTrackedSong;
    if (song == null || song.source == SongSource.local) return;

    final posSeconds  = pos.inSeconds;
    final durSeconds  = _duration.inSeconds;

    // ── EARLY SKIP detection ──────────────────────────────────────────────
    // If song was armed (just started) and user skips while position < 15s,
    // the song-change handler will fire — we fire the skip signal there
    // via _fireEarlySkipIfArmed(). Here we just track: if position > 15s,
    // disarm early-skip.
    if (_earlySkipArmed && posSeconds >= 15) {
      _earlySkipArmed = false;
    }

    // ── COMPLETION detection ──────────────────────────────────────────────
    // Fire once when user reaches 80% of duration.
    if (!_completionFired && durSeconds > 10 && posSeconds > 0) {
      final pct = posSeconds / durSeconds;
      if (pct >= 0.80) {
        _completionFired = true;
        _rp?.notifyCompletion(song);
      }
    }

    // ── REPLAY detection ─────────────────────────────────────────────────
    // Arm replay when song is >30% through; fire if user seeks back to <5s.
    //
    // BUG: this required BOTH the new position AND the previous position to
    // already be <=5s ("prevPosition.inSeconds <= 5"). But prevPosition here
    // is simply whatever _position held on the call before this one — i.e.
    // the position the user seeked FROM. A genuine "seek back to start
    // after playing past 30%" always jumps from some position >5s (that's
    // the whole point — the user was well into the song) down to ~0s in a
    // single event. That single jump could never satisfy
    // "prevPosition <= 5", so this signal could essentially never fire for
    // the actual behavior it exists to detect — notifyReplay() was
    // effectively dead code, silently starving RecommendationEngine of a
    // real positive signal. Fixed to key off the CURRENT position only,
    // which is what "user is now near the start" actually means; disarming
    // still prevents re-firing until the song is played past 30% again.
    if (!_replayArmed && durSeconds > 10) {
      if (posSeconds / durSeconds > 0.30) _replayArmed = true;
    }
    if (_replayArmed && posSeconds <= 5) {
      _replayArmed = false; // disarm until >30% again
      _rp?.notifyReplay(song);
    }

    // ── LOOKAHEAD PRELOAD ──────────────────────────────────────────────────
    // REMOVED (was previously fired at 70% progress via
    // _engine.lookaheadResolve): this called Kotlin's lookaheadResolve(),
    // which resolves the next song's stream URL and then immediately
    // discards it — HybridStreamResolver.kt doesn't cache resolved URLs
    // natively, and lookaheadResolve() never calls player.addMediaItem(),
    // so the result was thrown away and the next song still resolved from
    // scratch on transition. Pure wasted network calls, no playback benefit.
    //
    // The actual gapless mechanism lives in two places that already cover
    // this properly:
    //   1. AurumAudioEngine.resolveQueueInBackground() (Kotlin) — fires the
    //      moment a queue starts playing, resolves the immediate next/prev
    //      song and adds it directly to ExoPlayer's own timeline via
    //      player.addMediaItem(), so seekToNext() is truly gapless.
    //   2. _prewarmUpcoming() above (Dart) — warms the Worker/CDN cache for
    //      the next 5 upcoming YouTube songs the moment the current index
    //      settles, so even songs beyond ExoPlayer's immediate window
    //      resolve fast when their turn comes.
  }

  // Called when user explicitly taps skipNext() — check if it was an early skip
  void _fireEarlySkipIfArmed() {
    final song = _lastTrackedSong;
    if (song == null) return;
    if (_earlySkipArmed) {
      _earlySkipArmed = false;
      _rp?.notifySkip(song);
    }
  }

  // ---------------------------------------------------------------------------
  // SECTION: AUTO-QUEUE EXTENSION
  //
  // Triggers when ≤8 songs remain in queue (doc corrected to match the
  // actual `remaining > 8` guard below — comment previously said ≤2,
  // which was stale/out of date with the code).
  // Uses RecommendationEngine-powered getAutoQueue (v3).
  // ---------------------------------------------------------------------------
  Future<void> _maybeExtendQueue(int index) async {
    final q = _queue;
    if (q.isEmpty) return;

    final remaining = q.length - 1 - index;
    if (q.length < 2 || remaining > 8 || _isAutoExtendingQueue) return;
    if (index >= q.length) return;

    _isAutoExtendingQueue = true;
    try {
      final current = q[index];
      // FIX ("Up Next khaali reh jata hai jab downloaded/local song chal
      // raha ho" — production gap): this used to hard-return the instant
      // the CURRENTLY PLAYING song was local, with no fallback at all — a
      // local song has no online catalog ID for getAutoQueue to seed
      // Saavn/YT recommendations from, so extending was skipped outright.
      // That meant Up Next silently stopped refilling for the rest of a
      // session anywhere a local song landed mid-queue: play a downloaded
      // track, and the "≤8 remaining" trigger above would keep firing on
      // every subsequent song-change, hit this same early return every
      // time, and Up Next would run dry with nothing ever added back.
      // Fix: fall back to the most recent NON-local song already in the
      // queue (walking backward from the current index) as the seed for
      // getAutoQueue instead — same recommendation quality a normal
      // extend gets, just anchored to the last online song the user was
      // actually listening to rather than the local one. Only skip
      // entirely (as before) when the ENTIRE queue so far is local —
      // there's genuinely nothing online to anchor to in that case.
      Song anchor = current;
      if (anchor.source == SongSource.local) {
        for (int i = index - 1; i >= 0; i--) {
          if (q[i].source != SongSource.local) {
            anchor = q[i];
            break;
          }
        }
        if (anchor.source == SongSource.local) return; // whole queue is local so far — nothing to anchor to
      }

      // Full dedup: existing queue IDs + RecommendationEngine session window
      final existingIds = <String>{
        ...q.map((s) => s.id),
        ...RecommendationEngine.sessionRecentIds,
      };

      // TUNED: 20 -> 30 per refill batch, keeping pace with the larger
      // ~80-song initial build above rather than trickling back down
      // to a much smaller buffer between refills.
      final nextSongs = await ApiService.getAutoQueue(
        anchor,
        limit: 30,
        existingQueueIds: existingIds,
      );

      // Final dedup safety check — FIX: was ID-only, so the same song
      // re-released under a different Saavn ID (movie OST vs "Best of"
      // compilation vs singer's greatest-hits) could still slip past this
      // and get added again later in the queue. Title-based check added
      // alongside the ID check so genuine repeats of the same song are
      // blocked even when their catalog IDs differ.
      //
      // FIX (upgraded — "same song re-appears hours later via auto-extend"):
      // exact-string title match alone misses re-uploads whose junk suffix
      // differs ("8K...", "With LYRICS...", "-Duet | Alka..."), same gap
      // as the initial queue build. This is the never-ending background
      // extend path, so leaving it on the weaker check meant a duplicate
      // could still sneak back in during a long listening session even
      // after the initial-queue fix. Smart title-head comparison (raw
      // titles, not pre-stripped) closes it here too.
      final currentQueueIds = _queue.map((s) => s.id).toSet();
      final currentQueueTitles = _queue.map((s) => _normTitleForDedup(s.title)).toSet();
      final currentQueueRawTitles = _queue.map((s) => s.title).toList();
      final toAdd = <Song>[];
      for (final s in nextSongs) {
        if (currentQueueIds.contains(s.id)) continue;
        final tk = _normTitleForDedup(s.title);
        if (currentQueueTitles.contains(tk)) continue;
        var isDup = false;
        for (final rawTitle in currentQueueRawTitles) {
          if (RecommendationEngine.isSameSongSmart(s.title, rawTitle)) { isDup = true; break; }
        }
        if (isDup) continue;
        currentQueueTitles.add(tk);
        currentQueueRawTitles.add(s.title);
        toAdd.add(s);
      }

      // Background metadata cleanup — see api_service.dart's "METADATA
      // CLEANUP" section for why this is safe here: the current song is
      // already playing, this only touches songs about to be appended to
      // Up Next, and it has its own hard timeout so a slow/failed lookup
      // just means those songs keep their original Saavn/YT titles.
      final cleanToAdd = await ApiService.enrichWithCleanMetadata(toAdd);

      for (final song in cleanToAdd) {
        await _engine.addToQueue(song);
        _queue.add(song);
      }

      // Prefetch next song's stream URL so it starts instantly
      if (cleanToAdd.isNotEmpty) {
        ApiService.prefetchNext(cleanToAdd.first);
        if (cleanToAdd.length > 1) ApiService.prefetchNext(cleanToAdd[1]);
        notifyListeners();
      }
    } catch (e) {
      // Silent to UI — auto-queue is background-only, never crashes UI —
      // but logged so a real failure (e.g. worker down) is diagnosable.
      debugPrint('[_maybeExtendQueue] failed: $e');
    } finally {
      _isAutoExtendingQueue = false;
    }
  }

  // ---------------------------------------------------------------------------
  // GETTERS (all unchanged)
  // ---------------------------------------------------------------------------
  bool     get isPlaying      => _isPlaying;
  bool     get isLoading      => _isLoading;
  bool     get resolveTakingLong => _resolveTakingLong;
  Duration get position       => _position;
  Duration get duration       => _duration;
  Duration get buffered       => _buffered;

  /// True when the engine still has meaningful unplayed audio buffered
  /// ahead of the current position. Used by SourceProvider so a
  /// connectivity drop doesn't yank an online stream mid-playback —
  /// same as Spotify, which keeps riding the buffer instead of cutting
  /// out the instant the network blips. A half-second cushion avoids
  /// treating normal buffered==position moments (right after a seek,
  /// or the very start of a track) as "no buffer".
  bool get hasPlaybackBuffer =>
      _buffered - _position > const Duration(milliseconds: 500);
  LoopMode get loopMode       => _loopMode;
  bool     get shuffle        => _shuffle;
  bool     get showFullPlayer => _showFullPlayer;
  Song?    get currentSong    => _currentSong;
  List<Song> get queue        => _queue;
  int      get currentIndex   => _currentIndex;
  bool     get hasSong        => _currentSong != null;

  // DEBUG ONLY — temporary diagnostic snapshot for tracking down the
  // "seek bar stuck at 00:00" report. Remove once root-caused. Exposes the
  // internal fields that decide whether the seek bar should be showing a
  // live position: is anything expected-but-unconfirmed, is the engine
  // reporting playing, does it have a real duration yet.
  String get debugSeekBarState =>
      'expectedSongId=$_expectedSongId currentSongId=${_currentSong?.id} '
      'isPlaying=$_isPlaying isLoading=$_isLoading '
      'position=${_position.inMilliseconds}ms duration=${_duration.inMilliseconds}ms '
      'localTickerActive=${_localPositionTicker?.isActive == true}';

  // ── Mini player visibility — lives here, not in MiniPlayer's State ──
  // This used to be split across two separate pieces of state: a
  // StatefulWidget-local `_dismissed` bool inside MiniPlayer, and a
  // static `ValueNotifier<bool>` (MiniPlayer.visibleNotifier) that
  // MainShell read to decide whether to paint the background behind it.
  // Two separate places holding "is it visible" is exactly what let them
  // drift apart: MiniPlayer's dispose() (widget lifecycle) used to write
  // to the static notifier, and a theme change rebuilding MaterialApp
  // could tear down and recreate MiniPlayer's State independently of
  // whether a song was still genuinely playing — leaving the notifier
  // stuck on a stale value until the user force-quit the app.
  //
  // Moving "is the mini player dismissed" into the provider means there
  // is exactly ONE source of truth for mini-player visibility anywhere
  // in the app: `hasSong && !_miniPlayerDismissed`, read live via
  // Selector/Consumer wherever it's needed. It lives exactly as long as
  // PlayerProvider does (the whole app session, created once above
  // MaterialApp) — a theme rebuild, a settings screen, a widget
  // remount, none of that can touch it, because none of those ever
  // dispose PlayerProvider. There is no separate notifier left to fall
  // out of sync, and therefore no class of bug where the background
  // persists with stale visibility — the underlying state literally
  // cannot exist independently of whether a song is playing anymore.
  bool _miniPlayerDismissed = false;
  String? _miniPlayerDismissedSongId;
  bool get miniPlayerVisible => hasSong && !_miniPlayerDismissed;

  /// Called when the user swipes the mini player away. Auto-clears itself
  /// the moment a different song starts, or the same song resumes playing
  /// (see [_onSongChanged]/onIsPlayingChanged plumbing below) — same
  /// reappear rules the old widget-local `_dismissed` flag followed.
  void dismissMiniPlayer() {
    _miniPlayerDismissed = true;
    _miniPlayerDismissedSongId = _currentSong?.id;
    notifyListeners();
  }

  /// Explicitly clears the dismiss state — used when the mini player style
  /// switches to Compact Bar, which has no dismiss gesture of its own and
  /// must always show whenever a song is loaded, regardless of whether the
  /// Capsule style was mid-dismissed before the switch.
  void clearMiniPlayerDismissed() {
    if (!_miniPlayerDismissed) return;
    _miniPlayerDismissed = false;
    _miniPlayerDismissedSongId = null;
    notifyListeners();
  }

  double get progress {
    if (_duration.inMilliseconds == 0) return 0.0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  String get positionString => _formatDuration(_position);
  String get durationString => _formatDuration(_duration);

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      final h = d.inHours.toString();
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ---------------------------------------------------------------------------
  // PLAYBACK CONTROL
  // ---------------------------------------------------------------------------
  // FIX ("Up Next empty/wrong after playing from Liked Songs / a playlist /
  // album / mix"): playSong()'s caller-supplied-queue branch used to ALWAYS
  // trim `_queue` down to just the tapped song and rebuild Up Next from a
  // live online recommendation call (_buildInitialSmartQueue /
  // getAutoQueue), discarding whatever real queue the caller passed in —
  // see the FIX comment on that branch below for why that behavior exists
  // at all (it's correct for search results, which are just "whatever
  // matched the typed text", not a real playlist).
  //
  // The problem: that same trim-and-rebuild logic ALSO fired for taps that
  // came from a genuinely curated, user-picked list — Liked Songs, a saved
  // playlist, an album, a mix, a library section, Recently Played — where
  // the passed-in `queue` **is** exactly what the user wants Up Next to be.
  // Every one of those call sites already passes the full song list with a
  // correct `index`, so there is nothing to "rebuild" — the fix in those
  // cases is to just play that queue as given, online or fully offline.
  // `curatedQueue: true` marks that case explicitly instead of relying on
  // heuristics like queue length. Search/"just play this song" call sites
  // continue to omit it (defaults false) and keep the old smart-queue
  // rebuild behavior unchanged.
  Future<void> playSong(Song song, {List<Song>? queue, int? index, bool curatedQueue = false}) async {
    _lastHandledIndex = null;
    _uiPlaySession++;
    final mySession = _uiPlaySession;

    // FIX ("player still shows black for a moment on first tap"): the full
    // player's background color palette was only ever extracted once
    // FullPlayerScreen itself had already built and its first frame
    // callback fired — i.e. AFTER the push transition had already started
    // (or finished). That meant even with the 1.2s extraction timeout in
    // place, a brand-new (never-before-played) song's artwork still had to
    // be decoded from a cold start before any themed color could show, and
    // none of that decode work overlapped with the screen-open animation.
    // Firing the warm-up here — the instant playSong() is called, which is
    // the same tap that triggers navigation to the full player in every
    // call site (song tile, mini player, library, search, home) — means
    // the palette extraction now runs in parallel with the push transition
    // instead of starting only after it. By the time the full player's
    // first frame is up, the palette is very often already sitting in
    // cache, so _extractColor's `ArtworkPaletteCache.peek()` fast path
    // hits immediately and the themed background applies on that same
    // first frame instead of a visible beat later.
    if (song.artworkUrl.isNotEmpty) {
      ArtworkPaletteCache.warm(song.artworkUrl);
    }

    // FIX ("Up Next empty after tapping a downloaded song, even with 20+
    // songs downloaded"): the caller-supplied-queue branch below always
    // trimmed `_queue` to just the tapped song and rebuilt Up Next from
    // ApiService.getAutoQueue — a live Saavn/YouTube network call. That's
    // correct for search/library taps (see the FIX comment further down),
    // but downloaded songs are frequently played with no network at all —
    // that's the whole point of downloading them — so getAutoQueue came
    // back empty and Up Next stayed permanently empty even though the
    // Downloads screen had already built and passed a full, valid,
    // fully-offline queue (every entry resolved to its localPath copy).
    // Detect that case up front — every song in the caller's queue already
    // has a localPath — and use it as-is, skipping the online smart-queue
    // rebuild entirely, instead of discarding real offline songs in favor
    // of a network call that was never going to succeed.
    final isFullyOfflineQueue =
        queue != null && queue.isNotEmpty && queue.every((s) => s.isLocal);

    if (isFullyOfflineQueue) {
      _queue = List<Song>.from(queue);
      _currentIndex = index!.clamp(0, _queue.length - 1);
      _currentSong = _queue[_currentIndex];
      _expectedSongId = _currentSong!.id;
      _expectedSongIdSetAt = DateTime.now();
      _position = Duration.zero;
      _duration = Duration.zero;
      _isLoading = true;
      notifyListeners();
      _prewarmUpcoming(_currentIndex);
      try {
        await _engine.playQueue(_queue, _currentIndex).timeout(const Duration(seconds: 8));
      } catch (e) {
        if (mySession != _uiPlaySession) return;
        _isLoading = false;
        _expectedSongId = null;
        _expectedSongIdSetAt = null;
        _lastFailedSong = song;
        _playbackError = 'Couldn\'t play "${song.title}". Tap to retry.';
        notifyListeners();
        return;
      }
      return;
    }

    if (curatedQueue && queue != null && queue.isNotEmpty && index != null) {
      // Caller explicitly marked this as a real, user-picked list (Liked
      // Songs, playlist, album, mix, library section, Recently Played).
      // Use it exactly as given — no trimming, no online rebuild — same
      // treatment as the fully-offline branch above, just without
      // requiring every song to have a localPath.
      _queue = List<Song>.from(queue);
      _currentIndex = index.clamp(0, _queue.length - 1);
      _currentSong = _queue[_currentIndex];
      _expectedSongId = _currentSong!.id;
      _expectedSongIdSetAt = DateTime.now();
      _position = Duration.zero;
      _duration = Duration.zero;
      _isLoading = true;
      notifyListeners();
      _prewarmUpcoming(_currentIndex);
      try {
        await _engine.playQueue(_queue, _currentIndex).timeout(const Duration(seconds: 8));
      } catch (e) {
        if (mySession != _uiPlaySession) return;
        _isLoading = false;
        _expectedSongId = null;
        _expectedSongIdSetAt = null;
        _lastFailedSong = song;
        _playbackError = 'Couldn\'t play "${song.title}". Tap to retry.';
        notifyListeners();
        return;
      }
      if (mySession != _uiPlaySession) return;
      // Still extend Up Next with real recommendations once the curated
      // list runs low — same ≤8-remaining auto-extend path used elsewhere
      // — but only ever appended after every curated song, never replacing
      // them.
      if (_queue.length - _currentIndex <= 8 && song.source != SongSource.local) {
        _buildInitialSmartQueue(song, alreadyInQueue: _queue.map((s) => s.id).toSet(), sessionId: mySession);
      }
      return;
    }

    if (queue != null && index != null) {
      // FIX ("Up Next full of unrelated reupload junk after tapping a
      // search result"): a caller-supplied queue (search results, library
      // list, etc.) is just "whatever else was on screen when the user
      // tapped" — it was never a vetted recommendation list, and in
      // search's case it's every song that matched the *typed text*,
      // which has nothing to do with the tapped song's actual sound.
      // Passing that whole list straight into `_queue` here meant every
      // slot right after the tapped song was raw search/library junk,
      // and the real recommendation engine (getAutoQueue, below) only
      // ever got appended after it. Trimming to just the tapped song
      // means Up Next is built fresh from `_buildInitialSmartQueue`
      // every time — the exact same real-recommendation path already
      // used when no queue is passed at all — so search/library taps and
      // "just play this song" taps now produce an identical, relevant
      // Up Next instead of two different behaviors.
      //
      // NOTE: this branch is now only reached when curatedQueue is false
      // (or wasn't set) — see the curatedQueue branch above for real
      // playlist/liked/album/mix taps, which keep the caller's queue as-is.
      _queue = [song];
      _currentIndex = 0;
      _currentSong = song;
      _expectedSongId = song.id;
      _expectedSongIdSetAt = DateTime.now();
      // FIX (progress bar briefly shows old song's scale on tap): see the
      // matching fix in skipNext()/skipPrev()/skipToIndex() — same issue,
      // just for the direct-tap path. Without this, tapping a new song
      // while a longer one was playing could show a stale, too-small
      // progress fraction for the loading window before the real state
      // event corrects it.
      _position = Duration.zero;
      _duration = Duration.zero;
      // BUG: _isLoading was never set true here — it's only ever driven
      // by the native engine's state stream, which doesn't fire until
      // sometime after this await starts. On a slow network that left a
      // window right after tap where the UI (mini player / full player
      // both bind to isLoading for a spinner) still showed the OLD play/
      // pause icon instead of any loading indicator, even though the new
      // song genuinely hadn't started yet.
      _isLoading = true;
      notifyListeners();

      // Fire prewarm for the next 3-5 songs immediately on queue load —
      // don't wait for the 70%-of-song or index-settle hooks. This overlaps
      // the Worker round-trip with the current song's own start-up latency
      // instead of stacking after it.
      _prewarmUpcoming(_currentIndex);

      try {
        // FIX: comment below already described this as handling a "hung"
        // native call, but nothing here actually enforced a timeout —
        // _engine.playQueue() could hang indefinitely on a stuck
        // MethodChannel round-trip and this await would simply never
        // return, leaving _isLoading/_expectedSongId stuck and the UI
        // frozen on "loading" with no error surfaced. The catch block only
        // ever fires on a genuine exception, not a silent hang.
        // Play just the tapped song natively — _queue was trimmed to
        // [song] above, so the native engine's own queue starts clean too;
        // getAutoQueue-built recommendations get appended via
        // _engine.addToQueue() inside _buildInitialSmartQueue once ready,
        // same as the no-queue-passed path below.
        await _engine.playQueue(_queue, _currentIndex).timeout(const Duration(seconds: 8));
      } catch (e) {
        if (mySession != _uiPlaySession) return; // superseded — ignore stale failure
        // Native call hung/timed out or threw a PlatformException. Clear
        // the loading state and surface an error instead of leaving the
        // UI stuck showing "loading" forever with the song that never
        // actually started.
        _isLoading = false;
        _expectedSongId = null;
        _expectedSongIdSetAt = null;
        _lastFailedSong = song;
        _playbackError = 'Couldn\'t play "${song.title}". Tap to retry.';
        notifyListeners();
        return;
      }
      if (mySession != _uiPlaySession) return; // superseded by a newer tap
      // FIX ("Up Next full of unrelated reupload junk after tapping a
      // search result" — e.g. playing "Ye Dua Hai Meri Rab Se" from search
      // then seeing 8 different reuploads of an unrelated "Gori Hai
      // Kalaiyan" fill Up Next): this used to only build a real smart
      // queue when the caller-supplied queue was short (<10). Search
      // passes the entire on-screen results list (often 20+ songs) as the
      // queue, so that guard was false and getAutoQueue never ran at all
      // — the raw list of whatever else matched the *search text* became
      // permanent Up Next, with zero relation to the song actually
      // playing. The ≤8-remaining auto-extend path would eventually kick
      // in, but only after skipping deep into that irrelevant batch.
      // Any caller-provided queue is just "what was on screen when you
      // tapped" — never a vetted recommendation list — so a real
      // similar-songs queue always needs building around the tapped song,
      // regardless of how many songs happened to be on that screen.
      // Same isLocal-vs-source distinction as the no-queue branch below:
      // isLocal is also true for downloaded songs (they keep a localPath
      // for offline playback), so gating on isLocal here would skip smart
      // queue building for a downloaded song tapped from search/library —
      // even though downloaded songs keep their real source/id and
      // recommendations still work fine for them. Only genuinely imported
      // local files (SongSource.local) have no online identity to base
      // recommendations on.
      if (song.source != SongSource.local) {
        _buildInitialSmartQueue(song, alreadyInQueue: queue.map((s) => s.id).toSet(), sessionId: mySession);
      }
    } else {
      _queue = [song];
      _currentIndex = 0;
      _currentSong = song;
      _expectedSongId = song.id;
      _expectedSongIdSetAt = DateTime.now();
      // See matching comment in the queue-based branch above.
      _position = Duration.zero;
      _duration = Duration.zero;
      _isLoading = true;
      notifyListeners();

      try {
        // FIX — same real hang risk as playQueue() above: no timeout
        // previously enforced here despite the sibling catch block already
        // being written to handle "the call hung" as if it would surface.
        await _engine.playSong(song).timeout(const Duration(seconds: 8));
      } catch (e) {
        if (mySession != _uiPlaySession) return; // superseded — ignore stale failure
        _isLoading = false;
        _expectedSongId = null;
        _expectedSongIdSetAt = null;
        _lastFailedSong = song;
        _playbackError = 'Couldn\'t play "${song.title}". Tap to retry.';
        notifyListeners();
        return;
      }
      if (mySession != _uiPlaySession) return; // superseded by a newer tap
      // FIX: previously gated on `!song.isLocal`. isLocal is also true for
      // downloaded songs (they have localPath set for offline playback),
      // so tapping a downloaded song never auto-built an upNext queue at
      // all. Downloaded songs keep their real source (saavn/youtube) and
      // id, so recommendations still work for them — only genuinely
      // imported local files (SongSource.local) have no online identity
      // to base recommendations on, so we skip just those.
      if (song.source != SongSource.local) {
        _buildInitialSmartQueue(song, alreadyInQueue: {song.id}, sessionId: mySession);
      }
    }
    notifyListeners();
  }

  // Holds the most recent _buildInitialSmartQueue request that arrived
  // while a previous one was still in flight, so it can be replayed once
  // the in-flight build finishes instead of being silently dropped. Only
  // ever holds at most one — the latest request always wins over any
  // earlier one that was also waiting.
  ({Song song, Set<String> alreadyInQueue, int sessionId})? _pendingQueueBuild;

  Future<void> _buildInitialSmartQueue(
    Song song, {
    required Set<String> alreadyInQueue,
    required int sessionId,
    bool isRetry = false,
  }) async {
    // FIX (permanent missing Up Next queue on rapid song switching): this
    // used to check `_isBuildingInitialQueue` BEFORE checking whether this
    // call's own sessionId had already been superseded. If song A's build
    // was still in flight when the user tapped song B, B's call landed
    // here, saw `_isBuildingInitialQueue == true` (still true from A), and
    // returned immediately — song B then had NO Up Next queue built for it
    // at all, permanently, since nothing else ever retries this. The user
    // would see an empty/short queue after fast switching until the
    // separate ≤8-remaining auto-extend path eventually kicked in much
    // later. Checking staleness first means a superseded call (song A's,
    // once B has taken over) exits for the *correct* reason — it's simply
    // stale — while a genuinely current call (song B's) is never blocked
    // just because an old one happened to still be unwinding.
    if (sessionId != _uiPlaySession) return;
    if (_isBuildingInitialQueue) {
      // Still the current session, just arrived while an older song's
      // build hasn't wound down yet — remember it so it gets its own
      // build pass the moment that finishes, instead of never getting one.
      _pendingQueueBuild = (song: song, alreadyInQueue: alreadyInQueue, sessionId: sessionId);
      return;
    }
    _isBuildingInitialQueue = true;
    try {
      await RecommendationEngine.load();
      if (sessionId != _uiPlaySession) return;
      // FIX ("same song repeats 5-7x in Up Next from different albums"):
      // getAutoQueue dedups by Saavn track ID and by title, but only
      // *within* a single call's own pool. The same song re-released
      // across a movie OST, a "Best of" compilation, and a singer's
      // greatest-hits album has a different Saavn ID in each, so Phase 1
      // and Phase 2 — two separate getAutoQueue calls — could each pick a
      // different-ID copy of the same title and both pass their own
      // internal dedup untouched. Tracking normalized titles here, across
      // both phases and the song currently playing, closes that gap.
      final queuedTitles = <String>{
        _normTitleForDedup(song.title),
        for (final s in _queue) _normTitleForDedup(s.title),
      };
      // Raw (unstripped) titles in parallel with `queuedTitles`, so the
      // smart head-comparison below still has separators (|, :, -,
      // brackets) to split the real title from uploader/quality/credit
      // noise — _normTitleForDedup already strips those for the
      // exact-match check above, which would blind the smart comparison
      // if reused here.
      final queuedRawTitles = <String>[
        song.title,
        for (final s in _queue) s.title,
      ];
      // Phase 1: 20 songs fast
      final phase1 = await ApiService.getAutoQueue(song, limit: 20, existingQueueIds: alreadyInQueue);
      if (sessionId != _uiPlaySession) return;
      if (phase1.isNotEmpty) {
        final currentIds = _queue.map((s) => s.id).toSet();
        final toAdd = <Song>[];
        for (final s in phase1) {
          if (currentIds.contains(s.id)) continue;
          final tk = _normTitleForDedup(s.title);
          // FIX ("same song 5-8x in Up Next"): exact-string containment
          // check alone misses re-uploads whose junk suffix differs
          // ("8K...", "With LYRICS...", "-Duet | Alka...") — see the
          // matching fix in getAutoQueue's addToPool and rankAndFilter.
          // This is the third and last place the same exact-match gap
          // existed, so it needed the same smart title-head check,
          // compared on RAW titles, to close the loop end to end.
          if (queuedTitles.contains(tk)) continue;
          var isDup = false;
          for (final rawTitle in queuedRawTitles) {
            if (RecommendationEngine.isSameSongSmart(s.title, rawTitle)) { isDup = true; break; }
          }
          if (isDup) continue;
          queuedTitles.add(tk);
          queuedRawTitles.add(s.title);
          toAdd.add(s);
        }
        // Background metadata cleanup (see api_service.dart) — re-check
        // staleness after it since this is async and the user may have
        // switched songs while these lookups were in flight.
        final cleanToAdd = await ApiService.enrichWithCleanMetadata(toAdd);
        if (sessionId != _uiPlaySession) return;
        for (final s in cleanToAdd) {
          if (sessionId != _uiPlaySession) return;
          await _engine.addToQueue(s);
          _queue.add(s);
        }
        alreadyInQueue.addAll(cleanToAdd.map((s) => s.id));
        notifyListeners();
      }
      // Phase 2: 60 more songs (Phase 1's 20 + this = 80 total). TUNED:
      // raised from 40 to 60 so a freshly-started session's Up Next holds
      // ~80 songs up front instead of ~60 — matches the continuous
      // ≤8-remaining auto-extend below in "never feels like it's about to
      // run out" spirit, just for the very first build too.
      final phase2 = await ApiService.getAutoQueue(song, limit: 60, existingQueueIds: {
        ...alreadyInQueue, ...RecommendationEngine.sessionRecentIds,
      });
      if (sessionId != _uiPlaySession) return;
      if (phase2.isNotEmpty) {
        final currentIds = _queue.map((s) => s.id).toSet();
        final toAdd = <Song>[];
        for (final s in phase2) {
          if (currentIds.contains(s.id)) continue;
          final tk = _normTitleForDedup(s.title);
          if (queuedTitles.contains(tk)) continue;
          var isDup = false;
          for (final rawTitle in queuedRawTitles) {
            if (RecommendationEngine.isSameSongSmart(s.title, rawTitle)) { isDup = true; break; }
          }
          if (isDup) continue;
          queuedTitles.add(tk);
          queuedRawTitles.add(s.title);
          toAdd.add(s);
        }
        // Background metadata cleanup (see api_service.dart) — re-check
        // staleness after it, same reasoning as Phase 1 above.
        final cleanToAdd = await ApiService.enrichWithCleanMetadata(toAdd);
        if (sessionId != _uiPlaySession) return;
        for (final s in cleanToAdd) {
          if (sessionId != _uiPlaySession) return;
          await _engine.addToQueue(s);
          _queue.add(s);
        }
        notifyListeners();
      }
    } catch (e, st) {
      // FIX ("Up Next kabhi bhi empty reh jaata hai, koi bhi song play
      // karo"): this whole build — RecommendationEngine.load(), two
      // getAutoQueue network calls, enrichWithCleanMetadata, and every
      // _engine.addToQueue() native call — used to be wrapped in a bare
      // `catch (_) {}`. ANY single failure anywhere in that chain (a
      // timed-out host, a bad response, a native MethodChannel hiccup on
      // one addToQueue call) silently killed the ENTIRE build with zero
      // log, zero retry, and zero visibility — Up Next simply stayed
      // empty for that song forever, with nothing telling you why. Now
      // the failure is at least logged (visible in adb logcat / debug
      // console) instead of vanishing, and — since most real-world causes
      // here are transient (a cold/slow API host, a brief native channel
      // hiccup) rather than permanent — one quick retry is attempted
      // after a short delay instead of giving up on this song's Up Next
      // for the rest of the session. Only retries if still the current
      // song (stale sessionId means the user already moved on, so a retry
      // would just build a queue nobody will see).
      debugPrint('[_buildInitialSmartQueue] failed for "${song.title}": $e\n$st');
      // FIX (bounded retry): capped to exactly ONE retry via isRetry —
      // without this, a sustained backend outage (not a one-off blip)
      // would have this catch block re-triggered every ~2s for as long
      // as the user keeps this song playing, since each retry's own
      // failure lands back in this same catch and would otherwise
      // schedule yet another one indefinitely. One retry is enough to
      // absorb the common transient case (brief timeout, momentary
      // native-channel hiccup); if it fails twice in a row the issue is
      // almost certainly not transient, and repeatedly hammering a down
      // host every 2 seconds for the rest of the session helps nobody.
      if (sessionId == _uiPlaySession && !isRetry) {
        Future.delayed(const Duration(seconds: 2), () {
          if (sessionId != _uiPlaySession) return; // moved on — don't bother
          // RACE FIX: don't force _isBuildingInitialQueue = false here.
          // The finally block below (which always runs right after this
          // catch, same call) may have already replayed a DIFFERENT
          // pending build (a rapid song-switch that queued up while this
          // one was in flight) — that replay could still genuinely be
          // running 2 seconds later. Blindly clearing the flag here would
          // let this retry start concurrently with that unrelated build,
          // both appending to `_queue`/the native engine at the same
          // time. Only retry if the flag is still false on its own —
          // i.e. nothing else claimed it in the meantime — otherwise
          // just drop this retry silently; whatever build IS running
          // will produce a real Up Next regardless.
          if (_isBuildingInitialQueue) return;
          unawaited(_buildInitialSmartQueue(song, alreadyInQueue: alreadyInQueue, sessionId: sessionId, isRetry: true));
        });
      }
    } finally {
      _isBuildingInitialQueue = false;
      // Always tell the UI the loading flag flipped, even if phase1/phase2
      // both ended up empty and neither of their own notifyListeners()
      // calls above ever fired — without this, a build that genuinely
      // found nothing would leave the Queue screen's "finding songs..."
      // state stuck forever instead of falling through to a real empty
      // state message. Guarded on sessionId so a stale/superseded build
      // finishing late doesn't cause a pointless rebuild for a screen
      // that's already moved on to a different song.
      if (sessionId == _uiPlaySession) notifyListeners();
      // A newer song's build request arrived while this one was running
      // and got parked above — replay it now, but only if it's still the
      // current session (the user may have moved on yet again while THIS
      // build was finishing, in which case it's stale and simply dropped,
      // same as every other sessionId check in this file).
      final pending = _pendingQueueBuild;
      _pendingQueueBuild = null;
      if (pending != null && pending.sessionId == _uiPlaySession) {
        unawaited(_buildInitialSmartQueue(
          pending.song,
          alreadyInQueue: pending.alreadyInQueue,
          sessionId: pending.sessionId,
        ));
      }
    }
  }

  // FIX (duplicate-titles-in-queue root cause): mirrors api_service's own
  // private _normTitle so two Saavn entries of the same song from
  // different albums/compilations normalize to the same key here too,
  // even though that private helper isn't accessible across files.
  static String _normTitleForDedup(String title) {
    final clean = title
        .toLowerCase()
        .replaceAll(RegExp(r'\b(remix|lofi|lo[- ]?fi|slowed|reverb|nightcore|cover|'
                           r'karaoke|instrumental|bass[ -]?boost(?:ed)?|8d|sped[- ]?up|'
                           r'reprise|mashup|acoustic|unplugged|official|audio|video|'
                           r'lyric(?:s)?|full song|hd|4k)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), '')
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .trim();
    return clean.substring(0, clean.length.clamp(0, 30));
  }

  // Restores the last queue into the UI/notification on app reopen WITHOUT
  // starting playback. NativeAudioEngine has no dedicated "silent load"
  // method as of this bridge version, so we populate the local mirror
  // (queue/currentSong/currentIndex) directly for immediate UI display and
  // rely on the native session simply staying idle until play() is
  // explicitly called — no playQueue()/play() call is made here, so no
  // network resolve and no playback start occurs.
  Future<void> restoreQueueSilently(List<Song> queue, int index) async {
    _queue = List<Song>.from(queue);
    _currentIndex = index.clamp(0, queue.isEmpty ? 0 : queue.length - 1);
    _currentSong = queue.isNotEmpty ? queue[_currentIndex] : null;
    // BUG: _lastHandledIndex was left untouched (still null from provider
    // construction) after a silent restore. The next real state event from
    // the native engine — which, on app reopen, reports this SAME restored
    // index since nothing has changed yet — would see
    // `state.currentIndex != _lastHandledIndex` (null != restored index)
    // and treat it as a genuine song change, firing _onSongChanged().
    // That calls _rp?.addPlay(song), silently logging a spurious "played"
    // entry into Recently Played/History for a song the user hasn't
    // actually played yet this session — just restored on app start.
    // Setting it here up front means the upcoming state event, which will
    // report the same index, is correctly recognized as "nothing changed".
    _lastHandledIndex = _currentSong != null ? _currentIndex : null;
    notifyListeners();
  }

  Future<void> togglePlay() async {
    // BUG: no optimistic update here at all — the play/pause icon in the
    // UI only flips once _isPlaying is overwritten by the NEXT engine
    // state event, so every tap has a native round-trip's worth of delay
    // before the button visually responds. skipNext/skipPrev already got
    // this optimistic treatment; this button hadn't.
    if (_isPlaying) {
      _isPlaying = false;
      notifyListeners();
      await _engine.pause();
    } else {
      _isPlaying = true;
      // STABILITY FIX ("pause/play button click karne pe bump/jhatka
      // hota hai" — every tap, not just slow resumes): _isLoading used to
      // flip true immediately, unconditionally, on every single resume —
      // even the overwhelmingly common case where audio is already
      // buffered and _engine.play() resolves in a few milliseconds. The
      // play button's icon is wrapped in an AnimatedSwitcher (200ms
      // scale+fade both ways) that swaps to a spinner the instant
      // isLoading flips, then swaps BACK to the pause icon the instant
      // the near-instant play() call resolves a moment later — two
      // consecutive 200ms icon-swap animations firing back-to-back on
      // what the user experiences as a single tap. That double-swap is
      // exactly the visible "bump". A genuinely slow resume (real
      // re-buffer, network drop, long-idle stream-URL expiry — the case
      // this flag exists for, per the comment below) still needs the
      // spinner so the tap doesn't look like it silently did nothing.
      // The fix: only surface isLoading if the engine call hasn't
      // resolved within a short grace window — long enough that a normal
      // instant resume never shows it (closing the bump), short enough
      // that a real stall still gets its loading feedback almost as fast
      // as before.
      bool resolved = false;
      unawaited(Future.delayed(const Duration(milliseconds: 120), () {
        if (!resolved && _isPlaying) {
          _isLoading = true;
          notifyListeners();
        }
      }));
      // SMOOTHNESS: resuming after the app sat backgrounded a while (or
      // after a network drop) can need a brief re-buffer before audio
      // actually resumes — during that gap _isPlaying was already true
      // (optimistic) but nothing was audible yet, which read as the app
      // silently hanging with no explanation. Surfacing isLoading here
      // too means the UI's existing spinner (already wired to isLoading
      // everywhere) covers this gap instead of showing a bare "playing"
      // state with no sound and no feedback. The real state event corrects
      // isLoading the instant playback genuinely resumes, same as it
      // already does for every other loading transition in this file.
      // FIX (spinner stuck forever on resume after a long idle period —
      // e.g. tapping Auto Sleep Guard's "Resume" action, or any resume
      // where the loaded stream URL has since expired, JioSaavn/YouTube
      // URLs commonly do after several hours): unlike playSong()/
      // playQueue(), this call had no timeout and no catch — if the
      // native play() hangs or the resulting failure is a player error
      // event that, for whatever reason, doesn't cleanly round-trip back
      // to _isLoading via _onEngineState, nothing here ever closes the
      // optimistic spinner set two lines up. Same belt-and-suspenders
      // pattern as playSong/playQueue: a bounded wait, with the loading
      // state force-cleared in the catch so a stuck native call can never
      // leave the UI spinning with no way out.
      try {
        await _engine.play().timeout(const Duration(seconds: 8));
        resolved = true;
        if (_isLoading) {
          _isLoading = false;
          notifyListeners();
        }
      } catch (e) {
        resolved = true;
        _isLoading = false;
        _playbackError = 'Couldn\'t resume playback. Tap to retry.';
        notifyListeners();
      }
      // Auto Sleep Guard: an explicit in-app play tap is real activity —
      // resets its inactivity window the same as a screen unlock would.
      // Native-originated play (lock-screen/notification/widget buttons)
      // is already covered independently on the native side.
      unawaited(_engine.autoSleepGuardRecordActivity());
    }
  }

  Future<void> seek(double ratio) async {
    if (_duration == Duration.zero) return;
    final pos = Duration(milliseconds: (_duration.inMilliseconds * ratio).round());
    await _engine.seek(pos);
    unawaited(_engine.autoSleepGuardRecordActivity());
  }

  Future<void> seekTo(Duration pos) {
    unawaited(_engine.autoSleepGuardRecordActivity());
    return _engine.seek(pos);
  }

  /// Returns true if skip was allowed, false if limit reached (UI should show gate).
  Future<bool> skipNext() async {
    if (skipLimitReached) return false; // caller shows PremiumGate
    unawaited(_engine.autoSleepGuardRecordActivity());
    _recordSkip();
    _fireEarlySkipIfArmed(); // ← behavior tracking hook

    // The optimistic "just show queue[currentIndex + 1] immediately" guess
    // below is only correct in linear (non-shuffled) order — ExoPlayer's
    // actual shuffled "next" is a different index entirely, so applying
    // this guess while shuffle is on used to briefly flash the wrong
    // song's title/artwork before the real native state event corrected
    // it a beat later. Skipping the guess when shuffled means the UI just
    // waits those same tens-of-milliseconds for the authoritative index
    // instead of showing something wrong in the meantime.
    // BUG: rapid repeated taps (spam-skip) had no equivalent of
    // playSong()'s _uiPlaySession guard. Each tap bumped _currentIndex
    // optimistically and fired _engine.skipToNext() independently; if the
    // native side coalesces/drops rapid successive skip calls (common in
    // real players to avoid hammering ExoPlayer), the optimistic index can
    // run ahead of where native actually lands — e.g. three fast taps
    // advance _currentIndex by 3, but native only actually advances by 1.
    // The UI would show a song 2 positions further than what's really
    // about to play until the next real state event forced a resync,
    // which could itself show a visible "snap back" to an earlier song.
    // Setting _expectedSongId here reuses the exact same stale-event guard
    // playSong() already relies on: the real state event that eventually
    // arrives is authoritative and will correct any drift, and until it
    // does, in-flight/stale events can't clobber this optimistic guess.
    if (!_shuffle && _currentIndex + 1 < _queue.length) {
      _currentIndex += 1;
      _currentSong = _queue[_currentIndex];
      _lastHandledIndex = _currentIndex;
      _expectedSongId = _currentSong!.id;
      _expectedSongIdSetAt = DateTime.now();
      // FIX (progress bar briefly shows wrong scale after skip): title/
      // artwork/background all update optimistically in this block, but
      // _position/_duration were left untouched — still the OLD song's
      // values until the native state event round-trips back. A 5:30
      // song's progress fraction (position/duration) computed against a
      // freshly-tapped 3:00 song's actual playback position reads as a
      // visibly wrong progress-bar fill for that gap, right as everything
      // else has already (correctly) snapped to the new song. Resetting
      // both to zero here matches every other piece of optimistic state
      // in this block — the real event corrects it a beat later exactly
      // like it does for _currentSong itself.
      _position = Duration.zero;
      _duration = Duration.zero;
      // Warm palette right here, same tick as the optimistic title/artwork
      // update — not left to wait for the native engine's state event to
      // round-trip back through _onSongChanged. Previously title/artwork
      // snapped instantly on skip (this optimistic block) but the full
      // player's background color only started decoding once the native
      // event arrived, so on every skip the background visibly lagged
      // behind the rest of the UI for a beat — the "awkward" delay.
      if (_currentSong!.artworkUrl.isNotEmpty) {
        ArtworkPaletteCache.warm(_currentSong!.artworkUrl);
      }
      notifyListeners();
      // FIX (100-song rapid-fire stability): don't fire the native call
      // for THIS tap yet — schedule/reset a short debounce instead. If
      // more taps land within the window, this same call keeps getting
      // rescheduled and only the LAST tap's target index is kept. Only
      // once taps actually stop for _skipDebounceWindow does one single
      // native skipToQueueItem() fire, jumping straight to wherever the
      // user actually landed. See the field doc comment above for why.
      _scheduleSkipFlush(_currentIndex);
    } else {
      // Shuffled or already at the end of the queue — no safe optimistic
      // guess to make (see the doc comment on the optimistic block above).
      // Flush any already-pending debounced skip immediately so this tap
      // isn't silently swallowed, then fall through to a direct call.
      _skipDebounce?.cancel();
      _skipDebounce = null;
      _skipDebounceTargetIndex = null;
      final myExpectedId = _expectedSongId;
      try {
        await _engine.skipToNext().timeout(const Duration(seconds: 4));
      } catch (e) {
        if (_expectedSongId == myExpectedId) {
          _expectedSongId = null;
          _expectedSongIdSetAt = null;
          notifyListeners();
        }
      }
    }
    return true;
  }

  Future<void> skipPrev() async {
    unawaited(_engine.autoSleepGuardRecordActivity());
    // Same reasoning as skipNext — only safe to guess the next index
    // optimistically when the queue is in linear order.
    if (!_shuffle && _currentIndex - 1 >= 0) {
      _currentIndex -= 1;
      _currentSong = _queue[_currentIndex];
      _lastHandledIndex = _currentIndex;
      _expectedSongId = _currentSong!.id;
      _expectedSongIdSetAt = DateTime.now();
      // See matching comment in skipNext() — keeps the progress bar from
      // briefly showing the old song's duration scale after a skip.
      _position = Duration.zero;
      _duration = Duration.zero;
      if (_currentSong!.artworkUrl.isNotEmpty) {
        ArtworkPaletteCache.warm(_currentSong!.artworkUrl);
      }
      notifyListeners();
      // See matching comment in skipNext() — coalesce rapid taps into one
      // native call instead of one round-trip per tap.
      _scheduleSkipFlush(_currentIndex);
    } else {
      _skipDebounce?.cancel();
      _skipDebounce = null;
      _skipDebounceTargetIndex = null;
      final myExpectedId = _expectedSongId;
      try {
        await _engine.skipToPrevious().timeout(const Duration(seconds: 4));
      } catch (e) {
        if (_expectedSongId == myExpectedId) {
          _expectedSongId = null;
          _expectedSongIdSetAt = null;
          notifyListeners();
        }
      }
    }
  }

  // Shared debounce scheduler for skipNext()/skipPrev(). Resets the timer
  // on every call (i.e. every rapid tap) and remembers only the LATEST
  // target index — when taps finally settle for _skipDebounceWindow, one
  // single _engine.skipToQueueItem() call fires for that final index.
  void _scheduleSkipFlush(int targetIndex) {
    _skipDebounceTargetIndex = targetIndex;
    _skipDebounce?.cancel();
    _skipDebounce = Timer(_skipDebounceWindow, () => _flushSkip());
  }

  Future<void> _flushSkip() async {
    final targetIndex = _skipDebounceTargetIndex;
    _skipDebounceTargetIndex = null;
    if (targetIndex == null) return;
    // Snapshot exactly what THIS flush is chasing — used below to check
    // the gate is still "ours" before clearing it. Same reasoning as the
    // original per-tap guard: only clear _expectedSongId if a NEWER
    // request (a skip that happened after this flush was scheduled, e.g.
    // a direct queue-item tap) hasn't already claimed the gate.
    final myExpectedId = _expectedSongId;
    try {
      await _engine.skipToQueueItem(targetIndex).timeout(const Duration(seconds: 4));
    } catch (e) {
      if (_expectedSongId == myExpectedId) {
        _expectedSongId = null;
        _expectedSongIdSetAt = null;
        notifyListeners();
      }
    }
  }

  Future<void> addToQueue(Song song) async {
    await _engine.addToQueue(song);
    _queue.add(song);
    notifyListeners();
  }

  // NativeAudioEngine has no dedicated "insert at front" method — the old
  // AurumAudioHandler.playNext() spliced the song directly after the
  // current index. We replicate that with addToQueue + moveQueueItem so
  // the visible behavior (song plays immediately after the current one)
  // is preserved without needing a native-side API change.
  Future<void> playNext(Song song) async {
    await _engine.addToQueue(song);
    _queue.add(song);
    final from = _queue.length - 1;
    final to = (_currentIndex + 1).clamp(0, _queue.length - 1);
    if (from != to) {
      await _engine.moveQueueItem(from, to);
      final moved = _queue.removeAt(from);
      _queue.insert(to, moved);
    }
    notifyListeners();
  }

  Future<void> removeFromQueue(int index) async {
    await _engine.removeFromQueue(index);
    // BUG: removing an item never adjusted _currentIndex. Removing a song
    // that sits BEFORE the currently-playing index shifts every song after
    // it left by one, but _currentIndex stayed the same — silently
    // pointing at the WRONG song from then on. currentSong itself (a
    // separate field) still displayed correctly in that exact moment, but
    // _currentIndex was desynced from _queue, so anything that later reads
    // _queue[_currentIndex] directly (skipNext()'s optimistic
    // "queue[currentIndex+1]" guess, _onSongChanged, etc.) would then
    // operate on/report the wrong song. Removing the currently-playing
    // song itself is left to the native engine's own follow-up state
    // event to resolve (it knows what plays next); we only correct the
    // index math for removals that don't touch the current song.
    if (index >= 0 && index < _queue.length) {
      _queue.removeAt(index);
      if (index < _currentIndex) {
        _currentIndex -= 1;
      }
    }
    notifyListeners();
  }

  Future<void> moveQueueItem(int from, int to) async {
    await _engine.moveQueueItem(from, to);
    if (from >= 0 && from < _queue.length) {
      final item = _queue.removeAt(from);
      final clampedTo = to.clamp(0, _queue.length);
      _queue.insert(clampedTo, item);

      // BUG: same class of issue as removeFromQueue — reordering the
      // queue never adjusted _currentIndex to track the song that was
      // actually playing. Dragging a song from below the current index to
      // above it (or vice versa) shifted the current song to a different
      // slot without _currentIndex following it, so every index-based
      // lookup after a reorder silently pointed at whatever song ended up
      // in the OLD index instead of the one actually playing.
      if (from == _currentIndex) {
        _currentIndex = clampedTo;
      } else if (from < _currentIndex && clampedTo >= _currentIndex) {
        _currentIndex -= 1;
      } else if (from > _currentIndex && clampedTo <= _currentIndex) {
        _currentIndex += 1;
      }
    }
    notifyListeners();
  }

  Future<void> skipToIndex(int index) async {
    // BUG: unlike skipNext()/skipPrev(), this had NO optimistic update —
    // tapping a song directly in the queue screen left title/artwork/
    // background showing the OLD song until the native engine's state
    // event round-tripped back, even though skipNext/skipPrev already
    // solved exactly this for the next/prev buttons. Same fix applied
    // here: update _currentSong/_currentIndex and warm its palette
    // immediately, only when linear (queue order matches what index
    // means — under shuffle the same caveat as skipNext/skipPrev applies).
    if (!_shuffle && index >= 0 && index < _queue.length) {
      _currentIndex = index;
      _currentSong = _queue[index];
      _lastHandledIndex = index;
      _expectedSongId = _currentSong!.id;
      _expectedSongIdSetAt = DateTime.now();
      // See matching comment in skipNext() — keeps the progress bar from
      // briefly showing the old song's duration scale after a direct
      // queue-item tap.
      _position = Duration.zero;
      _duration = Duration.zero;
      if (_currentSong!.artworkUrl.isNotEmpty) {
        ArtworkPaletteCache.warm(_currentSong!.artworkUrl);
      }
      notifyListeners();
      // FIX (same 100-song rapid-fire stability gap as skipNext/skipPrev):
      // this used to fire its own independent _engine.skipToQueueItem()
      // call on every single invocation, with no debounce at all — tapping
      // rapidly through several queue items (Up Next screen) queued up one
      // stacked native round-trip per tap, exactly the spam problem
      // skipNext()/skipPrev() were already fixed for via _scheduleSkipFlush.
      // Routing through the same shared debounce means rapid taps on
      // different queue rows coalesce into a single native call for
      // wherever the user actually lands, instead of one per intermediate
      // tap.
      _scheduleSkipFlush(index);
      return;
    }
    // Shuffled, or an out-of-range index — no safe optimistic guess to
    // make (see the doc comment on the optimistic block above). Flush any
    // already-pending debounced skip immediately so it isn't silently
    // swallowed, then fall through to a direct call.
    _skipDebounce?.cancel();
    _skipDebounce = null;
    _skipDebounceTargetIndex = null;
    // FIX — same _expectedSongId stuck-gate risk as skipNext()/skipPrev();
    // see the comment there for the full reasoning.
    // FIX — same hang risk as skipNext()/skipPrev(): a MethodChannel call
    // that never resolves would otherwise leave _expectedSongId stuck
    // forever, silently freezing state tracking for the rest of the
    // session.
    // Snapshot what THIS call set the gate to — see the matching comment
    // in skipNext() for why unconditionally nulling _expectedSongId in
    // the catch block below is a real desync bug under rapid taps
    // (tapping multiple queue items fast), not just a cleanup nicety.
    final myExpectedId = _expectedSongId;
    try {
      await _engine.skipToQueueItem(index).timeout(const Duration(seconds: 4));
    } catch (e) {
      if (_expectedSongId == myExpectedId) {
        _expectedSongId = null;
        _expectedSongIdSetAt = null;
      }
    }
    notifyListeners();
  }

  Future<void> toggleLoop() async {
    final next = _loopMode == LoopMode.off
        ? LoopMode.all
        : _loopMode == LoopMode.all
            ? LoopMode.one
            : LoopMode.off;
    _loopMode = next;
    // NativeAudioEngine/Kotlin expects "none" | "one" | "all" (see
    // AurumAudioEngine.kt#setRepeatMode) — not "off".
    await _engine.setRepeatMode(
      next == LoopMode.off ? 'none' : next == LoopMode.one ? 'one' : 'all',
    );
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    _shuffle = !_shuffle;
    await _engine.setShuffleMode(_shuffle);
    notifyListeners();
  }

  void openFullPlayer() {
    _showFullPlayer = true;
    notifyListeners();
  }

  void closeFullPlayer() {
    _showFullPlayer = false;
    notifyListeners();
  }

  Future<void> pause() => _engine.pause();
  Future<void> stop() => _engine.stop();

  Future<void> stopAndClear() async {
    // FIX: a pending debounced skip (see _scheduleSkipFlush) firing AFTER
    // Stop would call _engine.skipToQueueItem() on a queue that's about to
    // be cleared — cancel it here so Stop always genuinely stops, with
    // nothing left in flight to contradict it a beat later.
    _skipDebounce?.cancel();
    _skipDebounce = null;
    _skipDebounceTargetIndex = null;
    await _engine.stop();
    await _engine.clearQueue();
    _queue = [];
    _currentSong = null;
    _currentIndex = 0;
    // FIX (next song after Stop can get silently blocked/misrouted): this
    // used to leave _expectedSongId, _lastHandledIndex, and the behavior-
    // tracking fields (_lastTrackedSong/_completionFired/_earlySkipArmed/
    // _replayArmed) exactly as they were before the stop. If the next
    // playSong() call happened to reuse or race against a state event
    // still referencing the old (pre-stop) expected id/index, the stale
    // guard could reject or misapply that genuinely new state — the same
    // class of bug as the auto-advance mismatch above, just triggered via
    // Stop instead of a track transition. Clearing every piece of
    // per-song tracking state here means Stop always returns the provider
    // to a truly clean slate, with nothing left over to misfire against
    // whatever plays next.
    _expectedSongId = null;
    _expectedSongIdSetAt = null;
    _lastHandledIndex = null;
    _lastTrackedSong = null;
    _completionFired = false;
    _earlySkipArmed = false;
    _replayArmed = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _isLoading = false;
    _isPlaying = false;
    notifyListeners();
  }

  Future<String?> fetchLyrics() async {
    final song = currentSong;
    if (song == null) return null;
    return ApiService.fetchLyrics(song);
  }

  /// Line-synced lyrics for the currently playing song. Returns a
  /// [LyricsResult] carrying either timestamped lines (preferred) or a
  /// plain-text fallback when no synced source is available.
  Future<LyricsResult> fetchSyncedLyrics() async {
    final song = currentSong;
    if (song == null) return const LyricsResult();
    return ApiService.fetchSyncedLyrics(song);
  }

  // ---------------------------------------------------------------------------
  // updateRecentlyPlayed — called by ChangeNotifierProxyProvider in main.dart
  // whenever RecentlyPlayedProvider rebuilds. Updates the internal reference
  // so behavior tracking signals always go to the live instance.
  // ---------------------------------------------------------------------------
  void updateRecentlyPlayed(RecentlyPlayedProvider rp) {
    // _recentlyPlayed is final — we shadow via a mutable field instead.
    // Nothing to notify here; this is a pure reference update.
    _latestRecentlyPlayed = rp;
  }

  // Mutable shadow of _recentlyPlayed — always points to the live instance.
  RecentlyPlayedProvider? _latestRecentlyPlayed;

  // Internal getter: prefers the live proxy instance, falls back to constructor arg.
  RecentlyPlayedProvider? get _rp => _latestRecentlyPlayed ?? _recentlyPlayed;

  // ---------------------------------------------------------------------------
  // DIAGNOSTICS — NativeAudioEngine has no runRealPlaybackTest equivalent
  // (that lived inside AurumAudioHandler and exercised just_audio directly).
  // Kept as a thin shim so the diagnostics dialog in home_screen.dart still
  // compiles and gives a meaningful result: it now drives the same
  // playSong() path real taps use and reports success/failure via
  // errorStream instead of a bespoke test harness.
  // ---------------------------------------------------------------------------
  Future<RealPlaybackResult> runRealPlaybackTest(Song song) async {
    String? capturedError;
    final sub = _engine.errorStream.listen((e) => capturedError = e.message);
    try {
      await _engine.playSong(song).timeout(const Duration(seconds: 8));
      await Future.delayed(const Duration(seconds: 3));
      final ok = capturedError == null && _isPlaying;
      return RealPlaybackResult(
        success: ok,
        positionMs: _position.inMilliseconds,
        processingState: _isLoading ? 'buffering' : (ok ? 'ready' : 'idle'),
        errorMessage: capturedError,
      );
    } catch (e) {
      return RealPlaybackResult(
        success: false,
        positionMs: 0,
        processingState: 'error',
        errorMessage: e.toString(),
      );
    } finally {
      await sub.cancel();
    }
  }

  // ---------------------------------------------------------------------------
  // DISPOSE
  // ---------------------------------------------------------------------------
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _indexDebounce?.cancel();
    _skipDebounce?.cancel();
    _loadingWatchdog?.cancel();
    _stopLocalPositionTicker();
    for (final sub in _subs) sub.cancel();
    _favoritesSub?.cancel();
    _engine.onLikeToggleRequested = null;
    super.dispose();
  }
}

/// Tiny adapter so we can "cancel" a ChangeNotifier listener the same way
/// we cancel StreamSubscriptions elsewhere in this file — keeps the
/// dispose() pattern consistent and avoids leaking a listener onto a
/// FavoritesProvider instance that may get replaced.
class _FavoritesListener {
  final FavoritesProvider _favorites;
  final VoidCallback _callback;

  _FavoritesListener(this._favorites, this._callback) {
    _favorites.addListener(_callback);
  }

  void cancel() => _favorites.removeListener(_callback);
}
