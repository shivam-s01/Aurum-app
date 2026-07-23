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
//        sending its Supabase access token (not a plain user id) along
//        with the plan. The Worker verifies that token server-side and
//        stamps the real user id into the Cashfree order's order_tags —
//        the client cannot forge which account an order belongs to.
//     2. Worker creates the order with Cashfree and returns a
//        `payment_session_id` (a short-lived, payment-scoped token - NOT
//        the account secret, so it's safe to hand to the client).
//     3. App opens the Cashfree Drop-in Checkout using that session id.
//     4. On completion, app asks the Worker to verify the order status.
//        The Worker checks PAID status directly with Cashfree (source of
//        truth) and, only then, grants premium SERVER-SIDE via Supabase's
//        Admin API using the plan/user stamped in step 1. The app never
//        writes is_premium to Supabase itself — see PremiumProvider for
//        why that matters (a client-writable premium flag can be forged).
// =============================================================================

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfpaymentgateway/cfpaymentgatewayservice.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfsession/cfsession.dart';
import 'package:flutter_cashfree_pg_sdk/api/cfpayment/cfwebcheckoutpayment.dart';
import 'package:flutter_cashfree_pg_sdk/utils/cfenums.dart';
import 'package:flutter_cashfree_pg_sdk/utils/cfexceptions.dart';
import 'package:flutter_cashfree_pg_sdk/api/cferrorresponse/cferrorresponse.dart';

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
  // Which account this local grant belongs to — 'guest' if paid while
  // signed out, otherwise the Supabase user id. Lets hasValidLocalGrant()
  // refuse to hand a paid grant to a *different* signed-in user on a
  // shared/resold device, while still honouring it for the payer
  // (signed out, or signed back into the same account) and for guests
  // (who have no Supabase identity to check against).
  static const _kPremiumOwnerId    = 'aurum_premium_owner_id';
  static const String guestOwnerId = 'guest';

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

      // Sent so the Worker can verify server-side WHO is actually paying
      // (via Supabase's /auth/v1/user) rather than trusting a client-
      // supplied identity. Null for guest checkout — the Worker treats a
      // missing/invalid token as "no verified user", same as before.
      final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;

      final resp = await http.post(
        Uri.parse('$_workerBaseUrl/api/create-cf-order'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'orderId': orderId,
          'orderAmount': plan.amountRupees,
          'planId': plan.id,
          'customerEmail': userEmail ?? 'guest@aurum.app',
          'customerName': userName ?? 'Aurum User',
          'accessToken': accessToken,
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
    } catch (e, st) {
      debugPrint('[PaymentService] startPayment error: $e\n$st');
      onPaymentError?.call('Could not open payment sheet: $e');
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
        // Local grant: instant UI update on this device, and the fallback
        // PremiumProvider._refresh() uses if a later Supabase check is
        // offline/slow.
        //
        // Supabase sync now happens SERVER-SIDE, inside the Worker's own
        // /api/verify-cf-order handler (grantPremiumServerSide) — using
        // order_tags it stamped at order-creation time from a verified
        // access token, and the service-role key it holds. The app used
        // to also call Supabase's updateUser() from here directly, but
        // that let any client forge the same call from their own session
        // and grant themselves premium for free — updateUser() only
        // proves "a logged-in user made this request", not "this user
        // paid". Removing it and trusting only the Worker's server-side
        // write (which only fires when Cashfree itself confirms PAID) is
        // what actually closes that hole.
        await _grantPremiumLocally(plan, orderId);
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
    final rawMessage = errorResponse.getMessage();
    final message = (rawMessage != null && rawMessage.isNotEmpty)
        ? rawMessage
        : 'Payment failed. Please try again.';
    if (kDebugMode) {
      debugPrint('[PaymentService] payment error: $message (order=$orderId)');
    }
    onPaymentError?.call(message);
  }

  Future<void> _grantPremiumLocally(AurumPlan plan, String orderId) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    // Stamp the grant with whoever is signed in at the moment of payment
    // (or 'guest' if no one is). This is what lets a later, *different*
    // signed-in user on the same device be refused this grant.
    final payerId = Supabase.instance.client.auth.currentUser?.id ?? guestOwnerId;

    await prefs.setBool(_kCachedPremium, true);
    await prefs.setString(_kPremiumGrantedAt, now.toIso8601String());
    await prefs.setString(_kPremiumPlan, plan.id);
    await prefs.setString(_kPremiumPaymentId, orderId);
    await prefs.setString(_kPremiumOwnerId, payerId);

    if (!plan.isLifetime && plan.duration != null) {
      final expiry = now.add(plan.duration!);
      await prefs.setString(_kPremiumExpiresAt, expiry.toIso8601String());
    } else {
      await prefs.remove(_kPremiumExpiresAt);
    }
  }

  /// Reads the locally-cached payment-based premium grant, if any, and
  /// whether it's still within its validity window AND belongs to the
  /// currently signed-in account.
  ///
  /// Ownership check: a grant stamped 'guest' (paid while signed out) is
  /// honoured for anyone, since it was never tied to an account in the
  /// first place. A grant stamped with a real user id is only honoured
  /// while that same user is the one signed in (or while signed out
  /// entirely, so the payer doesn't lose access mid-session) — never for
  /// a *different* signed-in user. This stops a paid grant on a
  /// shared/resold device from being silently inherited by whoever signs
  /// in next.
  ///
  /// Grants written before this field existed have no owner id on disk;
  /// they're treated as 'guest' (old behaviour: honoured for whoever's
  /// signed in) rather than invalidated, so no existing paying user loses
  /// premium on the app update that introduces this check.
  ///
  /// Lifetime grants (no expiry key) skip the expiry check but still go
  /// through the ownership check above.
  static Future<bool> hasValidLocalGrant() async {
    final prefs = await SharedPreferences.getInstance();
    final isCached = prefs.getBool(_kCachedPremium) ?? false;
    if (!isCached) return false;

    final ownerId = prefs.getString(_kPremiumOwnerId) ?? guestOwnerId;
    if (ownerId != guestOwnerId) {
      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      if (currentUserId != null && currentUserId != ownerId) {
        // Signed in as someone other than the payer — not their grant.
        return false;
      }
    }

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
