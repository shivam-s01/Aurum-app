import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';

class AppLockScreen extends StatefulWidget {
  final Widget child;
  const AppLockScreen({super.key, required this.child});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> with WidgetsBindingObserver {
  final _auth = LocalAuthentication();

  bool _locked       = true;
  bool _checking     = true;
  bool _biometric    = false;
  bool _appLockOn    = false;
  String _savedPin   = '';

  // PIN entry state
  String _enteredPin = '';
  String _error      = '';
  bool _shaking      = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-lock when app goes to background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _appLockOn) {
      setState(() { _locked = true; _enteredPin = ''; _error = ''; });
    }
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    final lockOn  = p.getBool('app_lock_enabled') ?? false;
    final pin     = p.getString('app_lock_pin')   ?? '';
    final bio     = p.getBool('biometric_lock')   ?? false;

    if (!lockOn || pin.isEmpty) {
      setState(() { _locked = false; _checking = false; });
      return;
    }

    setState(() {
      _appLockOn  = lockOn;
      _savedPin   = pin;
      _biometric  = bio;
      _checking   = false;
    });

    if (bio) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    try {
      final available = await _auth.canCheckBiometrics;
      if (!available) return;
      final authenticated = await _auth.authenticate(
        localizedReason: 'Unlock Aurum Music',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      if (authenticated && mounted) {
        setState(() => _locked = false);
      }
    } on PlatformException {
      // fallback to PIN
    }
  }

  void _onKeyTap(String digit) {
    if (_enteredPin.length >= 4) return;
    setState(() { _enteredPin += digit; _error = ''; });
    if (_enteredPin.length == 4) _checkPin();
  }

  void _onDelete() {
    if (_enteredPin.isEmpty) return;
    setState(() => _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1));
  }

  Future<void> _checkPin() async {
    await Future.delayed(const Duration(milliseconds: 120));
    if (_enteredPin == _savedPin) {
      setState(() => _locked = false);
    } else {
      setState(() { _shaking = true; _error = 'Wrong PIN'; _enteredPin = ''; });
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) setState(() => _shaking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: AurumTheme.darkBg,
        body: Center(child: CircularProgressIndicator(color: AurumTheme.gold)),
      );
    }
    if (!_locked) return widget.child;
    return _LockUI(
      enteredPin: _enteredPin,
      error: _error,
      shaking: _shaking,
      showBiometric: _biometric,
      onKey: _onKeyTap,
      onDelete: _onDelete,
      onBiometric: _tryBiometric,
    );
  }
}

// =============================================================================
// Lock UI
// =============================================================================
class _LockUI extends StatelessWidget {
  final String enteredPin;
  final String error;
  final bool shaking;
  final bool showBiometric;
  final ValueChanged<String> onKey;
  final VoidCallback onDelete;
  final VoidCallback onBiometric;

  const _LockUI({
    required this.enteredPin,
    required this.error,
    required this.shaking,
    required this.showBiometric,
    required this.onKey,
    required this.onDelete,
    required this.onBiometric,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.darkBg,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),

            // Lock icon + title
            ShaderMask(
              shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
              child: const Icon(Icons.lock_rounded, size: 48, color: Colors.white),
            ),
            const SizedBox(height: 16),
            const Text('Aurum Music',
                style: TextStyle(color: AurumTheme.gold, fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Enter your PIN to continue',
                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 14)),

            const Spacer(),

            // PIN dots
            AnimatedContainer(
              duration: const Duration(milliseconds: 60),
              transform: shaking
                  ? (Matrix4.translationValues(8, 0, 0))
                  : Matrix4.identity(),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (i) {
                  final filled = i < enteredPin.length;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    width: 16, height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? AurumTheme.gold : Colors.transparent,
                      border: Border.all(
                        color: filled ? AurumTheme.gold : Colors.white.withOpacity(0.3),
                        width: 2,
                      ),
                    ),
                  );
                }),
              ),
            ),

            // Error text
            const SizedBox(height: 16),
            AnimatedOpacity(
              opacity: error.isEmpty ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: Text(error,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ),

            const Spacer(),

            // Numpad
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Column(
                children: [
                  _numRow(['1', '2', '3']),
                  const SizedBox(height: 16),
                  _numRow(['4', '5', '6']),
                  const SizedBox(height: 16),
                  _numRow(['7', '8', '9']),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Biometric or empty
                      SizedBox(
                        width: 72, height: 72,
                        child: showBiometric
                            ? GestureDetector(
                                onTap: onBiometric,
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white.withOpacity(0.06),
                                  ),
                                  child: const Icon(Icons.fingerprint_rounded,
                                      color: AurumTheme.gold, size: 30),
                                ),
                              )
                            : const SizedBox(),
                      ),
                      _numKey('0'),
                      // Delete
                      SizedBox(
                        width: 72, height: 72,
                        child: GestureDetector(
                          onTap: onDelete,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withOpacity(0.06),
                            ),
                            child: Icon(Icons.backspace_outlined,
                                color: Colors.white.withOpacity(0.7), size: 22),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }

  Widget _numRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits.map(_numKey).toList(),
    );
  }

  Widget _numKey(String digit) {
    return GestureDetector(
      onTap: () => onKey(digit),
      child: Container(
        width: 72, height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.08),
        ),
        child: Center(
          child: Text(digit,
              style: const TextStyle(
                  color: Colors.white, fontSize: 24, fontWeight: FontWeight.w400)),
        ),
      ),
    );
  }
}
