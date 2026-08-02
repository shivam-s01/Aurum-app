// =============================================================================
// FILE: lib/widgets/auto_sleep_guard_tile.dart
// PROJECT: Aurum Music
// DESCRIPTION: Settings → Player card for Auto Sleep Guard — a battery
//   feature fully separate from the Sleep Timer. Available to every
//   signed-in user (free or premium), gated on sign-in only. Free users
//   get a fixed 5h duration with no picker; any signed-in user who opens
//   this card can choose 3h/5h, saved permanently until changed again.
//
//   All state (enabled flag, duration, last-auto-pause record) lives
//   natively in SharedPreferences via AutoSleepGuard.kt — this widget is a
//   thin, stateful view over NativeAudioEngine.autoSleepGuardXxx() calls,
//   not a second source of truth.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import 'package:provider/provider.dart';
import '../services/native_engine_bridge.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../l10n/generated/app_localizations.dart';

class AutoSleepGuardTile extends StatefulWidget {
  const AutoSleepGuardTile({super.key});

  @override
  State<AutoSleepGuardTile> createState() => _AutoSleepGuardTileState();
}

class _AutoSleepGuardTileState extends State<AutoSleepGuardTile> {
  static const _kExplainerShownKey = 'auto_sleep_guard_explainer_shown';

  final NativeAudioEngine _engine = NativeAudioEngine();

  bool _loading = true;
  bool _enabled = true;
  int _durationHours = 5;

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
      _durationHours = state['durationHours'] as int? ?? 5;
      _loading = false;
    });
  }

  Future<bool> _explainerAlreadyShown() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kExplainerShownKey) ?? false;
  }

  Future<void> _markExplainerShown() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kExplainerShownKey, true);
  }

  Future<void> _openSheet(BuildContext context, {required bool isFirstTime}) async {
    final result = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AurumTheme.bgCardOf(context),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AutoSleepGuardSheet(
        initialHours: _durationHours,
        isFirstTime: isFirstTime,
      ),
    );

    if (result == null) return; // dismissed without choosing

    setState(() => _durationHours = result);
    await _engine.autoSleepGuardSetDurationHours(result);
    if (isFirstTime) await _markExplainerShown();
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
          color: _enabled && isSignedIn
              ? AurumTheme.gold.withOpacity(0.35)
              : AurumTheme.dividerOf(context),
          width: _enabled && isSignedIn ? 1 : 0.5,
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
          child: const Icon(Icons.battery_saver_rounded, color: AurumTheme.gold, size: 18),
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
            color: (_enabled && isSignedIn) ? AurumTheme.gold : AurumTheme.textMutedOf(context),
            fontSize: 12,
          ),
        ),
        trailing: _loading
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: AurumTheme.gold),
              )
            : Switch.adaptive(
                value: _enabled && isSignedIn,
                activeColor: AurumTheme.gold,
                onChanged: !isSignedIn
                    ? null
                    : (v) async {
                        AurumHaptics.selection();
                        setState(() => _enabled = v);
                        await _engine.autoSleepGuardSetEnabled(v);
                      },
              ),
        onTap: !isSignedIn
            ? () => _showSignInRequiredHint(context)
            : () async {
                final firstTime = !(await _explainerAlreadyShown());
                if (!context.mounted) return;
                await _openSheet(context, isFirstTime: firstTime);
              },
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

// =============================================================================
// First-time explainer / duration picker bottom sheet
// =============================================================================
class _AutoSleepGuardSheet extends StatefulWidget {
  final int initialHours;
  final bool isFirstTime;
  const _AutoSleepGuardSheet({required this.initialHours, required this.isFirstTime});

  @override
  State<_AutoSleepGuardSheet> createState() => _AutoSleepGuardSheetState();
}

class _AutoSleepGuardSheetState extends State<_AutoSleepGuardSheet> {
  late int _selected = widget.initialHours;
  bool _showSavedTick = false;

  void _select(int hours) {
    if (_selected == hours) return;
    AurumHaptics.light();
    setState(() {
      _selected = hours;
      _showSavedTick = true;
    });
    // Subtle confirmation fade — no jarring dialog, matches the plan's
    // "Saved ✓" micro-animation request.
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showSavedTick = false);
    });
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
                  l10n.asgSheetTitle,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 17, fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                AnimatedOpacity(
                  opacity: _showSavedTick ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
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
            if (widget.isFirstTime) ...[
              const SizedBox(height: 14),
              Text(
                l10n.asgSheetBody(l10n.asgSheetHours(_selected)),
                style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13, height: 1.4),
              ),
            ],
            const SizedBox(height: 20),
            Text(
              l10n.asgSheetDurationLabel,
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Row(
              children: [3, 5].map((h) {
                final isSelected = _selected == h;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => _select(h),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
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
            const SizedBox(height: 20),
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
                  Navigator.of(context).pop(_selected);
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
