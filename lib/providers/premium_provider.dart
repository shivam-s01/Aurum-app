// =============================================================================
// FILE: lib/providers/premium_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Single source of truth for premium status.
//
//   HOW PREMIUM IS DETERMINED (priority order):
//   1. Supabase app_metadata -> 'is_premium' = true
//      (set server-side only: either by an admin directly, or by the
//      Cloudflare Worker's /api/verify-cf-order handler right after
//      Cashfree confirms a payment — see worker/src/index.js,
//      grantPremiumServerSide(). The app itself never writes this field;
//      doing so client-side used to let anyone forge the write and grant
//      themselves premium for free. _refresh() below calls Supabase's
//      getUser() — a real network round-trip, not the locally cached
//      session — specifically so a grant made on ANOTHER device shows up
//      here without the user needing to sign out and back in.)
//   2. Local Cashfree payment grant (SharedPreferences), validated against
//      its expiry window (30 days for monthly, 180 days for sixMonths) AND
//      against which account actually paid (see PaymentService.hasValidLocalGrant)
//   3. Default -> false (free user)
//
//   Google Sign-In is NO LONGER a path to premium. It is used purely for
//   account identity / cloud sync. Premium is granted only via:
//     - Supabase admin flag (is_premium = true in metadata), or
//     - A successful Cashfree payment (validated locally by expiry date)
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

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
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

  // Fires when a Supabase check has been stuck (no internet, or the
  // request is taking unusually long) past _slowNetworkTimeout, so the UI
  // can show a "Please check your internet connection" prompt. Does NOT
  // fire on a normal fast check, and does not fire more than once per
  // _refresh() call.
  void Function()? onSlowNetwork;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  // BUG FIX ("long term stability" — subscription leak): the
  // auth.onAuthStateChange listener below (in init()) used to be a
  // fire-and-forget `.listen(...)` with the returned StreamSubscription
  // never stored anywhere, so dispose() had nothing to cancel it with.
  // In normal operation this provider lives for the app's whole
  // lifetime so the practical impact is small, but it's still a genuine
  // leaked subscription that would double up (and keep doubling up) on
  // every _refresh() call if this provider were ever recreated — stored
  // now so dispose() can clean it up like every other subscription here.
  StreamSubscription<AuthState>? _authSub;
  static const _slowNetworkTimeout = Duration(seconds: 6);

  // -- Init --------------------------------------------------------------
  // Call once from main.dart after AuthService.init().
  // Loads cached value immediately so UI doesn't flash, then re-checks live.

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isPremium = prefs.getBool(_kCachedPremium) ?? false;
    _activePlanId = prefs.getString(_kPremiumPlan);
    notifyListeners();

    // Subscribe to auth changes so premium status auto-refreshes on
    // sign-in/out. Sign-out no longer wipes the local payment grant — see
    // _refresh(), which now re-derives status from the local grant alone
    // whenever there's no signed-in user, instead of forcing it to false.
    // Switching to a *different* signed-in account is still safe: the
    // ownership check inside PaymentService.hasValidLocalGrant() refuses
    // to honour a grant that belongs to another user id.
    _authSub =
        Supabase.instance.client.auth.onAuthStateChange.listen((_) => _refresh());

    // Spotify-style "just works on any device": if the app opened with no
    // signal (or the very first check timed out), re-check the moment
    // connectivity actually comes back, instead of leaving the user on a
    // stale/local-only status until they background/foreground the app.
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        _refresh();
      }
    });

    await _refresh();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  // -- Refresh -------------------------------------------------------------
  // Checks (in priority order): Supabase admin flag -> local Cashfree grant.

  // FIX (premium status could flicker back to stale/wrong value): _refresh()
  // is called from multiple independent triggers — init(), auth state
  // changes, connectivity changes, markPremiumGranted() — any of which can
  // fire in quick succession (e.g. a sign-in event immediately followed by
  // a token-refresh auth event, or connectivity flapping on/off). Each
  // call awaits a real network round-trip (getUser(), up to the 6s
  // timeout) before writing _isPremium/_activePlanId. Without a guard, an
  // OLDER call that happened to be slow (e.g. it hit the timeout and fell
  // back to a stale cached user) could finish AFTER a newer, faster call
  // that already fetched the correct current status — and silently
  // overwrite the correct value with its own stale result. For a paying
  // user this could mean seeing premium features disappear/reappear
  // incorrectly, or the reverse. Bumped on every _refresh() call; a call
  // whose session has been superseded by the time its awaits resolve
  // simply stops applying its result instead of clobbering a newer one.
  int _refreshSession = 0;

  Future<void> _refresh() async {
    final mySession = ++_refreshSession;
    _isChecking = true;
    notifyListeners();

    var sawSlowNetwork = false;
    void reportSlow() {
      if (!sawSlowNetwork) {
        sawSlowNetwork = true;
        onSlowNetwork?.call();
      }
    }

    try {
      // IMPORTANT: Supabase.instance.client.auth.currentUser is whatever
      // was cached in this session's local token — it will NOT reflect a
      // premium grant that another device just synced into user_metadata
      // a moment ago. getUser() makes an actual network call and returns
      // the current server-side record, which is what makes "pay on
      // Phone A, open Phone B, already premium" work without the user
      // having to sign out and back in. Bounded by a timeout so a slow/
      // absent connection degrades to the local grant instead of hanging
      // the UI indefinitely.
      User? user;
      try {
        final resp = await Supabase.instance.client.auth
            .getUser()
            .timeout(_slowNetworkTimeout, onTimeout: () {
          reportSlow();
          throw TimeoutException('getUser timed out');
        });
        user = resp.user;
      } on TimeoutException {
        // Fall back to whatever local session/cache we already have -
        // still lets a genuine local payment grant show as premium below.
        user = Supabase.instance.client.auth.currentUser;
      } catch (_) {
        // No session / network error - fall back the same way.
        user = Supabase.instance.client.auth.currentUser;
      }

      // A newer _refresh() call may have started (and even finished)
      // while the network round-trip above was in flight — if so, this
      // call's result is stale and must not be applied.
      if (mySession != _refreshSession) return;

      bool fromAdmin = false;
      if (user != null) {
        final meta = user.userMetadata ?? {};
        final fromMeta = meta['is_premium'] == true;
        final appMeta = user.appMetadata;
        final fromApp = appMeta['is_premium'] == true;
        fromAdmin = fromMeta || fromApp;
      }

      // Local Cashfree payment grant — validated against its own expiry
      // AND, as of the ownership fix in PaymentService, against who
      // actually paid for it (payment != identity, so this must still be
      // checked even when `user == null`; a guest checkout has no
      // Supabase user at all, and a signed-in paying user who later
      // signs out shouldn't lose premium they already paid for — but a
      // *different* user signing in on the same device must not inherit
      // it either; that check now lives in hasValidLocalGrant() itself).
      //
      // FIX: this used to return early with premium=false the moment
      // `user == null`, before ever calling hasValidLocalGrant() — so any
      // signed-out user with a valid, unexpired local payment grant was
      // wrongly shown as free. Now both sources are always checked and
      // combined, matching the priority order documented above the class.
      final hasValidPayment = await PaymentService.hasValidLocalGrant();
      if (mySession != _refreshSession) return;

      final isPremiumNow = fromAdmin || hasValidPayment;

      String? planId;
      if (hasValidPayment) {
        planId = await PaymentService.currentPlanId();
        if (mySession != _refreshSession) return;
      } else if (fromAdmin) {
        planId = null; // admin-granted, no specific plan
      }
      _activePlanId = planId;

      _setPremium(isPremiumNow);
    } catch (e) {
      if (kDebugMode) debugPrint('[PremiumProvider] _refresh error: $e');
      // Keep cached value on network error - don't downgrade silently
    } finally {
      if (mySession == _refreshSession) {
        _isChecking = false;
        notifyListeners();
      }
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
