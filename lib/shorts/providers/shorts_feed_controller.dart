import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../models/short_item.dart';
import '../services/shorts_prefs.dart';
import '../services/shorts_recommendation_engine.dart';

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
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // How many items ahead to keep pre-buffered/ready.
  static const int _preloadWindow = 3;
  static const int _refillThreshold = 5;
  static const int _batchSize = 15;

  List<ShortItem> get items => List.unmodifiable(_items);
  int get currentIndex => _currentIndex;
  bool get initialLoading => _initialLoading;
  bool get isLiked => _liked;
  Duration get position => _position;
  Duration get duration => _duration;
  ShortItem? get currentItem =>
      _items.isNotEmpty && _currentIndex < _items.length
          ? _items[_currentIndex]
          : null;

  List<String> _languages = [];
  List<String> _categories = [];

  Future<void> init() async {
    _languages = await ShortsPrefs.getLanguages();
    _categories = await ShortsPrefs.getCategories();

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

    await _loadMore();
    _initialLoading = false;
    notifyListeners();
    if (_items.isNotEmpty) {
      await _playCurrent();
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
      await ShortsPrefs.bumpArtist(item.artist);
      notifyListeners();
    } catch (_) {
      // Preview failed to load (dead URL / network) — skip forward
      // automatically rather than showing a stuck/frozen card.
      next();
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
    } else {
      _player.play();
    }
    notifyListeners();
  }

  bool get isPlaying => _player.playing;

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
