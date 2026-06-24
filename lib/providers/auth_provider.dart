// =============================================================================
// FILE: lib/providers/auth_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Google Sign-In provider — wraps google_sign_in package.
//   ✅ Sign in / sign out
//   ✅ Persists signed-in state across restarts (google_sign_in handles it)
//   ✅ Exposes user photo, name, email
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthProvider extends ChangeNotifier {
  static final _gsi = GoogleSignIn(scopes: ['email', 'profile']);

  GoogleSignInAccount? _user;

  GoogleSignInAccount? get user     => _user;
  bool get isSignedIn               => _user != null;
  String get displayName            => _user?.displayName ?? 'Guest';
  String? get email                 => _user?.email;
  String? get photoUrl              => _user?.photoUrl;

  AuthProvider() {
    _gsi.onCurrentUserChanged.listen((account) {
      _user = account;
      notifyListeners();
    });
    _tryRestoreSession();
  }

  Future<void> _tryRestoreSession() async {
    try {
      _user = await _gsi.signInSilently();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> signIn() async {
    try {
      _user = await _gsi.signIn();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> signOut() async {
    await _gsi.signOut();
    _user = null;
    notifyListeners();
  }
}
