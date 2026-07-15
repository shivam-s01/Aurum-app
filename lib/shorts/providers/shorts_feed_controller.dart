import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/short_item.dart';
import '../services/shorts_native_engine.dart';
import '../services/shorts_prefs.dart';
import '../services/shorts_recommendation_engine.dart';

enum DownloadTrackState { idle, downloading, done }

/// Status of the current card's native-resolved video — mirrors
/// ShortsNativeStatus but kept as its own enum so the rest of the app's
/// widgets don't need to import the native bridge type directly.
enum ShortsVideoStatus { none, loading, ready, failed }

/// Owns the Shorts feed state: item list, current index, preload
/// window. Playback itself — search, stream resolution, ExoPlayer,
/// preloading — lives entirely in native Kotlin now (AurumShortsEngine).
/// This controller's job shrank to: track which item is active, tell
/// the native engine to play/preload it, and mirror native
/// status/position back into ChangeNotifier state for the UI.
///
/// v3 rewrite: previously this held a `VideoPlayerController?` per card
/// and ran the whole resolve pipeline (ShortsVideoService -> Cloudflare
/// Worker) from Dart. That's gone — no VideoPlayerController, no
/// dart:ui video texture, no per-swipe controller dispose/GC churn.
/// The native engine owns two pooled ExoPlayer instances (current +
/// preload) for the smoothness a thin Flutter plugin wrapper couldn't
/// give us.
///
/// Still fully isolated from AurumAudioEngine / the main queue — the
/// native Shorts engine is a completely separate native object with no
/// shared state. The only crossover point is "Listen Full Song", same
/// as before.
class ShortsFeedController extends ChangeNotifier {
  final ShortsRecommendationEngine _engine = ShortsRecommendationEngine();
  final ShortsNativeEngine _native = ShortsNativeEngine.instance;

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

  ShortsVideoStatus _videoStatus = ShortsVideoStatus.none;
  bool _isPlaying = false;
  StreamSubscription<ShortsNativeState>? _stateSub;
  StreamSubscription<void>? _advanceSub;

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
  ShortsVideoStatus get videoStatus => _videoStatus;
  bool get isPlaying => _isPlaying;
  String get activeCategory => _category;
  ShortItem? get currentItem =>
      _items.isNotEmpty && _currentIndex < _items.length
          ? _items[_currentIndex]
          : null;

  String _category = '';
  String? _language;

  Future<void> init({String? category, String? language}) async {
    _category = category ?? await ShortsPrefs.getActiveCategory() ?? 'Trending';
    _language = language;
    await ShortsPrefs.setActiveCategory(_category);

    _native.startListening();
    _stateSub = _native.stateStream.listen(_onNativeState);
    _advanceSub = _native.autoAdvanceStream.listen((_) => unawaited(next()));

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
    unawaited(_preloadNext());
  }

  void _onNativeState(ShortsNativeState s) {
    _videoStatus = switch (s.status) {
      ShortsNativeStatus.none => ShortsVideoStatus.none,
      ShortsNativeStatus.loading => ShortsVideoStatus.loading,
      ShortsNativeStatus.ready => ShortsVideoStatus.ready,
      ShortsNativeStatus.failed => ShortsVideoStatus.failed,
    };
    _position = s.position;
    _duration = s.duration;
    _isPlaying = s.isPlaying;
    notifyListeners();
  }

  Future<void> switchCategory(String category) async {
    if (category == _category) return;
    _category = category;
    await ShortsPrefs.setActiveCategory(category);

    _items.clear();
    _shownKeys.clear();
    _currentIndex = 0;
    _initialLoading = true;
    _videoStatus = ShortsVideoStatus.none;
    notifyListeners();

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
    unawaited(_preloadNext());
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

    _liked = await ShortsPrefs.isLiked(item.trackId);
    _saved = await ShortsPrefs.isSaved(item.trackId);
    _downloadState = DownloadTrackState.idle;
    await ShortsPrefs.bumpArtist(item.artist);
    notifyListeners();

    await _native.playSong(
      dedupeKey: item.dedupeKey,
      title: item.title,
      artist: item.artist,
      previewUrl: item.previewUrl,
    );
    unawaited(_preloadNext());
  }

  Future<void> _preloadNext() async {
    final nextIndex = _currentIndex + 1;
    if (nextIndex >= _items.length) return;
    final nextItem = _items[nextIndex];
    await _native.preloadNext(
      dedupeKey: nextItem.dedupeKey,
      title: nextItem.title,
      artist: nextItem.artist,
      previewUrl: nextItem.previewUrl,
    );
  }

  Future<void> next() async {
    if (_currentIndex >= _items.length - 1) {
      if (!_loadingMore) await _loadMore();
      if (_currentIndex >= _items.length - 1) return;
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
    await ShortsPrefs.toggleLiked(item.trackId);
    _liked = await ShortsPrefs.isLiked(item.trackId);
    notifyListeners();
  }

  Future<void> toggleSave() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.toggleSaved(item.trackId);
    _saved = await ShortsPrefs.isSaved(item.trackId);
    notifyListeners();
  }

  void setDownloadState(DownloadTrackState state) {
    _downloadState = state;
    notifyListeners();
  }

  Future<void> registerReplay() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.incrementReplay(item.trackId);
  }

  Future<void> registerSkip() async {
    final item = currentItem;
    if (item == null) return;
    await ShortsPrefs.addSkipped(item.trackId);
  }

  void togglePlayPause() {
    unawaited(_native.togglePlayPause());
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _advanceSub?.cancel();
    _native.stopListening();
    unawaited(_native.release());
    super.dispose();
  }
}
