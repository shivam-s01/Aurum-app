// =============================================================================
// FILE: lib/widgets/auto_sleep_guard_tile.dart
// PROJECT: Astra Music
// DESCRIPTION: Settings → Player card for Auto Sleep Guard — a battery
//   feature fully separate from the Sleep Timer. Available to every
//   signed-in user (free or premium), gated on sign-in only.
//
//   Tapping the card opens a bottom sheet with two things: an Automatic /
//   Off mode picker (radio-style, matching the Stream Quality picker
//   elsewhere in Settings) and, only while Automatic, the inactivity
//   window picker (3h or 5h, default 3h). Both choices apply instantly —
//   no separate save step — and are saved permanently until changed
//   again.
//
//   All state (enabled flag, duration, last-auto-pause record) lives
//   natively in SharedPreferences via AutoSleepGuard.kt — this widget is
//   a thin, stateful view over NativeAudioEngine.autoSleepGuardXxx()
//   calls, not a second source of truth.
// =============================================================================

import 'package:flutter/material.dart';
import '../providers/auth_provider.dart';
import 'package:provider/provider.dart';
import '../services/native_engine_bridge.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_motion.dart';

class AutoSleepGuardTile extends StatefulWidget {
  const AutoSleepGuardTile({super.key});

  @override
  State<AutoSleepGuardTile> createState() => _AutoSleepGuardTileState();
}

class _AutoSleepGuardTileState extends State<AutoSleepGuardTile> {
  final NativeAudioEngine _engine = NativeAudioEngine();

  bool _loading = true;
  bool _enabled = true;
  int _durationHours = 3;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = await _engine.autoSleepGuardGetState();
    if (!mounted) return;
    setState(() {
      _enabled = state['enabled'] as bool? ?? true;
      _durationHours = state['durationHours'] as int? ?? 3;
      _loading = false;
    });
  }

  Future<void> _openSheet(BuildContext context) async {
    final result = await showAurumModalBottomSheet<_AutoSleepGuardResult>(
      context: context,
      backgroundColor: AurumTheme.bgCardOf(context),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AutoSleepGuardSheet(
        initialEnabled: _enabled,
        initialHours: _durationHours,
      ),
    );

    if (result == null) return; // dismissed without changing anything

    if (result.enabled != _enabled) {
      setState(() => _enabled = result.enabled);
      await _engine.autoSleepGuardSetEnabled(result.enabled);
    }
    if (result.hours != _durationHours) {
      setState(() => _durationHours = result.hours);
      await _engine.autoSleepGuardSetDurationHours(result.hours);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isSignedIn = context.watch<AuthProvider>().isSignedIn;

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
          // FIX ("Auto Sleep Guard looks copy-pasted from Battery Saver"):
          // this used to be Icons.battery_saver_rounded — the exact same
          // icon Battery Saver Mode's own tile/sheet use (see
          // battery_saver_mode_tile.dart). Auto Sleep Guard pauses
          // playback after inactivity, a completely different concept
          // from battery-driven behavior; sharing the battery icon made
          // the two features visually indistinguishable at a glance, one
          // of the two clearest "these were built from the same template
          // and never differentiated" tells. bedtime_rounded (a moon/
          // sleep glyph) matches what this feature actually represents.
          child: const Icon(Icons.bedtime_rounded, color: AurumTheme.gold, size: 18),
        ),
        title: Text(
          l10n.asgTileTitle,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 14, fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          !isSignedIn
              ? l10n.asgTileSubtitleSignedOut
              : (_enabled ? l10n.asgTileSubtitleOn(_durationHours) : l10n.asgTileSubtitleOff),
          style: TextStyle(
            color: isSignedIn ? AurumTheme.gold : AurumTheme.textMutedOf(context),
            fontSize: 12,
          ),
        ),
        trailing: _loading
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: AurumTheme.gold),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isSignedIn)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AurumTheme.gold.withOpacity(_enabled ? 0.12 : 0.06),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _enabled ? l10n.asgTileAutomaticBadge : l10n.asgTileOffBadge,
                        style: TextStyle(
                          color: _enabled ? AurumTheme.gold : AurumTheme.textMutedOf(context),
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
}

class _AutoSleepGuardResult {
  final bool enabled;
  final int hours;
  const _AutoSleepGuardResult(this.enabled, this.hours);
}

// =============================================================================
// Mode + duration picker bottom sheet.
//   - Mode row (Automatic / Off): radio-style, same visual language as the
//     Stream Quality picker elsewhere in Settings, so it reads as a
//     first-class choice rather than a bolted-on switch.
//   - Duration row: only shown/enabled while Automatic is selected — Off
//     has nothing to configure, so it fades out instead of leaving a
//     picker that does nothing.
//   - Every tap applies instantly (both mode and duration), confirmed by
//     the same subtle gold "Saved" tick used elsewhere in this sheet —
//     no separate save/apply step to feel bureaucratic about.
// =============================================================================
class _AutoSleepGuardSheet extends StatefulWidget {
  final bool initialEnabled;
  final int initialHours;
  const _AutoSleepGuardSheet({required this.initialEnabled, required this.initialHours});

  @override
  State<_AutoSleepGuardSheet> createState() => _AutoSleepGuardSheetState();
}

class _AutoSleepGuardSheetState extends State<_AutoSleepGuardSheet> {
  late bool _enabled = widget.initialEnabled;
  late int _selectedHours = widget.initialHours;
  bool _showSavedTick = false;

  void _flashSaved() {
    setState(() => _showSavedTick = true);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showSavedTick = false);
    });
  }

  void _selectMode(bool enabled) {
    if (_enabled == enabled) return;
    AurumHaptics.selection();
    setState(() => _enabled = enabled);
    _flashSaved();
  }

  void _selectHours(int hours) {
    if (_selectedHours == hours) return;
    AurumHaptics.light();
    setState(() => _selectedHours = hours);
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
                    gradient: AurumTheme.goldGradient,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  // See the tile leading-icon FIX comment above — same
                  // battery-icon mixup, same fix, here in the sheet header.
                  child: const Icon(Icons.bedtime_rounded, color: Colors.black, size: 20),
                ),
                const SizedBox(width: 12),
                Text(
                  l10n.asgSheetTitle,
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
                      Text(l10n.asgSheetSaved,
                          style: const TextStyle(color: AurumTheme.gold, fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              l10n.asgSheetBody,
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 8),
            // Small premium-feel line — subtle gold accent, low-key
            // reassurance copy, matching the app's existing "premium
            // card" language elsewhere in Settings.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome_rounded, color: AurumTheme.gold.withOpacity(0.8), size: 13),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.asgSheetPremiumHint,
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
              l10n.asgSheetModeLabel,
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            _ModeOption(
              selected: _enabled,
              title: l10n.asgSheetModeAutomatic,
              subtitle: l10n.asgSheetModeAutomaticDesc,
              onTap: () => _selectMode(true),
            ),
            const SizedBox(height: 8),
            _ModeOption(
              selected: !_enabled,
              title: l10n.asgSheetModeOff,
              subtitle: l10n.asgSheetModeOffDesc,
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
                    l10n.asgSheetDurationLabel,
                    style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [3, 5].map((h) {
                      final isSelected = _selectedHours == h;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => _selectHours(h),
                          child: AnimatedContainer(
                            duration: AurumMotion.durationOrZero(AurumMotion.medium1),
                            margin: EdgeInsets.only(right: h == 3 ? 10 : 0),
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
                              l10n.asgSheetHours(h),
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
                  Navigator.of(context).pop(_AutoSleepGuardResult(_enabled, _selectedHours));
                },
                child: Text(l10n.asgSheetDone, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Radio-style mode row — visually matches the Stream Quality picker
/// pattern used elsewhere in Settings (gold radio icon, gold-tinted fill
/// when selected) so this reads as consistent with the rest of the app
/// rather than a one-off control.
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
