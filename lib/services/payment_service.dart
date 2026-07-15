// =============================================================================
// FILE: lib/services/payment_service.dart
// PROJECT: Aurum Music
// DESCRIPTION: Cashfree payment integration for Aurum Plus subscriptions.
//
//   PLANS:
//     Monthly   -> Rs.19   (1900 paise)
//     6 Months  -> Rs.149  (14900 paise)
//     Lifetime  -> Rs.249  (24900 paise)  [One-time, never expires]
//
//   On successful payment:
//     - Saves `aurum_is_premium_cached` = true to SharedPreferences
//     - Saves `aurum_premium_granted_at` = now (ISO8601)
//     - Saves `aurum_premium_plan` = 'monthly' | 'sixMonths' | 'lifetime'
//     - Saves `aurum_premium_payment_id` = Cashfree order id
//     - Lifetime plan: `aurum_premium_expires_at` is NOT set (never expires)
//
//   HOW IT WORKS (important - secret key is NEVER in this file or the app):
//     1. App calls the Cloudflare Worker's /api/create-cf-order endpoint,
//        which holds the Cashfree secret key server-side only.
//     2. Worker creates the order with Cashfree and returns a
//        `payment_session_id` (a short-lived, payment-scoped token - NOT
//        the account secret, so it's safe to hand to the client).
//     3. App opens the Cashfree Drop-in Checkout using that session id.
//     4. On completion, app asks the Worker to verify the order status
//        server-side (source of truth) before granting premium locally.
// =============================================================================

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cashfree_pg_sdk/api/cfpaymentgateway_service.dart';
import 'package:cashfree_pg_sdk/api/cfsession.dart';
import 'package:cashfree_pg_sdk/api/cfwebcheckoutpayment.dart';
import 'package:cashfree_pg_sdk/utils/cfenums.dart';
import 'package:cashfree_pg_sdk/utils/cfexceptions.dart';

enum AurumPlan { monthly, sixMonths, lifetime }

extension AurumPlanX on AurumPlan {
  String get id {
    switch (this) {
      case AurumPlan.monthly:   return 'monthly';
      case AurumPlan.sixMonths: return 'sixMonths';
      case AurumPlan.lifetime:  return 'lifetime';
    }
  }

  String get label {
    switch (this) {
      case AurumPlan.monthly:   return '1 Month';
      case AurumPlan.sixMonths: return '6 Months';
      case AurumPlan.lifetime:  return 'Lifetime';
    }
  }

  /// Amount in rupees (Cashfree order API takes a decimal rupee amount,
  /// unlike Razorpay which wanted paise).
  int get amountRupees {
    switch (this) {
      case AurumPlan.monthly:   return 19;
      case AurumPlan.sixMonths: return 149;
      case AurumPlan.lifetime:  return 249;
    }
  }

  String get priceLabel => '\u20b9$amountRupees';

  /// Lifetime plan returns null - it never expires.
  Duration? get duration {
    switch (this) {
      case AurumPlan.monthly:   return const Duration(days: 30);
      case AurumPlan.sixMonths: return const Duration(days: 180);
      case AurumPlan.lifetime:  return null;
    }
  }

  bool get isLifetime => this == AurumPlan.lifetime;
}

class PaymentService {
  PaymentService._internal();
  static final PaymentService instance = PaymentService._internal();

  // Your Cloudflare Worker base URL - same worker used for YT/Saavn resolution.
  // Update this if your worker is deployed at a different URL.
  static const String _workerBaseUrl = 'https://aurum-worker.shivamsharma962122.workers.dev';

  static const String goldHex = '#C9A84C';

  static const _kCachedPremium     = 'aurum_is_premium_cached';
  static const _kPremiumGrantedAt  = 'aurum_premium_granted_at';
  static const _kPremiumPlan       = 'aurum_premium_plan';
  static const _kPremiumPaymentId  = 'aurum_premium_payment_id';
  static const _kPremiumExpiresAt  = 'aurum_premium_expires_at';

  final CFPaymentGatewayService _cfPaymentGatewayService = CFPaymentGatewayService();

  AurumPlan? _pendingPlan;
  String? _pendingOrderId;

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

    _cfPaymentGatewayService.setCallback(_handleVerify, _handleError);
  }

  /// Call from dispose() of the screen that called init(). Cashfree's SDK
  /// doesn't need an explicit teardown call like Razorpay's clear() did.
  void dispose() {}

  /// Creates an order via the Worker (server-side, holds the secret key),
  /// then opens Cashfree's Drop-in web checkout with the returned session id.
  Future<void> startPayment(AurumPlan plan, {String? userEmail, String? userName}) async {
    _pendingPlan = plan;

    try {
      final orderId = 'aurum_${plan.id}_${DateTime.now().millisecondsSinceEpoch}';
      _pendingOrderId = orderId;

      final resp = await http.post(
        Uri.parse('$_workerBaseUrl/api/create-cf-order'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'orderId': orderId,
          'orderAmount': plan.amountRupees,
          'planId': plan.id,
          'customerEmail': userEmail ?? 'guest@aurum.app',
          'customerName': userName ?? 'Aurum User',
        }),
      );

      if (resp.statusCode != 200) {
        onPaymentError?.call('Could not start payment. Please try again.');
        return;
      }

      final data = jsonDecode(resp.body);
      final sessionId = data['payment_session_id'] as String?;
      if (sessionId == null) {
        onPaymentError?.call('Could not start payment. Please try again.');
        return;
      }

      final session = CFSessionBuilder()
          .setEnvironment(CFEnvironment.PRODUCTION)
          .setOrderId(orderId)
          .setPaymentSessionId(sessionId)
          .build();

      final cfWebCheckout = CFWebCheckoutPaymentBuilder()
          .setSession(session)
          .build();

      _cfPaymentGatewayService.doPayment(cfWebCheckout);
    } catch (e) {
      if (kDebugMode) debugPrint('[PaymentService] startPayment error: $e');
      onPaymentError?.call('Could not open payment sheet. Please try again.');
    }
  }

  /// Called by the Cashfree SDK when checkout finishes (success OR failure
  /// both land here - Cashfree doesn't distinguish like Razorpay did).
  /// We verify the real status server-side via the Worker before granting
  /// anything, since client-side "it closed" is not proof of payment.
  void _handleVerify(String orderId) async {
    final plan = _pendingPlan;
    if (plan == null) return;

    try {
      final resp = await http.get(
        Uri.parse('$_workerBaseUrl/api/verify-cf-order?orderId=$orderId'),
      );
      if (resp.statusCode != 200) {
        onPaymentError?.call('Could not verify payment. Please contact support if you were charged.');
        return;
      }
      final data = jsonDecode(resp.body);
      final status = data['order_status'] as String?;

      if (status == 'PAID') {
        await _grantPremiumLocally(plan, orderId);
        await _syncToSupabase(plan, orderId);
        onPaymentSuccess?.call(plan, orderId);
      } else if (status == 'ACTIVE') {
        // Payment still pending/in-progress on Cashfree's side.
        onPaymentError?.call('Payment not completed. Please try again.');
      } else {
        onPaymentCancelled?.call();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[PaymentService] verify error: $e');
      onPaymentError?.call('Could not verify payment. Please contact support if you were charged.');
    }
  }

  void _handleError(CFErrorResponse errorResponse, String orderId) {
    final message = errorResponse.getMessage().isNotEmpty
        ? errorResponse.getMessage()
        : 'Payment failed. Please try again.';
    if (kDebugMode) {
      debugPrint('[PaymentService] payment error: $message (order=$orderId)');
    }
    onPaymentError?.call(message);
  }

  Future<void> _syncToSupabase(AurumPlan plan, String orderId) async {
    // Best-effort: mirror grant into Supabase user_metadata so it syncs
    // across devices too. Server-side validation still happens via the
    // Worker's verify-cf-order call above - this is a convenience cache,
    // not the source of truth for entitlement enforcement.
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await Supabase.instance.client.auth.updateUser(
          UserAttributes(
            data: {
              'is_premium': true,
              'premium_plan': plan.id,
              'premium_payment_id': orderId,
              'premium_granted_at': DateTime.now().toIso8601String(),
              if (plan.isLifetime) 'premium_lifetime': true,
            },
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[PaymentService] supabase sync error: $e');
      // Non-fatal - local grant already saved.
    }
  }

  Future<void> _grantPremiumLocally(AurumPlan plan, String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    await prefs.setBool(_kCachedPremium, true);
    await prefs.setString(_kPremiumGrantedAt, now.toIso8601String());
    await prefs.setString(_kPremiumPlan, plan.id);
    await prefs.setString(_kPremiumPaymentId, orderId);

    if (!plan.isLifetime && plan.duration != null) {
      final expiry = now.add(plan.duration!);
      await prefs.setString(_kPremiumExpiresAt, expiry.toIso8601String());
    } else {
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
}
