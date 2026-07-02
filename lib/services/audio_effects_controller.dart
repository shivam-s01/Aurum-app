// =============================================================================
// FILE: lib/services/audio_effects_controller.dart
// PROJECT: Aurum Music
// VERSION: 1.0.0 — Extracted from audio_handler.dart (2026-07-02)
//
// =============================================================================
// WHY THIS FILE EXISTS
// -----------------------------------------------------------------------
// Bass Boost / Equalizer used to live directly inside AurumAudioHandler.
// A single bad EQ gain value (out of the device's real native range) threw
// `IllegalArgumentException: AudioEffect: bad parameter value`, which left
// the native Android Equalizer effect instance in a corrupted state. Because
// that effect object was wired straight into the SAME AudioPipeline as the
// player, the corruption then broke EVERY subsequent setAudioSource() call
// on that session — regardless of source (local / Saavn / YouTube). One bad
// gain value made the whole app look like it couldn't play anything.
//
// THE FIX: isolate all effects logic — construction, gain application,
// error handling, and health tracking — into this single class, with two
// hard guarantees:
//
//   1. SELF-HEALING: if a native effect ever rejects a value, this class
//      catches it, backs off, and if it happens again, permanently disables
//      ONLY that effect for the rest of the session. It never lets a
//      rejected call propagate up into playback code.
//
//   2. ONE-WAY DEPENDENCY: AurumAudioHandler only ever calls
//      `AudioEffectsController.pipeline` (to construct the player) and
//      `AudioEffectsController.applySettings()` (on settings change). The
//      controller never reaches back into the handler, the queue, or
//      playback state. Effects bugs are now structurally contained to this
//      one file — nothing here can cascade into "songs won't play".
//
// NOTE ON WHY THE PIPELINE ITSELF CAN'T FULLY DETACH FROM AudioPlayer:
// just_audio requires androidAudioEffects to be supplied to AudioPipeline
// at AudioPlayer CONSTRUCTION time — effects can't be attached later. So
// `pipeline` still has to be handed to `AudioPlayer(audioPipeline: ...)`
// once, at startup. Everything else — every gain calculation, every retry,
// every failure mode — lives here, not in audio_handler.dart.
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AudioEffectsController {
  AudioEffectsController()
      : _loudnessEnhancer = AndroidLoudnessEnhancer(),
        _equalizer = AndroidEqualizer() {
    _pipeline = AudioPipeline(
      // DSP chain order: LoudnessEnhancer (overall perceived-loudness
      // boost) runs BEFORE Equalizer (per-band shaping).
      androidAudioEffects: [_loudnessEnhancer, _equalizer],
    );
  }

  final AndroidLoudnessEnhancer _loudnessEnhancer;
  final AndroidEqualizer _equalizer;
  late final AudioPipeline _pipeline;

  /// Hand this to `AudioPlayer(audioPipeline: ...)` exactly once, at
  /// construction. This is the only thing audio_handler.dart needs to know
  /// about at player-creation time.
  AudioPipeline get pipeline => _pipeline;

  // ── Health tracking ────────────────────────────────────────────────────
  // Once an effect has been rejected by the native side more than once,
  // stop trying to touch it for the rest of the app session. Retrying a
  // half-corrupted native effect over and over is what caused repeated
  // playback breaks before — better to just leave it off than risk it.
  bool _loudnessHealthy = true;
  bool _equalizerHealthy = true;

  // Bass Boost strength, in DECIBELS, applied to AndroidLoudnessEnhancer.
  static const double _bassBoostLoudnessGainDb = 10.0;
  static const double _bassBoostLoudnessGainFallbackDb = 6.0;

  // Extra EQ gain (in dB) stacked on the two lowest bands (32Hz sub-bass,
  // 64Hz bass) when Bass Boost is on, so the boost has real low-end weight
  // instead of sounding like the whole track just got louder.
  static const double _bassBoostSubBassExtraDb = 7.0; // 32Hz band
  static const double _bassBoostBassExtraDb = 5.0; // 64Hz band

  /// Reads current settings from SharedPreferences and applies them to the
  /// native effects. Never throws — every failure is caught, logged, and
  /// contained to the specific effect that failed.
  Future<void> applySettings() async {
    final p = await SharedPreferences.getInstance();
    final bassBoost = p.getBool('bass_boost') ?? false;
    final volNorm = p.getBool('volume_normalization') ?? false;

    await _applyLoudnessEnhancer(bassBoost);
    await _applyEqualizer(p, bassBoost: bassBoost, volNorm: volNorm);
  }

  Future<void> _applyLoudnessEnhancer(bool bassBoost) async {
    if (!_loudnessHealthy) return;

    try {
      await _loudnessEnhancer.setEnabled(bassBoost);
      if (!bassBoost) return;

      try {
        await _loudnessEnhancer.setTargetGain(_bassBoostLoudnessGainDb);
      } catch (e) {
        debugPrint(
          '[AudioEffects] LoudnessEnhancer ${_bassBoostLoudnessGainDb}dB rejected ($e) — retrying at ${_bassBoostLoudnessGainFallbackDb}dB',
        );
        try {
          await _loudnessEnhancer.setTargetGain(_bassBoostLoudnessGainFallbackDb);
        } catch (e2) {
          debugPrint(
            '[AudioEffects] LoudnessEnhancer fallback gain also rejected ($e2) — disabling for this session',
          );
          _loudnessHealthy = false;
          try {
            await _loudnessEnhancer.setEnabled(false);
          } catch (_) {
            // If even disabling fails, the effect is unusable — leave
            // _loudnessHealthy false so we never touch it again.
          }
        }
      }
    } catch (e) {
      debugPrint('[AudioEffects] LoudnessEnhancer apply failed: $e — disabling for this session');
      _loudnessHealthy = false;
    }
  }

  Future<void> _applyEqualizer(
    SharedPreferences p, {
    required bool bassBoost,
    required bool volNorm,
  }) async {
    if (!_equalizerHealthy) return;

    try {
      await _equalizer.setEnabled(true);
      final params = await _equalizer.parameters;
      final bands = params.bands;
      final bandCount = bands.length;

      // Volume Normalization only flattens to a neutral 0dB curve when the
      // user hasn't actually set a custom EQ. If they've picked a preset or
      // dragged sliders, their curve is respected.
      final savedBands = List.generate(
        bandCount,
        (i) => p.getDouble('eq_band_$i') ?? 0.0,
      );
      final hasCustomCurve = savedBands.any((g) => g != 0.0);

      int rejectedBands = 0;

      for (int i = 0; i < bandCount; i++) {
        double gain = (volNorm && !hasCustomCurve) ? 0.0 : savedBands[i];

        if (bassBoost) {
          if (i == 0) gain += _bassBoostSubBassExtraDb;
          if (i == 1) gain += _bassBoostBassExtraDb;
        }

        // Clamp to THIS device's actual reported range for this band —
        // never a hardcoded number. A hardcoded clamp is exactly what
        // caused the original "bad parameter value" cascade: the assumed
        // range didn't match what the native effect actually accepted.
        final minDb = bands[i].minDecibels;
        final maxDb = bands[i].maxDecibels;
        gain = gain.clamp(minDb, maxDb);

        try {
          await bands[i].setGain(gain);
        } catch (e) {
          rejectedBands++;
          debugPrint('[AudioEffects] Band $i setGain($gain) rejected ($e) — skipping band');
        }
      }

      // If every single band got rejected, this device's Equalizer effect
      // is fundamentally incompatible — stop trying for the rest of the
      // session rather than repeating the same failure on every track.
      if (bandCount > 0 && rejectedBands == bandCount) {
        debugPrint('[AudioEffects] All EQ bands rejected — disabling Equalizer for this session');
        _equalizerHealthy = false;
        try {
          await _equalizer.setEnabled(false);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[AudioEffects] Equalizer apply failed: $e — disabling for this session');
      _equalizerHealthy = false;
    }
  }

  /// No native teardown is required beyond disposing the AudioPlayer that
  /// owns this pipeline (handled in audio_handler.dart's dispose()) — kept
  /// here as an explicit no-op so the intent is documented at the call site
  /// rather than silently assumed.
  void dispose() {}
}
