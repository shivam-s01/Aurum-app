import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/player_provider.dart';
import '../providers/premium_provider.dart';
import 'premium_screen.dart';
import '../services/audio_handler.dart';
import 'settings_player_screen.dart';
import 'settings_appearance_screen.dart';
import 'settings_storage_screen.dart';
import 'settings_notifications_screen.dart';
import 'settings_about_screen.dart';
import 'settings_privacy_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Get the handler from PlayerProvider so we can pass it to player settings
    final handler = context.read<PlayerProvider>().handler;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            floating: true,
            snap: true,
            backgroundColor: AurumTheme.bgOf(context),
            automaticallyImplyLeading: false,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              title: ShaderMask(
                shaderCallback: (b) =>
                    AurumTheme.goldGradient.createShader(b),
                child: const Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // ── Premium Section ──
                _PremiumSettingsTile(),
                const SizedBox(height: 20),
                _SettingsTile(
                  icon: Icons.equalizer_rounded,
                  title: 'Player & Audio',
                  subtitle: 'Playback, EQ, crossfade & behavior',
                  onTap: () => _push(
                      context,
                      SettingsPlayerScreen(audioHandler: handler)),
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.palette_rounded,
                  title: 'Appearance',
                  subtitle: 'Theme, colors, player style & animations',
                  onTap: () =>
                      _push(context, const SettingsAppearanceScreen()),
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.storage_rounded,
                  title: 'Storage',
                  subtitle: 'Downloads, song cache & image cache',
                  onTap: () =>
                      _push(context, const SettingsStorageScreen()),
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.notifications_rounded,
                  title: 'Notifications',
                  subtitle: 'Media notification style & artwork',
                  onTap: () =>
                      _push(context, const SettingsNotificationsScreen()),
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.shield_rounded,
                  title: 'Privacy',
                  subtitle: 'App lock, incognito mode & data',
                  onTap: () =>
                      _push(context, const SettingsPrivacyScreen()),
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  title: 'About',
                  subtitle: 'Version, updates, privacy & developer',
                  onTap: () =>
                      _push(context, const SettingsAboutScreen()),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(PageRouteBuilder(
      pageBuilder: (_, animation, __) => screen,
      transitionsBuilder: (_, animation, __, child) {
        final tween = Tween(
                begin: const Offset(1.0, 0.0), end: Offset.zero)
            .chain(CurveTween(curve: Curves.easeOutCubic));
        return SlideTransition(
            position: animation.drive(tween), child: child);
      },
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 250),
    ));
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AurumTheme.bgCardOf(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AurumTheme.dividerOf(context), width: 0.5),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AurumTheme.gold.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: AurumTheme.gold.withOpacity(0.25), width: 0.5),
                ),
                child: Icon(icon, color: AurumTheme.gold, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            color: AurumTheme.textMutedOf(context),
                            fontSize: 12)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium settings tile — shown at top of Settings screen
// ─────────────────────────────────────────────────────────────────────────────
class _PremiumSettingsTile extends StatelessWidget {
  const _PremiumSettingsTile();

  static const _premiumFeatures = [
    '320kbps streaming',
    'Unlimited skips',
    'Like & follow',
    'Create playlists',
    'Cloud sync',
    'Exclusive themes',
  ];

  @override
  Widget build(BuildContext context) {
    final isPremium = context.watch<PremiumProvider>().isPremium;

    if (isPremium) {
      // ── Active premium — compact gold badge ──────────────────────────────
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              AurumTheme.goldDark.withOpacity(0.22),
              AurumTheme.gold.withOpacity(0.08),
            ],
          ),
          border: Border.all(color: AurumTheme.gold.withOpacity(0.35), width: 0.8),
        ),
        child: Row(children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AurumTheme.goldGradient,
            ),
            child: const Icon(Icons.workspace_premium_rounded,
                color: Colors.black, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Aurum Premium',
                  style: TextStyle(
                    color: AurumTheme.gold,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  )),
              Text('All features unlocked',
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 12,
                  )),
            ],
          )),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: AurumTheme.gold.withOpacity(0.15),
              border: Border.all(color: AurumTheme.gold.withOpacity(0.4)),
            ),
            child: Text('Active',
                style: TextStyle(
                  color: AurumTheme.gold,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                )),
          ),
        ]),
      );
    }

    // ── Free user — upgrade upsell card ─────────────────────────────────────
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AurumTheme.goldDark.withOpacity(0.18),
            AurumTheme.gold.withOpacity(0.06),
          ],
        ),
        border: Border.all(color: AurumTheme.gold.withOpacity(0.28), width: 0.8),
      ),
      child: Column(children: [
        // Header row
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: AurumTheme.goldGradient,
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.35),
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Icon(Icons.workspace_premium_rounded,
                  color: Colors.black, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Upgrade to Premium',
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    )),
                Text('Unlock everything in Aurum',
                    style: TextStyle(
                      color: AurumTheme.textMutedOf(context),
                      fontSize: 12,
                    )),
              ],
            )),
          ]),
        ),

        // Feature pills
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _premiumFeatures.map((f) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AurumTheme.gold.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: AurumTheme.gold.withOpacity(0.25), width: 0.6),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_rounded, color: AurumTheme.gold, size: 11),
                const SizedBox(width: 4),
                Text(f,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    )),
              ]),
            )).toList(),
          ),
        ),

        // CTA button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AurumTheme.goldGradient,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const PremiumScreen(),
                  ));
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  '✦  Get Aurum Premium',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
