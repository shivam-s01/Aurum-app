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
import '../services/native_engine_bridge.dart';

class AuthProvider extends ChangeNotifier {
  StreamSubscription<AuthState>? _sub;
  bool _isSigningIn = false;
  String? _lastError;

  // Cheap wrapper around the shared static MethodChannel in
  // NativeAudioEngine — not a second engine instance, just this
  // provider's own handle for pushing sign-in state to Auto Sleep Guard.
  final NativeAudioEngine _engineBridge = NativeAudioEngine();

  bool get isSignedIn => AuthService.instance.isSignedIn;
  bool get isSigningIn => _isSigningIn;
  String? get lastError => _lastError;
  String? get displayName => AuthService.instance.displayName;
  String? get email => AuthService.instance.email;
  String? get avatarUrl => AuthService.instance.avatarUrl;
  String? get userId => AuthService.instance.currentUser?.id;

  void init() {
    // Push the initial state immediately — the auth stream only fires on
    // subsequent changes, so without this a cold start where the user is
    // already signed in (restored session) would leave Auto Sleep Guard
    // thinking nobody's signed in until the next auth event happens to
    // fire, which might be never in that session.
    _engineBridge.autoSleepGuardSetSignedIn(isSignedIn);
    _sub = AuthService.instance.authStateChanges.listen((_) {
      _engineBridge.autoSleepGuardSetSignedIn(isSignedIn);
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
    _engineBridge.autoSleepGuardSetSignedIn(isSignedIn);
    notifyListeners();
    return error == null;
  }

  Future<void> signOut() async {
    await AuthService.instance.signOut();
    _engineBridge.autoSleepGuardSetSignedIn(false);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
