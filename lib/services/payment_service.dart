// =============================================================================
// FILE: lib/services/payment_service.dart
// PROJECT: Aurum Music
// DESCRIPTION: Razorpay payment integration for Aurum Plus subscriptions.
//
//   PLANS:
//     Monthly  → ₹1    (100 paise)    [INTRODUCTORY — 1st month only]
//     Yearly   → ₹29   (2900 paise)
//     Lifetime → ₹199  (19900 paise)  [One-time, never expires]
//
//   On successful payment:
//     - Saves `aurum_is_premium_cached` = true to SharedPreferences
//     - Saves `aurum_premium_granted_at` = now (ISO8601)
//     - Saves `aurum_premium_plan` = 'monthly' | 'yearly' | 'lifetime'
//     - Saves `aurum_premium_payment_id` = Razorpay payment id
//     - Lifetime plan: `aurum_premium_expires_at` is NOT set (never expires)
//
//   ⚠️ SECURITY NOTE:
//   The key below is the Razorpay TEST key (safe to ship in test builds).
//   Replace with your own LIVE key id before production release.
//   Razorpay key IDs are public by design (used client-side), but the
//   matching SECRET must NEVER be placed in this file or anywhere in the
//   app — it belongs only on your backend / Razorpay dashboard webhook
//   verification step.
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum AurumPlan { monthly, yearly, lifetime }

extension AurumPlanX on AurumPlan {
  String get id {
    switch (this) {
      case AurumPlan.monthly:  return 'monthly';
      case AurumPlan.yearly:   return 'yearly';
      case AurumPlan.lifetime: return 'lifetime';
    }
  }

  String get label {
    switch (this) {
      case AurumPlan.monthly:  return '1 Month';
      case AurumPlan.yearly:   return '1 Year';
      case AurumPlan.lifetime: return 'Lifetime';
    }
  }

  /// Amount in paise (smallest currency unit) — required by Razorpay.
  int get amountPaise {
    switch (this) {
      case AurumPlan.monthly:  return 100;    // ₹1
      case AurumPlan.yearly:   return 2900;   // ₹29
      case AurumPlan.lifetime: return 19900;  // ₹199
    }
  }

  /// Amount in rupees, for display.
  int get amountRupees {
    switch (this) {
      case AurumPlan.monthly:  return 1;
      case AurumPlan.yearly:   return 29;
      case AurumPlan.lifetime: return 199;
    }
  }

  String get priceLabel => '₹$amountRupees';

  /// Lifetime plan returns null — it never expires.
  Duration? get duration {
    switch (this) {
      case AurumPlan.monthly:  return const Duration(days: 30);
      case AurumPlan.yearly:   return const Duration(days: 365);
      case AurumPlan.lifetime: return null;
    }
  }

  bool get isLifetime => this == AurumPlan.lifetime;
}

class PaymentService {
  PaymentService._internal();
  static final PaymentService instance = PaymentService._internal();

  // ── TEST KEY — replace with your own LIVE key id before release ──────────
  static const String _razorpayKeyId = 'rzp_test_T6mKp7AGRdv2Zd';

  /// Gold theme color used in the Razorpay checkout sheet header.
  static const String goldHex = '#C9A84C';

  static const _kCachedPremium     = 'aurum_is_premium_cached';
  static const _kPremiumGrantedAt  = 'aurum_premium_granted_at';
  static const _kPremiumPlan       = 'aurum_premium_plan';
  static const _kPremiumPaymentId  = 'aurum_premium_payment_id';
  static const _kPremiumExpiresAt  = 'aurum_premium_expires_at';

  Razorpay? _razorpay;

  AurumPlan? _pendingPlan;

  void Function(AurumPlan plan, String paymentId)? onPaymentSuccess;
  void Function(String message)? onPaymentError;
  void Function()? onPaymentCancelled;

  /// Call once (e.g. in initState of PremiumScreen) before opening checkout.
  void init({
    required void Function(AurumPlan plan, String paymentId) onSuccess,
    required void Function(String message) onError,
    void Function()? onCancelled,
  }) {
    onPaymentSuccess = onSuccess;
    onPaymentError = onError;
    onPaymentCancelled = onCancelled;

    _razorpay?.clear();
    _razorpay = Razorpay();
    _razorpay!.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handleSuccess);
    _razorpay!.on(Razorpay.EVENT_PAYMENT_ERROR, _handleError);
    _razorpay!.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
  }

  /// Call from dispose() of the screen that called init().
  void dispose() {
    _razorpay?.clear();
    _razorpay = null;
  }

  /// Opens the Razorpay checkout sheet for the given plan.
  void startPayment(AurumPlan plan, {String? userEmail, String? userName}) {
    _pendingPlan = plan;

    final description = plan.isLifetime
        ? 'Aurum Plus — Lifetime Access'
        : 'Aurum Plus — ${plan.label} Subscription';

    final options = {
      'key': _razorpayKeyId,
      'amount': plan.amountPaise,
      'currency': 'INR',
      'name': 'Aurum Music',
      'description': description,
      'prefill': {
        if (userEmail != null) 'email': userEmail,
        if (userName != null) 'contact': '',
      },
      'theme': {
        'color': '#C9A84C',
      },
      'notes': {
        'plan': plan.id,
        'app': 'aurum_music',
      },
    };

    try {
      _razorpay?.open(options);
    } catch (e) {
      if (kDebugMode) debugPrint('[PaymentService] open() error: $e');
      onPaymentError?.call('Could not open payment sheet. Please try again.');
    }
  }

  void _handleSuccess(PaymentSuccessResponse response) async {
    final plan = _pendingPlan ?? AurumPlan.yearly;
    final paymentId = response.paymentId ?? 'unknown';

    await _grantPremiumLocally(plan, paymentId);

    // Best-effort: mirror grant into Supabase user_metadata so it syncs
    // across devices too. Server-side validation should still happen via
    // a backend webhook in production — this is a client-side convenience
    // cache, not the source of truth for entitlement enforcement.
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await Supabase.instance.client.auth.updateUser(
          UserAttributes(
            data: {
              'is_premium': true,
              'premium_plan': plan.id,
              'premium_payment_id': paymentId,
              'premium_granted_at': DateTime.now().toIso8601String(),
              if (plan.isLifetime) 'premium_lifetime': true,
            },
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[PaymentService] supabase sync error: $e');
      // Non-fatal — local grant already saved.
    }

    onPaymentSuccess?.call(plan, paymentId);
  }

  void _handleError(PaymentFailureResponse response) {
    final message = response.message?.isNotEmpty == true
        ? response.message!
        : 'Payment failed. Please try again.';
    if (kDebugMode) {
      debugPrint(
          '[PaymentService] payment error: code=${response.code} message=$message');
    }
    onPaymentError?.call(message);
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    onPaymentCancelled?.call();
  }

  Future<void> _grantPremiumLocally(AurumPlan plan, String paymentId) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    await prefs.setBool(_kCachedPremium, true);
    await prefs.setString(_kPremiumGrantedAt, now.toIso8601String());
    await prefs.setString(_kPremiumPlan, plan.id);
    await prefs.setString(_kPremiumPaymentId, paymentId);

    // Lifetime plan: don't set expiry — hasValidLocalGrant() handles null
    if (!plan.isLifetime && plan.duration != null) {
      final expiry = now.add(plan.duration!);
      await prefs.setString(_kPremiumExpiresAt, expiry.toIso8601String());
    } else {
      // Remove any old expiry key so lifetime is never treated as expired
      await prefs.remove(_kPremiumExpiresAt);
    }
  }

  /// Reads the locally-cached payment-based premium grant, if any,
  /// and whether it's still within its validity window.
  /// Lifetime grants (no expiry key) always return true.
  static Future<bool> hasValidLocalGrant() async {
    final prefs = await SharedPreferences.getInstance();
    final isCached = prefs.getBool(_kCachedPremium) ?? false;
    if (!isCached) return false;

    final plan = prefs.getString(_kPremiumPlan);
    // Lifetime plan — never expires
    if (plan == 'lifetime') return true;

    final expiresAtStr = prefs.getString(_kPremiumExpiresAt);
    if (expiresAtStr == null) return false;

    final expiresAt = DateTime.tryParse(expiresAtStr);
    if (expiresAt == null) return false;

    return DateTime.now().isBefore(expiresAt);
  }

  static Future<String?> currentPlanId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPremiumPlan);
  }

  static Future<DateTime?> currentExpiry() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_kPremiumExpiresAt);
    if (s == null) return null;
    return DateTime.tryParse(s);
  }

  /// DEV/TEST ONLY — clears the local payment grant (does not refund).
  static Future<void> clearLocalGrant() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCachedPremium);
    await prefs.remove(_kPremiumGrantedAt);
    await prefs.remove(_kPremiumExpiresAt);
    await prefs.remove(_kPremiumPlan);
    await prefs.remove(_kPremiumPaymentId);
  }
}
