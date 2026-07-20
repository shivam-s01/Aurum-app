// =============================================================================
// FILE: lib/services/native_engine_bridge.dart
// Stage 2 — full queue/session/resolve orchestration moved to Kotlin
// (AurumAudioEngine.kt). This file:
//   1. Answers Kotlin's "resolveStreamUrl"/"cancelResolve"/"invalidateStream"
//      calls by delegating to the EXISTING ApiService (untouched) — I7
//      (true cancellation) via a real Dart-side cancel token per requestId.
//   2. Exposes NativeAudioEngine — a Dart-facing facade with the same
//      method names as AurumAudioHandler's public API, backed by
//      MethodChannel calls into AurumAudioEngine.kt, and a state stream
//      that replays last-known-value to late subscribers (rxdart
//      BehaviorSubject), matching just_audio's stream semantics.
//   3. Handles the "onLikeToggleRequested" reverse call — fired by
//      AurumMediaSessionService when the user taps the like/heart button on
//      the lock screen or notification. PlayerProvider wires a callback
//      here (see onLikeToggleRequested below) so FavoritesProvider stays
//      the single source of truth for liked state even when the toggle
//      originates natively.
// =============================================================================

import 'dart:async';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';
import '../models/song.dart';
import 'api_service.dart';
import 'audio_prefs.dart';

class NativeEngineState {
  final String processingState;
  final bool playing;
  final Duration position;
  final Duration bufferedPosition;
  final Duration? duration;
  final int? currentIndex;
  final double speed;
  final List<String> queueIds;
  final String? currentSongId;
  final bool liked;

  const NativeEngineState({
    this.processingState = 'idle',
    this.playing = false,
    this.position = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.duration,
    this.currentIndex,
    this.speed = 1.0,
    this.queueIds = const [],
    this.currentSongId,
    this.liked = false,
  });
}

class PlaybackErrorEvent {
  final String message;
  final bool silent;
  const PlaybackErrorEvent(this.message, this.silent);
}

class NativeAudioEngine {
  static const MethodChannel _method = MethodChannel('com.aurum.music/audio_engine');
  static const EventChannel _stateEvents = EventChannel('com.aurum.music/audio_engine_state');
  static const EventChannel _errorEvents = EventChannel('com.aurum.music/audio_engine_errors');

  // I7: real per-request cancellation — each Kotlin resolve request gets a
  // CancelableCompleter-equivalent on the Dart side so a superseded resolve
  // actually abandons the underlying http.Client call, not just its result.
  static const MethodChannel _resolverChannel = MethodChannel('com.aurum.music/stream_resolver');
  static final Map<int, _ResolveJob> _inFlight = {};

  final _state = BehaviorSubject<NativeEngineState>.seeded(const NativeEngineState());
  final _errors = StreamController<PlaybackErrorEvent>.broadcast();

  Stream<NativeEngineState> get stateStream => _state.stream;
  Stream<PlaybackErrorEvent> get errorStream => _errors.stream;
  NativeEngineState get value => _state.value;

  StreamSubscription? _stateSub;
  StreamSubscription? _errorSub;

  // Fired when AurumMediaSessionService (lock screen / notification heart)
  // reports a like-toggle tap for the given song ID. PlayerProvider sets
  // this to bridge into FavoritesProvider.toggleFavorite(). Left null-safe
  // (no-op) if nothing has wired it yet, so an early native event can't
  // crash startup.
  void Function(String songId)? onLikeToggleRequested;

  NativeAudioEngine() {
    // Same MethodChannel as the outgoing calls below — Kotlin's
    // AurumEngineChannelHandler uses this channel bidirectionally: Dart
    // calls playQueue/playSong/etc. on it, and it calls back
    // "onLikeToggleRequested" on the same channel for the reverse
    // direction. setMethodCallHandler only affects incoming calls, so it's
    // safe to set alongside the outgoing invokeMethod calls further down.
    _method.setMethodCallHandler(_handleEngineCallback);

    _resolverChannel.setMethodCallHandler(_handleResolverCall);

    _stateSub = _stateEvents.receiveBroadcastStream().listen((raw) {
      final m = Map<String, dynamic>.from(raw as Map);
      _state.add(NativeEngineState(
        processingState: m['processingState'] as String? ?? 'idle',
        playing: m['playing'] as bool? ?? false,
        position: Duration(milliseconds: (m['positionMs'] as num? ?? 0).toInt()),
        bufferedPosition: Duration(milliseconds: (m['bufferedPositionMs'] as num? ?? 0).toInt()),
        duration: (m['durationMs'] as num?) != null
            ? Duration(milliseconds: (m['durationMs'] as num).toInt())
            : null,
        currentIndex: m['currentIndex'] as int?,
        speed: (m['speed'] as num? ?? 1.0).toDouble(),
        queueIds: List<String>.from(m['queueIds'] as List? ?? const []),
        currentSongId: m['currentSongId'] as String?,
        liked: m['liked'] as bool? ?? false,
      ));
    });

    _errorSub = _errorEvents.receiveBroadcastStream().listen((raw) {
      final m = Map<String, dynamic>.from(raw as Map);
      _errors.add(PlaybackErrorEvent(
        m['message'] as String? ?? 'Unknown playback error',
        m['silent'] as bool? ?? false,
      ));
    });
  }

  // ── Kotlin -> Dart: like-toggle reverse channel ──
  Future<dynamic> _handleEngineCallback(MethodCall call) async {
    switch (call.method) {
      case 'onLikeToggleRequested':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final songId = args['songId'] as String?;
        if (songId != null) onLikeToggleRequested?.call(songId);
        return null;
      default:
        return null;
    }
  }

  // ── Kotlin -> Dart: resolve/cancel/invalidate ──
  Future<dynamic> _handleResolverCall(MethodCall call) async {
    switch (call.method) {
      case 'resolveStreamUrl':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final requestId = args['requestId'] as int;
        final song = _songFromArgs(args);
        final forceRefresh = args['forceRefresh'] as bool? ?? false;

        final completer = Completer<String?>();
        _inFlight[requestId] = _ResolveJob(completer);
        try {
          // ApiService.resolveStreamUrl is untouched — same fallback chain
          // (Worker/Piped/Invidious) as before. If a cancelResolve arrives
          // for this requestId before it finishes, the completer below is
          // already gone from _inFlight and its result is simply discarded;
          // true upstream cancellation of the in-flight http.Client request
          // requires ApiService to expose a cancel token, which is Stage 4
          // scope — flagged here rather than silently assumed done.
          final result = await ApiService.resolveStreamUrl(song, forceRefresh: forceRefresh);
          if (_inFlight.containsKey(requestId)) completer.complete(result);
          if (result != null) {
            // Fire-and-forget: lets AurumAudioEffects know how compressed
            // this source is, so Premium Sound's low-bitrate compensation
            // curve (see applyPremiumSound) can scale itself in. Never
            // awaited/blocking on the resolve path — if this call fails,
            // the native side just falls back to treating the source as
            // unknown-bitrate, which is a graceful (if slightly less
            // tailored) default, not a broken one.
            unawaited(_method.invokeMethod('reportResolvedBitrate', {
              'kbps': AudioPrefs.lastResolvedKbps,
            }).catchError((_) {}));
          }
        } catch (e) {
          if (_inFlight.containsKey(requestId)) completer.complete(null);
        } finally {
          _inFlight.remove(requestId);
        }
        return completer.future;

      case 'cancelResolve':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final requestId = args['requestId'] as int;
        _inFlight.remove(requestId);
        return null;

      case 'invalidateStream':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final song = _songFromArgs(args);
        ApiService.invalidateStream(song);
        return null;

      default:
        return null;
    }
  }

  Song _songFromArgs(Map<String, dynamic> args) {
    final sourceStr = args['source'] as String? ?? 'saavn';
    final source = SongSource.values.firstWhere(
      (s) => s.name == sourceStr,
      orElse: () => SongSource.saavn,
    );
    return Song(
      id: args['songId'] as String? ?? '',
      title: args['title'] as String? ?? '',
      artist: args['artist'] as String? ?? '',
      album: args['album'] as String? ?? '',
      artworkUrl: args['artworkUrl'] as String? ?? '',
      localPath: args['localPath'] as String?,
      source: source,
    );
  }

  Map<String, dynamic> _songToArgs(Song song) => {
        'id': song.id,
        'title': song.title,
        'artist': song.artist,
        'album': song.album,
        'artworkUrl': song.artworkUrl,
        'source': song.source.name,
        'isLocal': song.isLocal,
        'localPath': song.localPath,
      };

  // ── Dart -> Kotlin: transport / queue commands ──
  Future<void> playQueue(List<Song> songs, int startIndex) => _method.invokeMethod(
        'playQueue',
        {'songs': songs.map(_songToArgs).toList(), 'startIndex': startIndex},
      );

  Future<void> playSong(Song song) => _method.invokeMethod('playSong', {'song': _songToArgs(song)});
  Future<void> addToQueue(Song song) => _method.invokeMethod('addToQueue', {'song': _songToArgs(song)});
  Future<void> lookaheadResolve(Song song) => _method.invokeMethod('lookaheadResolve', {'song': _songToArgs(song)});
  Future<void> removeFromQueue(int index) => _method.invokeMethod('removeFromQueue', {'index': index});
  Future<void> moveQueueItem(int from, int to) =>
      _method.invokeMethod('moveQueueItem', {'from': from, 'to': to});
  Future<void> clearQueue() => _method.invokeMethod('clearQueue');
  Future<void> play() => _method.invokeMethod('play');
  Future<void> pause() => _method.invokeMethod('pause');
  Future<void> stop() => _method.invokeMethod('stop');
  Future<void> seek(Duration pos) => _method.invokeMethod('seek', {'positionMs': pos.inMilliseconds});
  Future<void> skipToNext() => _method.invokeMethod('skipToNext');
  Future<void> skipToPrevious() => _method.invokeMethod('skipToPrevious');
  Future<void> skipToQueueItem(int index) => _method.invokeMethod('skipToQueueItem', {'index': index});
  Future<void> setRepeatMode(String mode) => _method.invokeMethod('setRepeatMode', {'mode': mode});
  Future<void> setShuffleMode(bool enabled) => _method.invokeMethod('setShuffleMode', {'enabled': enabled});
  Future<void> setSpeed(double speed) => _method.invokeMethod('setSpeed', {'speed': speed});
  Future<void> setCurrentSongLiked(bool liked) =>
      _method.invokeMethod('setCurrentSongLiked', {'liked': liked});
  Future<void> setCrossfadeSeconds(double secs) =>
      _method.invokeMethod('setCrossfadeSeconds', {'seconds': secs});
  Future<void> sleepAfterCurrentSong() => _method.invokeMethod('sleepAfterCurrentSong');

  // FIX (2026-07-07) — "downloads fail / stuck resolving": DownloadProvider
  // was calling ApiService.resolveStreamUrl() directly for every download,
  // which is the OLD, Worker-only resolve chain — it never benefited from
  // the native YoutubeInnertube/NewPipeExtractor path that live playback
  // now uses (via HybridStreamResolver), even after that path became the
  // reliable one. This calls the exact same resolver playback uses,
  // native-first with the existing Worker/Dart chain only as a fallback,
  // as a single one-shot lookup with no queue/player side effects —
  // DownloadProvider.download() calls this for youtube-source songs
  // instead of ApiService.resolveStreamUrl() directly.
  //
  // Returns null if resolution genuinely failed on both the native and
  // fallback paths (caller should treat this exactly like the old
  // resolveStreamUrl() returning null/throwing).
  Future<String?> resolveForDownload(Song song) async {
    try {
      final result = await _method.invokeMethod<String>(
        'resolveForDownload',
        {'song': _songToArgs(song)},
      );
      return result;
    } catch (_) {
      return null;
    }
  }

  // ── Bass Boost / Equalizer (native android.media.audiofx, see
  // AurumAudioEffects.kt) — replaces the old just_audio-based
  // AudioEffectsController. Gains are given/received in dB (matching the
  // Dart-side slider unit the settings screen already uses) and converted
  // to millibels (Android's native unit, 100mB = 1dB) at the boundary here
  // so callers never have to think about the conversion.
  Future<void> applyAudioEffects({
    required bool bassBoost,
    required bool volumeNormalization,
    List<double>? bandGainsDb,
  }) =>
      _method.invokeMethod('applyAudioEffects', {
        'bassBoost': bassBoost,
        'volumeNormalization': volumeNormalization,
        'bandGainsMb': bandGainsDb?.map((db) => (db * 100).round()).toList(),
      });

  /// "Premium Sound" — single toggle for the license-free Virtualizer +
  /// native BassBoost + extra LoudnessEnhancer gain + presence/clarity EQ
  /// curve chain (see AurumAudioEffects.applyPremiumSound). Independent of
  /// applyAudioEffects' Bass Boost/Volume Normalization/manual EQ — the two
  /// compose on the native side rather than one overriding the other.
  Future<void> applyPremiumSound(bool enabled) =>
      _method.invokeMethod('applyPremiumSound', {'enabled': enabled});

  /// A/B compare mode: switches Premium Sound on/off INSTANTLY (no fade),
  /// so tapping a compare button snaps immediately rather than blurring
  /// through the normal 1.4s transition. Does not change the user's saved
  /// Premium Sound preference — call [exitPremiumSoundCompare] when the
  /// user leaves the compare screen to land back on their real setting.
  Future<void> setPremiumSoundCompare(bool enabled) =>
      _method.invokeMethod('setPremiumSoundCompare', {'enabled': enabled});

  /// Ends A/B compare mode and restores whatever Premium Sound state was
  /// last set via [applyPremiumSound] (with its normal fade).
  Future<void> exitPremiumSoundCompare() =>
      _method.invokeMethod('exitPremiumSoundCompare');

  /// Supported-device check + current output route, so the UI can show an
  /// accurate note (e.g. "Spatial widening isn't supported on this device
  /// — clarity and bass effects are still active") instead of implying a
  /// full effect on hardware that silently can't do part of the chain.
  /// Returns null if the native side hasn't attached yet (call again after
  /// playback starts).
  Future<PremiumSoundCapabilities?> getPremiumSoundCapabilities() async {
    final raw = await _method.invokeMethod('getPremiumSoundCapabilities');
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw as Map);
    return PremiumSoundCapabilities(
      virtualizerSupported: m['virtualizerSupported'] as bool? ?? false,
      bassBoostSupported: m['bassBoostSupported'] as bool? ?? false,
      outputRoute: m['outputRoute'] as String? ?? 'UNKNOWN',
    );
  }

  /// Returns null if the native Equalizer hasn't attached yet (e.g. nothing
  /// has played this session — attach happens on the first audioSessionId
  /// assignment). Call again after playback starts if null.
  Future<EqualizerBandInfo?> getEqualizerBands() async {
    final raw = await _method.invokeMethod('getEqualizerBands');
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw as Map);
    return EqualizerBandInfo(
      bandCount: m['bandCount'] as int? ?? 0,
      minDb: ((m['minMb'] as num? ?? 0).toInt()) / 100.0,
      maxDb: ((m['maxMb'] as num? ?? 0).toInt()) / 100.0,
      centerFreqsHz: List<int>.from(m['centerFreqsHz'] as List? ?? const []),
    );
  }

  Future<void> dispose() async {
    await _stateSub?.cancel();
    await _errorSub?.cancel();
    await _state.close();
    await _errors.close();
  }
}

class _ResolveJob {
  final Completer<String?> completer;
  _ResolveJob(this.completer);
}

/// Describes this device's real Equalizer capabilities — band count, gain
/// range in dB, and each band's center frequency — so the EQ slider UI
/// (settings_player_screen.dart) can build itself around what the device
/// actually supports instead of an assumed 5-band/±15dB layout.
class EqualizerBandInfo {
  final int bandCount;
  final double minDb;
  final double maxDb;
  final List<int> centerFreqsHz;

  const EqualizerBandInfo({
    required this.bandCount,
    required this.minDb,
    required this.maxDb,
    required this.centerFreqsHz,
  });
}

/// What this device's audio stack can actually do for Premium Sound, and
/// what output it's currently routed to — lets the settings UI show an
/// accurate "partial support" note instead of implying full effect on
/// hardware that silently can't do part of the chain.
class PremiumSoundCapabilities {
  final bool virtualizerSupported;
  final bool bassBoostSupported;
  final String outputRoute; // 'WIRED_HEADPHONES' | 'BLUETOOTH' | 'SPEAKER' | 'UNKNOWN'

  const PremiumSoundCapabilities({
    required this.virtualizerSupported,
    required this.bassBoostSupported,
    required this.outputRoute,
  });

  bool get fullySupported => virtualizerSupported && bassBoostSupported;
}
