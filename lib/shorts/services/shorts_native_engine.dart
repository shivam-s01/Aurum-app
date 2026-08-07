import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ShortsNativeStatus { none, loading, ready, failed }

class ShortsNativeState {
  final ShortsNativeStatus status;
  final Duration position;
  final Duration duration;
  final bool isPlaying;

  const ShortsNativeState({
    required this.status,
    required this.position,
    required this.duration,
    required this.isPlaying,
  });

  static const initial = ShortsNativeState(
    status: ShortsNativeStatus.none,
    position: Duration.zero,
    duration: Duration.zero,
    isPlaying: false,
  );
}

/// Thin Dart-side bridge to AurumShortsEngine (Kotlin). Search, stream
/// resolution (reusing the same resolver the main song queue uses),
/// buffering, the 30-second clip timer, and playback all happen
/// natively. This class owns nothing but the MethodChannel/EventChannel
/// plumbing.
///
/// Shorts are audio-only 30-second clips — there is no video surface
/// or PlatformView involved. The visible layer is always the artwork
/// (see ShortsVisualCard's Ken Burns zoom).
class ShortsNativeEngine {
  ShortsNativeEngine._();
  static final ShortsNativeEngine instance = ShortsNativeEngine._();

  static const _methodChannel = MethodChannel('com.aurum.music/shorts_engine');
  static const _eventChannel = EventChannel('com.aurum.music/shorts_engine_state');
  static const _advanceChannel = MethodChannel('com.aurum.music/shorts_engine_advance');

  final _stateController = StreamController<ShortsNativeState>.broadcast();
  final _autoAdvanceController = StreamController<void>.broadcast();
  StreamSubscription? _eventSub;

  Stream<ShortsNativeState> get stateStream => _stateController.stream;
  Stream<void> get autoAdvanceStream => _autoAdvanceController.stream;

  bool _listening = false;

  /// Call once when the Shorts feed screen mounts.
  void startListening() {
    if (_listening) return;
    _listening = true;

    _eventSub = _eventChannel.receiveBroadcastStream().listen((event) {
      final map = Map<String, dynamic>.from(event as Map);
      final status = ShortsNativeStatus.values.firstWhere(
        (s) => s.name.toUpperCase() == (map['status'] as String? ?? 'NONE'),
        orElse: () => ShortsNativeStatus.none,
      );
      _stateController.add(ShortsNativeState(
        status: status,
        position: Duration(milliseconds: (map['positionMs'] as num? ?? 0).toInt()),
        duration: Duration(milliseconds: (map['durationMs'] as num? ?? 0).toInt()),
        isPlaying: map['isPlaying'] as bool? ?? false,
      ));
    });

    _advanceChannel.setMethodCallHandler((call) async {
      if (call.method == 'onAutoAdvance') {
        _autoAdvanceController.add(null);
      }
      return null;
    });
  }

  /// Call when the Shorts feed screen unmounts.
  void stopListening() {
    _listening = false;
    _eventSub?.cancel();
    _eventSub = null;
    _advanceChannel.setMethodCallHandler(null);
  }

  // FIX (crash hardening): every invokeMethod call here used to
  // propagate PlatformException straight to its caller. playSong() in
  // particular is awaited directly inside
  // ShortsFeedController._playCurrent(), which itself is awaited from
  // next()/previous()/jumpTo() with no try/catch anywhere in that
  // chain — so a single native-side failure (e.g. ExoPlayer rejecting
  // a malformed previewUrl, a transient MethodChannel error during
  // hot-reload, engine not yet attached) would throw all the way up
  // through a PageView's onPageChanged callback and crash the whole
  // Shorts screen instead of just failing that one card. Swallowing
  // here (with debug-only logging) means a bad card degrades to "this
  // one preview didn't play" — the feed and controller state stay
  // intact and the user can keep swiping.
  Future<void> playSong({
    required String dedupeKey,
    required String title,
    required String artist,
    required String previewUrl,
  }) async {
    try {
      await _methodChannel.invokeMethod('playSong', {
        'dedupeKey': dedupeKey,
        'title': title,
        'artist': artist,
        'previewUrl': previewUrl,
      });
    } catch (e) {
      debugPrint('ShortsNativeEngine.playSong failed: $e');
    }
  }

  Future<void> preloadNext({
    required String dedupeKey,
    required String title,
    required String artist,
    required String previewUrl,
  }) async {
    try {
      await _methodChannel.invokeMethod('preloadNext', {
        'dedupeKey': dedupeKey,
        'title': title,
        'artist': artist,
        'previewUrl': previewUrl,
      });
    } catch (e) {
      debugPrint('ShortsNativeEngine.preloadNext failed: $e');
    }
  }

  Future<void> togglePlayPause() async {
    try {
      await _methodChannel.invokeMethod('togglePlayPause');
    } catch (e) {
      debugPrint('ShortsNativeEngine.togglePlayPause failed: $e');
    }
  }

  Future<void> pause() async {
    try {
      await _methodChannel.invokeMethod('pause');
    } catch (e) {
      debugPrint('ShortsNativeEngine.pause failed: $e');
    }
  }

  Future<void> resume() async {
    try {
      await _methodChannel.invokeMethod('resume');
    } catch (e) {
      debugPrint('ShortsNativeEngine.resume failed: $e');
    }
  }

  /// Releases both native ExoPlayer instances — call when the Shorts
  /// feed screen is fully closed (not on every card change).
  Future<void> release() async {
    try {
      await _methodChannel.invokeMethod('release');
    } catch (e) {
      debugPrint('ShortsNativeEngine.release failed: $e');
    }
  }
}
