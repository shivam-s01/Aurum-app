import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import '../models/short_item.dart';
import '../services/shorts_prefs.dart';
import '../services/shorts_recommendation_engine.dart';
import '../services/shorts_video_service.dart';

enum DownloadTrackState { idle, downloading, done }

/// Status of the current card's single YouTube video — now the ONLY
/// playback source (audio + video together), not a muted visual
/// layer on top of a separate audio player.
enum ShortsVideoStatus { none, loading, ready, failed }

const _kAndroidVrUserAgent =
    'com.google.android.apps.youtube.vr.oculus/1.71.26 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

/// Owns the Shorts feed state: item list, current index, preload
/// window, and a single VideoPlayerController per card that supplies
/// BOTH audio and video from one resolved YouTube muxed stream.
///
/// v2 rewrite: previously this ran two independent players — a
/// just_audio instance for the iTunes 30s preview (the real audio
/// source) plus a separate always-muted VideoPlayerController for a
/// "matching" YouTube clip layered visually on top. That's gone.
/// There is now exactly one player per card, one network resolve
/// pipeline (ShortsVideoService -> aurum-shorts-video Worker), and
/// its audio is unmuted and IS the playback.
///
/// Still fully isolated from AurumAudioEngine / the native Media3
/// pipeline / the main queue and playback history — per spec this
/// feed remains its own self-contained module. The only crossover
/// point is "Listen Full Song", which only ever hands off song
/// identity (title/artist), same as before.
///
/// Category is STRICT and SINGLE: the controller is always scoped to
/// exactly one active category. Switching category is a full feed
/// replacement (see ShortsFeedScreen._restartFeedWithNewPreferences),
/// never a blend of two categories in the same feed.
class ShortsFeedController extends ChangeNotifier {
  final ShortsRecommendationEngine _engine = ShortsRecommendationEngine();

  final List<ShortItem> _items = [];
  final Set<String> _shownKeys = {};
  int _currentIndex = 0;
  bool _loadingMore = false;
  bool _initialLoading = true;
  bool _liked = false;
  bool _saved = false;
  DownloadTrackState _downloadState = DownloadTrackState.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Timer? _positionTicker;

  VideoPlayerController? _videoController;
  ShortsVideoStatus _videoStatus = ShortsVideoStatus.none;
  // Guards against a slow resolve landing after the user has already
  // swiped away — the classic "wrong clip flickers in" bug.
  int _videoRequestToken = 0;

  // Single-slot preload: the NEXT card's stream is prepared (paused,
  // muted until swapped in) ahead of time so swiping forward feels
  // instant — the Instagram/Reels "already there" feel. Capped at one
  // item ahead since each VideoPlayerController holds a real decoder.
  String? _preloadedForVideoId;
  VideoPlayerController? _preloadedVideoController;
  int _preloadToken = 0;

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
  String get activeCategory => _category;
  ShortItem? get currentItem =>
      _items.isNotEmpty && _currentIndex < _items.length
          ? _items[_currentIndex]
          : null;

  String _category = '';
  String? _language;
  bool _wifiOnlyVideo = true;

  /// [category] and optional [language] scope this controller for its
  /// entire lifetime — pass a new controller instance (see
  /// ShortsFeedScreen) rather than mutating an existing one, so a
  /// category switch is always a clean full replacement.
  Future<void> init({String? category, String? language}) async {
    _category = category ?? await ShortsPrefs.getActiveCategory() ?? 'Trending';
    _language = language;
    _wifiOnlyVideo = await ShortsPrefs.getWifiOnlyVideo();
    await ShortsPrefs.setActiveCategory(_category);

    final firstPaint = await _engine.fetchFirstPaint(
      category: _category,
      language: _language,
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
      unawaited(_preloadNextVideo());
    }
  }

  /// Switches the active category on THIS controller without the
  /// caller needing to construct a new one. Kept for convenience, but
  /// ShortsFeedScreen's toggle bar uses full controller replacement
  /// (like the old preferences restart) since that's the safest way
  /// to guarantee zero state bleed between categories — this method
  /// exists for callers that explicitly want an in-place switch.
  Future<void> switchCategory(String category) async {
    if (category == _category) return;
    _category = category;
    await ShortsPrefs.setActiveCategory(category);

    _items.clear();
    _shownKeys.clear();
    _currentIndex = 0;
    _initialLoading = true;
    notifyListeners();

    final oldVideo = _videoController;
    _videoController = null;
    _videoStatus = ShortsVideoStatus.none;
    if (oldVideo != null) unawaited(oldVideo.dispose());
    final oldPreload = _preloadedVideoController;
    _preloadedVideoController = null;
    _preloadedForVideoId = null;
    if (oldPreload != null) unawaited(oldPreload.dispose());

    final firstPaint = await _engine.fetchFirstPaint(
      category: _category,
      language: _language,
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
    await _loadMore();
    notifyListeners();
    if (_items.isNotEmpty) {
      unawaited(_preloadNextVideo());
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    _loadingMore = true;
    try {
      final batch = await _engine.fetchBatch(
        category: _category,
        language: _language,
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

    _liked = await ShortsPrefs.isLiked(item.videoId);
    _saved = await ShortsPrefs.isSaved(item.videoId);
    _downloadState = DownloadTrackState.idle; // fresh per card
    await ShortsPrefs.bumpArtist(item.artist);
    notifyListeners();

    await _loadVideo(item);
  }

  /// Resolves and plays the single muxed YouTube stream for [item] —
  /// this IS the audio+video source now, not a muted overlay.
  Future<void> _loadVideo(ShortItem item) async {
    final myToken = ++_videoRequestToken;

    // Fast path: this exact item was already preloaded while the
    // user was on the previous card — swap it in immediately.
    if (_preloadedForVideoId == item.videoId &&
        _preloadedVideoController != null) {
      final oldController = _videoController;
      final newController = _preloadedVideoController!;
      _preloadedVideoController = null;
      _preloadedForVideoId = null;
      _videoController = newController;
      _videoStatus = ShortsVideoStatus.ready;
      _duration = newController.value.duration;
      _position = Duration.zero;
      unawaited(newController.setVolume(1.0));
      unawaited(newController.setLooping(true));
      unawaited(newController.play());
      _attachPositionListener(newController);
      notifyListeners();
      if (oldController != null) unawaited(oldController.dispose());
      unawaited(_preloadNextVideo());
      return;
    }

    // Slow path: nothing preloaded — tear down the previous card's
    // player immediately so stale audio/video never lingers.
    final oldController = _videoController;
    _videoController = null;
    _videoStatus = ShortsVideoStatus.loading;
    _position = Duration.zero;
    notifyListeners();
    if (oldController != null) unawaited(oldController.dispose());

    if (_preloadedForVideoId != null && _preloadedForVideoId != item.videoId) {
      final stale = _preloadedVideoController;
      _preloadedVideoController = null;
      _preloadedForVideoId = null;
      if (stale != null) unawaited(stale.dispose());
    }

    final result = await ShortsVideoService.resolveForSong(
      dedupeKey: item.dedupeKey,
      title: item.title,
      artist: item.artist,
    );

    if (myToken != _videoRequestToken || currentItem?.videoId != item.videoId) {
      return; // user already moved on
    }

    if (result == null) {
      _videoStatus = ShortsVideoStatus.failed;
      notifyListeners();
      // Auto-advance rather than leaving a dead/frozen card on
      // screen — matches the old "preview failed, skip forward"
      // behavior, now for the single unified stream.
      unawaited(next());
      return;
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(result.streamUrl),
        httpHeaders: const {'User-Agent': _kAndroidVrUserAgent},
      );
      await controller.initialize();
      if (myToken != _videoRequestToken || currentItem?.videoId != item.videoId) {
        unawaited(controller.dispose());
        return;
      }
      await controller.setVolume(1.0);
      await controller.setLooping(true);
      await controller.play();
      _videoController = controller;
      _videoStatus = ShortsVideoStatus.ready;
      _duration = controller.value.duration;
      _attachPositionListener(controller);
      notifyListeners();
    } catch (e, st) {
      debugPrint('AURUM_SHORTS_VIDEO_FAIL: $e');
      debugPrint('$st');
      if (myToken == _videoRequestToken) {
        _videoStatus = ShortsVideoStatus.failed;
        notifyListeners();
        unawaited(next());
      }
      return;
    }

    unawaited(_preloadNextVideo());
  }

  /// video_player has no position stream — poll lightly instead.
  /// Also drives auto-advance when a clip finishes (mirrors the old
  /// just_audio "completed" auto-next behavior).
  void _attachPositionListener(VideoPlayerController controller) {
    _positionTicker?.cancel();
    _positionTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!controller.value.isInitialized) return;
      _position = controller.value.position;
      notifyListeners();
    });
  }

  /// Prepares the video for the item immediately after the current
  /// one, fully initialized and paused, so swiping forward can swap
  /// it straight in. Fails soft — the slow path in _loadVideo is
  /// always the safety net.
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
    if (myPreload != _preloadToken || _items.indexOf(nextItem) != nextIndex) {
      return;
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(result.streamUrl),
        httpHeaders: const {'User-Agent': _kAndroidVrUserAgent},
      );
      await controller.initialize();
      if (myPreload != _preloadToken) {
        unawaited(controller.dispose());
        return;
      }
      // Muted while merely preloaded/paused — _loadVideo restores
      // volume to 1.0 and calls .play() itself once swapped in.
      await controller.setVolume(0);
      await controller.setLooping(true);
      _preloadedVideoController = controller;
      _preloadedForVideoId = nextItem.videoId;
    } catch (_) {
      // Fail soft — slow path in _loadVideo covers it.
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

    if (_items.length - _currentIndex <= _refillThreshold && !_loadingMore) {
      unawaited(_loadMore());
    }
  }

  Future<void> toggleLike() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.toggleLiked(item.videoId);
    _liked = await ShortsPrefs.isLiked(item.videoId);
    notifyListeners();
  }

  Future<void> toggleSave() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.toggleSaved(item.videoId);
    _saved = await ShortsPrefs.isSaved(item.videoId);
    notifyListeners();
  }

  void setDownloadState(DownloadTrackState state) {
    _downloadState = state;
    notifyListeners();
  }

  Future<void> registerReplay() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.incrementReplay(item.videoId);
  }

  Future<void> registerSkip() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.addSkipped(item.videoId);
  }

  void togglePlayPause() {
    final ctrl = _videoController;
    if (ctrl == null) return;
    if (ctrl.value.isPlaying) {
      ctrl.pause();
    } else {
      ctrl.play();
    }
    notifyListeners();
  }

  bool get isPlaying => _videoController?.value.isPlaying ?? false;

  @override
  void dispose() {
    _positionTicker?.cancel();
    _videoController?.dispose();
    _preloadedVideoController?.dispose();
    super.dispose();
  }
}
