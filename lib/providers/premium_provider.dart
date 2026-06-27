// =============================================================================
// FILE: lib/providers/premium_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Single source of truth for premium status.
//
//   HOW PREMIUM IS DETERMINED (priority order):
//   1. Supabase user_metadata / app_metadata -> 'is_premium' = true
//      (set server-side by an admin, OR mirrored client-side right after
//      a successful Razorpay payment - see PaymentService._handleSuccess)
//   2. Local Razorpay payment grant (SharedPreferences), validated against
//      its expiry window (30 days for monthly, 365 days for yearly)
//   3. Default -> false (free user)
//
//   Google Sign-In is NO LONGER a path to premium. It is used purely for
//   account identity / cloud sync. Premium is granted only via:
//     - Supabase admin flag (is_premium = true in metadata), or
//     - A successful Razorpay payment (validated locally by expiry date)
//
//   PREMIUM FEATURES GATED:
//   [x] High bitrate streaming (320kbps)
//   [x] Unlimited skips (free = 6/hour)
//   [x] Follow artist
//   [x] Create playlist
//   [x] Like/Favorite songs
//   [x] Cloud sync (sign-in required)
//   [x] Extra accent colors (beyond default gold)
//   [x] Now Playing Card style: "Card" and "Immersive"
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/payment_service.dart';

class PremiumProvider extends ChangeNotifier {
  static const _kCachedPremium = 'aurum_is_premium_cached';
  static const _kPremiumPlan = 'aurum_premium_plan';

  bool _isPremium = false;
  bool _isChecking = false;
  String? _activePlanId; // 'monthly' | 'yearly' | null (admin-granted)

  bool get isPremium => _isPremium;
  bool get isChecking => _isChecking;
  String? get activePlanId => _activePlanId;

  // -- Init --------------------------------------------------------------
  // Call once from main.dart after AuthService.init().
  // Loads cached value immediately so UI doesn't flash, then re-checks live.

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isPremium = prefs.getBool(_kCachedPremium) ?? false;
    _activePlanId = prefs.getString(_kPremiumPlan);
    notifyListeners();

    // Subscribe to auth changes so premium status auto-refreshes on sign-in/out
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.signedOut) {
        _clearLocalGrant();
      } else {
        _refresh();
      }
    });

    await _refresh();
  }

  // Clears local Razorpay grant + cached premium on sign-out.
  Future<void> _clearLocalGrant() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCachedPremium);
    await prefs.remove(_kPremiumPlan);
    // Also clear PaymentService keys
    await prefs.remove('aurum_premium_granted_at');
    await prefs.remove('aurum_premium_payment_id');
    await prefs.remove('aurum_premium_expires_at');
    _isPremium = false;
    _activePlanId = null;
    notifyListeners();
  }

  // -- Refresh -------------------------------------------------------------
  // Checks (in priority order): Supabase admin flag -> local Razorpay grant.

  Future<void> _refresh() async {
    _isChecking = true;
    notifyListeners();

    try {
      bool fromAdmin = false;

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        // No signed-in user — revoke all premium immediately
        _setPremium(false);
        _activePlanId = null;
        _isChecking = false;
        notifyListeners();
        return;
      }
      final meta = user.userMetadata ?? {};
      final fromMeta = meta['is_premium'] == true;
      final appMeta = user.appMetadata;
      final fromApp = appMeta['is_premium'] == true;
      fromAdmin = fromMeta || fromApp;

      // Local Razorpay payment grant - validated against its own expiry,
      // independent of sign-in state (works even if the user isn't signed
      // in with Google, since payment != identity).
      final hasValidPayment = await PaymentService.hasValidLocalGrant();

      final isPremiumNow = fromAdmin || hasValidPayment;

      String? planId;
      if (hasValidPayment) {
        planId = await PaymentService.currentPlanId();
      } else if (fromAdmin) {
        planId = null; // admin-granted, no specific plan
      }
      _activePlanId = planId;

      _setPremium(isPremiumNow);
    } catch (e) {
      if (kDebugMode) debugPrint('[PremiumProvider] _refresh error: $e');
      // Keep cached value on network error - don't downgrade silently
    } finally {
      _isChecking = false;
      notifyListeners();
    }
  }

  void _setPremium(bool value) async {
    _isPremium = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCachedPremium, value);
    notifyListeners();
  }

  /// Call after sign-in, or right after a successful Razorpay payment,
  /// to force a fresh entitlement check.
  Future<void> refresh() => _refresh();

  /// Call immediately after PaymentService reports success, so the UI
  /// reflects premium status without waiting for a full async refresh.
  void markPremiumGranted(String planId) {
    _isPremium = true;
    _activePlanId = planId;
    notifyListeners();
    // Persist + reconcile with server in the background.
    _refresh();
  }

  /// DEV ONLY - toggle premium locally for testing UI.
  /// Remove before production release.
  void devToggle() {
    assert(() {
      _setPremium(!_isPremium);
      return true;
    }());
  }
}
