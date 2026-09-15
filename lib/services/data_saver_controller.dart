import 'dart:async';
import 'audio_prefs.dart';
import 'native_engine_bridge.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// DataSaverController — pushes [AudioPrefs.dataSaverActiveNotifier] down to
/// the native pre-buffer resolver (AurumAudioEngine.setDataSaverActive)
/// whenever it changes, for as long as the app process is alive.
///
/// EXTREME DATA SAVER ("ekdam extreme sb kuch control mai le le, data kam se
/// kam use ho, bs play aur thumbnail mein problem na aaye" — 2026-09-15):
/// before this controller existed, AudioPrefs.dataSaver only ever fed
/// Dart-side URL/bitrate construction (qualityOrder(), the artwork-size
/// helpers in api_service.dart, AurumArtwork.upgradeForFullPlayer). The
/// single biggest real data cost in the app — ExoPlayer's own ahead-of-need
/// audio buffering for upcoming queue songs, driven natively by
/// AurumAudioEngine.resolveQueueInBackground() — never knew Data Saver was
/// on at all. This controller is the missing link: same "single owner,
/// every consumer only reads" shape as BatterySaverController, just for the
/// Data Saver signal instead of the battery signal, and with no live
/// sensor stream to subscribe to (Data Saver is a direct user toggle /
/// streamQuality pick, not something that changes on its own the way
/// battery percentage does — AudioPrefs._recomputeDataSaverActive already
/// recomputes dataSaverActiveNotifier synchronously the moment either
/// signal changes, so this controller only needs to listen and forward).
///
/// Deliberately a single app-lifetime singleton (start() once from
/// main.dart, after AudioPrefs.load()), same lifecycle reasoning as
/// BatterySaverController — Data Saver has to keep narrowing native's
/// pre-buffer window for the whole session, not just while a particular
/// screen is open.
/// ─────────────────────────────────────────────────────────────────────────
class DataSaverController {
  DataSaverController._();
  static final DataSaverController instance = DataSaverController._();

  bool _started = false;

  /// Begin listening. Safe to call multiple times — subsequent calls are
  /// no-ops. Never throws: this feature failing to initialize must never
  /// be able to affect app startup or playback.
  void start() {
    if (_started) return;
    _started = true;
    AudioPrefs.dataSaverActiveNotifier.addListener(_pushToNative);
    // Push the current value immediately too, in case native's default
    // (false) doesn't match a persisted-on state restored by
    // AudioPrefs.load() earlier in startup (see
    // AudioPrefs._recomputeDataSaverActive, called at the end of load()).
    _pushToNative();
  }

  void _pushToNative() {
    // Fire-and-forget, matching BatterySaverController's philosophy: a
    // failure here (channel not ready yet during very early startup, odd
    // platform build) must never crash or block anything — worst case
    // native just keeps its last-known/default paced-resolve delay until
    // the next successful push.
    unawaited(
      NativeAudioEngine()
          .setDataSaverActive(AudioPrefs.dataSaverActiveNotifier.value)
          .catchError((_) {}),
    );
  }

  void dispose() {
    _started = false;
    AudioPrefs.dataSaverActiveNotifier.removeListener(_pushToNative);
  }
}
