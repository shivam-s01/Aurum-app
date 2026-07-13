import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_transitions.dart';
import '../providers/player_provider.dart';
import '../providers/premium_provider.dart';
import 'premium_screen.dart';
import 'settings_player_screen.dart';
import 'settings_appearance_screen.dart';
import 'settings_storage_screen.dart';
import 'settings_notifications_screen.dart';
import 'settings_about_screen.dart';
import 'settings_privacy_screen.dart';
import 'settings_language_screen.dart';
import '../l10n/generated/app_localizations.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Get the native engine from PlayerProvider so we can pass it to player settings
    final engine = context.read<PlayerProvider>().handler;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
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
                child: Text(
                  l10n.settingsTitle,
                  style: const TextStyle(
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
                  title: l10n.settingsPlayerAudio,
                  subtitle: l10n.settingsPlayerAudioSubtitle,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    AurumPageRoute.to(context, SettingsPlayerScreen(audioEngine: engine));
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.palette_rounded,
                  title: l10n.settingsAppearance,
                  subtitle: l10n.settingsAppearanceSubtitle,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    AurumPageRoute.to(context, const SettingsAppearanceScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.language_rounded,
                  title: l10n.settingsLanguage,
                  subtitle: l10n.settingsLanguageSubtitle,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    AurumPageRoute.to(context, const SettingsLanguageScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.storage_rounded,
                  title: l10n.settingsStorage,
                  subtitle: l10n.settingsStorageSubtitle,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    AurumPageRoute.to(context, const SettingsStorageScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.notifications_rounded,
                  title: l10n.settingsNotifications,
                  subtitle: l10n.settingsNotificationsSubtitle,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    AurumPageRoute.to(context, const SettingsNotificationsScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.shield_rounded,
                  title: l10n.settingsPrivacy,
                  subtitle: l10n.settingsPrivacySubtitle,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    AurumPageRoute.to(context, const SettingsPrivacyScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  title: l10n.settingsAbout,
                  subtitle: l10n.settingsAboutSubtitle,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    AurumPageRoute.to(context, const SettingsAboutScreen());
                  },
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

}

class _SettingsTile extends StatefulWidget {
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
  State<_SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<_SettingsTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pressCtrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
      reverseDuration: const Duration(milliseconds: 160),
      lowerBound: 0.0,
      upperBound: 0.025,
    );
    _scale = Tween<double>(begin: 1.0, end: 0.975).animate(
      CurvedAnimation(parent: _pressCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _pressCtrl.forward(),
      onTapUp: (_) {
        _pressCtrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _pressCtrl.reverse(),
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
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
                child: Icon(widget.icon, color: AurumTheme.gold, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title,
                        style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(widget.subtitle,
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final premiumFeatures = [
      l10n.premiumFeature320kbps,
      l10n.premiumFeatureUnlimitedSkips,
      l10n.premiumFeatureLikeFollow,
      l10n.premiumFeatureCreatePlaylists,
      l10n.premiumFeatureCloudSync,
      l10n.premiumFeatureExclusiveThemes,
    ];
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
              Text(l10n.premiumBrandName,
                  style: TextStyle(
                    color: AurumTheme.gold,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  )),
              Text(l10n.premiumAllFeaturesUnlocked,
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
            child: Text(l10n.premiumActive,
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
                Text(l10n.premiumUpgradeTitle,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    )),
                Text(l10n.premiumUnlockEverything,
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
            children: premiumFeatures.map((f) => Container(
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
                  HapticFeedback.mediumImpact();
                  AurumPageRoute.to(context, const PremiumScreen());
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  l10n.premiumGetButton,
                  style: const TextStyle(
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
