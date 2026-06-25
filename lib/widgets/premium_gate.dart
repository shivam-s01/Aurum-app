// =============================================================================
// FILE: lib/widgets/premium_gate.dart
// PROJECT: Aurum Music
// DESCRIPTION: Reusable premium gate — shows a bottom sheet explaining the
//   feature is premium-only, with a "Sign in & Upgrade" CTA.
//
//   USAGE:
//     // Simple one-liner anywhere in the widget tree:
//     PremiumGate.show(context, feature: 'Follow Artist');
//
//     // Or wrap a callback:
//     PremiumGate.guard(
//       context,
//       feature: 'Create Playlist',
//       onAllowed: () => _showCreateDialog(context),
//     );
// =============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/premium_provider.dart';
import '../providers/auth_provider.dart';

class PremiumGate {
  // ── Static helpers ─────────────────────────────────────────────────────────

  /// Shows the gate dialog unconditionally.
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

  /// Runs [onAllowed] if user is premium, otherwise shows the gate.
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
// Internal bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _PremiumGateSheet extends StatelessWidget {
  final String feature;
  final String? description;

  const _PremiumGateSheet({
    required this.feature,
    this.description,
  });

  static const _perks = [
    (Icons.high_quality_rounded,    'High Bitrate Streaming',   '320kbps — best available quality'),
    (Icons.all_inclusive_rounded,   'Unlimited Skips',          'Skip as many as you want'),
    (Icons.favorite_rounded,        'Like & Save Songs',        'Build your personal library'),
    (Icons.person_add_rounded,      'Follow Artists',           'Stay updated with your favorites'),
    (Icons.queue_music_rounded,     'Create Playlists',         'Organize music your way'),
    (Icons.sync_rounded,            'Cloud Sync',               'Access your library anywhere'),
    (Icons.palette_rounded,         'Exclusive Themes',         'More accent colors & player styles'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(
          color: AurumTheme.gold.withOpacity(0.2),
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
              color: AurumTheme.dividerOf(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Column(children: [
              // Gold crown icon
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AurumTheme.goldGradient,
                  boxShadow: [
                    BoxShadow(
                      color: AurumTheme.gold.withOpacity(0.4),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.workspace_premium_rounded,
                  color: Colors.black,
                  size: 30,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '$feature is Premium',
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                description ??
                    'Upgrade to Aurum Premium to unlock this feature and much more.',
                style: TextStyle(
                  color: AurumTheme.textMutedOf(context),
                  fontSize: 13,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ]),
          ),

          const SizedBox(height: 20),

          // Perks list — horizontal scroll, pill style
          SizedBox(
            height: 72,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              itemCount: _perks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
                final perk = _perks[i];
                return Container(
                  width: 110,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AurumTheme.gold.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AurumTheme.gold.withOpacity(0.2),
                      width: 0.7,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(perk.$1, color: AurumTheme.gold, size: 18),
                      const SizedBox(height: 4),
                      Text(
                        perk.$2,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 20),

          // CTA buttons
          Padding(
            padding: EdgeInsets.fromLTRB(
              20, 0, 20,
              20 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(children: [
              // Primary CTA
              SizedBox(
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: AurumTheme.goldGradient,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: AurumTheme.gold.withOpacity(0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _handleUpgrade(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      '✦  Get Aurum Premium',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // Dismiss
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Maybe later',
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 13,
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  void _handleUpgrade(BuildContext context) {
    final auth = context.read<AuthProvider>();
    if (!auth.isSignedIn) {
      // First sign in, then premium is checked from Supabase metadata
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign in first to activate your premium'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      // User is signed in — show info about how to upgrade
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Premium upgrades coming soon — stay tuned!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}
