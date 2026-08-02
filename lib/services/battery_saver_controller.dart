import 'dart:async';
import 'package:flutter/services.dart';
import 'audio_prefs.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// BatterySaverController — subscribes to the native battery-percentage
/// stream (AurumBatteryChannelHandler.kt) and drives
/// [AudioPrefs.batteryLevelNotifier] / [AudioPrefs.batterySaverActiveNotifier]
/// live, for as long as the app process is alive.
///
/// This is the ONLY writer of batterySaverActiveNotifier — every UI/motion
/// consumer (AurumMotion.enabled, AudioPrefs.effectivePlayerBgStyle, the
/// Settings tile subtitle) only ever reads it. Keeping a single owner
/// avoids any two places racing to decide activation state.
///
/// Deliberately a single app-lifetime singleton (start() once from
/// main.dart, after AudioPrefs.load()) rather than something screens
/// start/stop — Battery Saver Mode has to keep working even while the
/// Settings screen itself isn't open, exactly like Auto Sleep Guard's
/// native alarm keeps running regardless of what's on screen.
/// ─────────────────────────────────────────────────────────────────────────
class BatterySaverController {
  BatterySaverController._();
  static final BatterySaverController instance = BatterySaverController._();

  static const EventChannel _channel = EventChannel('com.aurum.music/battery');

  StreamSubscription<dynamic>? _sub;
  bool _started = false;

  /// Begin listening. Safe to call multiple times — subsequent calls are
  /// no-ops. Never throws: a battery-saver feature failing to initialize
  /// must never be able to affect app startup or playback.
  void start() {
    if (_started) return;
    _started = true;
    AudioPrefs.registerBatterySaverReevaluateHook(reevaluateNow);
    try {
      _sub = _channel.receiveBroadcastStream().listen(
        _onBatteryLevel,
        onError: (_) {
          // Stream errors (e.g. receiver registration failing on some
          // OEM skin) should never crash anything — just leave the
          // last-known state as-is. Worst case, Battery Saver Mode
          // simply never activates on that device, which is a silent
          // no-op, not a visible failure.
        },
        cancelOnError: false,
      );
    } catch (_) {
      // EventChannel construction/listen failing entirely (very old
      // platform build, etc.) — same reasoning as above, fail silent.
    }
  }

  void _onBatteryLevel(dynamic level) {
    if (level is! int) return;
    AudioPrefs.batteryLevelNotifier.value = level;

    final shouldBeActive = AudioPrefs.batterySaverEnabledNotifier.value &&
        level <= AudioPrefs.batterySaverThresholdNotifier.value;

    if (AudioPrefs.batterySaverActiveNotifier.value != shouldBeActive) {
      AudioPrefs.batterySaverActiveNotifier.value = shouldBeActive;
    }
  }

  /// Re-evaluate activation against the current battery level without
  /// waiting for the next native broadcast — call this right after the
  /// user changes the enabled toggle or the threshold in Settings, so a
  /// user raising the threshold above the current level (or disabling
  /// the feature) sees the effect immediately rather than on the next
  /// battery tick (which can be several minutes away, since Android only
  /// broadcasts ACTION_BATTERY_CHANGED on percentage-point changes or
  /// charge-state changes).
  void reevaluateNow() {
    final level = AudioPrefs.batteryLevelNotifier.value;
    if (level == null) return;
    _onBatteryLevel(level);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _started = false;
  }
}
