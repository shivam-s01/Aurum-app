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

// Settings — top-level redesign pass (Spotify/Apple-Music flagship tier).
//
// What changed from the previous "Spotify-classic" pass and why:
//
// 1. Hero identity block instead of a plain list row. Spotify, Apple
//    Music and every other top-tier settings surface opens on a real
//    moment, not a table row — a bigger avatar (64 vs the old 52), a soft
//    accent-tinted glow behind it, and a pill-style "Sign in" CTA when
//    signed out instead of a passive "Tap to sign in" caption. Signed-in
//    state still shows name + email exactly as before.
//
// 2. One accent color, used with more intention. The old build already
//    kept accent confined to the avatar — that discipline is kept — but
//    the accent now also drives the hero card's background glow (very
//    low alpha, never a hard fill) so the top of the screen still reads
//    as "premium app" rather than "flat grey list", without breaking the
//    no-rainbow-icons rule anywhere else on the page.
//
// 3. Section headers get an inline icon + firmer type scale, matching
//    how Spotify weights "ACCOUNT" / "PLAYBACK" etc. — small, bold,
//    wide-tracked, but no longer feeling like an afterthought caption.
//
// 4. Rows keep their icon-tile + title/subtitle + chevron shape (that
//    part already matched the target), but tiles now get a subtle inner
//    highlight + hairline border so they read as "soft-pressed" glass
//    tiles rather than flat blocks, and the whole row has a touch more
//    vertical breathing room.
//
// 5. Cards get a slightly larger radius (24 vs 20) and a two-layer
//    shadow (soft ambient + tighter contact shadow) for real depth
//    instead of a single flat blur — the same trick Spotify's Material 3
//    surfaces use to feel "lifted" rather than outlined.
//
// Structure is otherwise unchanged: large-title-that-collapses header,
// identity anchor at the top, three grouped sections below it. All
// existing navigation, providers, and localization keys are untouched.
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
                // Hero identity block — the moment every flagship settings
                // screen opens with, now with real presence instead of a
                // plain row: bigger avatar, soft accent glow, and a clear
                // sign-in CTA when signed out.
                AurumStaggerItem(index: 0, child: _AccountHero()),
                const SizedBox(height: 36),

                _SectionHeader(icon: Icons.tune_rounded, label: l10n.settingsSectionGeneral),
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
                const SizedBox(height: 30),

                _SectionHeader(icon: Icons.graphic_eq_rounded, label: l10n.settingsSectionPlayback),
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
                const SizedBox(height: 30),

                _SectionHeader(icon: Icons.shield_rounded, label: l10n.settingsSectionSystem),
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
// Hero identity block. Replaces the old plain account row: a real,
// slightly larger avatar (64) sitting on a soft accent-tinted glow card,
// name in a bigger weight, and — when signed out — a proper pill CTA
// button instead of a passive caption, matching how Spotify/Apple Music
// treat the very top of their settings/account surface as a moment, not
// a list item. Still built from the same AuthProvider/ProfileScreen the
// rest of the app already uses — no new data source.
// ─────────────────────────────────────────────────────────────────────────
class _AccountHero extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final signedIn = auth.isSignedIn;
    final name = auth.displayName ?? 'Guest';
    final email = auth.email;
    final avatarUrl = auth.avatarUrl;
    final accent = AurumTheme.accentOf(context);

    return AurumPressable(
      onTap: () {
        AurumHaptics.light();
        AurumDepthRoute.to(context, const ProfileScreen());
      },
      scaleAmount: 0.98,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 22, 18, 22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
          // Soft accent glow gradient instead of a flat card fill — very
          // low alpha throughout, so it reads as "warm surface" rather
          // than a colored block. This is the one place besides the
          // avatar itself where the accent is allowed to show, per the
          // single-accent-color rule this file follows everywhere else.
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accent.withValues(alpha: 0.14),
              AurumTheme.bgCardOf(context),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: AurumTheme.textPrimaryOf(context).withValues(alpha: 0.05),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: signedIn ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            _Avatar(url: avatarUrl, name: name, signedIn: signedIn),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (signedIn)
                    Text(
                      email ?? 'View profile',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 13.5,
                      ),
                    )
                  else ...[
                    Text(
                      'Sign in to sync your library & queue',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Sign in',
                            style: TextStyle(
                              color: AurumTheme.bgOf(context),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.1,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_forward_rounded,
                              color: AurumTheme.bgOf(context), size: 14),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (signedIn)
              Icon(Icons.chevron_right_rounded,
                  color: AurumTheme.textMutedOf(context).withValues(alpha: 0.7), size: 22)
            else
              const SizedBox(width: 22),
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
    const size = 64.0;

    Widget ring({required Widget child}) => Container(
          width: size,
          height: size,
          padding: EdgeInsets.all(signedIn ? 2.5 : 0),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Accent sweep ring only for an actual signed-in identity —
            // a guest gets a plain hairline border instead, so the
            // colorful ring reads as "this is someone", not decoration
            // slapped on every state including the empty one.
            gradient: signedIn
                ? SweepGradient(
                    colors: [
                      accent.withValues(alpha: 0.9),
                      accent.withValues(alpha: 0.25),
                      accent.withValues(alpha: 0.9),
                    ],
                  )
                : null,
            border: signedIn
                ? null
                : Border.all(color: AurumTheme.dividerOf(context), width: 1),
          ),
          child: ClipOval(child: child),
        );

    Widget fallback() => Container(
          color: accent.withValues(alpha: 0.16),
          alignment: Alignment.center,
          child: signedIn
              ? Text(
                  initial,
                  style: TextStyle(
                    color: accent,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : Icon(Icons.person_rounded, color: accent, size: 30),
        );

    // Guard explicitly on signedIn rather than just url-presence — even
    // if a stale avatarUrl were ever left around from a previous session,
    // a signed-out state should never show it. Belt-and-suspenders: in
    // practice AuthProvider only ever populates avatarUrl while signed
    // in, but this keeps the widget correct even if that assumption
    // ever changes elsewhere in the app.
    if (!signedIn || url == null || url!.isEmpty) return ring(child: fallback());

    return ring(
      child: CachedNetworkImage(
        imageUrl: url!,
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback(),
        errorWidget: (_, __, ___) => fallback(),
      ),
    );
  }
}

// Section label with a small leading icon — firmer, more intentional
// than a bare caption, matching how Spotify weights its section titles
// while staying inside the same neutral-grey, single-accent discipline
// (the icon here is muted, not accent-colored).
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SectionHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final muted = AurumTheme.textMutedOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
      child: Row(
        children: [
          Icon(icon, size: 14, color: muted.withValues(alpha: 0.8)),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

// One card holding a related cluster of rows, hairline dividers between
// them. Spotify-classic discipline kept: a flat neutral card, no colored
// border — the only accent color on the whole screen lives on the avatar
// (and the hero glow behind it), nowhere else, including this group's
// chrome. Radius bumped and shadow layered for more "lifted" depth than
// the previous single-blur version.
class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
        boxShadow: [
          BoxShadow(
            color: AurumTheme.textPrimaryOf(context).withValues(alpha: 0.035),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 4,
            offset: const Offset(0, 1),
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
// feedback is a subtle neutral highlight, not an accent tint. Icon tile
// now carries a hairline border of its own so it reads as a soft glass
// chip rather than a flat block, and row padding opened up slightly for
// more breathing room at this larger card radius.
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
    final iconBg = AurumTheme.textMutedOf(context).withValues(alpha: 0.08);
    final iconBorder = AurumTheme.textMutedOf(context).withValues(alpha: 0.14);
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
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: iconBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: iconBorder, width: 0.75),
                    ),
                    child: Icon(icon, color: iconColor, size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(
                                color: AurumTheme.textPrimaryOf(context),
                                fontSize: 15.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.1)),
                        const SizedBox(height: 3),
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
            padding: const EdgeInsets.only(left: 72),
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
