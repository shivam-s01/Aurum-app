// =============================================================================
// FILE: lib/screens/link_tv_screen.dart
// DESCRIPTION: Settings -> Link TV. Approve a TV sign-in: scan the QR shown on
//   the Astra TV (or type its code), confirm, done — no email/password on the
//   TV. The phone hands the TV a fresh Google ID token through the
//   tv_pair_approve() Supabase function; the TV signs in as the same user with
//   its own session.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';

/// Pulls the 8-char pairing code out of a scanned/pasted value: a bare code,
/// astra://tv/CODE or https://astra.mmusic.workers.dev/tv/CODE. Returns null
/// when it doesn't look like a TV code.
String? parseTvCode(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  final i = s.toLowerCase().indexOf('/tv/');
  if (i >= 0) s = s.substring(i + 4);
  s = s.split(RegExp(r'[?#/]')).first;
  s = s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  s = s.replaceAll('O', '0').replaceAll('I', '1').replaceAll('L', '1');
  return RegExp(r'^[0-9A-F]{8}$').hasMatch(s) ? s : null;
}

class LinkTvScreen extends StatefulWidget {
  final String? initialCode;
  const LinkTvScreen({super.key, this.initialCode});

  @override
  State<LinkTvScreen> createState() => _LinkTvScreenState();
}

class _LinkTvScreenState extends State<LinkTvScreen> {
  final TextEditingController _input = TextEditingController();
  MobileScannerController? _scanner;
  // Camera is OFF until the user taps "Scan QR code" — opening this screen
  // must never jump straight into the camera.
  bool _scanning = false;
  String? _pendingCode; // scanned/typed, waiting for the user's Approve tap
  bool _busy = false;
  bool _done = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final c = parseTvCode(widget.initialCode);
    if (c != null) _pendingCode = c;
  }

  void _startScanner() {
    if (_scanning) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _message = null;
      _scanner ??= MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        formats: const [BarcodeFormat.qrCode],
      );
      _scanning = true;
    });
  }

  /// Turns the camera fully off (widget removed first, controller disposed
  /// after the frame so the preview never touches a disposed controller).
  void _stopScanner() {
    final c = _scanner;
    _scanner = null;
    _scanning = false;
    if (c != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    }
  }

  @override
  void dispose() {
    _scanner?.dispose();
    _input.dispose();
    super.dispose();
  }

  String _pretty(String c) => '${c.substring(0, 4)}-${c.substring(4)}';

  void _onDetect(BarcodeCapture capture) {
    if (_pendingCode != null || _busy || _done) return;
    for (final b in capture.barcodes) {
      final code = parseTvCode(b.rawValue);
      if (code != null) {
        // Never auto-approve: the user must see the code and confirm, so a
        // QR shown by someone else can't silently link THEIR TV to this
        // account.
        if (!mounted) return;
        setState(() {
          _stopScanner();
          _pendingCode = code;
          _message = null;
        });
        return;
      }
    }
  }

  void _useTypedCode() {
    final code = parseTvCode(_input.text);
    if (code == null) {
      setState(() => _message = 'That code looks wrong — it has 8 letters/numbers.');
      return;
    }
    setState(() {
      _stopScanner();
      _pendingCode = code;
      _message = null;
    });
  }

  Future<void> _approve() async {
    final code = _pendingCode;
    if (code == null || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final token = await AuthService.instance.freshGoogleIdToken();
      if (!mounted) return;
      if (token == null) {
        setState(() => _message = 'Couldn\'t get your Google sign-in. Try again.');
        return;
      }
      final ok = await Supabase.instance.client
          .rpc('tv_pair_approve', params: {'p_code': code, 'p_id_token': token});
      if (!mounted) return;
      if (ok == true) {
        setState(() => _done = true);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (mounted) Navigator.of(context).maybePop();
      } else {
        setState(() {
          _pendingCode = null;
          _message = 'That code expired or was already used. Check the TV for a new one.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _message = 'Couldn\'t link the TV: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    final err = await AuthService.instance.signInWithGoogle();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err != null && err != 'cancelled') _message = err;
    });
  }

  // Shown instead of a live camera until the user asks for it.
  Widget _buildScanCard(TextTheme text, ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.qr_code_scanner_rounded, size: 52, color: scheme.primary),
          const SizedBox(height: 14),
          Text('Scan the QR code on your TV', style: text.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(
            'The camera only turns on when you tap the button.',
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _startScanner,
            icon: const Icon(Icons.photo_camera_rounded),
            label: const Text('Scan QR code'),
          ),
        ],
      ),
    );
  }

  Widget _buildCamera(TextTheme text, ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 300,
            width: double.infinity,
            child: _scanner == null
                ? const SizedBox.shrink()
                : RepaintBoundary(
                    child: MobileScanner(
                      controller: _scanner,
                      onDetect: _onDetect,
                      errorBuilder: (context, error, child) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'Camera unavailable. Allow camera access, or type the code below.',
                            textAlign: TextAlign.center,
                            style: text.bodyMedium,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => setState(_stopScanner),
          icon: const Icon(Icons.close_rounded),
          label: const Text('Close camera'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final signedIn = AuthService.instance.isSignedIn;

    Widget body;
    if (_done) {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle_rounded, size: 72, color: scheme.primary),
          const SizedBox(height: 16),
          Text('TV connected', style: text.titleLarge),
          const SizedBox(height: 6),
          Text('Your Astra library is now on the TV.', style: text.bodyMedium),
        ]),
      );
    } else if (!signedIn) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Sign in to Astra first', style: text.titleLarge),
            const SizedBox(height: 8),
            Text(
              'The TV gets the same account you use here.',
              textAlign: TextAlign.center,
              style: text.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _signIn,
              child: Text(_busy ? 'Signing in…' : 'Sign in with Google'),
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!, style: TextStyle(color: scheme.error)),
            ],
          ]),
        ),
      );
    } else if (_pendingCode != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.tv_rounded, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text('Link this TV to your account?', style: text.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(
              _pretty(_pendingCode!),
              style: text.headlineMedium?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Only approve if this exact code is on YOUR TV screen right now.',
              textAlign: TextAlign.center,
              style: text.bodyMedium,
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _busy ? null : _approve,
              child: Text(_busy ? 'Linking…' : 'Approve'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _pendingCode = null;
                        _message = null;
                      }),
              child: const Text('Cancel'),
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: TextStyle(color: scheme.error), textAlign: TextAlign.center),
            ],
          ]),
        ),
      );
    } else {
      body = ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'On your TV open Astra → profile icon. Then scan the code shown there, or type it below.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 16),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _scanning ? _buildCamera(text, scheme) : _buildScanCard(text, scheme),
          ),
          const SizedBox(height: 22),
          Text('Or type the code from the TV', style: text.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _input,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _useTypedCode(),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'XXXX-XXXX',
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(onPressed: _useTypedCode, child: const Text('Continue')),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, style: TextStyle(color: scheme.error)),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Link TV')),
      body: SafeArea(child: body),
    );
  }
}
