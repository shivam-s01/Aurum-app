import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/short_item.dart';
import '../services/itunes_shorts_api.dart';
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

  // FIX (same class of bug as PlayerProvider._uiPlaySession): _playCurrent()
  // is async — it awaits ShortsPrefs.isLiked/isSaved before calling
  // _native.playSong(). Fast repeated swipes (next()/previous()/jumpTo(),
  // or an auto-advance firing while a previous _playCurrent() is still
  // resolving) can leave more than one _playCurrent() call in flight at
  // once. Without a guard, an OLDER call finishing after a NEWER one had
  // already moved _currentIndex on could still overwrite _liked/_saved
  // with its own (now stale) item's state, and fire _native.playSong()
  // for the wrong (previous) card — the native engine would then briefly
  // or permanently play/display a card that isn't the one the UI has
  // already swiped to, the exact same "state shows one thing, playback is
  // another" bug class fixed elsewhere in player_provider.dart and
  // native_engine_bridge.dart. Bumped on every _playCurrent() call; any
  // call whose session has been superseded by the time its awaits
  // resolve simply stops touching shared state instead of clobbering it.
  int _playSession = 0;

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
    var resolvedFirstPaint = firstPaint;
    // FIX (empty feed on transient failure, e.g. iTunes rate-limit):
    // a single empty first-paint result used to go straight to
    // _EmptyFeedState with no retry — the most common real-world cause
    // being a brief 403 rate-limit window that ItunesShortsApi itself
    // already retries internally, but a slower/aggregate failure could
    // still slip through. One extra attempt here, after a short delay,
    // covers that gap without adding a visible extra spinner cycle for
    // the user (initialLoading stays true throughout).
    if (resolvedFirstPaint.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 800));
      resolvedFirstPaint = await _engine.fetchFirstPaint(
        category: _category,
        language: _language,
      );
    }
    for (final item in resolvedFirstPaint) {
      _shownKeys.add(item.dedupeKey);
    }
    _items.addAll(resolvedFirstPaint);
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

    // FIX ("fresh content every time, category-wise"): ItunesShortsApi's
    // per-(category,language) offset is module-level and persists across
    // switches within the same app session — only _shownKeys (below) was
    // being cleared here. Without this reset, returning to a category
    // already visited this session would resume from wherever its offset
    // was left, not restart from a fresh rotation — so a quick
    // Punjabi -> Bhojpuri -> Punjabi hop showed the same songs again
    // instead of a genuinely new batch. Resetting the cursor here makes
    // every category switch a true fresh start, same as a first app
    // launch would give it.
    ItunesShortsApi.resetCursor(category, _language);

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
    var resolvedFirstPaint = firstPaint;
    if (resolvedFirstPaint.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 800));
      resolvedFirstPaint = await _engine.fetchFirstPaint(
        category: _category,
        language: _language,
      );
    }
    for (final item in resolvedFirstPaint) {
      _shownKeys.add(item.dedupeKey);
    }
    _items.addAll(resolvedFirstPaint);
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

    final mySession = ++_playSession;

    final liked = await ShortsPrefs.isLiked(item.trackId);
    final saved = await ShortsPrefs.isSaved(item.trackId);
    // A newer _playCurrent() call (from another fast swipe) may have
    // started and even finished while these awaits were resolving — if
    // so, this call is stale and must not touch any shared state or tell
    // the native engine to play its (now-previous) card.
    if (mySession != _playSession) return;

    _liked = liked;
    _saved = saved;
    _downloadState = DownloadTrackState.idle;
    await ShortsPrefs.bumpArtist(item.artist);
    if (mySession != _playSession) return;
    notifyListeners();

    await _native.playSong(
      dedupeKey: item.dedupeKey,
      title: item.title,
      artist: item.artist,
      previewUrl: item.previewUrl,
    );
    if (mySession != _playSession) return;
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
