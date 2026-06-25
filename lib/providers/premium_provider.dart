// =============================================================================
// FILE: lib/providers/premium_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Single source of truth for premium status.
//
//   HOW PREMIUM IS DETERMINED (priority order):
//   1. Supabase user_metadata → 'is_premium' = true  (set server-side)
//   2. SharedPreferences fallback (cached from last successful check)
//   3. Default → false (free user)
//
//   PREMIUM FEATURES GATED:
//   ✅ High bitrate streaming (320kbps)
//   ✅ Unlimited skips (free = 6/hour)
//   ✅ Follow artist
//   ✅ Create playlist
//   ✅ Like/Favorite songs
//   ✅ Cloud sync (sign-in required)
//   ✅ Extra accent colors (beyond default gold)
//   ✅ Now Playing Card style: "Card" and "Immersive"
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PremiumProvider extends ChangeNotifier {
  static const _kCachedPremium      = 'aurum_is_premium_cached';
  static const _kPremiumGrantedAt   = 'aurum_premium_granted_at';
  static const _kPremiumExpiryDays  = 365; // 1 year free offer

  bool _isPremium = false;
  bool _isChecking = false;

  bool get isPremium   => _isPremium;
  bool get isChecking  => _isChecking;

  // ── Init ──────────────────────────────────────────────────────────────────
  // Call once from main.dart after AuthService.init().
  // Loads cached value immediately so UI doesn't flash, then re-checks live.

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isPremium = prefs.getBool(_kCachedPremium) ?? false;
    notifyListeners();

    // Subscribe to auth changes so premium status auto-refreshes on sign-in
    Supabase.instance.client.auth.onAuthStateChange.listen((_) => _refresh());

    await _refresh();
  }

  // ── Refresh ───────────────────────────────────────────────────────────────
  // Reads is_premium from Supabase user_metadata and caches locally.

  Future<void> _refresh() async {
    _isChecking = true;
    notifyListeners();

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        _setPremium(false);
        return;
      }

      // Server flags take priority
      final meta     = user.userMetadata ?? {};
      final fromMeta = meta['is_premium'] == true;
      final appMeta  = user.appMetadata ?? {};
      final fromApp  = appMeta['is_premium'] == true;

      // Limited 1-year free offer: any Google-signed-in user gets premium,
      // but only for 365 days from the date they first signed in.
      final isGoogleUser = user.appMetadata['provider'] == 'google' ||
          (user.identities ?? []).any((id) => id.provider == 'google');

      bool offerActive = false;
      if (isGoogleUser) {
        final prefs = await SharedPreferences.getInstance();
        // Record grant date on first sign-in
        if (!prefs.containsKey(_kPremiumGrantedAt)) {
          await prefs.setString(
              _kPremiumGrantedAt, DateTime.now().toIso8601String());
        }
        final grantedAtStr = prefs.getString(_kPremiumGrantedAt);
        if (grantedAtStr != null) {
          final grantedAt = DateTime.tryParse(grantedAtStr);
          if (grantedAt != null) {
            final expiry = grantedAt.add(
                const Duration(days: _kPremiumExpiryDays));
            offerActive = DateTime.now().isBefore(expiry);
          }
        }
      }

      _setPremium(fromMeta || fromApp || offerActive);
    } catch (e) {
      if (kDebugMode) debugPrint('[PremiumProvider] _refresh error: $e');
      // Keep cached value on network error — don't downgrade silently
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

  /// Call after sign-in to force a fresh check
  Future<void> refresh() => _refresh();

  /// DEV ONLY — toggle premium locally for testing UI.
  /// Remove before production release.
  void devToggle() {
    assert(() {
      _setPremium(!_isPremium);
      return true;
    }());
  }
}
