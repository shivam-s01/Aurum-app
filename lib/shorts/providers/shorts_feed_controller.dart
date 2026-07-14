import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import '../models/short_item.dart';
import '../services/shorts_prefs.dart';
import '../services/shorts_recommendation_engine.dart';
import '../services/shorts_video_service.dart';

enum DownloadTrackState { idle, downloading, done }

/// Muted background video status for the currently-active card only.
/// Purely visual — never affects the real (audio) playback state.
enum ShortsVideoStatus { none, loading, ready, failed }

/// Owns the Shorts feed state: the item list, current index, preload
/// window, and a dedicated just_audio player instance for 30s
/// previews. Deliberately does NOT touch AurumAudioEngine / the
/// native Media3 pipeline, the main queue, or playback history —
/// per spec this feed must be fully isolated.
class ShortsFeedController extends ChangeNotifier {
  final ShortsRecommendationEngine _engine = ShortsRecommendationEngine();
  final AudioPlayer _player = AudioPlayer();

  final List<ShortItem> _items = [];
  final Set<String> _shownKeys = {};
  int _currentIndex = 0;
  bool _loadingMore = false;
  bool _initialLoading = true;
  bool _liked = false;
  bool _saved = false;
  DownloadTrackState _downloadState = DownloadTrackState.idle;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Muted background video — visual only, fully decoupled from the
  // just_audio player above which remains the single audio source.
  VideoPlayerController? _videoController;
  ShortsVideoStatus _videoStatus = ShortsVideoStatus.none;
  // Guards against a slow resolve landing after the user has already
  // swiped away — the classic "wrong clip flickers in" bug.
  int _videoRequestToken = 0;

  // Single-slot preload: the NEXT card's video is prepared (muted,
  // initialized, paused) ahead of time so swiping forward feels
  // instant instead of showing a loading gap — this is what makes
  // the feed feel like Reels/TikTok rather than a lazy-loaded list.
  // Deliberately capped at one item ahead (not a full window) since
  // each VideoPlayerController holds a real decoder — keeping many
  // alive at once is exactly the kind of thing that makes a phone
  // feel cheap, which is the opposite of the goal here.
  String? _preloadedForItemId;
  VideoPlayerController? _preloadedVideoController;
  int _preloadToken = 0;

  // How many items ahead to keep pre-buffered/ready.
  static const int _preloadWindow = 3;
  static const int _refillThreshold = 5;
  static const int _batchSize = 15;

  List<ShortItem> get items => List.unmodifiable(_items);
  int get currentIndex => _currentIndex;
  bool get initialLoading => _initialLoading;
  bool get isLiked => _liked;
  bool get isSaved => _saved;
  DownloadTrackState get downloadState => _downloadState;
  Duration get position => _position;
  Duration get duration => _duration;
  VideoPlayerController? get videoController => _videoController;
  ShortsVideoStatus get videoStatus => _videoStatus;
  ShortItem? get currentItem =>
      _items.isNotEmpty && _currentIndex < _items.length
          ? _items[_currentIndex]
          : null;

  List<String> _languages = [];
  List<String> _categories = [];
  bool _wifiOnlyVideo = true;

  Future<void> init() async {
    _languages = await ShortsPrefs.getLanguages();
    _categories = await ShortsPrefs.getCategories();
    _wifiOnlyVideo = await ShortsPrefs.getWifiOnlyVideo();

    _stateSub = _player.playerStateStream.listen((state) {
      // Auto-advance when a preview finishes playing naturally.
      if (state.processingState == ProcessingState.completed) {
        next();
      }
    });
    _positionSub = _player.positionStream.listen((pos) {
      _position = pos;
      notifyListeners();
    });

    // FAST PATH: get a tiny first batch (single language, single
    // category, low limit) so the feed starts playing almost
    // instantly instead of waiting on the full multi-language,
    // multi-era fetch. The full batch loads right behind it in the
    // background and appends once ready — user never sees the seam
    // because they're still on/near item 0 by the time it lands.
    //
    // rotation is bumped in persisted storage on every launch (see
    // ShortsPrefs.nextFirstPaintRotation) so the opening card's query
    // term varies across app restarts / feed re-inits instead of
    // being frozen on the same seed-artist+category combo forever.
    final rotation = await ShortsPrefs.nextFirstPaintRotation();
    final firstPaint = await _engine.fetchFirstPaint(
      languages: _languages,
      categories: _categories,
      rotation: rotation,
    );
    for (final item in firstPaint) {
      _shownKeys.add(item.dedupeKey);
    }
    _items.addAll(firstPaint);
    _initialLoading = false;
    notifyListeners();

    if (_items.isNotEmpty) {
      unawaited(_playCurrent());
    }

    // Full batch — runs in background, doesn't block first paint.
    await _loadMore();
    notifyListeners();
    if (_items.isNotEmpty) {
      unawaited(_preloadAhead());
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    _loadingMore = true;
    try {
      final batch = await _engine.fetchBatch(
        languages: _languages,
        categories: _categories,
        excludeKeys: _shownKeys,
        targetCount: _batchSize,
      );
      for (final item in batch) {
        _shownKeys.add(item.dedupeKey);
      }
      _items.addAll(batch);
      notifyListeners();
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _playCurrent() async {
    final item = currentItem;
    if (item == null) return;
    try {
      _duration = Duration(milliseconds: item.durationMs);
      await _player.setUrl(item.previewUrl);
      await _player.play();
      _liked = await ShortsPrefs.isLiked(item.id);
      _saved = await ShortsPrefs.isSaved(item.id);
      _downloadState = DownloadTrackState.idle; // fresh per card
      await ShortsPrefs.bumpArtist(item.artist);
      notifyListeners();
    } catch (_) {
      // Preview failed to load (dead URL / network) — skip forward
      // automatically rather than showing a stuck/frozen card.
      next();
      return;
    }
    unawaited(_loadBackgroundVideo(item));
  }

  /// Resolves and prepares a muted, looping YouTube video clip as a
  /// purely visual background layer for the current card. Audio for
  /// the card is, and remains, only ever the iTunes preview above —
  /// this controller is created fresh (volume 0, looping) and never
  /// wired to any audio session.
  Future<void> _loadBackgroundVideo(ShortItem item) async {
    final myToken = ++_videoRequestToken;

    // Fast path: this exact item was already preloaded while the
    // user was on the previous card — swap it in immediately, no
    // network wait, no loading gap. This is the Instagram-instant
    // feel: the clip is just already sitting there ready to go.
    if (_preloadedForItemId == item.id && _preloadedVideoController != null) {
      final oldController = _videoController;
      _videoController = _preloadedVideoController;
      _preloadedVideoController = null;
      _preloadedForItemId = null;
      _videoStatus = ShortsVideoStatus.ready;
      unawaited(_videoController!.setLooping(true));
      unawaited(_videoController!.play());
      notifyListeners();
      if (oldController != null) unawaited(oldController.dispose());
      unawaited(_preloadNextVideo());
      return;
    }

    // Slow path: nothing preloaded for this item (first card in the
    // session, or the user swiped faster than the preload finished).
    // Tear down whatever video was showing for the previous card
    // immediately so a stale clip never lingers under a new song.
    final oldController = _videoController;
    _videoController = null;
    _videoStatus = ShortsVideoStatus.loading;
    notifyListeners();
    if (oldController != null) {
      unawaited(oldController.dispose());
    }
    // Also drop any in-flight/finished preload that was for a
    // different item than the one we ended up on.
    if (_preloadedForItemId != null && _preloadedForItemId != item.id) {
      final stale = _preloadedVideoController;
      _preloadedVideoController = null;
      _preloadedForItemId = null;
      if (stale != null) unawaited(stale.dispose());
    }

    // WiFi-only gate — a paid app never silently spends the user's
    // mobile data on a muted background video they didn't ask for.
    // The card still works perfectly on cellular: audio plays, the
    // static Ken Burns artwork stays up, nothing looks broken.
    if (_wifiOnlyVideo) {
      final connectivity = await Connectivity().checkConnectivity();
      final onWifi = connectivity.contains(ConnectivityResult.wifi);
      if (!onWifi) {
        if (myToken == _videoRequestToken) {
          _videoStatus = ShortsVideoStatus.none;
          notifyListeners();
        }
        return;
      }
    }

    final result = await ShortsVideoService.resolveForSong(
      dedupeKey: item.dedupeKey,
      title: item.title,
      artist: item.artist,
    );

    // Bail if the user has swiped to another card while this was
    // resolving, or the item itself changed underneath us.
    if (myToken != _videoRequestToken || currentItem?.id != item.id) {
      return;
    }

    if (result == null) {
      _videoStatus = ShortsVideoStatus.failed;
      notifyListeners();
      return;
    }

    try {
      // IMPORTANT: googlevideo.com playback URLs are bound to the
      // User-Agent of the client that requested them from YouTube
      // (the Worker used ANDROID_VR/iOS/TV headers server-side to
      // get this URL in the first place). A bare request with no
      // User-Agent — which is what VideoPlayerController.networkUrl
      // sends by default — gets silently rejected by the CDN, which
      // ExoPlayer surfaces as a generic ExoPlaybackException/"Source
      // error" rather than a clear 403. Passing the matching header
      // here is what makes the resolved URL actually playable.
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(result.streamUrl),
        httpHeaders: const {
          'User-Agent':
              'com.google.android.apps.youtube.vr.oculus/1.71.26 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
        },
      );
      await controller.initialize();
      if (myToken != _videoRequestToken || currentItem?.id != item.id) {
        unawaited(controller.dispose());
        return;
      }
      await controller.setVolume(0); // visual only — never a second audio source
      await controller.setLooping(true);
      await controller.play();
      _videoController = controller;
      _videoStatus = ShortsVideoStatus.ready;
      notifyListeners();
    } catch (e, st) {
      debugPrint('AURUM_SHORTS_VIDEO_FAIL: $e');
      debugPrint('$st');
      if (myToken == _videoRequestToken) {
        _videoStatus = ShortsVideoStatus.failed;
        notifyListeners();
      }
    }

    unawaited(_preloadNextVideo());
  }

  /// Prepares the video for the item immediately after the current
  /// one, fully initialized and paused (volume 0), so the moment the
  /// user swipes forward `_loadBackgroundVideo` can swap it straight
  /// in. Silently does nothing if there's no next item, on-cellular
  /// with the WiFi-only gate on, or the resolve/init fails — the
  /// normal slow path in `_loadBackgroundVideo` is always the safety
  /// net, so a failed preload never breaks anything, it just means
  /// the next card loads live instead of instantly.
  Future<void> _preloadNextVideo() async {
    final myPreload = ++_preloadToken;
    final nextIndex = _currentIndex + 1;
    if (nextIndex >= _items.length) return;
    final nextItem = _items[nextIndex];

    if (_wifiOnlyVideo) {
      final connectivity = await Connectivity().checkConnectivity();
      if (!connectivity.contains(ConnectivityResult.wifi)) return;
    }

    final result = await ShortsVideoService.resolveForSong(
      dedupeKey: nextItem.dedupeKey,
      title: nextItem.title,
      artist: nextItem.artist,
    );
    if (result == null) return;
    // Stale if the user already moved on past the item we were
    // preloading for, or another preload superseded this one.
    if (myPreload != _preloadToken || _items.indexOf(nextItem) != nextIndex) {
      return;
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(result.streamUrl),
        httpHeaders: const {
          'User-Agent':
              'com.google.android.apps.youtube.vr.oculus/1.71.26 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
        },
      );
      await controller.initialize();
      if (myPreload != _preloadToken) {
        unawaited(controller.dispose());
        return;
      }
      await controller.setVolume(0);
      await controller.setLooping(true);
      // Paused — this is a silent preload, not visible playback yet.
      // _loadBackgroundVideo calls .play() itself once swapped in.
      _preloadedVideoController = controller;
      _preloadedForItemId = nextItem.id;
    } catch (_) {
      // Fail soft — the slow path in _loadBackgroundVideo covers it.
    }
  }

  /// Preload strategy: just_audio doesn't expose a clean "preload
  /// without playing" API across a single shared player, so instead
  /// we warm the HTTP/CDN connection for upcoming items by issuing a
  /// lightweight HEAD-less priming request via a throwaway player.
  /// This keeps swipe-to-next feeling instant without holding N
  /// decoder instances open (bad on entry-level devices).
  Future<void> _preloadAhead() async {
    final upcoming = _items.skip(_currentIndex + 1).take(_preloadWindow);
    for (final item in upcoming) {
      if (item.previewUrl.isEmpty) continue;
      final warmer = AudioPlayer();
      unawaited(
        warmer.setUrl(item.previewUrl).then((_) {
          warmer.dispose();
        }).catchError((_) {
          warmer.dispose();
        }),
      );
    }
  }

  Future<void> next() async {
    if (_currentIndex >= _items.length - 1) {
      if (!_loadingMore) await _loadMore();
      if (_currentIndex >= _items.length - 1) return; // nothing new
    }
    _currentIndex++;
    notifyListeners();
    await _playCurrent();
    unawaited(_preloadAhead());

    if (_items.length - _currentIndex <= _refillThreshold && !_loadingMore) {
      unawaited(_loadMore());
    }
  }

  Future<void> previous() async {
    if (_currentIndex == 0) return;
    _currentIndex--;
    notifyListeners();
    await _playCurrent();
  }

  /// Jump directly to an index — used by PageView's onPageChanged so
  /// swipe gestures (both directions, fast flicks) stay in sync.
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= _items.length || index == _currentIndex) {
      return;
    }
    _currentIndex = index;
    notifyListeners();
    await _playCurrent();
    unawaited(_preloadAhead());

    if (_items.length - _currentIndex <= _refillThreshold && !_loadingMore) {
      unawaited(_loadMore());
    }
  }

  Future<void> toggleLike() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.toggleLiked(item.id);
    _liked = await ShortsPrefs.isLiked(item.id);
    notifyListeners();
  }

  Future<void> toggleSave() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.toggleSaved(item.id);
    _saved = await ShortsPrefs.isSaved(item.id);
    notifyListeners();
  }

  /// Called by the feed screen while it resolves+downloads the full
  /// song, so the download button can show a real progress state
  /// (idle → downloading → done) instead of instantly flipping.
  void setDownloadState(DownloadTrackState state) {
    _downloadState = state;
    notifyListeners();
  }

  Future<void> registerReplay() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.incrementReplay(item.id);
  }

  Future<void> registerSkip() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.addSkipped(item.id);
  }

  void togglePlayPause() {
    if (_player.playing) {
      _player.pause();
      _videoController?.pause();
    } else {
      _player.play();
      _videoController?.play();
    }
    notifyListeners();
  }

  bool get isPlaying => _player.playing;

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _player.dispose();
    _videoController?.dispose();
    _preloadedVideoController?.dispose();
    super.dispose();
  }
}
