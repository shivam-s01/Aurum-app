import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_transitions.dart';
import '../providers/player_provider.dart';
import '../providers/auth_provider.dart';
import 'settings_player_screen.dart';
import 'settings_appearance_screen.dart';
import 'settings_storage_screen.dart';
import 'settings_privacy_screen.dart';
import 'settings_about_screen.dart';
import 'support_developer_screen.dart';
import 'settings_language_screen.dart';
import 'settings_region_screen.dart';
import 'profile_screen.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_settings_tile.dart' show AurumStaggerItem;
import '../services/aurum_image_cache.dart';

// Settings — production-grade layout.
//
// Design rules this screen follows:
//  • Large title that collapses into a slim pinned bar, with a back button.
//  • One clean account card at the top (avatar, name, email — or a clear
//    "Sign in" action for guests).
//  • Three tidy groups (General / Playback / System). Rows use one
//    consistent accent-tinted icon tile, a title, a one-line subtitle and a
//    chevron — no per-row colours, no heavy shadows, just a hairline border.
//  • Support is its own highlighted card, and a small version footer closes
//    the page like every shipped app does.
//  • No runtime-downloaded fonts (the old title used GoogleFonts, which
//    fetches a font file over the network on first open and can flash).
//  • Every colour comes from the active theme → Light / Dark / AMOLED /
//    dynamic colour all stay consistent.
//
// Navigation targets, providers and localisation keys are unchanged.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _open(BuildContext context, Widget screen) {
    AurumHaptics.light();
    AurumDepthRoute.to(context, screen);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final engine = context.read<PlayerProvider>().handler;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _CollapsingTitleDelegate(
              title: l10n.settingsTitle,
              topPadding: MediaQuery.of(context).padding.top,
              backgroundColor: AurumTheme.bgOf(context),
              textColor: AurumTheme.textPrimaryOf(context),
              dividerColor: AurumTheme.dividerOf(context),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 110),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                AurumStaggerItem(index: 0, child: const _AccountCard()),
                const SizedBox(height: 30),

                _SectionLabel(l10n.settingsSectionGeneral),
                AurumStaggerItem(
                  index: 1,
                  child: _SettingsGroup(children: [
                    _SettingsRow(
                      icon: Icons.palette_rounded,
                      title: l10n.settingsAppearance,
                      subtitle: l10n.settingsAppearanceSubtitle,
                      onTap: () => _open(context, const SettingsAppearanceScreen()),
                    ),
                    _SettingsRow(
                      icon: Icons.language_rounded,
                      title: l10n.settingsLanguage,
                      subtitle: l10n.settingsLanguageSubtitle,
                      onTap: () => _open(context, const SettingsLanguageScreen()),
                    ),
                    _SettingsRow(
                      icon: Icons.public_rounded,
                      title: l10n.settingsRegion,
                      subtitle: l10n.settingsRegionSubtitle,
                      onTap: () => _open(context, const SettingsRegionScreen()),
                      isLast: true,
                    ),
                  ]),
                ),
                const SizedBox(height: 26),

                _SectionLabel(l10n.settingsSectionPlayback),
                AurumStaggerItem(
                  index: 2,
                  child: _SettingsGroup(children: [
                    _SettingsRow(
                      icon: Icons.graphic_eq_rounded,
                      title: l10n.settingsPlayerAudio,
                      subtitle: l10n.settingsPlayerAudioSubtitle,
                      onTap: () => _open(context, SettingsPlayerScreen(audioEngine: engine)),
                    ),
                    _SettingsRow(
                      icon: Icons.sd_storage_rounded,
                      title: l10n.settingsStorage,
                      subtitle: l10n.settingsStorageSubtitle,
                      onTap: () => _open(context, const SettingsStorageScreen()),
                      isLast: true,
                    ),
                  ]),
                ),
                const SizedBox(height: 26),

                _SectionLabel(l10n.settingsSectionSystem),
                AurumStaggerItem(
                  index: 3,
                  child: _SettingsGroup(children: [
                    _SettingsRow(
                      icon: Icons.shield_rounded,
                      title: l10n.settingsPrivacy,
                      subtitle: l10n.settingsPrivacySubtitle,
                      onTap: () => _open(context, const SettingsPrivacyScreen()),
                    ),
                    _SettingsRow(
                      icon: Icons.info_rounded,
                      title: l10n.settingsAbout,
                      subtitle: l10n.settingsAboutSubtitle,
                      onTap: () => _open(context, const SettingsAboutScreen()),
                      isLast: true,
                    ),
                  ]),
                ),
                const SizedBox(height: 26),

                AurumStaggerItem(
                  index: 4,
                  child: _SupportCard(
                    title: l10n.settingsSupportDeveloper,
                    subtitle: l10n.settingsSupportDeveloperSubtitle,
                    onTap: () => _open(context, const SupportDeveloperScreen()),
                  ),
                ),
                const SizedBox(height: 28),
                const _VersionFooter(),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Collapsing title header — one manual interpolation drives font size,
// padding and the bottom hairline, so nothing can fight anything else.
// ─────────────────────────────────────────────────────────────────────────
class _CollapsingTitleDelegate extends SliverPersistentHeaderDelegate {
  final String title;
  final double topPadding;
  final Color backgroundColor;
  final Color textColor;
  final Color dividerColor;

  static const double _collapsedH = 56;
  static const double _expandedH = 104;

  _CollapsingTitleDelegate({
    required this.title,
    required this.topPadding,
    required this.backgroundColor,
    required this.textColor,
    required this.dividerColor,
  });

  @override
  double get minExtent => _collapsedH + topPadding;

  @override
  double get maxExtent => _expandedH + topPadding;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = maxExtent - minExtent;
    // t = 1 expanded (large title) … t = 0 collapsed (small pinned title).
    final t = range == 0 ? 0.0 : (1 - (shrinkOffset / range)).clamp(0.0, 1.0);
    final fontSize = 20 + (14 * t); // 20 → 34
    final titleLeft = 20 + (36 * (1 - t)); // slides right to make room for back button

    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border(
          bottom: BorderSide(
            color: dividerColor.withValues(alpha: (1 - t) * 0.8),
            width: 0.6,
          ),
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: topPadding + 6,
            left: 10,
            child: AurumPressable(
              onTap: () => Navigator.maybePop(context),
              scaleAmount: 0.9,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(Icons.arrow_back_rounded, size: 24, color: textColor),
              ),
            ),
          ),
          Positioned(
            left: titleLeft,
            right: 20,
            bottom: 14 + (2 * (1 - t)),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w800,
                color: textColor,
                letterSpacing: -0.8 * t - 0.2,
                height: 1.0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _CollapsingTitleDelegate old) {
    return old.title != title ||
        old.topPadding != topPadding ||
        old.backgroundColor != backgroundColor ||
        old.textColor != textColor ||
        old.dividerColor != dividerColor;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Account card — compact and clean. Tap opens the profile page.
// ─────────────────────────────────────────────────────────────────────────
class _AccountCard extends StatelessWidget {
  const _AccountCard();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final auth = context.watch<AuthProvider>();
    final signedIn = auth.isSignedIn;
    final name = auth.displayName ?? l10n.settingsGuest;
    final accent = AurumTheme.accentOf(context);

    return AurumPressable(
      onTap: () {
        AurumHaptics.light();
        AurumDepthRoute.to(context, const ProfileScreen());
      },
      scaleAmount: 0.985,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.6),
        ),
        child: Row(
          children: [
            _Avatar(url: auth.avatarUrl, name: name, signedIn: signedIn),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 17.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    signedIn
                        ? (auth.email ?? l10n.settingsViewProfile)
                        : l10n.settingsSignInPrompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textSecondaryOf(context),
                      fontSize: 12.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (signedIn)
              Icon(Icons.chevron_right_rounded,
                  size: 22, color: AurumTheme.textMutedOf(context))
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  l10n.prSignIn,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
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
    const size = 58.0;

    Widget fallback() => Container(
          color: accent.withValues(alpha: 0.16),
          alignment: Alignment.center,
          child: signedIn
              ? Text(initial,
                  style: TextStyle(
                      color: accent, fontSize: 23, fontWeight: FontWeight.w800))
              : Icon(Icons.person_rounded, color: accent, size: 28),
        );

    // Never show a stale photo while signed out.
    final hasPhoto = signedIn && url != null && url!.isNotEmpty;

    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: signedIn
              ? accent.withValues(alpha: 0.75)
              : AurumTheme.dividerOf(context),
          width: signedIn ? 1.6 : 1,
        ),
      ),
      child: ClipOval(
        child: hasPhoto
            ? CachedNetworkImage(
                cacheManager: AurumImageCache(),
                imageUrl: url!,
                memCacheWidth: 200,
                fit: BoxFit.cover,
                placeholder: (_, __) => fallback(),
                errorWidget: (_, __, ___) => fallback(),
              )
            : fallback(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Section label + grouped card + row.
// ─────────────────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: AurumTheme.textMutedOf(context),
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

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
    final accent = AurumTheme.accentOf(context);
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            splashFactory: NoSplash.splashFactory,
            highlightColor:
                AurumTheme.textPrimaryOf(context).withValues(alpha: 0.05),
            hoverColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: accent, size: 21),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AurumTheme.textSecondaryOf(context),
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded,
                      color: AurumTheme.textMutedOf(context), size: 21),
                ],
              ),
            ),
          ),
        ),
        if (!isLast)
          Padding(
            padding: const EdgeInsets.only(left: 70),
            child: Divider(
              height: 1,
              thickness: 0.6,
              color: AurumTheme.dividerOf(context),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Support card — its own highlighted block, not just another row.
// ─────────────────────────────────────────────────────────────────────────
class _SupportCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _SupportCard(
      {required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    return AurumPressable(
      onTap: onTap,
      scaleAmount: 0.985,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accent.withValues(alpha: 0.20),
              accent.withValues(alpha: 0.06),
            ],
          ),
          border: Border.all(color: accent.withValues(alpha: 0.28), width: 0.8),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: AurumTheme.accentGradientOf(context),
              ),
              child: const Icon(Icons.favorite_rounded,
                  color: Colors.black, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textSecondaryOf(context),
                      fontSize: 12.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded,
                color: AurumTheme.textMutedOf(context), size: 21),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Version footer — read once, cached for the rest of the session.
// ─────────────────────────────────────────────────────────────────────────
class _VersionFooter extends StatefulWidget {
  const _VersionFooter();

  @override
  State<_VersionFooter> createState() => _VersionFooterState();
}

class _VersionFooterState extends State<_VersionFooter> {
  static String? _cached;
  String? _text = _cached;

  @override
  void initState() {
    super.initState();
    if (_text == null) {
      PackageInfo.fromPlatform().then((info) {
        _cached = 'Astra Music  •  v${info.version} (${info.buildNumber})';
        if (mounted) setState(() => _text = _cached);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: Center(
        child: Text(
          _text ?? '',
          style: TextStyle(
            color: AurumTheme.textMutedOf(context),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
