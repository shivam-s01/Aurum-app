// =============================================================================
// FILE: lib/services/auth_service.dart
// PROJECT: Aurum Music
// DESCRIPTION: Google Sign-In via Supabase Auth (native OAuth flow, no
//   browser redirect). Wraps Supabase client + google_sign_in package.
//   ✅ Sign in with Google (idToken flow — fast, no webview)
//   ✅ Session persistence (Supabase handles this automatically)
//   ✅ Sign out
//   ✅ Auth state stream for reactive UI
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  // ── Supabase project credentials ─────────────────────────────────────────
  // Same project the Railway backend (server.py) already talks to.
  static const String supabaseUrl = 'https://uurejujwjaxzwnjpsrrz.supabase.co';
  static const String supabaseAnonKey = 'sb_publishable_isqVWcsXnxihYSO4rwBqCQ_ieeVE4lw';

  // Web Client ID from Google Cloud Console (the one already in Railway's
  // GOOGLE_CLIENT_ID env var). Required by google_sign_in even on Android,
  // because Supabase verifies the idToken against this server client ID.
  static const String googleWebClientId =
      '770149348902-m0d6id81ojka4tohae7udkj0b9eqqobm.apps.googleusercontent.com';

  late final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: googleWebClientId,
    scopes: ['email', 'profile'],
  );

  SupabaseClient get _client => Supabase.instance.client;

  /// Call once in main() before runApp().
  static Future<void> init() async {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
  }

  // ── State ─────────────────────────────────────────────────────────────────

  User? get currentUser => _client.auth.currentUser;
  bool get isSignedIn => currentUser != null;
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  String? get displayName =>
      currentUser?.userMetadata?['full_name'] ??
      currentUser?.userMetadata?['name'];
  String? get email => currentUser?.email;
  String? get avatarUrl =>
      currentUser?.userMetadata?['avatar_url'] ??
      currentUser?.userMetadata?['picture'];

  // ── Sign in ───────────────────────────────────────────────────────────────

  /// Returns null on success, or an error message on failure.
  Future<String?> signInWithGoogle() async {
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return 'cancelled'; // user backed out

      final googleAuth = await googleUser.authentication;
      final idToken = googleAuth.idToken;
      final accessToken = googleAuth.accessToken;

      if (idToken == null) {
        return 'Google sign-in failed: no ID token returned.';
      }

      await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[AuthService] signIn error: $e');
      // TEMP: surfacing the raw error so we can see the real cause on a
      // release APK (no logcat access from Termux-only workflow).
      // Revert to the generic message once the real issue is found.
      return 'Sign-in failed: $e';
    }
  }

  // ── Sign out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    await _client.auth.signOut();
  }
}
