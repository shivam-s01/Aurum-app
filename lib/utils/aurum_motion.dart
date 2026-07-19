import 'package:flutter/animation.dart';
import '../services/audio_prefs.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// AurumMotion — a single, small source of truth for animation timing and
/// easing across the whole app.
///
/// WHY THIS EXISTS:
/// Aurum's animations currently pick a fresh duration ad-hoc at nearly
/// every call site — 40+ distinct values (180ms, 200ms, 220ms, 260ms,
/// 280ms, 300ms, 320ms, 380ms...) chosen independently screen by screen,
/// on top of 9 different easing curves used inconsistently. None of that
/// is "wrong" in isolation, but the eye picks up on the lack of a shared
/// rhythm even when it can't say why — it reads as slightly less
/// polished/premium than an app where everything moves to the same
/// small set of beats.
///
/// This mirrors the fix Material Design 3 (and Echo, which leans on MD3's
/// MotionUtils) uses: instead of hand-picking a duration per animation,
/// every animation picks from a small fixed set of *tiers* based on what
/// kind of motion it is (a tiny state flip vs. a full-screen transition),
/// and every animation uses the same 1-2 easing curves app-wide. The
/// specific numbers below are Aurum's own (chosen to sit close to the
/// existing 180-320ms range already used everywhere, so nothing has to
/// look different — just more consistent), not copied from any specific
/// third-party app's exact values.
///
/// HOW TO USE:
/// This is additive — nothing existing breaks if you don't switch it
/// over. For NEW animations, or when touching an existing one, prefer:
///   duration: AurumMotion.medium1
///   curve: AurumMotion.standard
/// instead of a fresh `Duration(milliseconds: 267)` + a curve picked at
/// random. Migrating old call sites can happen gradually, file by file,
/// with zero risk since the values chosen were picked to be within a few
/// ms of what's already common in the app.
/// ─────────────────────────────────────────────────────────────────────────
class AurumMotion {
  AurumMotion._();

  // ── Duration tiers ───────────────────────────────────────────────────
  // Short: micro-interactions — icon toggles, small state flips, ripples.
  static const short1 = Duration(milliseconds: 100);
  static const short2 = Duration(milliseconds: 150);

  // Medium: the default for most UI motion — dialogs, sheets, tab
  // switches, list item changes. medium1 is the one to reach for first.
  static const medium1 = Duration(milliseconds: 220);
  static const medium2 = Duration(milliseconds: 280);

  // Long: full-screen transitions, hero-style moves, anything covering
  // a large area of the screen at once.
  static const long1 = Duration(milliseconds: 350);
  static const long2 = Duration(milliseconds: 420);

  // Extra-long: rare, deliberate showcase moments (splash, onboarding).
  static const extraLong1 = Duration(milliseconds: 600);

  // ── Easing ───────────────────────────────────────────────────────────
  // Standard: the one curve to use for ~90% of animations — smooth
  // accelerate-then-decelerate, matches Curves.easeOutCubic which is
  // already Aurum's single most-used curve (67 call sites), so adopting
  // this as *the* standard curve costs nothing visually anywhere it's
  // already used and just formalizes what's already the de facto choice.
  static const standard = Curves.easeOutCubic;

  // Standard-reverse: for anything animating back out / closing —
  // mirrors `standard` so open/close feels like one continuous motion
  // rather than two different personalities.
  static const standardReverse = Curves.easeInCubic;

  // Emphasized: reserved for the rare moment something should call
  // attention to itself (a celebratory pop, a first-run reveal). Not a
  // default — using it everywhere would defeat the point.
  static const emphasized = Curves.easeOutBack;

  // ── Respecting the user's "Enable Animations" setting ────────────────
  // Every call site that guards on AudioPrefs.enableAnimationsNotifier
  // today keeps doing so — this doesn't change that behavior, just gives
  // it one shared helper so the check itself is also consistent.
  static bool get enabled => AudioPrefs.enableAnimationsNotifier.value;

  /// Returns [duration] normally, or Duration.zero if animations are
  /// disabled in settings — the same pattern already used ad-hoc in
  /// several places (e.g. AurumPageRoute._animsOn()), centralized here
  /// so new code doesn't have to re-derive it.
  static Duration durationOrZero(Duration duration) =>
      enabled ? duration : Duration.zero;
}
