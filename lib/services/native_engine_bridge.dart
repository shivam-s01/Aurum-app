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
import 'package:flutter/foundation.dart' show debugPrint;
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
  // Mirrors AurumAudioEngine.kt's NativeEngineState.resolveTakingLong:
  // true while the current song's stream has been retrying to resolve
  // for longer than a normal connection should need, but the engine is
  // still actively retrying in the background rather than having given
  // up — PlayerProvider surfaces this as a "check your connection"
  // message, never as a song change. See AurumAudioEngine's no-auto-skip
  // resolve policy for the full reasoning.
  final bool resolveTakingLong;

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
    this.resolveTakingLong = false,
  });
}

class PlaybackErrorEvent {
  final String message;
  final bool silent;
  const PlaybackErrorEvent(this.message, this.silent);
}

class NativeAudioEngine {
  // FIX (root cause of "seek bar permanently frozen, isLoading stuck true,
  // audio genuinely plays and notification shows the correct song" —
  // reported on EVERY song, regardless of source/how it was started):
  // NativeAudioEngine() used to be a plain constructor, called fresh at
  // FIVE separate call sites across the app (main.dart's real _audioEngine,
  // AuthProvider._engineBridge, home_screen.dart's one-shot Auto Sleep
  // Guard prompt check, auto_sleep_guard_tile.dart, and potentially more).
  // Each call site's comment assumed this was a cheap, side-effect-free
  // "handle" onto shared native state — it is NOT. The constructor calls
  // _stateEvents.receiveBroadcastStream().listen(...), and Flutter's
  // EventChannel only supports ONE live native-side sink per channel name
  // at a time: subscribing a SECOND Dart-side listener on the same
  // EventChannel silently fires onCancel on Kotlin's existing sink, then
  // onListen again for the new one — stealing the subscription. Every
  // extra `NativeAudioEngine()` instantiation after the first (e.g.
  // AuthProvider's field initializer running during app startup, or
  // home_screen.dart's one-shot _maybeShowAutoSleepGuardResumePrompt())
  // silently killed the event stream that PlayerProvider's `_engine` was
  // actually listening to — permanently, for the rest of the session,
  // since nothing ever re-subscribes the original instance. The native
  // Kotlin engine itself was always correct (which is exactly why audio
  // played fine and the notification always showed the right song/title/
  // duration) — PlayerProvider simply never received another state event
  // to update _isLoading/_currentSong/_position/_duration from again after
  // the first stray extra instantiation happened, anywhere in the app.
  //
  // Fix: true singleton. Every call site's `NativeAudioEngine()` now
  // returns the exact same object, so the constructor body (and its
  // EventChannel subscriptions) only ever runs once per app process,
  // regardless of how many places construct it or in what order.
  static NativeAudioEngine? _instance;
  factory NativeAudioEngine() => _instance ??= NativeAudioEngine._internal();

  static const MethodChannel _method = MethodChannel('com.aurum.music/audio_engine');
  static const EventChannel _stateEvents = EventChannel('com.aurum.music/audio_engine_state');
  static const EventChannel _errorEvents = EventChannel('com.aurum.music/audio_engine_errors');
  static const EventChannel _outputDeviceEvents =
      EventChannel('com.aurum.music/audio_output_devices');
  static const EventChannel _castStateEvents =
      EventChannel('com.aurum.music/cast_state');
  static const EventChannel _castRoutesEvents =
      EventChannel('com.aurum.music/cast_routes');

  // I7: real per-request cancellation — each Kotlin resolve request gets a
  // CancelableCompleter-equivalent on the Dart side so a superseded resolve
  // actually abandons the underlying http.Client call, not just its result.
  static const MethodChannel _resolverChannel = MethodChannel('com.aurum.music/stream_resolver');
  static final Map<int, _ResolveJob> _inFlight = {};

  final _state = BehaviorSubject<NativeEngineState>.seeded(const NativeEngineState());
  final _errors = StreamController<PlaybackErrorEvent>.broadcast();
  // Seeded null: no snapshot has arrived yet (native side only pushes an
  // update on device connect/disconnect, not on subscribe) — callers
  // should pair this stream with an initial getAudioOutputDevices() call
  // rather than waiting on the stream alone for the first paint.
  final _outputDevices =
      BehaviorSubject<AudioOutputDevices?>.seeded(null);
  // Seeded "unavailable/unsupported" rather than null: unlike output
  // devices (where "no snapshot yet" and "not supported" are genuinely
  // different states worth distinguishing), the cast button should just
  // render hidden/disabled until the first real snapshot arrives, and
  // "unavailable" already produces exactly that — no separate null
  // handling needed at call sites.
  //
  // BATTERY FIX: this used to be a BehaviorSubject fed by a permanent
  // constructor-time .listen() on _castStateEvents (same pattern as
  // _state/_errors/_outputDevices, which is correct for those — they're
  // needed for the whole app session). Cast state is different: the
  // Kotlin side (AurumCastManager.startCastStateDiscovery/
  // stopCastStateDiscovery, wired to this exact EventChannel's
  // onListen/onCancel) only stops its LAN mDNS/SSDP discovery scan once
  // NOTHING is subscribed to this channel. A permanent constructor-level
  // .listen() meant onListen fired once at app launch and onCancel never
  // fired at all — discovery ran for the entire app session regardless
  // of whether any cast-button widget was ever on screen, silently
  // defeating that native-side fix. _lastCastState below keeps the same
  // "always have a snapshot" convenience the old seeded BehaviorSubject
  // gave callers, without keeping a permanent platform-channel
  // subscription alive to produce it.
  CastState _lastCastState = const CastState();

  Stream<NativeEngineState> get stateStream => _state.stream;
  Stream<PlaybackErrorEvent> get errorStream => _errors.stream;
  Stream<AudioOutputDevices?> get outputDevicesStream => _outputDevices.stream;

  /// Live cast availability/connection updates. Deliberately NOT
  /// auto-subscribed at construction — same reasoning as
  /// [castRoutesStream] below: each .listen() (StreamBuilder mounting,
  /// widget disposing) is exactly what starts/stops Kotlin's low-
  /// intensity MediaRouter discovery on the native side (see
  /// AurumCastManager.startCastStateDiscovery/stopCastStateDiscovery).
  /// receiveBroadcastStream() is itself a broadcast stream, so multiple
  /// simultaneous listeners (e.g. CastIconButton + CastingBanner both
  /// mounted at once) share one underlying platform subscription rather
  /// than each opening their own — the platform channel only sees
  /// onListen when the first Dart listener attaches and onCancel when
  /// the last one detaches.
  ///
  /// IMPORTANT: built ONCE and cached (not rebuilt per access) —
  /// CastIconButton/CastingBanner call this from build(), which re-runs
  /// on every PlayerProvider.notifyListeners() (i.e. multiple times a
  /// second during normal playback, via context.watch). If this were a
  /// plain getter constructing a fresh Stream each call, StreamBuilder
  /// would see a new stream identity on every rebuild and tear down +
  /// recreate its subscription every time — thrashing Kotlin's
  /// start/stopCastStateDiscovery in a tight loop instead of the clean
  /// mount/unmount-scoped on/off this was meant to achieve.
  late final Stream<CastState> castStateStream = _castStateEvents
      .receiveBroadcastStream()
      .map(_parseCastState)
      .map((s) {
        _lastCastState = s;
        return s;
      });
  CastState get castState => _lastCastState;
  NativeEngineState get value => _state.value;

  StreamSubscription? _stateSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _outputDevicesSub;

  // Fired when AurumMediaSessionService (lock screen / notification heart)
  // reports a like-toggle tap for the given song ID. PlayerProvider sets
  // this to bridge into FavoritesProvider.toggleFavorite(). Left null-safe
  // (no-op) if nothing has wired it yet, so an early native event can't
  // crash startup.
  void Function(String songId)? onLikeToggleRequested;

  NativeAudioEngine._internal() {
    // Same MethodChannel as the outgoing calls below — Kotlin's
    // AurumEngineChannelHandler uses this channel bidirectionally: Dart
    // calls playQueue/playSong/etc. on it, and it calls back
    // "onLikeToggleRequested" on the same channel for the reverse
    // direction. setMethodCallHandler only affects incoming calls, so it's
    // safe to set alongside the outgoing invokeMethod calls further down.
    _method.setMethodCallHandler(_handleEngineCallback);

    _resolverChannel.setMethodCallHandler(_handleResolverCall);

    // FIX ("song plays fine in background but UI stays stuck/loading
    // forever"): none of these .listen() calls had an onError handler.
    // If a single malformed event ever threw during parsing, that became
    // an uncaught async error and this subscription stopped being driven
    // by fresh events — while ExoPlayer/Media3 kept playing audio
    // completely independently on the native side (that's why the
    // notification/lock-screen player always still showed correct,
    // playing state). PlayerProvider._onEngineState (and therefore
    // _isLoading, the 3s _expectedSongId self-heal, and every other bit
    // of UI state derived from this stream) never got its next tick, so
    // the UI froze permanently. Adding onError logs and drops the bad
    // event instead of killing the listener; the stream keeps delivering
    // subsequent events normally.
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
        resolveTakingLong: m['resolveTakingLong'] as bool? ?? false,
      ));
    }, onError: (Object e, StackTrace st) {
      debugPrint('[NativeAudioEngine] state event error (ignored, stream stays alive): $e');
    });

    _errorSub = _errorEvents.receiveBroadcastStream().listen((raw) {
      final m = Map<String, dynamic>.from(raw as Map);
      _errors.add(PlaybackErrorEvent(
        m['message'] as String? ?? 'Unknown playback error',
        m['silent'] as bool? ?? false,
      ));
    }, onError: (Object e, StackTrace st) {
      debugPrint('[NativeAudioEngine] error-event stream error (ignored): $e');
    });

    _outputDevicesSub =
        _outputDeviceEvents.receiveBroadcastStream().listen((raw) {
      _outputDevices.add(_parseOutputDevices(raw));
    }, onError: (Object e, StackTrace st) {
      debugPrint('[NativeAudioEngine] output-device stream error (ignored): $e');
    });
  }

  /// Live list of nearby Cast devices for the custom picker sheet.
  /// Deliberately NOT auto-subscribed in the constructor like
  /// [castStateStream] — listening to this stream is what starts
  /// Kotlin's active MediaRouter scan (see AurumCastManager.startRouteDiscovery),
  /// and cancelling the subscription stops it, so this should only be
  /// listened to while the picker sheet is actually open (each
  /// .listen() call gets its own underlying platform subscription via
  /// receiveBroadcastStream(), so opening the sheet twice in a row
  /// still behaves correctly).
  Stream<List<CastRoute>> get castRoutesStream =>
      _castRoutesEvents.receiveBroadcastStream().map(_parseCastRoutes);

  List<CastRoute> _parseCastRoutes(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => CastRoute(
              id: m['id'] as String? ?? '',
              name: m['name'] as String? ?? '',
              description: m['description'] as String?,
              selected: m['selected'] as bool? ?? false,
            ))
        .where((r) => r.id.isNotEmpty)
        .toList();
  }

  /// Connects to the given route id from the custom picker sheet —
  /// starts a Cast session the same way tapping a device in Google's
  /// own picker dialog would. Returns false if the route disappeared
  /// between being shown in the list and being tapped (rare, but a
  /// device can go offline mid-pick).
  Future<bool> selectCastRoute(String routeId) async {
    final ok = await _method.invokeMethod('selectCastRoute', {'routeId': routeId});
    return ok as bool? ?? false;
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
          // FIX (permanent hang on cancelled resolve): if a `cancelResolve`
          // arrived for this requestId while the await above was still
          // running, both completion branches above are skipped by their
          // `_inFlight.containsKey(requestId)` guard on purpose (a
          // cancelled request's result should be discarded) — but that
          // guard also meant `completer` was simply never completed at
          // all. `return completer.future` below still hands that
          // never-completing Future straight back to
          // MethodChannel/Kotlin's `invokeMethod` call, which then hangs
          // indefinitely waiting on a response that will never arrive —
          // exactly the kind of permanent stuck-state bug this file
          // otherwise guards against everywhere else (see every timeout/
          // stale-guard fix in player_provider.dart). A genuinely
          // cancelled request must still resolve its Future — with null,
          // same as any other "no stream available" outcome — so the
          // native side's await always gets an answer instead of hanging
          // forever on a fast song-switch/cancel.
          if (!completer.isCompleted) completer.complete(null);
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

  // FIX ("UI stuck showing loading/paused while audio genuinely plays in
  // background"): this is the method PlayerProvider.didChangeAppLifecycleState
  // was already trying to call (as forceStateResync, which never existed —
  // see player_provider.dart doc comment) and the loading watchdog now also
  // reaches for. Kotlin's AurumAudioEngine.refreshState() re-reads
  // ExoPlayer's live playbackState/isPlaying/position directly and re-emits
  // a fresh NativeEngineState — it doesn't touch playback, just forces a
  // state push, so it's safe to call any time a stuck UI needs a nudge.
  Future<void> refreshState() => _method.invokeMethod('refreshState');

  // ── Dart -> Kotlin: transport / queue commands ──
  Future<void> playQueue(List<Song> songs, int startIndex) => _method.invokeMethod(
        'playQueue',
        {'songs': songs.map(_songToArgs).toList(), 'startIndex': startIndex},
      );

  Future<void> playSong(Song song) => _method.invokeMethod('playSong', {'song': _songToArgs(song)});
  Future<void> addToQueue(Song song) => _method.invokeMethod('addToQueue', {'song': _songToArgs(song)});
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

  /// Fades volume smoothly to 0 over [fadeMs] then pauses — used by the
  /// sleep timer so playback winds down instead of cutting out abruptly.
  /// Native side restores volume to full right after pausing, so the next
  /// manual play() isn't silently stuck at 0.
  Future<void> sleepFadeOutAndPause({int fadeMs = 8000}) =>
      _method.invokeMethod('sleepFadeOutAndPause', {'fadeMs': fadeMs});

  // ── Auto Sleep Guard ──────────────────────────────────────────────────
  // Battery feature, fully separate from the Sleep Timer above. See
  // AutoSleepGuard.kt for the native implementation. All state (duration,
  // enabled flag, last-auto-pause record) lives natively in
  // SharedPreferences — these calls are thin passthroughs, not a
  // second/duplicate Dart-side store.

  /// Returns `{enabled: bool, durationHours: int, isSignedIn: bool}`.
  Future<Map<String, dynamic>> autoSleepGuardGetState() async {
    final result = await _method.invokeMapMethod<String, dynamic>('autoSleepGuardGetState');
    return result ?? const {'enabled': true, 'durationHours': 3, 'isSignedIn': false};
  }

  /// [hours] must be 3 or 5 — anything else is clamped to 3 natively.
  Future<void> autoSleepGuardSetDurationHours(int hours) =>
      _method.invokeMethod('autoSleepGuardSetDurationHours', {'hours': hours});

  /// Automatic ([enabled] = true, default) vs fully Off. Off cancels any
  /// pending native alarm/grace-timeout immediately and dismisses an
  /// outstanding "Still there?" prompt — a real shutdown, not a pause.
  /// Switching back to Automatic resumes normal guarding right away.
  Future<void> autoSleepGuardSetEnabled(bool enabled) =>
      _method.invokeMethod('autoSleepGuardSetEnabled', {'enabled': enabled});

  /// Call whenever [SleepTimerService]'s active state changes (start,
  /// cancel, or natural expiry) so the native guard knows to stay
  /// completely out of the way while a Sleep Timer is running.
  Future<void> autoSleepGuardSetSleepTimerActive(bool active) =>
      _method.invokeMethod('autoSleepGuardSetSleepTimerActive', {'active': active});

  /// Call whenever [AuthProvider]'s sign-in state changes — Auto Sleep
  /// Guard is available to every plan, but only once signed in.
  Future<void> autoSleepGuardSetSignedIn(bool signedIn) =>
      _method.invokeMethod('autoSleepGuardSetSignedIn', {'signedIn': signedIn});

  /// Explicit in-app activity ping — call from play/pause/skip/seek
  /// button handlers in the UI. Native-originated activity (notification/
  /// lock-screen controls, screen unlock) is already covered on the
  /// native side and does not need this.
  Future<void> autoSleepGuardRecordActivity() =>
      _method.invokeMethod('autoSleepGuardRecordActivity');

  /// Epoch-millis timestamp of the last auto-pause if it hasn't been
  /// shown to the user yet, else null. Call once on app open/resume to
  /// drive the "Paused after inactivity — Resume?" prompt; call
  /// [autoSleepGuardConsumeLastAutoPause] right after showing it so it
  /// doesn't reappear on the next open.
  Future<int?> autoSleepGuardPeekLastAutoPause() =>
      _method.invokeMethod<int>('autoSleepGuardPeekLastAutoPause');

  Future<void> autoSleepGuardConsumeLastAutoPause() =>
      _method.invokeMethod('autoSleepGuardConsumeLastAutoPause');

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

  /// Snapshot of currently available output devices (speaker, wired
  /// headphones, each connected Bluetooth device, USB audio). Call this
  /// once when opening the picker sheet; after that, [outputDevicesStream]
  /// pushes updates live as devices connect/disconnect.
  Future<AudioOutputDevices> getAudioOutputDevices() async {
    final raw = await _method.invokeMethod('getAudioOutputDevices');
    return _parseOutputDevices(raw) ??
        const AudioOutputDevices(devices: [], supportsExplicitRouting: false);
  }

  /// Requests routing to the given device. Returns false (not an error)
  /// on Android versions below 12 (API 31), which have no explicit
  /// per-device routing API for media playback — the OS routes
  /// automatically to the most recently connected device instead, same
  /// as every other media app on those versions. The UI should treat
  /// `false` there as "not supported on this Android version", not as a
  /// failed tap.
  Future<bool> selectAudioOutputDevice(int deviceId) async {
    final ok = await _method
        .invokeMethod('selectAudioOutputDevice', {'deviceId': deviceId});
    return ok as bool? ?? false;
  }

  /// Pre-API-31 fallback control: force routing to the built-in speaker
  /// (true) or step out of forced-speaker mode and let the OS route to
  /// whatever external device is connected (false). No-op on 31+, where
  /// [selectAudioOutputDevice] should be used instead.
  Future<void> setForceSpeaker(bool force) =>
      _method.invokeMethod('setForceSpeaker', {'force': force});

  /// Current system media (STREAM_MUSIC) volume — the same level the
  /// hardware volume keys control. Isolated from the engine's internal
  /// fade/duck/crossfade volume, which never changes as a result of
  /// reading or writing this.
  Future<MediaVolume> getMediaVolume() async {
    final raw = await _method.invokeMethod('getMediaVolume');
    final m = Map<String, dynamic>.from(raw as Map);
    return MediaVolume(
      level: m['volume'] as int? ?? 0,
      max: m['max'] as int? ?? 1,
    );
  }

  /// Sets system media volume directly (0..max from [getMediaVolume]).
  Future<void> setMediaVolume(int level) =>
      _method.invokeMethod('setMediaVolume', {'volume': level});

  /// Live network throughput estimate in kbps, from ExoPlayer's shared
  /// BandwidthMeter (fed by every streamed-song read). Returns 0 if not
  /// enough data has flowed yet to produce an estimate (e.g. right after
  /// app start, before any song has streamed). Never touches playback —
  /// a pure read of an already-running estimator.
  Future<int> getEstimatedBandwidthKbps() async {
    try {
      final bitsPerSec = await _method.invokeMethod('getEstimatedBandwidth');
      final bits = (bitsPerSec as num?)?.toInt() ?? 0;
      if (bits <= 0) return 0;
      return bits ~/ 1000;
    } catch (_) {
      // Method missing/failed on this platform build — treat as
      // "unknown", never let a Smart Saver probe crash resolve.
      return 0;
    }
  }

  AudioOutputDevices? _parseOutputDevices(dynamic raw) {
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw as Map);
    final rawDevices = (m['devices'] as List? ?? const []);
    return AudioOutputDevices(
      devices: rawDevices.map((d) {
        final dm = Map<String, dynamic>.from(d as Map);
        return AudioOutputDevice(
          id: dm['id'] as int? ?? -1,
          name: dm['name'] as String? ?? 'Audio device',
          kind: AudioOutputDeviceKind.fromNative(dm['kind'] as String?),
          selected: dm['selected'] as bool? ?? false,
        );
      }).toList(),
      supportsExplicitRouting: m['supportsExplicitRouting'] as bool? ?? false,
    );
  }

  /// Supported-device check + current output route, so the UI can show an
  /// accurate note (e.g. "Spatial widening isn't supported on this device
  /// — clarity and bass effects are still active") instead of implying a
  /// full effect on hardware that silently can't do part of the chain.
  /// Returns null if the native side hasn't attached yet (call again after
  /// playback starts).
  /// Snapshot of current cast availability/connection state. Call once
  /// when a cast-aware widget (mini player, full player) mounts; after
  /// that [castStateStream] pushes live updates as devices come/go and
  /// as sessions connect/disconnect — same pairing pattern as
  /// [getAudioOutputDevices] + [outputDevicesStream].
  Future<CastState> getCastState() async {
    final raw = await _method.invokeMethod('getCastState');
    return _parseCastState(raw);
  }

  /// Ends the active cast session. [stopCasting] = true also stops
  /// playback on the receiver ("Stop casting"); false just disconnects
  /// this app's control while leaving the receiver playing
  /// ("Disconnect") — mirrors the two options Spotify's cast sheet
  /// offers.
  Future<void> endCastSession({bool stopCasting = false}) =>
      _method.invokeMethod('endCastSession', {'stopCasting': stopCasting});

  CastState _parseCastState(dynamic raw) {
    if (raw == null) return const CastState();
    final m = Map<String, dynamic>.from(raw as Map);
    return CastState(
      status: CastConnectionStatus.fromNative(m['state'] as String?),
      deviceName: m['deviceName'] as String?,
      supported: m['supported'] as bool? ?? false,
    );
  }

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
    await _outputDevicesSub?.cancel();
    await _state.close();
    await _errors.close();
    await _outputDevices.close();
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

/// Icon/label category for an output device — kept small and stable (see
/// AurumAudioOutputManager.kt's KIND_* constants) so the UI can map each
/// to a fixed icon without needing to know Android's AudioDeviceInfo.TYPE_*
/// constants.
enum AudioOutputDeviceKind {
  speaker,
  wired,
  bluetooth,
  usb,
  unknown;

  static AudioOutputDeviceKind fromNative(String? kind) {
    switch (kind) {
      case 'speaker':
        return AudioOutputDeviceKind.speaker;
      case 'wired':
        return AudioOutputDeviceKind.wired;
      case 'bluetooth':
        return AudioOutputDeviceKind.bluetooth;
      case 'usb':
        return AudioOutputDeviceKind.usb;
      default:
        return AudioOutputDeviceKind.unknown;
    }
  }
}

/// Snapshot of the system media (STREAM_MUSIC) volume — [level] is the
/// current step and [max] is the top of that stream's step range (varies
/// by device/OEM, typically 15 or 25 — never assume a fixed value).
class MediaVolume {
  final int level;
  final int max;

  const MediaVolume({required this.level, required this.max});
}

/// A single selectable audio output (the phone's own speaker, a connected
/// Bluetooth speaker/headphones, wired headphones, USB audio).
class AudioOutputDevice {
  final int id;
  final String name;
  final AudioOutputDeviceKind kind;
  final bool selected;

  const AudioOutputDevice({
    required this.id,
    required this.name,
    required this.kind,
    required this.selected,
  });
}

/// Full picker snapshot: the device list plus whether this Android version
/// supports explicit per-device routing (API 31+) at all. Below that, the
/// picker still shows what's connected but routing is automatic — the UI
/// uses [supportsExplicitRouting] to show that distinction honestly rather
/// than implying a tap always moves audio to that exact device.
class AudioOutputDevices {
  final List<AudioOutputDevice> devices;
  final bool supportsExplicitRouting;

  const AudioOutputDevices({
    required this.devices,
    required this.supportsExplicitRouting,
  });
}

/// Cast connection lifecycle — kept small/stable (see
/// AurumCastManager.State on the Kotlin side) so the cast button icon
/// logic maps each to a fixed visual state without needing Cast SDK
/// constants: [unavailable] hides the button entirely (no Cast devices
/// on this network), [available] shows the outline "cast" icon,
/// [connecting] shows a brief loading/pulse state, [connected] shows the
/// filled icon plus the device name.
enum CastConnectionStatus {
  unavailable,
  available,
  connecting,
  connected;

  static CastConnectionStatus fromNative(String? state) {
    switch (state) {
      case 'AVAILABLE':
        return CastConnectionStatus.available;
      case 'CONNECTING':
        return CastConnectionStatus.connecting;
      case 'CONNECTED':
        return CastConnectionStatus.connected;
      default:
        return CastConnectionStatus.unavailable;
    }
  }
}

/// Cast state snapshot for driving the cast button + "Casting to X" UI.
/// [supported] is false only when the Cast SDK itself couldn't init on
/// this device (broken/missing Google Play Services) — distinct from
/// [status] == unavailable, which just means no Cast devices are
/// currently visible on the network. The UI should hide the cast button
/// entirely when [supported] is false, and show it (dimmed/outline) when
/// [supported] is true but [status] is unavailable — same distinction
/// [AudioOutputDevices.supportsExplicitRouting] makes for the audio
/// output picker.
class CastState {
  final CastConnectionStatus status;
  final String? deviceName;
  final bool supported;

  const CastState({
    this.status = CastConnectionStatus.unavailable,
    this.deviceName,
    this.supported = false,
  });

  bool get isConnected => status == CastConnectionStatus.connected;
  bool get isConnecting => status == CastConnectionStatus.connecting;
}

/// A single Cast device as shown in the custom picker sheet.
class CastRoute {
  final String id;
  final String name;
  final String? description;
  final bool selected;

  const CastRoute({
    required this.id,
    required this.name,
    this.description,
    this.selected = false,
  });
}
