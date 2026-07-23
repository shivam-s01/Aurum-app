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

  bool _isBuildingInitialQueue = false;
  bool _isAutoExtendingQueue = false;
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

  // FIX (see playQueue/playSong timeout doc comment in native_engine_bridge.
  // dart): surfaces to the UI when a play attempt genuinely failed or timed
  // out (native call hung / stream never resolved), instead of the app
  // just sitting there with a stale loading state and no explanation.
  // Screens can watch this to show a retry snackbar/toast.
  String? _playbackError;
  String? get playbackError => _playbackError;
  void clearPlaybackError() {
    _playbackError = null;
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
    resolvedSong ??= (_queue.isNotEmpty && newIndex >= 0 && newIndex < _queue.length)
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

    if (queue != null && index != null) {
      _queue = List<Song>.from(queue);
      _currentIndex = index;
      _currentSong = song;
      _expectedSongId = song.id;
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
        await _engine.playQueue(queue, index);
      } catch (e) {
        if (mySession != _uiPlaySession) return; // superseded — ignore stale failure
        // Native call hung/timed out or threw a PlatformException. Clear
        // the loading state and surface an error instead of leaving the
        // UI stuck showing "loading" forever with the song that never
        // actually started.
        _isLoading = false;
        _expectedSongId = null;
        _playbackError = 'Couldn\'t play "${song.title}". Tap to retry.';
        notifyListeners();
        return;
      }
      if (mySession != _uiPlaySession) return; // superseded by a newer tap
      if (queue.length < 10 && !song.isLocal) {
        _buildInitialSmartQueue(song, alreadyInQueue: queue.map((s) => s.id).toSet(), sessionId: mySession);
      }
    } else {
      _queue = [song];
      _currentIndex = 0;
      _currentSong = song;
      _expectedSongId = song.id;
      _isLoading = true;
      notifyListeners();

      try {
        await _engine.playSong(song);
      } catch (e) {
        if (mySession != _uiPlaySession) return; // superseded — ignore stale failure
        _isLoading = false;
        _expectedSongId = null;
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

  Future<void> _buildInitialSmartQueue(Song song, {required Set<String> alreadyInQueue, required int sessionId}) async {
    if (_isBuildingInitialQueue) return;
    if (sessionId != _uiPlaySession) return;
    _isBuildingInitialQueue = true;
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
      // Phase 2: 40 more songs (Phase 1's 20 + this = 60 total, matching
      // getAutoQueue's own default depth)
      final phase2 = await ApiService.getAutoQueue(song, limit: 40, existingQueueIds: {
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
      _isBuildingInitialQueue = false;
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
      _isLoading = true;
      notifyListeners();
      await _engine.play();
    }
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
    }

    // FIX — this used to be a bare `await` with nothing to clear
    // _expectedSongId if the native call threw or simply never landed on
    // the expected song (e.g. queue-edge recovery resolves to a different
    // index than guessed). _expectedSongId is a hard gate in
    // _onEngineState: while it's set, EVERY incoming state event whose
    // currentSongId doesn't match is treated as stale and dropped —
    // including position ticks, song-change detection, and auto-extend.
    // If the engine's genuine follow-up event was ever going to report a
    // different id than what we guessed here, that gate would never
    // clear on its own, and the UI (progress bar, title, queue
    // auto-extension) would silently freeze until some unrelated
    // playSong()/skipToQueueItem() call happened to reset it. Clearing it
    // on any failure here means a bad guess degrades to "wait for the
    // next real event" instead of "stay stuck forever".
    try {
      await _engine.skipToNext();
    } catch (e) {
      _expectedSongId = null;
      notifyListeners();
    }
    return true;
  }

  Future<void> skipPrev() async {
    // Same reasoning as skipNext — only safe to guess the next index
    // optimistically when the queue is in linear order.
    if (!_shuffle && _currentIndex - 1 >= 0) {
      _currentIndex -= 1;
      _currentSong = _queue[_currentIndex];
      _lastHandledIndex = _currentIndex;
      _expectedSongId = _currentSong!.id;
      if (_currentSong!.artworkUrl.isNotEmpty) {
        ArtworkPaletteCache.warm(_currentSong!.artworkUrl);
      }
      notifyListeners();
    }
    // FIX — see skipNext() above for why this guard is required: without
    // it, a failed/mismatched native skip call could leave _expectedSongId
    // stuck, silently freezing position/song-change/auto-extend tracking.
    try {
      await _engine.skipToPrevious();
    } catch (e) {
      _expectedSongId = null;
      notifyListeners();
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
      if (_currentSong!.artworkUrl.isNotEmpty) {
        ArtworkPaletteCache.warm(_currentSong!.artworkUrl);
      }
      notifyListeners();
    }
    // FIX — same _expectedSongId stuck-gate risk as skipNext()/skipPrev();
    // see the comment there for the full reasoning.
    try {
      await _engine.skipToQueueItem(index);
    } catch (e) {
      _expectedSongId = null;
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
