// aurum_settings_tile.dart
// Aurum Music — Shared Animated Settings Row
//
// WHY THIS EXISTS:
// Every settings sub-screen (Privacy, Storage, Notifications, About, ...)
// had its own copy-pasted `_switchTile` / `_navTile` / `_dangerTile` /
// `_dropdownTile` / `_actionTile` helper — plain Container + ListTile,
// no press feedback, and a stock Switch that just snaps on/off. Meanwhile
// the top-level Settings list (_SettingsTile in settings_screen.dart) has
// a nice press-scale animation, so jumping from the main list into any
// sub-page felt like landing somewhere less alive — "stuck".
//
// This file is the single reusable row for every settings screen:
//   - Wraps AurumPressable (project's existing shared press-scale) so
//     every row responds to touch identically to the rest of the app.
//   - A custom animated switch/chevron/dropdown that eases instead of
//     snapping, on AurumMotion's shared timing.
//   - AurumSettingsListStagger: wrap a screen's rows once to get a
//     gentle fade+slide-up entrance when the page opens, matching the
//     "cool, alive" feel across every settings page instead of some
//     pages animating and others rendering instantly.
//
// Drop-in usage — same named params as the old per-screen helpers:
//   AurumSettingsTile.switchTile(context, icon: ..., title: ..., subtitle: ...,
//     value: v, onChanged: (v) {})
//   AurumSettingsTile.nav(context, icon: ..., title: ..., subtitle: ..., onTap: () {})
//   AurumSettingsTile.danger(context, icon: ..., title: ..., subtitle: ..., onTap: () {}, isDanger: true)
//   AurumSettingsTile.dropdown(context, icon: ..., title: ..., subtitle: ..., value: v, options: [...], onChanged: (v) {})

import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_motion.dart';
import 'aurum_pressable.dart';

class AurumSettingsTile extends StatelessWidget {
  const AurumSettingsTile._({
    required this.icon,
    this.customIcon,
    required this.title,
    required this.subtitle,
    this.iconColor,
    this.onTap,
    this.trailing,
    this.isDanger = false,
  });

  final IconData? icon;
  final Widget? customIcon;
  final String title;
  final String subtitle;
  final Color? iconColor;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool isDanger;

  // ── Factory constructors matching the old per-screen helpers ──────────

  factory AurumSettingsTile.switchTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return AurumSettingsTile._(
      icon: icon,
      title: title,
      subtitle: subtitle,
      iconColor: value ? AurumTheme.gold : null,
      onTap: () => onChanged(!value),
      trailing: _AurumAnimatedSwitch(value: value, onChanged: onChanged),
    );
  }

  factory AurumSettingsTile.nav(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Widget? customIcon,
    Color? iconColor,
  }) {
    return AurumSettingsTile._(
      icon: icon,
      customIcon: customIcon,
      title: title,
      subtitle: subtitle,
      iconColor: iconColor,
      onTap: onTap,
      trailing: Icon(Icons.chevron_right_rounded,
          color: AurumTheme.textMutedOf(context), size: 20),
    );
  }

  factory AurumSettingsTile.action(
    BuildContext context, {
    IconData? icon,
    Widget? customIcon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return AurumSettingsTile._(
      icon: icon,
      customIcon: customIcon,
      title: title,
      subtitle: subtitle,
      iconColor: iconColor,
      onTap: onTap,
      trailing: Icon(Icons.arrow_forward_ios_rounded,
          color: AurumTheme.textMutedOf(context), size: 14),
    );
  }

  factory AurumSettingsTile.danger(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDanger = false,
  }) {
    return AurumSettingsTile._(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      isDanger: isDanger,
      trailing: Icon(Icons.chevron_right_rounded,
          color: AurumTheme.textMutedOf(context), size: 20),
    );
  }

  factory AurumSettingsTile.dropdown(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
    String Function(String)? optionLabel,
  }) {
    final label = optionLabel ?? (String o) => o;
    return AurumSettingsTile._(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: DropdownButton<String>(
        value: value,
        underline: const SizedBox(),
        dropdownColor: AurumTheme.bgCardOf(context),
        style: TextStyle(color: AurumTheme.gold, fontSize: 12, fontWeight: FontWeight.w600),
        icon: Icon(Icons.keyboard_arrow_down_rounded, color: AurumTheme.gold, size: 18),
        items: options.map((o) => DropdownMenuItem(value: o, child: Text(label(o)))).toList(),
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final danger = isDanger;
    final baseColor = danger ? Colors.redAccent : (iconColor ?? AurumTheme.gold);
    final leading = customIcon ??
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: baseColor.withOpacity(danger ? 0.1 : 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: baseColor, size: 18),
        );

    return AurumPressable(
      onTap: onTap,
      scaleAmount: 0.98,
      haptic: false, // switches/dropdowns fire their own haptic; nav/danger rows still get a tap ripple feel via scale
      child: AnimatedContainer(
        duration: AurumMotion.durationOrZero(AurumMotion.short2),
        curve: AurumMotion.standard,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: danger ? Colors.redAccent.withOpacity(0.3) : AurumTheme.dividerOf(context),
            width: danger ? 1 : 0.5,
          ),
        ),
        child: ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          leading: leading,
          title: Text(
            title,
            style: TextStyle(
              color: danger ? Colors.redAccent : AurumTheme.textPrimaryOf(context),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
          trailing: trailing,
        ),
      ),
    );
  }
}

/// Custom animated switch — same visual size/position as Material's
/// [Switch] so it drops in without layout shift, but the thumb eases
/// across on AurumMotion's curve instead of Flutter's default snap,
/// and the track color crossfades instead of hard-cutting.
class _AurumAnimatedSwitch extends StatelessWidget {
  const _AurumAnimatedSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: AurumMotion.durationOrZero(AurumMotion.short2),
        curve: AurumMotion.standard,
        width: 46,
        height: 28,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: value ? AurumTheme.gold : AurumTheme.dividerOf(context),
        ),
        child: AnimatedAlign(
          duration: AurumMotion.durationOrZero(AurumMotion.short2),
          curve: AurumMotion.standard,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 2, offset: Offset(0, 1))],
            ),
          ),
        ),
      ),
    );
  }
}

/// Wrap a settings screen's row list with this to give every row a
/// gentle staggered fade + slide-up entrance when the page first opens.
/// Each row's start is offset by [stagger] from the one before it, so
/// the list reads as one continuous cascading motion rather than every
/// row popping in at once — the same "premium load" feel the app
/// already uses for its home feed and library grids.
///
/// Usage: wrap each row (not the whole Column) —
///   AurumStaggerItem(index: i, child: AurumSettingsTile.nav(...))
class AurumStaggerItem extends StatefulWidget {
  const AurumStaggerItem({
    super.key,
    required this.index,
    required this.child,
    this.stagger = const Duration(milliseconds: 40),
  });

  final int index;
  final Widget child;
  final Duration stagger;

  @override
  State<AurumStaggerItem> createState() => _AurumStaggerItemState();
}

class _AurumStaggerItemState extends State<AurumStaggerItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: AurumMotion.medium2);
    _fade = CurvedAnimation(parent: _ctrl, curve: AurumMotion.standard);
    _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: AurumMotion.standard));

    if (!AurumMotion.enabled) {
      _ctrl.value = 1;
    } else {
      // Cap the stagger so long screens (Privacy has ~13 rows) don't
      // make the last row wait half a second to appear — beyond a
      // handful of rows the cascade has already read as "cascading",
      // so everything past that starts together instead of queuing
      // further, keeping the whole entrance snappy on any list length.
      final cappedIndex = widget.index > 6 ? 6 : widget.index;
      final delay = widget.stagger * cappedIndex;
      Future.delayed(delay, () {
        if (mounted) _ctrl.forward();
      });
    }
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
