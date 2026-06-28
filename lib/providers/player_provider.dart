// =============================================================================
// FILE: lib/providers/player_provider.dart
// PROJECT: Aurum Music
// VERSION: 2.0.0 — Behavior Tracking + Smart Queue
//
// WHAT'S NEW IN v2:
//   ✅ Early skip detection (<15s → RecentlyPlayedProvider.notifySkip)
//   ✅ Completion detection (≥80% → RecentlyPlayedProvider.notifyCompletion)
//   ✅ Replay detection (user re-seeks to start → notifyReplay)
//   ✅ RecentlyPlayedProvider injected via constructor (passed from main.dart)
//   ✅ Prefetch next song after auto-queue extension
//   ✅ Auto-queue: passes existingQueueIds + session recent IDs for full dedup
//
// BACKWARD COMPATIBILITY:
//   - All existing getters unchanged
//   - All existing methods unchanged
//   - New constructor param `recentlyPlayedProvider` added (nullable for safety)
//   - No breaking API changes
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import '../services/audio_handler.dart';
import '../services/api_service.dart';
import '../services/audio_prefs.dart';
import '../services/recommendation_engine.dart';
import 'recently_played_provider.dart';

class PlayerProvider extends ChangeNotifier {
  final AurumAudioHandler       _handler;
  final RecentlyPlayedProvider? _recentlyPlayed;

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

  // Last error reported by AurumAudioHandler.onPlaybackError — exposed so
  // the UI (home_screen.dart) can show it via SnackBar the instant a real
  // playSong/playQueue attempt fails, without needing logcat/adb access.
  String? _lastPlaybackError;
  String? get lastPlaybackError => _lastPlaybackError;

  // Fired every time a new playback error comes in, even if the message
  // text is identical to the previous one (so repeated taps on the same
  // broken song each show a fresh SnackBar instead of being deduped away).
  void Function(String error)? onPlaybackError;

  // ── Phase 4: Skip limit for free users ───────────────────────────────────
  // Free users get 6 skips per hour. Resets automatically after 60 min.
  static const int _kFreeSkipLimit = 6;
  static const Duration _kSkipWindow = Duration(hours: 1);

  int _skipsUsed = 0;
  DateTime _skipWindowStart = DateTime.now();

  /// How many skips remain for free users this hour. Returns null if premium.
  int? get freeSkipsRemaining {
    if (AudioPrefs.isPremium) return null; // unlimited
    _resetWindowIfExpired();
    return (_kFreeSkipLimit - _skipsUsed).clamp(0, _kFreeSkipLimit);
  }

  bool get skipLimitReached {
    if (AudioPrefs.isPremium) return false;
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
    if (!AudioPrefs.isPremium) {
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
  PlayerProvider(this._handler, {RecentlyPlayedProvider? recentlyPlayedProvider})
      : _recentlyPlayed = recentlyPlayedProvider {
    _handler.onPlaybackError = (error) {
      _lastPlaybackError = error;
      onPlaybackError?.call(error);
      notifyListeners();
    };

    _subs.add(_handler.player.playingStream.listen((playing) {
      _isPlaying = playing;
      notifyListeners();
    }));

    _subs.add(_handler.player.positionStream.listen(_onPosition));

    _subs.add(_handler.player.durationStream.listen((dur) {
      if (dur != null) {
        _duration = dur;
        notifyListeners();
      }
    }));

    _subs.add(_handler.player.bufferedPositionStream.listen((buf) {
      _buffered = buf;
      notifyListeners();
    }));

    _subs.add(_handler.player.processingStateStream.listen((state) {
      _isLoading = state == ProcessingState.loading || state == ProcessingState.buffering;
      notifyListeners();
    }));

    _subs.add(_handler.player.loopModeStream.listen((mode) {
      _loopMode = mode;
      notifyListeners();
    }));

    _subs.add(_handler.player.shuffleModeEnabledStream.listen((s) {
      _shuffle = s;
      notifyListeners();
    }));

    // Song change: reset tracking + trigger auto-queue
    _subs.add(_handler.player.currentIndexStream.listen((index) {
      if (index == null) return;
      // Debounce: same rapid-fire burst that hits audio_handler's listener
      // also hits this one — skip duplicate/sequential events so _onSongChanged
      // and _maybeExtendQueue don't fire multiple times per real transition.
      _indexDebounce?.cancel();
      _indexDebounce = Timer(const Duration(milliseconds: 150), () {
        if (index == _lastHandledIndex) return;
        _lastHandledIndex = index;
        _onSongChanged(index);
        _maybeExtendQueue(index);
      });
    }));

    // Fired synchronously the instant audio_handler updates its queue —
    // happens before stream resolution, so the UI shows the new "now
    // playing" song right away instead of waiting several seconds for
    // currentIndexStream (which only fires once playback actually starts).
    _handler.onQueueChanged = () => notifyListeners();
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
    final q    = _handler.currentQueue;
    if (q.isEmpty || index >= q.length) return;
    final song = q[index];

    // Reset all tracking state for new song
    _lastTrackedSong  = song;
    _completionFired  = false;
    _earlySkipArmed   = song.source != SongSource.local; // arm for online songs
    _replayArmed      = false;
    _nextPrefetchFired = false;
  }

  void _onPosition(Duration pos) {
    _position = pos;
    notifyListeners();

    final song = _lastTrackedSong;
    if (song == null || song.source == SongSource.local) return;

    final posSeconds  = pos.inSeconds;
    final durSeconds  = _duration.inSeconds;

    // ── EARLY SKIP detection ──────────────────────────────────────────────
    // If song was armed (just started) and user skips while position < 15s,
    // the currentIndexStream will fire — we fire the skip signal there.
    // Here we just track: if position > 15s, disarm early-skip.
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
    if (_replayArmed && posSeconds <= 5 && _position.inSeconds <= 5) {
      _replayArmed = false; // disarm until >30% again
      _rp?.notifyReplay(song);
    }

    // ── LOOKAHEAD PRELOAD (70%) ──────────────────────────────────────────────
    // At 70% of current song, resolve next song's stream URL into
    // _LookaheadCache inside AurumAudioHandler. When the song actually
    // switches, _sourceForSong checks this cache first — making the
    // transition feel gapless (0ms resolve wait instead of 1-3s).
    // 70% chosen over 50% to avoid wasting resolves on songs users skip early.
    if (!_nextPrefetchFired && durSeconds > 10 && posSeconds / durSeconds >= 0.70) {
      _nextPrefetchFired = true;
      final q   = _handler.currentQueue;
      final idx = _handler.currentIndex;
      if (idx + 1 < q.length) {
        final next = q[idx + 1];
        if (!next.isLocal) {
          // Use handler's lookaheadResolve — stores in _LookaheadCache,
          // not just ApiService stream cache. Faster path on song switch.
          _handler.lookaheadResolve(next);
        }
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
  // Prefetches next song's stream URL after adding to queue.
  // ---------------------------------------------------------------------------
  Future<void> _maybeExtendQueue(int index) async {
    final q = _handler.currentQueue;
    if (q.isEmpty) return;

    final remaining = q.length - 1 - index;
    if (q.length < 2 || remaining > 8 || _isExtendingQueue) return;

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
      final currentQueueIds = _handler.currentQueue.map((s) => s.id).toSet();
      final toAdd = nextSongs
          .where((s) => !currentQueueIds.contains(s.id))
          .toList();

      for (final song in toAdd) {
        await _handler.addToQueue(song);
      }

      // Prefetch next song's stream URL so it starts instantly
      if (toAdd.isNotEmpty) {
        ApiService.prefetchNext(toAdd.first);
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
  Song?    get currentSong    => _handler.currentSong;
  List<Song> get queue        => _handler.currentQueue;
  int      get currentIndex   => _handler.currentIndex;
  bool     get hasSong        => _handler.currentSong != null;
  AurumAudioHandler get handler => _handler;

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
    if (queue != null && index != null) {
      await _handler.playQueue(queue, index);
      if (queue.length < 10 && !song.isLocal) {
        _buildInitialSmartQueue(song, alreadyInQueue: queue.map((s) => s.id).toSet());
      }
    } else {
      await _handler.playSong(song);
      if (!song.isLocal) {
        _buildInitialSmartQueue(song, alreadyInQueue: {song.id});
      }
    }
    notifyListeners();
  }

  Future<void> _buildInitialSmartQueue(Song song, {required Set<String> alreadyInQueue}) async {
    if (_isExtendingQueue) return;
    _isExtendingQueue = true;
    try {
      await RecommendationEngine.load();
      // Phase 1: 20 songs fast
      final phase1 = await ApiService.getAutoQueue(song, limit: 20, existingQueueIds: alreadyInQueue);
      if (phase1.isNotEmpty) {
        final currentIds = _handler.currentQueue.map((s) => s.id).toSet();
        final toAdd = phase1.where((s) => !currentIds.contains(s.id)).toList();
        for (final s in toAdd) await _handler.addToQueue(s);
        alreadyInQueue.addAll(toAdd.map((s) => s.id));
        notifyListeners();
      }
      // Phase 2: 30 more songs
      final phase2 = await ApiService.getAutoQueue(song, limit: 30, existingQueueIds: {
        ...alreadyInQueue, ...RecommendationEngine.sessionRecentIds,
      });
      if (phase2.isNotEmpty) {
        final currentIds = _handler.currentQueue.map((s) => s.id).toSet();
        final toAdd = phase2.where((s) => !currentIds.contains(s.id)).toList();
        for (final s in toAdd) await _handler.addToQueue(s);
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _isExtendingQueue = false;
    }
  }

  // Restores the last queue into the UI/notification on app reopen WITHOUT
  // starting playback. No network resolve, no AudioSource, no play() —
  // genuinely idle until the user taps play themselves.
  Future<void> restoreQueueSilently(List<Song> queue, int index) async {
    await _handler.loadQueueSilently(queue, index);
    notifyListeners();
  }

  Future<void> togglePlay() async {
    if (_isPlaying) await _handler.pause();
    else            await _handler.play();
  }

  Future<void> seek(double ratio) async {
    if (_duration == Duration.zero) return;
    final pos = Duration(milliseconds: (_duration.inMilliseconds * ratio).round());
    await _handler.seek(pos);
  }

  Future<void> seekTo(Duration pos) => _handler.seek(pos);

  /// Returns true if skip was allowed, false if limit reached (UI should show gate).
  Future<bool> skipNext() async {
    if (skipLimitReached) return false; // caller shows PremiumGate
    _recordSkip();
    _fireEarlySkipIfArmed(); // ← behavior tracking hook
    await _handler.skipToNext();
    return true;
  }

  Future<void> skipPrev() => _handler.skipToPrevious();

  Future<void> addToQueue(Song song) async {
    await _handler.addToQueue(song);
    notifyListeners();
  }

  Future<void> playNext(Song song) async {
    await _handler.playNext(song);
    notifyListeners();
  }

  Future<void> removeFromQueue(int index) async {
    await _handler.removeFromQueue(index);
    notifyListeners();
  }

  Future<void> moveQueueItem(int from, int to) async {
    await _handler.moveQueueItem(from, to);
    notifyListeners();
  }

  Future<void> skipToIndex(int index) async {
    await _handler.skipToQueueItem(index);
    notifyListeners();
  }

  Future<void> toggleLoop() async {
    final next = _loopMode == LoopMode.off
        ? LoopMode.all
        : _loopMode == LoopMode.all
            ? LoopMode.one
            : LoopMode.off;
    await _handler.setRepeatMode(
      next == LoopMode.off
          ? AudioServiceRepeatMode.none
          : next == LoopMode.one
              ? AudioServiceRepeatMode.one
              : AudioServiceRepeatMode.all,
    );
  }

  Future<void> toggleShuffle() async {
    await _handler.setShuffleMode(
      _shuffle
          ? AudioServiceShuffleMode.none
          : AudioServiceShuffleMode.all,
    );
  }

  void openFullPlayer() {
    _showFullPlayer = true;
    notifyListeners();
  }

  void closeFullPlayer() {
    _showFullPlayer = false;
    notifyListeners();
  }

  Future<void> pause() => _handler.pause();
  Future<void> stop() => _handler.stop();

  Future<void> stopAndClear() async {
    await _handler.stop();
    await _handler.clearQueue();
    notifyListeners();
  }

  Future<String?> fetchLyrics() async {
    final song = currentSong;
    if (song == null) return null;
    return ApiService.fetchLyrics(song);
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
  // DIAGNOSTICS — exposes the real handler's playback test to the UI layer
  // (home_screen.dart) without that screen needing to know about
  // AurumAudioHandler directly. See audio_handler.dart's
  // runRealPlaybackTest() and api_service.dart's debugPlaybackPath() for
  // why this matters: it lets the diagnostics dialog test the SAME
  // play path real taps use, instead of a throwaway player.
  // ---------------------------------------------------------------------------
  Future<RealPlaybackResult> runRealPlaybackTest(Song song) =>
      _handler.runRealPlaybackTest(song);

  // ---------------------------------------------------------------------------
  // DISPOSE
  // ---------------------------------------------------------------------------
  @override
  void dispose() {
    _indexDebounce?.cancel();
    for (final sub in _subs) sub.cancel();
    super.dispose();
  }
}
