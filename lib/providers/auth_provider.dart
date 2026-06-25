// =============================================================================
// FILE: lib/providers/auth_provider.dart
// PROJECT: Aurum Music
// DESCRIPTION: Reactive wrapper around AuthService — exposes sign-in state
//   to the widget tree via Provider. ProfileScreen and any gated UI watch
//   this instead of touching Supabase/Google directly.
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  StreamSubscription<AuthState>? _sub;
  bool _isSigningIn = false;
  String? _lastError;

  bool get isSignedIn => AuthService.instance.isSignedIn;
  bool get isSigningIn => _isSigningIn;
  String? get lastError => _lastError;
  String? get displayName => AuthService.instance.displayName;
  String? get email => AuthService.instance.email;
  String? get avatarUrl => AuthService.instance.avatarUrl;
  String? get userId => AuthService.instance.currentUser?.id;

  void init() {
    _sub = AuthService.instance.authStateChanges.listen((_) {
      notifyListeners();
    });
  }

  Future<bool> signInWithGoogle() async {
    _isSigningIn = true;
    _lastError = null;
    notifyListeners();

    final error = await AuthService.instance.signInWithGoogle();

    _isSigningIn = false;
    if (error != null && error != 'cancelled') {
      _lastError = error;
    }
    notifyListeners();
    return error == null;
  }

  Future<void> signOut() async {
    await AuthService.instance.signOut();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
