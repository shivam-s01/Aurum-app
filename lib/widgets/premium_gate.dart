// =============================================================================
// FILE: lib/widgets/premium_gate.dart
// PROJECT: Aurum Music
// DESCRIPTION: Reusable premium gate — cinematic bottom sheet that gates
//   premium features. Shows Google sign-in first if user is not signed in,
//   then navigates to PremiumScreen for payment.
//
//   USAGE:
//     PremiumGate.show(context, feature: 'Follow Artist');
//     PremiumGate.guard(context, feature: 'Create Playlist',
//       onAllowed: () => _showCreateDialog(context));
// =============================================================================

import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/premium_provider.dart';
import '../providers/auth_provider.dart';
import '../screens/premium_screen.dart';
import '../utils/aurum_transitions.dart';

class PremiumGate {
  static void show(
    BuildContext context, {
    required String feature,
    String? description,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _PremiumGateSheet(
        feature: feature,
        description: description,
      ),
    );
  }

  static void guard(
    BuildContext context, {
    required String feature,
    String? description,
    required VoidCallback onAllowed,
  }) {
    final isPremium = context.read<PremiumProvider>().isPremium;
    if (isPremium) {
      onAllowed();
    } else {
      show(context, feature: feature, description: description);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _PremiumGateSheet extends StatefulWidget {
  final String feature;
  final String? description;

  const _PremiumGateSheet({required this.feature, this.description});

  @override
  State<_PremiumGateSheet> createState() => _PremiumGateSheetState();
}

class _PremiumGateSheetState extends State<_PremiumGateSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _crownFade, _contentFade, _ctaFade;
  late final Animation<Offset> _contentSlide, _ctaSlide;
  bool _isSigningIn = false;

  static const _perks = [
    (Icons.high_quality_rounded,  'HD Audio',          '320kbps quality'),
    (Icons.all_inclusive_rounded, 'Unlimited Skips',   'Skip freely'),
    (Icons.favorite_rounded,      'Like & Save',       'Personal library'),
    (Icons.person_add_rounded,    'Follow Artists',    'Stay updated'),
    (Icons.queue_music_rounded,   'Playlists',         'Organize music'),
    (Icons.sync_rounded,          'Cloud Sync',        'All devices'),
    (Icons.palette_rounded,       'Themes',            'Premium styles'),
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 680),
    );

    _crownFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
    );
    _contentFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.2, 0.7, curve: Curves.easeOut),
    );
    _contentSlide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.2, 0.7, curve: Curves.easeOutCubic),
    ));
    _ctaFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.45, 1.0, curve: Curves.easeOut),
    );
    _ctaSlide = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.45, 1.0, curve: Curves.easeOutCubic),
    ));

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _handleCTA(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final auth = context.read<AuthProvider>();

    if (!auth.isSignedIn) {
      // Not signed in — trigger Google login first
      setState(() => _isSigningIn = true);
      final success = await auth.signInWithGoogle();
      if (!mounted) return;
      setState(() => _isSigningIn = false);

      if (success) {
        // Signed in — now go to premium screen
        Navigator.pop(context);
        AurumPageRoute.to(context, const PremiumScreen());
      }
      // If cancelled/failed, sheet stays open
    } else {
      // Already signed in — go directly to premium screen
      Navigator.pop(context);
      AurumPageRoute.to(context, const PremiumScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSignedIn = context.watch<AuthProvider>().isSignedIn;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E0E12),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(
          color: AurumTheme.gold.withOpacity(0.22),
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Crown + header
          FadeTransition(
            opacity: _crownFade,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
              child: Column(children: [
                // Glowing crown
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AurumTheme.goldGradient,
                    boxShadow: [
                      BoxShadow(
                        color: AurumTheme.gold.withOpacity(0.5),
                        blurRadius: 24,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.workspace_premium_rounded,
                    color: Colors.black,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 16),
                ShaderMask(
                  shaderCallback: (b) => const LinearGradient(
                    colors: [AurumTheme.goldDark, AurumTheme.goldLight],
                  ).createShader(b),
                  child: Text(
                    '${widget.feature} is Plus',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.description ??
                      'Unlock this and every premium feature\nwith Aurum Plus.',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.45),
                    fontSize: 13,
                    height: 1.45,
                  ),
                  textAlign: TextAlign.center,
                ),
              ]),
            ),
          ),

          const SizedBox(height: 20),

          // Perks horizontal scroll
          FadeTransition(
            opacity: _contentFade,
            child: SlideTransition(
              position: _contentSlide,
              child: SizedBox(
                height: 76,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  itemCount: _perks.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (ctx, i) {
                    final perk = _perks[i];
                    return Container(
                      width: 88,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                      decoration: BoxDecoration(
                        color: AurumTheme.gold.withOpacity(0.07),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AurumTheme.gold.withOpacity(0.18),
                          width: 0.7,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(perk.$1, color: AurumTheme.gold, size: 17),
                          const SizedBox(height: 5),
                          Text(
                            perk.$2,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            perk.$3,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.3),
                              fontSize: 8,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          const SizedBox(height: 22),

          // CTA
          FadeTransition(
            opacity: _ctaFade,
            child: SlideTransition(
              position: _ctaSlide,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20, 0, 20,
                  20 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(children: [
                  // Sign-in note if not signed in
                  if (!isSignedIn) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                          width: 0.7,
                        ),
                      ),
                      child: Row(children: [
                        Icon(Icons.info_outline_rounded,
                            color: AurumTheme.gold.withOpacity(0.7), size: 15),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'You\'ll sign in with Google first, then complete your upgrade.',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.45),
                              fontSize: 11.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Primary CTA button
                  SizedBox(
                    width: double.infinity,
                    child: _isSigningIn
                        ? Container(
                            height: 56,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              color: AurumTheme.gold.withOpacity(0.15),
                            ),
                            child: const Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: Center(child: AurumM3Loader(width: 22, height: 2.5)),
                              ),
                            ),
                          )
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: AurumTheme.goldGradient,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: AurumTheme.gold.withOpacity(0.4),
                                  blurRadius: 20,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: () => _handleCTA(context),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isSignedIn
                                        ? Icons.workspace_premium_rounded
                                        : Icons.login_rounded,
                                    color: Colors.black,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    isSignedIn
                                        ? '✦  Get Aurum Plus'
                                        : 'Sign in & Get Plus',
                                    style: const TextStyle(
                                      color: Colors.black,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),

                  const SizedBox(height: 10),

                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Maybe later',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.3),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
