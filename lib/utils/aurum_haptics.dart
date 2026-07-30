import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single choke-point for every haptic tap in the app, driven by the
/// Settings → Player → "Haptic Intensity" preference (Off / Light / Strong).
///
/// Flutter's built-in `HapticFeedback.lightImpact()` / `mediumImpact()` /
/// `heavyImpact()` map to fixed OS haptic constants — there's no strength
/// parameter on that API, so "Light" vs "Strong" can't be expressed through
/// it at all. For "Strong", this instead calls into the native
/// `vibrateHaptic` method channel (see MainActivity.kt) which drives the
/// vibrator motor directly at a specific amplitude. For "Light" it uses
/// the plain Flutter API (cheap, no permission dance, good enough for a
/// subtle tap). "Off" skips everything.
///
/// Every existing `HapticFeedback.xxxImpact()` / `.selectionClick()` call
/// in the app is being replaced with the matching `AurumHaptics.xxx()`
/// call — same call sites, same trigger points, just routed through here
/// so the intensity setting actually has something to control.
class AurumHaptics {
  AurumHaptics._();

  static const MethodChannel _channel =
      MethodChannel('com.aurum.music/media_store');

  /// off | light | strong — cached in memory after first load so every
  /// tap doesn't hit SharedPreferences. Defaults to 'light' — the same
  /// feel the app already had everywhere before this setting existed, so
  /// upgrading users see zero behavior change until they open Settings.
  static String _intensity = 'light';
  static bool _loaded = false;

  /// Call once at app startup (see main.dart) so the very first haptic
  /// tap already has the right intensity instead of using the 'light'
  /// default for a frame or two.
  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _intensity = p.getString('haptic_intensity') ?? 'light';
    _loaded = true;
  }

  static Future<void> setIntensity(String value) async {
    _intensity = value;
    _loaded = true;
    final p = await SharedPreferences.getInstance();
    await p.setString('haptic_intensity', value);
  }

  static String get intensity => _intensity;

  static void _fire({
    required VoidCallback lightFallback,
    required int strongAmplitude,
    required int strongDurationMs,
  }) {
    // init() hasn't resolved yet (only possible for the first frame or two
    // right after cold start) — rather than dropping the tap entirely,
    // fall back to the plain Flutter API. This matches _intensity's own
    // default of 'light', so it's the exact same feel the app already had
    // everywhere before this setting existed; the user just doesn't get a
    // silently-missing haptic on the very first tap.
    if (!_loaded) {
      lightFallback();
      return;
    }
    switch (_intensity) {
      case 'off':
        return;
      case 'strong':
        // Fire-and-forget — a haptic tap is never worth awaiting or
        // blocking a gesture callback on, and any failure (e.g. no
        // vibrator hardware) is already handled silently on the native
        // side.
        _channel.invokeMethod('vibrateHaptic', {
          'amplitude': strongAmplitude,
          'durationMs': strongDurationMs,
        }).catchError((_) {});
        return;
      case 'light':
      default:
        lightFallback();
        return;
    }
  }

  /// Replaces HapticFeedback.selectionClick() — toggles, chip taps, tab
  /// switches, scroll-through-item ticks.
  static void selection() => _fire(
        lightFallback: HapticFeedback.selectionClick,
        strongAmplitude: 90,
        strongDurationMs: 8,
      );

  /// Replaces HapticFeedback.lightImpact() — light taps, small
  /// confirmations.
  static void light() => _fire(
        lightFallback: HapticFeedback.lightImpact,
        strongAmplitude: 130,
        strongDurationMs: 10,
      );

  /// Replaces HapticFeedback.mediumImpact() — primary actions (play/pause,
  /// like, start timer, confirm dialogs).
  static void medium() => _fire(
        lightFallback: HapticFeedback.mediumImpact,
        strongAmplitude: 190,
        strongDurationMs: 14,
      );

  /// Replaces HapticFeedback.heavyImpact() — destructive/high-emphasis
  /// actions (delete, long-press context menus).
  static void heavy() => _fire(
        lightFallback: HapticFeedback.heavyImpact,
        strongAmplitude: 255,
        strongDurationMs: 18,
      );

  /// Replaces the rare HapticFeedback.vibrate() call site.
  static void vibrate() => _fire(
        lightFallback: HapticFeedback.vibrate,
        strongAmplitude: 200,
        strongDurationMs: 16,
      );
}
