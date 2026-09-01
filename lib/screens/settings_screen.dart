import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
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
import '../widgets/aurum_settings_tile.dart' show AurumStaggerItem;

// Settings — Spotify / Apple Music style.
// Rebuilt from scratch. The old version leaned on per-row rainbow icon
// tints, gradient chips, and a shader-masked title — the kind of thing
// that reads as an amateur "cool effects" pass rather than a real
// production settings screen. Neither Spotify nor Apple Music color-code
// their settings icons or decorate their title; they rely on generous
// whitespace, a single restrained icon treatment, and plain typography
// to feel premium. This version does the same: one neutral icon style
// throughout, a plain pinned title, flat grouped rows with hairline
// dividers, no gradients, no glow, no per-item novelty.
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
            pinned: true,
            elevation: 0,
            scrolledUnderElevation: 0,
            backgroundColor: AurumTheme.bgOf(context),
            surfaceTintColor: Colors.transparent,
            automaticallyImplyLeading: false,
            titleSpacing: 20,
            toolbarHeight: 56,
            // Plain, pinned, sentence-weight title — no shader, no gradient,
            // no oversized display font. Pinned to a fixed font (not the
            // user's app-wide font choice) so it stays a consistent brand
            // moment even when the reading font elsewhere is Mono/Serif.
            title: Text(
              l10n.settingsTitle,
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AurumTheme.textPrimaryOf(context),
                letterSpacing: -0.2,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _SectionHeader(l10n.settingsSectionGeneral),
                // Same AurumStaggerItem entrance used by every other
                // Settings screen (Privacy/Storage/Language/Notifications/
                // About/Player) — one group per stagger slot keeps the
                // cascade timing identical across the whole Settings
                // section instead of this screen animating differently.
                AurumStaggerItem(index: 0, child: _SettingsGroup(children: [
                  _SettingsRow(
                    icon: Icons.tune_rounded,
                    title: l10n.settingsAppearance,
                    subtitle: l10n.settingsAppearanceSubtitle,
                    onTap: () {
                      AurumHaptics.light();
                      AurumDepthRoute.to(context, const SettingsAppearanceScreen());
                    },
                  ),
                  _SettingsRow(
                    icon: Icons.language_rounded,
                    title: l10n.settingsLanguage,
                    subtitle: l10n.settingsLanguageSubtitle,
                    onTap: () {
                      AurumHaptics.light();
                      AurumDepthRoute.to(context, const SettingsLanguageScreen());
                    },
                  ),
                  _SettingsRow(
                    icon: Icons.notifications_none_rounded,
                    title: l10n.settingsNotifications,
                    subtitle: l10n.settingsNotificationsSubtitle,
                    onTap: () {
                      AurumHaptics.light();
                      AurumDepthRoute.to(context, const SettingsNotificationsScreen());
                    },
                    isLast: true,
                  ),
                ])),
                const SizedBox(height: 28),
                _SectionHeader(l10n.settingsSectionPlayback),
                AurumStaggerItem(index: 1, child: _SettingsGroup(children: [
                  _SettingsRow(
                    icon: Icons.graphic_eq_rounded,
                    title: l10n.settingsPlayerAudio,
                    subtitle: l10n.settingsPlayerAudioSubtitle,
                    onTap: () {
                      AurumHaptics.light();
                      // Matches the Liked/Playlist fade + slide-up push
                      // (see aurum_transitions.dart's AurumDepthRoute) —
                      // Settings' whole sub-navigation shares it.
                      AurumDepthRoute.to(context, SettingsPlayerScreen(audioEngine: engine));
                    },
                  ),
                  _SettingsRow(
                    icon: Icons.folder_outlined,
                    title: l10n.settingsStorage,
                    subtitle: l10n.settingsStorageSubtitle,
                    onTap: () {
                      AurumHaptics.light();
                      AurumDepthRoute.to(context, const SettingsStorageScreen());
                    },
                    isLast: true,
                  ),
                ])),
                const SizedBox(height: 28),
                _SectionHeader(l10n.settingsSectionSystem),
                AurumStaggerItem(index: 2, child: _SettingsGroup(children: [
                  _SettingsRow(
                    icon: Icons.shield_outlined,
                    title: l10n.settingsPrivacy,
                    subtitle: l10n.settingsPrivacySubtitle,
                    onTap: () {
                      AurumHaptics.light();
                      AurumDepthRoute.to(context, const SettingsPrivacyScreen());
                    },
                  ),
                  _SettingsRow(
                    icon: Icons.info_outline_rounded,
                    title: l10n.settingsAbout,
                    subtitle: l10n.settingsAboutSubtitle,
                    onTap: () {
                      AurumHaptics.light();
                      AurumDepthRoute.to(context, const SettingsAboutScreen());
                    },
                    isLast: true,
                  ),
                ])),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// Small caps section label above each group — quiet, muted, no
// letter-spacing theatrics. Exactly the density Spotify/Apple Music use
// between grouped rows.
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: AurumTheme.textMutedOf(context),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

// One flat card holding a related cluster of rows, hairline dividers
// between them. Single hairline border, no elevated shadow, no heavy
// corner radius — reads as a quiet grouping, not a decorated panel.
class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

// One row: a single neutral icon treatment (muted color, no per-item
// tint, no gradient chip), title + subtitle, chevron. Press feedback is a
// simple, quiet background tint — no scale-pump, no icon-brightening
// theatrics. This restraint is exactly what separates Spotify/Apple
// Music's settings rows from an "effects showcase".
class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isLast;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            splashFactory: NoSplash.splashFactory,
            highlightColor: AurumTheme.textPrimaryOf(context).withValues(alpha: 0.04),
            hoverColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(icon, color: AurumTheme.textMutedOf(context), size: 22),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(
                                color: AurumTheme.textPrimaryOf(context),
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                letterSpacing: -0.1)),
                        const SizedBox(height: 2),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AurumTheme.textMutedOf(context),
                                fontSize: 12.5)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded,
                      color: AurumTheme.textMutedOf(context).withValues(alpha: 0.6), size: 20),
                ],
              ),
            ),
          ),
        ),
        if (!isLast)
          Padding(
            padding: const EdgeInsets.only(left: 54),
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: AurumTheme.dividerOf(context),
            ),
          ),
      ],
    );
  }
}
