// =============================================================================
// FILE: lib/widgets/battery_saver_mode_tile.dart
// PROJECT: Astra Music
// DESCRIPTION: Settings → Player card for Battery Saver Mode — a purely
//   visual power-saving feature, fully separate from Auto Sleep Guard
//   (which pauses playback after inactivity). Battery Saver Mode never
//   touches playback: while active, it only suppresses animations, the
//   full player's blurred/breathing background, and other heavy
//   rendering — see AudioPrefs.batterySaverActiveNotifier and its
//   consumers (AurumMotion.enabled, AudioPrefs.effectivePlayerBgStyle).
//
//   Tapping the card opens a bottom sheet with two things: an Automatic /
//   Off mode picker (radio-style, same visual language as Auto Sleep
//   Guard's own mode picker) and, only while Automatic, the trigger
//   threshold picker (15% or 20%, default 20%). Both choices apply
//   instantly — no separate save step.
//
//   Live state (current battery %, whether the override is active right
//   now) comes from BatterySaverController via AudioPrefs' notifiers —
//   this widget only reads/writes the enabled + threshold preferences;
//   the actual battery-level watching runs continuously at the app level
//   regardless of whether this screen is open (see main.dart, which
//   starts BatterySaverController once at startup).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/audio_prefs.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_motion.dart';

class BatterySaverModeTile extends StatelessWidget {
  const BatterySaverModeTile({super.key});

  Future<void> _openSheet(BuildContext context) async {
    final result = await showAurumModalBottomSheet<_BatterySaverResult>(
      context: context,
      backgroundColor: AurumTheme.bgCardOf(context),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _BatterySaverSheet(
        initialEnabled: AudioPrefs.batterySaverEnabledNotifier.value,
        initialThreshold: AudioPrefs.batterySaverThresholdNotifier.value,
      ),
    );

    if (result == null) return; // dismissed without changing anything

    if (result.enabled != AudioPrefs.batterySaverEnabledNotifier.value) {
      await AudioPrefs.setBatterySaverEnabled(result.enabled);
    }
    if (result.threshold != AudioPrefs.batterySaverThresholdNotifier.value) {
      await AudioPrefs.setBatterySaverThreshold(result.threshold);
    }
  }

  void _showSignInRequiredHint(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    AurumHaptics.selection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AurumTheme.bgCardOf(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text(
          l10n.asgTileSubtitleSignedOut,
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 13),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isSignedIn = context.watch<AuthProvider>().isSignedIn;

    // Three live values, one Selector-less rebuild via three
    // ValueListenableBuilders nested — cheap, and each only touches this
    // one small card (not the whole settings screen) when it changes.
    return ValueListenableBuilder<bool>(
      valueListenable: AudioPrefs.batterySaverEnabledNotifier,
      builder: (context, enabled, _) {
        return ValueListenableBuilder<int>(
          valueListenable: AudioPrefs.batterySaverThresholdNotifier,
          builder: (context, threshold, __) {
            return ValueListenableBuilder<bool>(
              valueListenable: AudioPrefs.batterySaverActiveNotifier,
              builder: (context, active, ___) {
                return ValueListenableBuilder<int?>(
                  valueListenable: AudioPrefs.batteryLevelNotifier,
                  builder: (context, level, ____) {
                    return _buildTile(
                      context, l10n, isSignedIn, enabled, threshold, active, level,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildTile(
    BuildContext context,
    AppLocalizations l10n,
    bool isSignedIn,
    bool enabled,
    int threshold,
    bool active,
    int? level,
  ) {
    final String subtitle;
    if (!isSignedIn) {
      subtitle = l10n.asgTileSubtitleSignedOut;
    } else if (!enabled) {
      subtitle = l10n.bsmTileSubtitleOff;
    } else if (active && level != null) {
      subtitle = l10n.bsmTileSubtitleActive(level);
    } else {
      subtitle = l10n.bsmTileSubtitleWatching(threshold);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSignedIn
              ? AurumTheme.gold.withOpacity(0.35)
              : AurumTheme.dividerOf(context),
          width: isSignedIn ? 1 : 0.5,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: AurumTheme.gold.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            active ? Icons.battery_alert_rounded : Icons.battery_saver_rounded,
            color: AurumTheme.gold, size: 18,
          ),
        ),
        title: Text(
          l10n.bsmTileTitle,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 14, fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            color: isSignedIn ? AurumTheme.gold : AurumTheme.textMutedOf(context),
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSignedIn)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AurumTheme.gold.withOpacity(enabled ? 0.12 : 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  enabled ? l10n.bsmTileAutomaticBadge : l10n.bsmTileOffBadge,
                  style: TextStyle(
                    color: enabled ? AurumTheme.gold : AurumTheme.textMutedOf(context),
                    fontSize: 11, fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (isSignedIn) const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded,
                color: AurumTheme.textMutedOf(context), size: 18),
          ],
        ),
        onTap: !isSignedIn
            ? () => _showSignInRequiredHint(context)
            : () => _openSheet(context),
      ),
    );
  }
}

class _BatterySaverResult {
  final bool enabled;
  final int threshold;
  const _BatterySaverResult(this.enabled, this.threshold);
}

// =============================================================================
// Mode + threshold picker bottom sheet — same visual language as Auto
// Sleep Guard's sheet (radio-style mode row, gold-tinted selection,
// AnimatedCrossFade to hide the threshold row while Off is selected).
// =============================================================================
class _BatterySaverSheet extends StatefulWidget {
  final bool initialEnabled;
  final int initialThreshold;
  const _BatterySaverSheet({
    required this.initialEnabled,
    required this.initialThreshold,
  });

  @override
  State<_BatterySaverSheet> createState() => _BatterySaverSheetState();
}

class _BatterySaverSheetState extends State<_BatterySaverSheet> {
  late bool _enabled = widget.initialEnabled;
  late int _selectedThreshold = widget.initialThreshold;
  bool _showSavedTick = false;

  void _flashSaved() {
    setState(() => _showSavedTick = true);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showSavedTick = false);
    });
  }

  void _selectMode(bool enabled) {
    if (_enabled == enabled) return;
    AurumHaptics.light();
    setState(() => _enabled = enabled);
    _flashSaved();
  }

  void _selectThreshold(int value) {
    if (_selectedThreshold == value) return;
    AurumHaptics.light();
    setState(() => _selectedThreshold = value);
    _flashSaved();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: AurumTheme.gold.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(Icons.battery_saver_rounded, color: AurumTheme.gold, size: 20),
                ),
                const SizedBox(width: 12),
                Text(
                  l10n.bsmSheetTitle,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 17, fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                AnimatedOpacity(
                  opacity: _showSavedTick ? 1 : 0,
                  duration: AurumMotion.durationOrZero(AurumMotion.medium1),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle_rounded, color: AurumTheme.gold, size: 16),
                      const SizedBox(width: 4),
                      Text(l10n.bsmSheetSaved,
                          style: const TextStyle(color: AurumTheme.gold, fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              l10n.bsmSheetBody,
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome_rounded, color: AurumTheme.gold.withOpacity(0.8), size: 13),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.bsmSheetPremiumHint,
                    style: TextStyle(
                      color: AurumTheme.gold.withOpacity(0.85),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              l10n.bsmSheetModeLabel,
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            _ModeOption(
              selected: _enabled,
              title: l10n.bsmSheetModeAutomatic,
              subtitle: l10n.bsmSheetModeAutomaticDesc,
              onTap: () => _selectMode(true),
            ),
            const SizedBox(height: 8),
            _ModeOption(
              selected: !_enabled,
              title: l10n.bsmSheetModeOff,
              subtitle: l10n.bsmSheetModeOffDesc,
              onTap: () => _selectMode(false),
            ),
            const SizedBox(height: 20),
            AnimatedCrossFade(
              duration: AurumMotion.durationOrZero(AurumMotion.medium1),
              crossFadeState: _enabled ? CrossFadeState.showFirst : CrossFadeState.showSecond,
              firstChild: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.bsmSheetThresholdLabel,
                    style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [15, 20].map((v) {
                      final isSelected = _selectedThreshold == v;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => _selectThreshold(v),
                          child: AnimatedContainer(
                            duration: AurumMotion.durationOrZero(AurumMotion.medium1),
                            margin: EdgeInsets.only(right: v == 15 ? 10 : 0),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: isSelected ? AurumTheme.gold.withOpacity(0.14) : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected ? AurumTheme.gold : AurumTheme.dividerOf(context),
                                width: isSelected ? 1.4 : 0.8,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              l10n.bsmSheetPercent(v),
                              style: TextStyle(
                                color: isSelected ? AurumTheme.gold : AurumTheme.textPrimaryOf(context),
                                fontSize: 15,
                                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
              secondChild: const SizedBox.shrink(),
            ),
            SizedBox(height: _enabled ? 20 : 4),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AurumTheme.gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  AurumHaptics.light();
                  Navigator.of(context).pop(_BatterySaverResult(_enabled, _selectedThreshold));
                },
                child: Text(l10n.bsmSheetDone, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Radio-style mode row — identical visual language to Auto Sleep
/// Guard's own _ModeOption, kept as a private copy here rather than
/// shared/exported since both are intentionally small, self-contained
/// settings-sheet internals (same reasoning the app already applies to
/// its other per-feature sheets).
class _ModeOption extends StatelessWidget {
  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ModeOption({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AurumMotion.durationOrZero(AurumMotion.medium1),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AurumTheme.gold.withOpacity(0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AurumTheme.gold.withOpacity(0.5) : AurumTheme.dividerOf(context),
            width: selected ? 1.2 : 0.8,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              color: selected ? AurumTheme.gold : AurumTheme.textMutedOf(context),
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11.5, height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
