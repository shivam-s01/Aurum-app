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
          // ── Grouped, production-style layout ──────────────────────────
          // Instead of 7 identical floating cards (flat, no hierarchy, felt
          // like one long undifferentiated list), items are now clustered
          // into labeled sections — GENERAL / PLAYBACK / SYSTEM — each
          // rendered as ONE rounded card containing its rows with thin
          // hairline dividers between them (Spotify/Apple Music/YT Music
          // settings all use exactly this pattern). A small caps section
          // header sits above each card. Per-category icon tint (instead of
          // every icon being the same gold) gives instant visual scannability
          // — the eye can jump straight to "Storage" or "Privacy" by color
          // before even reading the label.
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _StaggerIn(
                  index: 0,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionHeader(l10n.settingsSectionGeneral),
                      _SettingsGroup(
                        children: [
                          _SettingsRow(
                            icon: Icons.palette_rounded,
                            iconColor: const Color(0xFFE07BB0),
                            title: l10n.settingsAppearance,
                            subtitle: l10n.settingsAppearanceSubtitle,
                            onTap: () {
                              AurumHaptics.light();
                              AurumDepthRoute.to(context, const SettingsAppearanceScreen());
                            },
                          ),
                          _SettingsRow(
                            icon: Icons.language_rounded,
                            iconColor: const Color(0xFF5BA8E8),
                            title: l10n.settingsLanguage,
                            subtitle: l10n.settingsLanguageSubtitle,
                            onTap: () {
                              AurumHaptics.light();
                              AurumDepthRoute.to(context, const SettingsLanguageScreen());
                            },
                          ),
                          _SettingsRow(
                            icon: Icons.notifications_rounded,
                            iconColor: const Color(0xFFE8A64F),
                            title: l10n.settingsNotifications,
                            subtitle: l10n.settingsNotificationsSubtitle,
                            onTap: () {
                              AurumHaptics.light();
                              AurumDepthRoute.to(context, const SettingsNotificationsScreen());
                            },
                            isLast: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _StaggerIn(
                  index: 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionHeader(l10n.settingsSectionPlayback),
                      _SettingsGroup(
                        children: [
                          _SettingsRow(
                            icon: Icons.equalizer_rounded,
                            iconColor: AurumTheme.gold,
                            title: l10n.settingsPlayerAudio,
                            subtitle: l10n.settingsPlayerAudioSubtitle,
                            onTap: () {
                              AurumHaptics.light();
                              // Matches the Liked/Playlist fade + slide-up
                              // push (see aurum_transitions.dart's
                              // AurumDepthRoute) — Settings' whole
                              // sub-navigation now shares it.
                              AurumDepthRoute.to(context, SettingsPlayerScreen(audioEngine: engine));
                            },
                          ),
                          _SettingsRow(
                            icon: Icons.storage_rounded,
                            iconColor: const Color(0xFF6FC08A),
                            title: l10n.settingsStorage,
                            subtitle: l10n.settingsStorageSubtitle,
                            onTap: () {
                              AurumHaptics.light();
                              AurumDepthRoute.to(context, const SettingsStorageScreen());
                            },
                            isLast: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _StaggerIn(
                  index: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionHeader(l10n.settingsSectionSystem),
                      _SettingsGroup(
                        children: [
                          _SettingsRow(
                            icon: Icons.shield_rounded,
                            iconColor: const Color(0xFF8A8AE8),
                            title: l10n.settingsPrivacy,
                            subtitle: l10n.settingsPrivacySubtitle,
                            onTap: () {
                              AurumHaptics.light();
                              AurumDepthRoute.to(context, const SettingsPrivacyScreen());
                            },
                          ),
                          _SettingsRow(
                            icon: Icons.info_outline_rounded,
                            iconColor: AurumTheme.textMutedOf(context),
                            title: l10n.settingsAbout,
                            subtitle: l10n.settingsAboutSubtitle,
                            onTap: () {
                              AurumHaptics.light();
                              AurumDepthRoute.to(context, const SettingsAboutScreen());
                            },
                            isLast: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

}

// ── Entrance stagger — each section (header+group) fades and slides up
// into place with a small delay after the previous one, instead of the
// whole list just snapping onto screen instantly. This is the other half
// of "feels dead": a static list that's already fully rendered the moment
// you land on it reads as inert even if it's well laid out. A quick
// 300–380ms per-item reveal with a slight stagger gives the screen a
// sense of things settling into place, matching the kind of entrance
// polish Spotify/Apple Music apply to their own settings/library lists.
class _StaggerIn extends StatefulWidget {
  final Widget child;
  final int index;
  const _StaggerIn({required this.child, required this.index});

  @override
  State<_StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<_StaggerIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    // Stagger delay capped at 3 sections' worth (~240ms max) so a long
    // settings list never makes the last section feel like it's waiting
    // around — it just means items past the cap start together.
    final delay = Duration(milliseconds: 60 * widget.index.clamp(0, 4));
    Future.delayed(delay, () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

// ── Small caps section label above each group (GENERAL / PLAYBACK / SYSTEM)
// — the piece that was missing entirely before. Gives the scroll a rhythm
// instead of one undifferentiated stack of identical cards.
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
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ── One rounded card holding a related cluster of rows, hairline dividers
// between them — replaces the old "every single item is its own floating
// card" pattern that read as flat and repetitive.
class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _SettingsRow extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isLast;

  const _SettingsRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isLast = false,
  });

  @override
  State<_SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<_SettingsRow>
    with SingleTickerProviderStateMixin {
  // Real tap feedback (press-scale on the whole row + the icon chip
  // brightening) instead of the near-invisible 4%-opacity background tint
  // this had before — that was too subtle to register as "the app
  // responded to my touch", which is a big part of why the screen felt
  // dead even after the grouping/color fixes. forward on tap-down (fast,
  // 90ms — has to feel instant) and a springy elasticOut release back to
  // 1.0 gives the same "pump" character the bottom nav tabs already use.
  late final AnimationController _pressCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
    reverseDuration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _scale = Tween(begin: 1.0, end: 0.975).animate(
    CurvedAnimation(
      parent: _pressCtrl,
      curve: Curves.easeOut,
      reverseCurve: Curves.elasticOut,
    ),
  );

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTapDown: (_) => _pressCtrl.forward(),
          onTapUp: (_) {
            _pressCtrl.reverse();
            widget.onTap();
          },
          onTapCancel: () => _pressCtrl.reverse(),
          child: AnimatedBuilder(
            animation: _scale,
            builder: (context, child) => Transform.scale(
              scale: _scale.value,
              alignment: Alignment.center,
              child: child,
            ),
            child: AnimatedBuilder(
              animation: _pressCtrl,
              builder: (context, child) => Container(
                color: AurumTheme.textPrimaryOf(context)
                    .withValues(alpha: _pressCtrl.value * 0.06),
                child: child,
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    AnimatedBuilder(
                      animation: _pressCtrl,
                      builder: (context, child) => Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          // Icon chip brightens slightly on press (0.14 →
                          // up to 0.24 opacity) — a second, more localized
                          // signal that this exact row is the one being
                          // touched, on top of the whole-row scale+tint.
                          color: widget.iconColor.withValues(
                              alpha: 0.14 + _pressCtrl.value * 0.10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: child,
                      ),
                      child: Icon(widget.icon, color: widget.iconColor, size: 20),
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
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.2)),
                          const SizedBox(height: 2),
                          Text(widget.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
          ),
        ),
        if (!widget.isLast)
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

// ─────────────────────────────────────────────────────────────────────────────
