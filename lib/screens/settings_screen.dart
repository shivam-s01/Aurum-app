import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_transitions.dart';
import '../providers/player_provider.dart';
import 'settings_player_screen.dart';
import 'settings_appearance_screen.dart';
import 'settings_storage_screen.dart';
import 'settings_notifications_screen.dart';
import 'settings_about_screen.dart';
import 'settings_privacy_screen.dart';
import 'settings_language_screen.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';

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
                // ── Premium Section removed (all features free) ──
                _SettingsTile(
                  icon: Icons.equalizer_rounded,
                  title: l10n.settingsPlayerAudio,
                  subtitle: l10n.settingsPlayerAudioSubtitle,
                  onTap: () {
                    AurumHaptics.light();
                    // Matches the Liked/Playlist fade + slide-up push
                    // (see aurum_transitions.dart's AurumDepthRoute) —
                    // Settings' whole sub-navigation now shares it.
                    AurumDepthRoute.to(context, SettingsPlayerScreen(audioEngine: engine));
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.palette_rounded,
                  title: l10n.settingsAppearance,
                  subtitle: l10n.settingsAppearanceSubtitle,
                  onTap: () {
                    AurumHaptics.light();
                    AurumDepthRoute.to(context, const SettingsAppearanceScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.language_rounded,
                  title: l10n.settingsLanguage,
                  subtitle: l10n.settingsLanguageSubtitle,
                  onTap: () {
                    AurumHaptics.light();
                    AurumDepthRoute.to(context, const SettingsLanguageScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.storage_rounded,
                  title: l10n.settingsStorage,
                  subtitle: l10n.settingsStorageSubtitle,
                  onTap: () {
                    AurumHaptics.light();
                    AurumDepthRoute.to(context, const SettingsStorageScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.notifications_rounded,
                  title: l10n.settingsNotifications,
                  subtitle: l10n.settingsNotificationsSubtitle,
                  onTap: () {
                    AurumHaptics.light();
                    AurumDepthRoute.to(context, const SettingsNotificationsScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.shield_rounded,
                  title: l10n.settingsPrivacy,
                  subtitle: l10n.settingsPrivacySubtitle,
                  onTap: () {
                    AurumHaptics.light();
                    AurumDepthRoute.to(context, const SettingsPrivacyScreen());
                  },
                ),
                const SizedBox(height: 10),
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  title: l10n.settingsAbout,
                  subtitle: l10n.settingsAboutSubtitle,
                  onTap: () {
                    AurumHaptics.light();
                    AurumDepthRoute.to(context, const SettingsAboutScreen());
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
                  boxShadow: [
                    BoxShadow(
                      color: AurumTheme.gold.withOpacity(0.10),
                      blurRadius: 10,
                      spreadRadius: -2,
                    ),
                  ],
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
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2)),
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
