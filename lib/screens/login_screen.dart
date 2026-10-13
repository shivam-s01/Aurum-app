// =============================================================================
// FILE: lib/screens/login_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Sign-in screen — redesigned.
//   • Soft accent glows (top-left / bottom-right) over the themed background
//   • Big gradient app tile, large "Sign in" title, centered subtitle
//   • Three benefit cards that reveal one after another
//   • Full-width gradient "Continue with Google" pill (dark text — readable on
//     every accent), Google "G" in a white badge, busy loader state
//   • Inline error (no silent fail), friendly "sign-in is optional" footnote
//   • One short entrance animation only (no looping effects) — light on
//     low-end phones, and off entirely when animations are disabled
//   • Fully theme-aware (Light / Dark / AMOLED / dynamic colour)
//   • Behaviour unchanged: on success → sync cloud data → pop(true);
//     back / cancel → pop(false)
// =============================================================================

import '../services/analytics_service.dart';
import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../l10n/generated/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/recently_played_provider.dart';
import '../services/sync_service.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_motion.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/google_logo.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _glow;
  late final Animation<double> _hero;
  late final List<Animation<double>> _cards;
  late final Animation<double> _bottom;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.logScreen('Login');
    _ctrl = AnimationController(
      vsync: this,
      duration: AurumMotion.durationOrZero(const Duration(milliseconds: 1300)),
    );
    Animation<double> seg(double a, double b) => CurvedAnimation(
          parent: _ctrl,
          curve: Interval(a, b, curve: Curves.easeOutCubic),
        );
    _glow = seg(0.0, 0.7);
    _hero = seg(0.05, 0.50);
    _cards = [seg(0.28, 0.64), seg(0.36, 0.72), seg(0.44, 0.80)];
    _bottom = seg(0.58, 1.0);
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
    setState(() {
      _busy = true;
      _error = null;
    });

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
          history: context.read<RecentlyPlayedProvider>(),
        );
      } catch (_) {}
      if (!mounted) return;
      AurumHaptics.light();
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _busy = false;
      _error = auth.lastError; // null if the user just cancelled the picker
    });
  }

  Widget _reveal(Animation<double> a, Widget child, {Offset from = const Offset(0, 0.06)}) {
    return FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween<Offset>(begin: from, end: Offset.zero).animate(a),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accent = AurumTheme.accentOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final benefits = <(IconData, String)>[
      (Icons.cloud_sync_rounded, l10n.loginBenefitSyncDevices),
      (Icons.devices_rounded, l10n.loginBenefitResumeWhereLeft),
      (Icons.shield_rounded, l10n.loginBenefitLibrarySafe),
    ];

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: Stack(
        children: [
          // Ambient glows — fade in once, then stay still.
          Positioned(
            top: -140,
            left: -110,
            child: FadeTransition(
              opacity: _glow,
              child: _Glow(color: accent, size: 420, opacity: isDark ? 0.30 : 0.22),
            ),
          ),
          Positioned(
            bottom: -170,
            right: -140,
            child: FadeTransition(
              opacity: _glow,
              child: _Glow(color: accent, size: 400, opacity: isDark ? 0.14 : 0.10),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // ── Back ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AurumPressable(
                      onTap: _busy ? null : () => Navigator.of(context).pop(false),
                      scaleAmount: 0.9,
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        child: Icon(Icons.arrow_back_rounded,
                            size: 26, color: AurumTheme.textPrimaryOf(context)),
                      ),
                    ),
                  ),
                ),

                // ── Hero + benefits (scrolls on very small screens) ──
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: c.maxHeight),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _reveal(
                              _hero,
                              Column(
                                children: [
                                  _AppTile(accent: accent),
                                  const SizedBox(height: 28),
                                  Text(
                                    l10n.prSignIn,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: AurumTheme.textPrimaryOf(context),
                                      fontSize: 38,
                                      height: 1.05,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    l10n.loginSyncSubtitle,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: AurumTheme.textSecondaryOf(context),
                                      fontSize: 15.5,
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 34),
                            for (var i = 0; i < benefits.length; i++)
                              Padding(
                                padding: EdgeInsets.only(bottom: i == benefits.length - 1 ? 0 : 12),
                                child: _reveal(
                                  _cards[i],
                                  _BenefitCard(icon: benefits[i].$1, label: benefits[i].$2),
                                ),
                              ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // ── Action area ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: _reveal(
                    _bottom,
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_error != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            margin: const EdgeInsets.only(bottom: 14),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.10),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.red.withOpacity(0.28)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.error_outline_rounded,
                                    color: Colors.red.shade300, size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _error!,
                                    style: TextStyle(
                                        color: Colors.red.shade300, fontSize: 12.5, height: 1.3),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        _GoogleContinueButton(busy: _busy, onTap: _continueWithGoogle),
                        const SizedBox(height: 16),
                        Text(
                          l10n.loginOptionalNote,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AurumTheme.textMutedOf(context),
                            fontSize: 12.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                    from: const Offset(0, 0.10),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Soft radial accent glow.
class _Glow extends StatelessWidget {
  final Color color;
  final double size;
  final double opacity;
  const _Glow({required this.color, required this.size, required this.opacity});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color.withOpacity(opacity), Colors.transparent],
          ),
        ),
      ),
    );
  }
}

/// Rounded-square gradient tile with a soft glow — the screen's anchor.
class _AppTile extends StatelessWidget {
  final Color accent;
  const _AppTile({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: AurumTheme.accentGradientOf(context),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.42),
            blurRadius: 36,
            spreadRadius: 1,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Subtle top sheen for depth.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(32),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [Colors.white.withOpacity(0.22), Colors.transparent],
                ),
              ),
            ),
          ),
          const Icon(Icons.cloud_sync_rounded, color: Colors.black87, size: 48),
        ],
      ),
    );
  }
}

class _BenefitCard extends StatelessWidget {
  final IconData icon;
  final String label;
  const _BenefitCard({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              color: accent.withOpacity(0.14),
            ),
            child: Icon(icon, size: 21, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 14.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Continue with Google" — gradient pill, white G badge, busy loader.
class _GoogleContinueButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _GoogleContinueButton({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    return AurumPressable(
      onTap: busy ? null : onTap,
      haptic: false,
      scaleAmount: 0.975,
      child: Container(
        width: double.infinity,
        height: 58,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: AurumTheme.accentGradientOf(context),
          boxShadow: [
            BoxShadow(
              color: accent.withOpacity(0.38),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Center(
          child: busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(child: AurumM3Loader(width: 24, height: 2.5)),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                      child: const GoogleLogo(size: 18),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      AppLocalizations.of(context)!.loginContinueWithGoogle,
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
