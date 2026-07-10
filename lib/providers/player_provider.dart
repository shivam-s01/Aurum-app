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
//   - `playNext`, `lookaheadResolve`, `loadQueueSilently`, and
//     `runRealPlaybackTest` had no NativeAudioEngine equivalent as of this
//     bridge version — they're adapted below (see inline notes) rather than
//     silently dropped, since UI call sites still call them.
//   - No breaking API changes for callers of PlayerProvider.
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import '../models/song.dart';
import '../models/lyrics.dart';
import '../services/native_engine_bridge.dart';
import '../services/api_service.dart';
import '../services/audio_prefs.dart';
import '../services/recommendation_engine.dart';
import 'recently_played_provider.dart';
import 'favorites_provider.dart';

// NOTE: LoopMode is still sourced from just_audio (`off`/`one`/`all`) purely
// as a shared value type — full_player_screen.dart imports the same enum
// directly and compares against `player.loopMode`. No just_audio Player is
// constructed anywhere in this file; only the enum is reused so the UI
// layer needs no changes for this engine swap.

class PlayerProvider extends ChangeNotifier {
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
  Duration _position       = Duration.zero;
  Duration _duration       = Duration.zero;
  Duration _buffered       = Duration.zero;
  LoopMode _loopMode       = LoopMode.off;
  bool     _shuffle        = false;
  bool     _showFullPlayer = false;

  bool _isExtendingQueue = false;
  Timer? _indexDebounce;
  int?   _lastHandledIndex;

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

  // ── Phase 4: Skip limit for free users ───────────────────────────────────
  // Free users get 6 skips per hour. Resets automatically after 60 min.
  static const int _kFreeSkipLimit = 6;
  static const Duration _kSkipWindow = Duration(hours: 1);

  int _skipsUsed = 0;
  DateTime _skipWindowStart = DateTime.now();

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
    }
  }

  void _recordSkip() {
    if (!AudioPrefs.isSignedIn) {
      _resetWindowIfExpired();
      _skipsUsed++;
      notifyListeners();
    }
  }

  // ── Behavior tracking state ────────────────────────────────────────────────
  // Used to fire one-shot events per song (completion/skip/replay).
  Song?   _lastTrackedSong;       // song currently being tracked
  bool    _completionFired = false; // 80%+ fired for current song?
  bool    _earlySkipArmed  = false; // true when position < 15s
  bool    _replayArmed     = false; // true when position near 0 after non-start
  bool    _nextPrefetchFired = false; // true once next-song prefetch has fired for current song

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
    _subs.add(_engine.errorStream.listen((event) {
      _lastPlaybackError = event.message;
      onPlaybackError?.call(event.message, silent: event.silent);
      notifyListeners();
    }));

    _subs.add(_engine.stateStream.listen(_onEngineState));

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
    _isPlaying = state.playing;
    _isLoading = state.processingState == 'loading' ||
        state.processingState == 'buffering';
    _buffered  = state.bufferedPosition;
    if (state.duration != null) _duration = state.duration!;

    // Reconcile the local queue mirror against queueIds. If the lengths and
    // order already match by ID, nothing to do — this keeps us from
    // rebuilding _queue (and losing any richer Song fields we already have,
    // like artworkUrl) on every single state tick, since queueIds is sent
    // on every position update too.
    if (!_queueMatchesIds(state.queueIds)) {
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
      resolvedSong ??= Song(
        id: state.currentSongId!,
        title: _currentSong?.id == state.currentSongId ? _currentSong!.title : '',
        artist: _currentSong?.id == state.currentSongId ? _currentSong!.artist : '',
        album: '',
        artworkUrl: '',
        source: SongSource.saavn,
      );
    }
    resolvedSong ??= (_queue.isNotEmpty && newIndex >= 0 && newIndex < _queue.length)
        ? _queue[newIndex]
        : _currentSong;
    _currentSong = resolvedSong;
    _currentIndex = newIndex;

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
    _nextPrefetchFired = false;

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
    final prevPosition = _position;
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
    if (!_replayArmed && durSeconds > 10) {
      if (posSeconds / durSeconds > 0.30) _replayArmed = true;
    }
    if (_replayArmed && posSeconds <= 5 && prevPosition.inSeconds <= 5) {
      _replayArmed = false; // disarm until >30% again
      _rp?.notifyReplay(song);
    }

    // ── LOOKAHEAD PRELOAD (70%) ──────────────────────────────────────────────
    // At 70% of current song, ask the native engine to pre-warm the next
    // song's stream so the transition feels gapless. NativeAudioEngine
    // doesn't expose a Dart-side lookaheadResolve — under Stage 2/Kotlin
    // orchestration this pre-warming is handled natively (see Worker v5's
    // predictive pre-warm), so this hook now just invalidates nothing and
    // is kept as a no-op trigger point in case a future engine build adds
    // an explicit prefetch method.
    if (!_nextPrefetchFired && durSeconds > 10 && posSeconds / durSeconds >= 0.70) {
      _nextPrefetchFired = true;
      final nextIdx = _currentIndex + 1;
      if (nextIdx < _queue.length) {
        _engine.lookaheadResolve(_queue[nextIdx]);
      }
    }
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
  // Triggers when ≤2 songs remain in queue.
  // Uses RecommendationEngine-powered getAutoQueue (v3).
  // ---------------------------------------------------------------------------
  Future<void> _maybeExtendQueue(int index) async {
    final q = _queue;
    if (q.isEmpty) return;

    final remaining = q.length - 1 - index;
    if (q.length < 2 || remaining > 8 || _isExtendingQueue) return;
    if (index >= q.length) return;

    _isExtendingQueue = true;
    try {
      final current = q[index];
      if (current.source == SongSource.local) return;

      // Full dedup: existing queue IDs + RecommendationEngine session window
      final existingIds = <String>{
        ...q.map((s) => s.id),
        ...RecommendationEngine.sessionRecentIds,
      };

      final nextSongs = await ApiService.getAutoQueue(
        current,
        limit: 20,
        existingQueueIds: existingIds,
      );

      // Final dedup safety check
      final currentQueueIds = _queue.map((s) => s.id).toSet();
      final toAdd = nextSongs
          .where((s) => !currentQueueIds.contains(s.id))
          .toList();

      for (final song in toAdd) {
        await _engine.addToQueue(song);
        _queue.add(song);
      }

      // Prefetch next song's stream URL so it starts instantly
      if (toAdd.isNotEmpty) {
        ApiService.prefetchNext(toAdd.first);
        if (toAdd.length > 1) ApiService.prefetchNext(toAdd[1]);
        notifyListeners();
      }
    } catch (_) {
      // Silent fail — auto-queue is background-only, never crashes UI
    } finally {
      _isExtendingQueue = false;
    }
  }

  // ---------------------------------------------------------------------------
  // GETTERS (all unchanged)
  // ---------------------------------------------------------------------------
  bool     get isPlaying      => _isPlaying;
  bool     get isLoading      => _isLoading;
  Duration get position       => _position;
  Duration get duration       => _duration;
  Duration get buffered       => _buffered;
  LoopMode get loopMode       => _loopMode;
  bool     get shuffle        => _shuffle;
  bool     get showFullPlayer => _showFullPlayer;
  Song?    get currentSong    => _currentSong;
  List<Song> get queue        => _queue;
  int      get currentIndex   => _currentIndex;
  bool     get hasSong        => _currentSong != null;

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
  Future<void> playSong(Song song, {List<Song>? queue, int? index}) async {
    _lastHandledIndex = null;
    _uiPlaySession++;
    final mySession = _uiPlaySession;

    if (queue != null && index != null) {
      _queue = List<Song>.from(queue);
      _currentIndex = index;
      _currentSong = song;
      notifyListeners();

      // Fire prewarm for the next 3-5 songs immediately on queue load —
      // don't wait for the 70%-of-song or index-settle hooks. This overlaps
      // the Worker round-trip with the current song's own start-up latency
      // instead of stacking after it.
      _prewarmUpcoming(_currentIndex);

      await _engine.playQueue(queue, index);
      if (mySession != _uiPlaySession) return; // superseded by a newer tap
      if (queue.length < 10 && !song.isLocal) {
        _buildInitialSmartQueue(song, alreadyInQueue: queue.map((s) => s.id).toSet(), sessionId: mySession);
      }
    } else {
      _queue = [song];
      _currentIndex = 0;
      _currentSong = song;
      notifyListeners();

      await _engine.playSong(song);
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

  Future<void> _buildInitialSmartQueue(Song song, {required Set<String> alreadyInQueue, required int sessionId}) async {
    if (_isExtendingQueue) return;
    if (sessionId != _uiPlaySession) return;
    _isExtendingQueue = true;
    try {
      await RecommendationEngine.load();
      if (sessionId != _uiPlaySession) return;
      // Phase 1: 20 songs fast
      final phase1 = await ApiService.getAutoQueue(song, limit: 20, existingQueueIds: alreadyInQueue);
      if (sessionId != _uiPlaySession) return;
      if (phase1.isNotEmpty) {
        final currentIds = _queue.map((s) => s.id).toSet();
        final toAdd = phase1.where((s) => !currentIds.contains(s.id)).toList();
        for (final s in toAdd) {
          if (sessionId != _uiPlaySession) return;
          await _engine.addToQueue(s);
          _queue.add(s);
        }
        alreadyInQueue.addAll(toAdd.map((s) => s.id));
        notifyListeners();
      }
      // Phase 2: 30 more songs
      final phase2 = await ApiService.getAutoQueue(song, limit: 30, existingQueueIds: {
        ...alreadyInQueue, ...RecommendationEngine.sessionRecentIds,
      });
      if (sessionId != _uiPlaySession) return;
      if (phase2.isNotEmpty) {
        final currentIds = _queue.map((s) => s.id).toSet();
        final toAdd = phase2.where((s) => !currentIds.contains(s.id)).toList();
        for (final s in toAdd) {
          if (sessionId != _uiPlaySession) return;
          await _engine.addToQueue(s);
          _queue.add(s);
        }
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _isExtendingQueue = false;
    }
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
    notifyListeners();
  }

  Future<void> togglePlay() async {
    if (_isPlaying) await _engine.pause();
    else            await _engine.play();
  }

  Future<void> seek(double ratio) async {
    if (_duration == Duration.zero) return;
    final pos = Duration(milliseconds: (_duration.inMilliseconds * ratio).round());
    await _engine.seek(pos);
  }

  Future<void> seekTo(Duration pos) => _engine.seek(pos);

  /// Returns true if skip was allowed, false if limit reached (UI should show gate).
  Future<bool> skipNext() async {
    if (skipLimitReached) return false; // caller shows PremiumGate
    _recordSkip();
    _fireEarlySkipIfArmed(); // ← behavior tracking hook

    if (_currentIndex + 1 < _queue.length) {
      _currentIndex += 1;
      _currentSong = _queue[_currentIndex];
      _lastHandledIndex = _currentIndex;
      notifyListeners();
    }

    await _engine.skipToNext();
    return true;
  }

  Future<void> skipPrev() async {
    if (_currentIndex - 1 >= 0) {
      _currentIndex -= 1;
      _currentSong = _queue[_currentIndex];
      _lastHandledIndex = _currentIndex;
      notifyListeners();
    }
    await _engine.skipToPrevious();
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
    if (index >= 0 && index < _queue.length) _queue.removeAt(index);
    notifyListeners();
  }

  Future<void> moveQueueItem(int from, int to) async {
    await _engine.moveQueueItem(from, to);
    if (from >= 0 && from < _queue.length) {
      final item = _queue.removeAt(from);
      _queue.insert(to.clamp(0, _queue.length), item);
    }
    notifyListeners();
  }

  Future<void> skipToIndex(int index) async {
    await _engine.skipToQueueItem(index);
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
    await _engine.stop();
    await _engine.clearQueue();
    _queue = [];
    _currentSong = null;
    _currentIndex = 0;
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
      await _engine.playSong(song);
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
    _indexDebounce?.cancel();
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
