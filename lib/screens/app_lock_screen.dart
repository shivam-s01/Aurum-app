import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../providers/player_provider.dart';

class AppLockScreen extends StatefulWidget {
  final Widget child;
  const AppLockScreen({super.key, required this.child});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> with WidgetsBindingObserver {
  final _auth = LocalAuthentication();

  bool   _locked          = false;
  bool   _checking        = true;
  bool   _biometric       = false;
  bool   _appLockOn       = false;
  bool   _dontLockPlaying = false; // NEW
  String _savedPin        = '';
  int    _delayMins       = 10;

  DateTime? _backgroundedAt;

  // PIN UI
  String _enteredPin = '';
  String _error      = '';
  bool   _shaking    = false;

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_appLockOn || _savedPin.isEmpty) return;

    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
    }

    if (state == AppLifecycleState.resumed && _backgroundedAt != null) {
      final elapsed = DateTime.now().difference(_backgroundedAt!).inMinutes;
      _backgroundedAt = null;

      if (elapsed < _delayMins) return; // not enough time passed

      // Check if music is playing and user wants to skip lock
      if (_dontLockPlaying) {
        try {
          final player = context.read<PlayerProvider>();
          if (player.isPlaying) return; // music chal rahi hai — lock mat karo
        } catch (_) {}
      }

      setState(() { _locked = true; _enteredPin = ''; _error = ''; });
      if (_biometric) _tryBiometric();
    }
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    final lockOn        = p.getBool('app_lock_enabled')      ?? false;
    final pin           = p.getString('app_lock_pin')        ?? '';
    final bio           = p.getBool('biometric_lock')        ?? false;
    final delay         = p.getInt('lock_delay_mins')        ?? 10;
    final dontLockPlay  = p.getBool('dont_lock_while_playing') ?? false;

    if (!lockOn || pin.isEmpty) {
      setState(() { _locked = false; _checking = false; });
      return;
    }

    setState(() {
      _appLockOn       = lockOn;
      _savedPin        = pin;
      _biometric       = bio;
      _delayMins       = delay;
      _dontLockPlaying = dontLockPlay;
      _locked          = true;
      _checking        = false;
    });

    if (bio) _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final devices  = await _auth.getAvailableBiometrics();
      if (!canCheck || devices.isEmpty) return;

      final ok = await _auth.authenticate(
        localizedReason: 'Use fingerprint to unlock Aurum Music',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (ok && mounted) setState(() => _locked = false);
    } on PlatformException {
      // PIN fallback already showing
    }
  }

  void _onKey(String digit) {
    if (_enteredPin.length >= 4) return;
    setState(() { _enteredPin += digit; _error = ''; });
    if (_enteredPin.length == 4) _checkPin();
  }

  void _onDelete() {
    if (_enteredPin.isEmpty) return;
    setState(() => _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1));
  }

  Future<void> _checkPin() async {
    await Future.delayed(const Duration(milliseconds: 100));
    if (_enteredPin == _savedPin) {
      setState(() => _locked = false);
    } else {
      HapticFeedback.vibrate();
      setState(() { _shaking = true; _error = 'Wrong PIN. Try again.'; _enteredPin = ''; });
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) setState(() => _shaking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: AurumTheme.darkBg,
        body: const Center(child: AurumM3Loader()),
      );
    }
    if (!_locked) return widget.child;

    return _LockUI(
      enteredPin: _enteredPin,
      error: _error,
      shaking: _shaking,
      showBiometric: _biometric,
      onKey: _onKey,
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
    required this.enteredPin, required this.error, required this.shaking,
    required this.showBiometric, required this.onKey,
    required this.onDelete, required this.onBiometric,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.darkBg,
      body: SafeArea(
        child: Column(children: [
          const Spacer(flex: 2),

          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AurumTheme.goldGradient,
              boxShadow: [BoxShadow(color: AurumTheme.gold.withOpacity(0.3), blurRadius: 20, spreadRadius: 2)],
            ),
            child: const Icon(Icons.lock_rounded, color: Colors.black, size: 32),
          ),
          const SizedBox(height: 20),
          const Text('Aurum Music',
              style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('Enter PIN to unlock',
              style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 14)),

          const Spacer(),

          // PIN dots with shake animation
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: shaking ? 1 : 0),
            duration: const Duration(milliseconds: 400),
            builder: (_, v, child) => Transform.translate(
              offset: Offset(
                8 * (v < 0.5 ? v * 2 : (1 - v) * 2) *
                    (v < 0.25 || (v > 0.5 && v < 0.75) ? 1 : -1),
                0,
              ),
              child: child,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (i) {
                final filled = i < enteredPin.length;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  width: filled ? 18 : 14,
                  height: filled ? 18 : 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? AurumTheme.gold : Colors.transparent,
                    border: Border.all(
                      color: filled ? AurumTheme.gold : Colors.white.withOpacity(0.3),
                      width: 2,
                    ),
                    boxShadow: filled
                        ? [BoxShadow(color: AurumTheme.gold.withOpacity(0.4), blurRadius: 8)]
                        : null,
                  ),
                );
              }),
            ),
          ),

          const SizedBox(height: 16),
          AnimatedOpacity(
            opacity: error.isEmpty ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: Text(error, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ),

          const Spacer(),

          // Numpad
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(children: [
              _row(['1', '2', '3']),
              const SizedBox(height: 14),
              _row(['4', '5', '6']),
              const SizedBox(height: 14),
              _row(['7', '8', '9']),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  SizedBox(
                    width: 80, height: 80,
                    child: showBiometric
                        ? _actionKey(icon: Icons.fingerprint_rounded, color: AurumTheme.gold, onTap: onBiometric)
                        : const SizedBox(),
                  ),
                  _numKey('0'),
                  SizedBox(
                    width: 80, height: 80,
                    child: _actionKey(icon: Icons.backspace_outlined, color: Colors.white54, onTap: onDelete),
                  ),
                ],
              ),
            ]),
          ),

          const Spacer(flex: 2),
        ]),
      ),
    );
  }

  Widget _row(List<String> digits) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: digits.map(_numKey).toList(),
  );

  Widget _numKey(String digit) => GestureDetector(
    onTap: () => onKey(digit),
    child: Container(
      width: 80, height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withOpacity(0.07),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Center(
        child: Text(digit,
            style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w300)),
      ),
    ),
  );

  Widget _actionKey({required IconData icon, required Color color, required VoidCallback onTap}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(0.05),
          ),
          child: Icon(icon, color: color, size: 28),
        ),
      );
}
