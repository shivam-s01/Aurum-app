// =============================================================================
// FILE: lib/screens/login_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Spotify-style full-screen login gate.
//   ✅ Animated entrance (fade + slide + gold glow pulse on logo)
//   ✅ "Continue with Google" — the ONLY way in, shown explicitly
//   ✅ Loading state while Supabase/Google round-trip happens
//   ✅ Inline error (no silent fail, no auto-retry)
//   ✅ On success: syncs cloud data, then pops back to caller
// =============================================================================

import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../l10n/generated/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/favorites_provider.dart';
import '../services/sync_service.dart';
import '../utils/aurum_haptics.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  late final Animation<double> _glow;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: const Interval(0, 0.6, curve: Curves.easeOut));
    _slide = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.1, 0.7, curve: Curves.easeOutCubic)));
    _glow = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.3, 1.0, curve: Curves.easeOut)));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _continueWithGoogle() async {
    if (_busy) return;
    AurumHaptics.medium();
    setState(() { _busy = true; _error = null; });

    final auth = context.read<AuthProvider>();
    final ok = await auth.signInWithGoogle();

    if (!mounted) return;

    if (ok) {
      try {
        await SyncService.instance.syncAll(
          playlists: context.read<PlaylistProvider>(),
          followedArtists: context.read<FollowedArtistsProvider>(),
          followedAlbums: context.read<FollowedAlbumsProvider>(),
          favorites: context.read<FavoritesProvider>(),
        );
      } catch (_) {}
      if (!mounted) return;
      AurumHaptics.light();
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _busy = false;
      _error = auth.lastError; // null if user just cancelled the picker
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AurumTheme.darkBg,
      body: Stack(
        children: [
          // Ambient gold glow, top-anchored — premium depth instead of flat black.
          Positioned(
            top: -120, left: -80,
            child: AnimatedBuilder(
              animation: _glow,
              builder: (_, __) => Container(
                width: 360, height: 360,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AurumTheme.gold.withOpacity(0.18 * _glow.value),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: Column(
                        children: [
                          SizedBox(height: constraints.maxHeight * 0.07),
                          FadeTransition(
                    opacity: _fade,
                    child: SlideTransition(
                      position: _slide,
                      child: Column(
                        children: [
                          AnimatedBuilder(
                            animation: _glow,
                            builder: (_, __) => Container(
                              width: 88, height: 88,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                  colors: [AurumTheme.goldLight, AurumTheme.goldDark],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AurumTheme.gold.withOpacity(0.45 * _glow.value),
                                    blurRadius: 28,
                                    spreadRadius: 4,
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.music_note_rounded,
                                  color: Colors.black, size: 42),
                            ),
                          ),
                          const SizedBox(height: 28),
                          Text(
                            'Aurum',
                            style: TextStyle(
                              color: AurumTheme.darkTextPrimary,
                              fontSize: 32,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.loginSyncSubtitle,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AurumTheme.darkTextSecondary,
                              fontSize: 14.5,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 30),
                          const _BenefitsList(),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  FadeTransition(
                    opacity: _fade,
                    child: Column(
                      children: [
                        if (_error != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.red.withOpacity(0.25)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.error_outline_rounded, color: Colors.red.shade300, size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _error!,
                                    style: TextStyle(color: Colors.red.shade300, fontSize: 12.5),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        _GoogleContinueButton(busy: _busy, onTap: _continueWithGoogle),
                        const SizedBox(height: 18),
                        TextButton(
                          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                          child: Text(
                            l10n.loginMaybeLater,
                            style: TextStyle(
                              color: AurumTheme.darkTextMuted,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated, staggered list of sign-in benefits — each row fades + slides
/// in slightly after the previous one for a premium "reveal" feel.
class _BenefitsList extends StatefulWidget {
  const _BenefitsList();
  @override
  State<_BenefitsList> createState() => _BenefitsListState();
}

class _BenefitsListState extends State<_BenefitsList> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static List<(IconData, String)> _items(AppLocalizations l10n) => [
    (Icons.cloud_sync_rounded, l10n.loginBenefitSyncDevices),
    (Icons.history_rounded, l10n.loginBenefitResumeWhereLeft),
    (Icons.lock_outline_rounded, l10n.loginBenefitLibrarySafe),
    (Icons.person_outline_rounded, l10n.loginBenefitPersonalizedProfile),
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500 + 4 * 120),
    )..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = _items(l10n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(items.length, (i) {
        final start = (i * 0.15).clamp(0.0, 0.7);
        final end = (start + 0.5).clamp(0.0, 1.0);
        final anim = CurvedAnimation(
          parent: _ctrl,
          curve: Interval(start, end, curve: Curves.easeOutCubic),
        );
        final (icon, label) = items[i];
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(-0.06, 0), end: Offset.zero).animate(anim),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Container(
                    width: 30, height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AurumTheme.gold.withOpacity(0.12),
                    ),
                    child: Icon(icon, size: 16, color: AurumTheme.goldLight),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: AurumTheme.darkTextPrimary.withOpacity(0.85),
                        fontSize: 13.5,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// "Continue with Google" — white pill, Google "G" mark, busy spinner state.
class _GoogleContinueButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _GoogleContinueButton({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        elevation: 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: busy ? null : onTap,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 22, height: 22,
                    child: Center(child: AurumM3Loader(width: 22, height: 2.5)),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _GoogleMark(size: 20),
                      const SizedBox(width: 12),
                      Text(
                        AppLocalizations.of(context)!.loginContinueWithGoogle,
                        style: TextStyle(
                          color: Colors.black.withOpacity(0.87),
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Minimal 4-color Google "G" mark, hand-painted (no asset dependency).
class _GoogleMark extends StatelessWidget {
  final double size;
  const _GoogleMark({required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GMarkPainter()),
    );
  }
}

/// Faithful redraw of the official Google "G" mark using real path
/// geometry (not approximated arcs), scaled from a 48x48 source grid —
/// this is the standard shape used in Google's own Sign-In buttons.
class _GMarkPainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 48.0;
    canvas.save();
    canvas.scale(scale, scale);

    final paint = Paint()..style = PaintingStyle.fill;

    // Blue: right-side body + crossbar (the piece that makes it a "G").
    paint.color = _blue;
    canvas.drawPath(
      Path()
        ..moveTo(45.12, 24.5)
        ..cubicTo(45.12, 22.98, 44.98, 21.52, 44.72, 20.1)
        ..lineTo(24, 20.1)
        ..lineTo(24, 28.36)
        ..lineTo(35.86, 28.36)
        ..cubicTo(35.34, 31.18, 33.74, 33.56, 31.32, 35.16)
        ..lineTo(31.32, 40.62)
        ..lineTo(38.48, 40.62)
        ..cubicTo(42.66, 36.76, 45.12, 31.16, 45.12, 24.5)
        ..close(),
      paint,
    );

    // Green: bottom curve.
    paint.color = _green;
    canvas.drawPath(
      Path()
        ..moveTo(24, 46)
        ..cubicTo(29.88, 46, 34.82, 44.06, 38.48, 40.62)
        ..lineTo(31.32, 35.16)
        ..cubicTo(29.36, 36.46, 26.86, 37.22, 24, 37.22)
        ..cubicTo(18.32, 37.22, 13.5, 33.36, 11.78, 28.14)
        ..lineTo(4.4, 28.14)
        ..lineTo(4.4, 33.78)
        ..cubicTo(8.04, 41.02, 15.42, 46, 24, 46)
        ..close(),
      paint,
    );

    // Yellow: bottom-left curve.
    paint.color = _yellow;
    canvas.drawPath(
      Path()
        ..moveTo(11.78, 28.14)
        ..cubicTo(11.32, 26.84, 11.06, 25.44, 11.06, 24)
        ..cubicTo(11.06, 22.56, 11.32, 21.16, 11.78, 19.86)
        ..lineTo(11.78, 14.22)
        ..lineTo(4.4, 14.22)
        ..cubicTo(2.86, 17.24, 2, 20.62, 2, 24)
        ..cubicTo(2, 27.38, 2.86, 30.76, 4.4, 33.78)
        ..lineTo(11.78, 28.14)
        ..close(),
      paint,
    );

    // Red: top curve.
    paint.color = _red;
    canvas.drawPath(
      Path()
        ..moveTo(24, 10.78)
        ..cubicTo(27.16, 10.78, 29.98, 11.86, 32.2, 13.98)
        ..lineTo(38.62, 7.56)
        ..cubicTo(34.8, 3.98, 29.88, 2, 24, 2)
        ..cubicTo(15.42, 2, 8.04, 6.98, 4.4, 14.22)
        ..lineTo(11.78, 19.86)
        ..cubicTo(13.5, 14.64, 18.32, 10.78, 24, 10.78)
        ..close(),
      paint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
