import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_transitions.dart';
import '../providers/player_provider.dart';
import '../providers/auth_provider.dart';
import 'settings_player_screen.dart';
import 'settings_appearance_screen.dart';
import 'settings_storage_screen.dart';
import 'settings_privacy_screen.dart';
import 'settings_about_screen.dart';
import 'settings_language_screen.dart';
import 'settings_region_screen.dart';
import 'profile_screen.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_settings_tile.dart' show AurumStaggerItem;

// Settings — Spotify-classic pass.
//
// The rule this file follows throughout: exactly ONE accent color on the
// entire screen, and it lives in exactly one place — the avatar. Every
// icon container, every card border, every chevron, every section is the
// same neutral grey. No per-section color-coding, no accent borders, no
// tinted card fills — that's the "chapri" rainbow-icons trap this was
// rewritten out of. Spotify's own settings page is almost entirely
// grayscale text and icons on a flat background; the identity/brand color
// shows up once, on the profile photo, and nowhere else. This file mirrors
// that discipline exactly.
//
// Structure carried over from the original pass and still correct: a
// large title that collapses to a small pinned one on scroll (never a
// flat static bar), an account row at the top as the identity anchor, and
// three grouped card sections below it (General / Playback / System).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final engine = context.read<PlayerProvider>().handler;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // Large-title-that-collapses, matching Apple Music/Spotify:
          // big and bold while at rest, shrinks to a small pinned label
          // once content scrolls under it — never a flat static bar.
          //
          // Built as a bare SliverPersistentHeader instead of
          // SliverAppBar+FlexibleSpaceBar deliberately: FlexibleSpaceBar
          // applies its OWN implicit title scale/fade/position animation
          // on top of whatever the title widget already does, so a
          // manually font-size-interpolated Text inside it double-
          // animates — the title visibly shrinks twice at slightly
          // different rates, reading as a stutter/jump rather than one
          // clean collapse. A raw SliverPersistentHeader has no built-in
          // title behavior to fight with, so the single manual
          // interpolation below is the *only* thing moving the title —
          // one continuous, glitch-free collapse.
          SliverPersistentHeader(
            pinned: true,
            delegate: _CollapsingTitleDelegate(
              title: l10n.settingsTitle,
              topPadding: MediaQuery.of(context).padding.top,
              backgroundColor: AurumTheme.bgOf(context),
              textColor: AurumTheme.textPrimaryOf(context),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Account anchor — the identity moment every top-tier
                // settings screen opens with. Tapping it goes to the same
                // ProfileScreen the rest of the app uses.
                AurumStaggerItem(index: 0, child: _AccountCard()),
                const SizedBox(height: 32),

                _SectionHeader(l10n.settingsSectionGeneral),
                AurumStaggerItem(index: 1, child: _SettingsGroup(
                  children: [
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
                      icon: Icons.public_rounded,
                      title: 'Region & Music Preferences',
                      subtitle: 'Country, genres, and followed artists',
                      onTap: () {
                        AurumHaptics.light();
                        AurumDepthRoute.to(context, const SettingsRegionScreen());
                      },
                      isLast: true,
                    ),
                  ],
                )),
                const SizedBox(height: 28),

                _SectionHeader(l10n.settingsSectionPlayback),
                AurumStaggerItem(index: 2, child: _SettingsGroup(
                  children: [
                    _SettingsRow(
                      icon: Icons.graphic_eq_rounded,
                      title: l10n.settingsPlayerAudio,
                      subtitle: l10n.settingsPlayerAudioSubtitle,
                      onTap: () {
                        AurumHaptics.light();
                        AurumDepthRoute.to(context, SettingsPlayerScreen(audioEngine: engine));
                      },
                    ),
                    _SettingsRow(
                      icon: Icons.folder_rounded,
                      title: l10n.settingsStorage,
                      subtitle: l10n.settingsStorageSubtitle,
                      onTap: () {
                        AurumHaptics.light();
                        AurumDepthRoute.to(context, const SettingsStorageScreen());
                      },
                      isLast: true,
                    ),
                  ],
                )),
                const SizedBox(height: 28),

                _SectionHeader(l10n.settingsSectionSystem),
                AurumStaggerItem(index: 3, child: _SettingsGroup(
                  children: [
                    _SettingsRow(
                      icon: Icons.shield_rounded,
                      title: l10n.settingsPrivacy,
                      subtitle: l10n.settingsPrivacySubtitle,
                      onTap: () {
                        AurumHaptics.light();
                        AurumDepthRoute.to(context, const SettingsPrivacyScreen());
                      },
                    ),
                    _SettingsRow(
                      icon: Icons.info_rounded,
                      title: l10n.settingsAbout,
                      subtitle: l10n.settingsAboutSubtitle,
                      onTap: () {
                        AurumHaptics.light();
                        AurumDepthRoute.to(context, const SettingsAboutScreen());
                      },
                      isLast: true,
                    ),
                  ],
                )),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Collapsing title header. One manual interpolation drives font size,
// bottom padding, and background — no FlexibleSpaceBar underneath to
// double-animate against. minExtent/maxExtent match the small/large
// title heights standard on both Apple Music and Spotify's own settings
// bars (56 collapsed, 96 expanded, before the safe-area inset).
// ─────────────────────────────────────────────────────────────────────────
class _CollapsingTitleDelegate extends SliverPersistentHeaderDelegate {
  final String title;
  final double topPadding;
  final Color backgroundColor;
  final Color textColor;

  static const double _collapsedH = 56;
  static const double _expandedH = 96;

  _CollapsingTitleDelegate({
    required this.title,
    required this.topPadding,
    required this.backgroundColor,
    required this.textColor,
  });

  @override
  double get minExtent => _collapsedH + topPadding;

  @override
  double get maxExtent => _expandedH + topPadding;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = maxExtent - minExtent;
    // t = 1 fully expanded (large title), t = 0 fully collapsed (small
    // pinned title) — the single value every animated property below
    // derives from, so nothing can drift out of sync with anything else.
    final t = range == 0 ? 0.0 : (1 - (shrinkOffset / range)).clamp(0.0, 1.0);
    final fontSize = 20 + (12 * t); // 20 -> 32
    final bottomPadding = 14 + (2 * (1 - t));

    return Container(
      color: backgroundColor,
      alignment: Alignment.bottomLeft,
      padding: EdgeInsets.only(
        top: topPadding,
        left: 20,
        right: 20,
        bottom: bottomPadding,
      ),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.inter(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          color: textColor,
          letterSpacing: -0.6,
          height: 1.0,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _CollapsingTitleDelegate oldDelegate) {
    return oldDelegate.title != title ||
        oldDelegate.topPadding != topPadding ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.textColor != textColor;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Account anchor row. Spotify opens Settings with avatar + name + "View
// profile"; Apple Music/iOS opens with the signed-in Apple ID summary at
// the very top. This is that same identity moment, built from the same
// AuthProvider/ProfileScreen the rest of the app already uses — no new
// data source, just surfaced here first. Kept flat and neutral like every
// other card on the page — the accent color lives on the avatar alone,
// not on the border, the subtitle, or the chevron.
// ─────────────────────────────────────────────────────────────────────────
class _AccountCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final signedIn = auth.isSignedIn;
    final name = auth.displayName ?? 'Guest';
    final email = auth.email;
    final avatarUrl = auth.avatarUrl;

    return AurumPressable(
      onTap: () {
        AurumHaptics.light();
        AurumDepthRoute.to(context, const ProfileScreen());
      },
      scaleAmount: 0.98,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
        ),
        child: Row(
          children: [
            _Avatar(url: avatarUrl, name: name, signedIn: signedIn),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    signedIn ? (email ?? 'View profile') : 'Tap to sign in',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textMutedOf(context),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: AurumTheme.textMutedOf(context).withValues(alpha: 0.7), size: 20),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final String name;
  final bool signedIn;
  const _Avatar({required this.url, required this.name, required this.signedIn});

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final initial = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?';

    Widget fallback() => Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.16),
            shape: BoxShape.circle,
            border: Border.all(color: accent.withValues(alpha: 0.25), width: 1.5),
          ),
          child: signedIn
              ? Text(
                  initial,
                  style: TextStyle(
                    color: accent,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : Icon(Icons.person_rounded, color: accent, size: 26),
        );

    // Guard explicitly on signedIn rather than just url-presence — even
    // if a stale avatarUrl were ever left around from a previous session,
    // a signed-out state should never show it. Belt-and-suspenders: in
    // practice AuthProvider only ever populates avatarUrl while signed
    // in, but this keeps the widget correct even if that assumption
    // ever changes elsewhere in the app.
    if (!signedIn || url == null || url!.isEmpty) return fallback();

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url!,
        width: 52,
        height: 52,
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback(),
        errorWidget: (_, __, ___) => fallback(),
      ),
    );
  }
}

// Small caps section label above each group.
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: AurumTheme.textMutedOf(context),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

// One card holding a related cluster of rows, hairline dividers between
// them. Spotify-classic: a flat neutral card, no colored border — the
// only accent color on the whole screen lives on the avatar circle, and
// nowhere else, including this group's chrome.
class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
        boxShadow: [
          BoxShadow(
            color: AurumTheme.textPrimaryOf(context).withValues(alpha: 0.03),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

// One row: icon in a flat neutral tonal container — Spotify-classic,
// every icon the same muted grey regardless of section, no per-row or
// per-section color coding. Title + subtitle, quiet chevron. Press
// feedback is a subtle neutral highlight, not an accent tint.
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
    final iconBg = AurumTheme.textMutedOf(context).withValues(alpha: 0.10);
    final iconColor = AurumTheme.textSecondaryOf(context);
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
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: iconBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: iconColor, size: 19),
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
                      color: AurumTheme.textMutedOf(context).withValues(alpha: 0.7), size: 20),
                ],
              ),
            ),
          ),
        ),
        if (!isLast)
          Padding(
            padding: const EdgeInsets.only(left: 68),
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
