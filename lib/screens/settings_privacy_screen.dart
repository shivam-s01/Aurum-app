import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../services/audio_prefs.dart';
import '../services/auth_service.dart';
import '../services/recommendation_engine.dart';
import '../services/sync_service.dart';
import '../providers/auth_provider.dart';
import '../providers/recently_played_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/favorites_provider.dart';
import '../l10n/generated/app_localizations.dart';
import '../widgets/aurum_focus_field.dart';
import '../widgets/aurum_settings_tile.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';

class SettingsPrivacyScreen extends StatefulWidget {
  const SettingsPrivacyScreen({super.key});
  @override
  State<SettingsPrivacyScreen> createState() => _SettingsPrivacyScreenState();
}

class _SettingsPrivacyScreenState extends State<SettingsPrivacyScreen> {
  bool   _appLock         = false;
  bool   _biometricLock   = false;
  bool   _incognitoMode   = false;
  bool   _hideListenStats = false;
  String _appLockPin      = '';
  // Internal, language-independent key. Display label is resolved via
  // _delayLabel() at build time so switching app language doesn't break
  // the stored preference.
  String _lockDelayKey    = 'after10';
  bool   _dontLockPlaying = false;
  bool   _deletingAccount = false;

  // FIX (toggle flash — same root cause across every settings screen):
  // all the fields above are given hardcoded defaults, but the real saved
  // values only arrive once _load()'s async SharedPreferences read
  // completes. The very first build() always paints with these hardcoded
  // defaults for at least a frame, then snaps to the real value the moment
  // _load() finishes — reading as "a toggle looked on/off for a moment,
  // then flipped by itself." _loaded gates the real UI behind a brief
  // loader until the actual saved values are in hand, so the screen only
  // ever paints once, already correct.
  bool _loaded = false;

  static const _delayKeys = ['immediately', 'after1', 'after5', 'after10', 'after30'];

  String _delayLabel(AppLocalizations l10n, String key) {
    switch (key) {
      case 'immediately': return l10n.sprDelayImmediately;
      case 'after1':      return l10n.sprDelayAfter1Min;
      case 'after5':      return l10n.sprDelayAfter5Min;
      case 'after30':     return l10n.sprDelayAfter30Min;
      case 'after10':
      default:            return l10n.sprDelayAfter10Min;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _appLock         = p.getBool('app_lock_enabled')    ?? false;
      _biometricLock   = p.getBool('biometric_lock')      ?? false;
      _incognitoMode   = p.getBool('incognito_mode')      ?? false;
      _hideListenStats = p.getBool('hide_listen_stats')   ?? false;
      _appLockPin      = p.getString('app_lock_pin')      ?? '';
      _lockDelayKey    = p.getString('lock_delay_key')     ?? 'after10';
      _dontLockPlaying = p.getBool('dont_lock_while_playing') ?? false;
      _loaded = true;
    });
  }

  Future<void> _save(String key, dynamic value) async {
    final p = await SharedPreferences.getInstance();
    if (value is bool)   await p.setBool(key, value);
    if (value is String) await p.setString(key, value);
  }

  // ── PIN Setup Sheet ────────────────────────────────────────────────────────
  void _showPinSheet(BuildContext context) {
    showAurumModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // FIX: same barrier-dismiss race as feedback_dialog.dart's
      // showDialog (see that file's comment for the full mechanism) —
      // isDismissible defaults to true, and when the keyboard rises it
      // shrinks the viewport and relayouts this sheet's content, which
      // can read as an outside tap and pop the sheet before the keyboard
      // even finishes rising. The sheet already has its own back-swipe/
      // handle-drag affordance and no outside-tap was ever load-bearing
      // here, so disabling it removes the race entirely.
      isDismissible: false,
      enableDrag: true,
      backgroundColor: AurumTheme.bgCardOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PinSetupSheet(
        currentPin: _appLockPin,
        onSave: (pin) {
          setState(() => _appLockPin = pin);
          _save('app_lock_pin', pin);
          if (pin.isEmpty) {
            setState(() => _appLock = false);
            _save('app_lock_enabled', false);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (!_loaded) {
      return Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        appBar: _appBar(context, l10n.settingsPrivacy),
        body: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    // Built as a flat list (instead of inline in `children:`) so every
    // row — including conditional ones like the PIN sub-rows — can be
    // wrapped in AurumStaggerItem with a clean sequential index. That's
    // what gives the page its cascading "alive" entrance instead of
    // every row appearing at once.
    final rows = <Widget>[
      // ── APP LOCK ──────────────────────────────────────────────────
      _sectionLabel(context, l10n.sprAppLock),
      AurumSettingsTile.switchTile(context,
        icon: Icons.lock_rounded,
        title: l10n.sprAppLockTitle,
        subtitle: _appLockPin.isEmpty
            ? l10n.sprAppLockSubtitleSet
            : l10n.sprAppLockSubtitleChange,
        value: _appLock,
        onChanged: (v) async {
          if (v && _appLockPin.isEmpty) {
            // Must set PIN first
            _showPinSheet(context);
            return;
          }
          setState(() => _appLock = v);
          await _save('app_lock_enabled', v);
        },
      ),
      if (_appLock || _appLockPin.isNotEmpty) ...[
        AurumSettingsTile.nav(context,
          icon: Icons.pin_rounded,
          title: _appLockPin.isEmpty ? l10n.sprSetPin : l10n.sprChangePin,
          subtitle: _appLockPin.isEmpty
              ? l10n.sprSetPinSubtitle
              : l10n.sprChangePinSubtitle,
          onTap: () { AurumHaptics.light(); _showPinSheet(context); },
        ),
        AurumSettingsTile.switchTile(context,
          icon: Icons.fingerprint_rounded,
          title: l10n.sprBiometricUnlock,
          subtitle: l10n.sprBiometricUnlockSubtitle,
          value: _biometricLock,
          onChanged: (v) {
            setState(() => _biometricLock = v);
            _save('biometric_lock', v);
          },
        ),
        AurumSettingsTile.dropdown(context,
          icon: Icons.timer_rounded,
          title: l10n.sprAutoLockAfter,
          subtitle: l10n.sprAutoLockAfterSubtitle,
          value: _lockDelayKey,
          options: _delayKeys,
          optionLabel: (key) => _delayLabel(l10n, key),
          onChanged: (v) async {
            setState(() => _lockDelayKey = v!);
            await _save('lock_delay_key', v!);
            const delays = {
              'immediately': 0, 'after1': 1, 'after5': 5,
              'after10': 10, 'after30': 30,
            };
            final p = await SharedPreferences.getInstance();
            await p.setInt('lock_delay_mins', delays[v] ?? 10);
          },
        ),
        AurumSettingsTile.switchTile(context,
          icon: Icons.music_note_rounded,
          title: l10n.sprDontLockWhilePlaying,
          subtitle: l10n.sprDontLockWhilePlayingSubtitle,
          value: _dontLockPlaying,
          onChanged: (v) {
            setState(() => _dontLockPlaying = v);
            _save('dont_lock_while_playing', v);
          },
        ),
      ],

      // ── INCOGNITO ─────────────────────────────────────────────────
      _sectionLabel(context, l10n.sprIncognito),
      AurumSettingsTile.switchTile(context,
        icon: Icons.visibility_off_rounded,
        title: l10n.sprIncognitoMode,
        subtitle: l10n.sprIncognitoModeSubtitle,
        value: _incognitoMode,
        onChanged: (v) {
          setState(() => _incognitoMode = v);
          _save('incognito_mode', v);
          AudioPrefs.setIncognito(v);
        },
      ),
      if (_incognitoMode)
        _infoTile(context,
          icon: Icons.info_outline_rounded,
          message: l10n.sprIncognitoOnInfo,
          color: AurumTheme.accentOf(context),
        ),
      AurumSettingsTile.switchTile(context,
        icon: Icons.bar_chart_rounded,
        title: l10n.sprHideListeningStats,
        subtitle: l10n.sprHideListeningStatsSubtitle,
        value: _hideListenStats,
        onChanged: (v) {
          setState(() => _hideListenStats = v);
          _save('hide_listen_stats', v);
          AudioPrefs.setHideListenStats(v);
        },
      ),

      // ── CLEAR DATA ────────────────────────────────────────────────
      _sectionLabel(context, l10n.sprClearData),
      AurumSettingsTile.danger(context,
        icon: Icons.history_rounded,
        title: l10n.sprClearHistory,
        subtitle: l10n.sprClearHistorySubtitle,
        onTap: () { AurumHaptics.medium(); _confirmClear(context, l10n, l10n.sprHistoryTitle, () async {
          await context.read<RecentlyPlayedProvider>().clearHistory();
          // Also wipe the cloud copy — otherwise the next sign-in (this
          // device or another) pulls the "cleared" history right back
          // down from Supabase, undoing what the user just asked for.
          unawaited(SyncService.instance.clearRemoteHistory());
        }); },
      ),
      AurumSettingsTile.danger(context,
        icon: Icons.recommend_rounded,
        title: l10n.sprResetRecommendations,
        subtitle: l10n.sprResetRecommendationsSubtitle,
        onTap: () { AurumHaptics.medium(); _confirmClear(context, l10n, l10n.sprRecommendationsTitle, () async {
          await RecommendationEngine.resetAll();
        }); },
      ),
      AurumSettingsTile.danger(context,
        icon: Icons.delete_sweep_rounded,
        title: l10n.sprClearAllData,
        subtitle: l10n.sprClearAllDataSubtitle,
        onTap: () { AurumHaptics.heavy(); _confirmClear(context, l10n, l10n.sprAllAppDataTitle, () async {
          // Subtitle promises "playlists, settings, history" — the old
          // implementation only ever cleared SharedPreferences (settings),
          // silently leaving playlists/favorites/follows/history/download
          // cache untouched. This is local-device-only (unlike "Delete
          // Account" above, it never touches Supabase — the cloud copy is
          // left alone so it's still there if the user signs in again).
          final ctx = context;
          if (ctx.mounted) {
            await ctx.read<PlaylistProvider>().clearAll();
            await ctx.read<FollowedArtistsProvider>().clearAll();
            await ctx.read<FollowedAlbumsProvider>().clearAll();
            await ctx.read<FavoritesProvider>().clearAll();
            await ctx.read<RecentlyPlayedProvider>().clearHistory();
          }
          await RecommendationEngine.resetAll();
          final p = await SharedPreferences.getInstance();
          await p.clear();
        }); },
        isDanger: true,
      ),

      // ── DANGER ZONE — ACCOUNT DELETION ───────────────────────────────
      if (context.watch<AuthProvider>().isSignedIn) ...[
        _sectionLabel(context, 'DANGER ZONE'),
        AurumSettingsTile.danger(context,
          icon: Icons.person_remove_rounded,
          title: 'Delete Account',
          subtitle: 'Permanently erase your favorites, playlists, follows and listening history',
          onTap: () { if (!_deletingAccount) _showDeleteAccountSheet(context); },
          isDanger: true,
        ),
      ],
    ];

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, l10n.settingsPrivacy),
      body: ListView(
        // AlwaysScrollableScrollPhysics wraps BouncingScrollPhysics so the
        // bounce still fires even when the content is shorter than the
        // viewport — e.g. before App Lock is turned on, the PIN/biometric/
        // auto-lock sub-rows aren't rendered and this list can be short
        // enough to fit the screen with nothing left to scroll. Plain
        // BouncingScrollPhysics only bounces once content actually
        // overflows; on a short list it silently does nothing, which read
        // as this screen feeling "stuck" compared to longer screens where
        // content naturally overflows and the same physics line works
        // without this wrapper.
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          for (int i = 0; i < rows.length; i++)
            AurumStaggerItem(index: i, child: rows[i]),
        ],
      ),
    );
  }

  void _showDeleteAccountSheet(BuildContext context) {
    showAurumModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: !_deletingAccount,
      enableDrag: !_deletingAccount,
      backgroundColor: AurumTheme.bgCardOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _DeleteAccountSheet(
        onConfirmed: () async {
          if (!mounted) return;
          setState(() => _deletingAccount = true);

          final providerContext = context;
          final error = await AuthService.instance.deleteAllUserData();

          if (error != null) {
            // Server-side delete didn't fully succeed — say so plainly,
            // leave the session and local data untouched so nothing is
            // half-deleted, and let the user retry.
            if (mounted) setState(() => _deletingAccount = false);
            if (sheetContext.mounted) Navigator.pop(sheetContext);
            if (providerContext.mounted) {
              ScaffoldMessenger.of(providerContext).showSnackBar(
                SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
              );
            }
            return;
          }

          // Server-side rows are gone — now clear the local mirrors so
          // nothing stale flashes on screen, then sign out.
          if (providerContext.mounted) {
            await providerContext.read<PlaylistProvider>().clearAll();
            await providerContext.read<FollowedArtistsProvider>().clearAll();
            await providerContext.read<FollowedAlbumsProvider>().clearAll();
            await providerContext.read<FavoritesProvider>().clearAll();
            await providerContext.read<RecentlyPlayedProvider>().clearHistory();
            await providerContext.read<AuthProvider>().signOut();
          }

          if (sheetContext.mounted) Navigator.pop(sheetContext);

          if (providerContext.mounted) {
            // Pop back out of the settings stack to the app root, where
            // the signed-out state naturally lands on the login screen —
            // avoids leaving the user stranded deep in a settings screen
            // that now has nothing signed-in left to show.
            Navigator.of(providerContext).popUntil((route) => route.isFirst);
            ScaffoldMessenger.of(providerContext).showSnackBar(
              const SnackBar(content: Text('Your account data has been deleted.')),
            );
          }
        },
      ),
    );
  }

  void _confirmClear(BuildContext context, AppLocalizations l10n, String title, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AurumTheme.bgCardOf(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.sprClearTitle(title),
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text(l10n.sprClearCannotUndo,
          style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
            child: Text(l10n.sprCancel, style: TextStyle(color: AurumTheme.textSecondaryOf(context)))),
          TextButton(
            onPressed: () { Navigator.pop(context); onConfirm(); },
            child: Text(l10n.sprClear, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// PIN Setup Sheet
// =============================================================================
class _PinSetupSheet extends StatefulWidget {
  final String currentPin;
  final ValueChanged<String> onSave;
  const _PinSetupSheet({required this.currentPin, required this.onSave});

  @override
  State<_PinSetupSheet> createState() => _PinSetupSheetState();
}

class _PinSetupSheetState extends State<_PinSetupSheet> {
  final _step1Controller = TextEditingController();
  final _step2Controller = TextEditingController();
  String _error = '';
  bool   _step2 = false;

  // Keyboard-focus timing (autofocus-during-sheet-entrance-animation bug)
  // is handled centrally by AurumFocusField — see that file for the full
  // history. _step2 is passed as its refocusSignal so stepping from PIN
  // entry to PIN confirmation re-requests focus on the new field without
  // waiting on a route animation a second time.

  void _next(AppLocalizations l10n) {
    if (_step1Controller.text.length < 4) {
      setState(() => _error = l10n.sprPinMustBe4Digits);
      return;
    }
    setState(() { _step2 = true; _error = ''; });
  }

  @override
  void dispose() {
    _step1Controller.dispose();
    _step2Controller.dispose();
    super.dispose();
  }

  void _confirm(AppLocalizations l10n) {
    if (_step1Controller.text != _step2Controller.text) {
      setState(() => _error = l10n.sprPinsDontMatch);
      _step2Controller.clear();
      return;
    }
    widget.onSave(_step1Controller.text);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 36,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AurumTheme.dividerOf(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            _step2 ? l10n.sprConfirmPin : (widget.currentPin.isEmpty ? l10n.sprSetPinSheetTitle : l10n.sprChangePinSheetTitle),
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 18, fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _step2 ? l10n.sprEnterPinAgain : l10n.sprChoose4DigitPin,
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13),
          ),
          const SizedBox(height: 20),
          AurumFocusField(
            refocusSignal: _step2,
            builder: (focusNode) => TextField(
              controller: _step2 ? _step2Controller : _step1Controller,
              focusNode: focusNode,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 4,
              style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 24, letterSpacing: 12),
              decoration: InputDecoration(
                counterText: '',
                hintText: '• • • •',
                hintStyle: TextStyle(color: AurumTheme.textMutedOf(context), letterSpacing: 12),
                filled: true,
                fillColor: AurumTheme.bgOf(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AurumTheme.dividerOf(context)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AurumTheme.accentOf(context)),
                ),
                errorText: _error.isEmpty ? null : _error,
              ),
              onSubmitted: (_) => _step2 ? _confirm(l10n) : _next(l10n),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            if (widget.currentPin.isNotEmpty && !_step2)
              Expanded(
                child: OutlinedButton(
                  onPressed: () { widget.onSave(''); Navigator.pop(context); },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(l10n.sprRemovePin, style: const TextStyle(color: Colors.redAccent)),
                ),
              ),
            if (widget.currentPin.isNotEmpty && !_step2) const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () => _step2 ? _confirm(l10n) : _next(l10n),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AurumTheme.accentOf(context),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: Text(_step2 ? l10n.sprConfirm : l10n.sprNext,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

// =============================================================================
// Delete Account Sheet
// =============================================================================
// Type-to-confirm pattern (same idea as GitHub/Spotify) so this can never
// fire from an accidental tap. onConfirmed handles the actual delete +
// sign-out; this widget only owns the confirmation UI and its own
// in-flight/error state.
class _DeleteAccountSheet extends StatefulWidget {
  final Future<void> Function() onConfirmed;
  const _DeleteAccountSheet({required this.onConfirmed});

  @override
  State<_DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<_DeleteAccountSheet> {
  final _controller = TextEditingController();
  bool _submitting = false;
  bool get _canConfirm => _controller.text.trim().toUpperCase() == 'DELETE';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 36,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AurumTheme.dividerOf(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Icon(Icons.warning_rounded, color: Colors.redAccent, size: 22),
              const SizedBox(width: 10),
              Text('Delete account data',
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 18, fontWeight: FontWeight.w700,
                )),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'This permanently deletes:',
            style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ..._points.map((p) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.close_rounded, color: Colors.redAccent.withOpacity(0.8), size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(p, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13.5)),
                    ),
                  ],
                ),
              )),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.redAccent.withOpacity(0.25)),
            ),
            child: Text(
              'This cannot be undone. Everything above — including your '
              'Google account link — will be removed, and you will be signed '
              'out. Your email stays registered so you can sign back in with '
              'Google later.',
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12.5, height: 1.4),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Type DELETE to confirm',
            style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          AurumFocusField(
            builder: (focusNode) => TextField(
              controller: _controller,
              focusNode: focusNode,
              enabled: !_submitting,
              textCapitalization: TextCapitalization.characters,
              style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 15, letterSpacing: 2),
              decoration: InputDecoration(
                hintText: 'DELETE',
                hintStyle: TextStyle(color: AurumTheme.textMutedOf(context), letterSpacing: 2),
                filled: true,
                fillColor: AurumTheme.bgOf(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AurumTheme.dividerOf(context)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.redAccent),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: TextButton(
                onPressed: _submitting ? null : () => Navigator.pop(context),
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                child: Text('Cancel',
                  style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                onPressed: (!_canConfirm || _submitting) ? null : () async {
                  AurumHaptics.heavy();
                  setState(() => _submitting = true);
                  await widget.onConfirmed();
                  // Sheet is popped by the caller once the flow finishes
                  // (success or error) — if it's still mounted here,
                  // something kept it open, so just release the lock.
                  if (mounted) setState(() => _submitting = false);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.redAccent.withOpacity(0.3),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _submitting
                    ? const SizedBox(
                        height: 18, width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Delete permanently',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  static const _points = [
    'Your favorites',
    'Your playlists',
    'Followed artists and albums',
    'Your listening history',
    'Your Google account, including its link to the app',
    'You will be signed out',
  ];
}

// =============================================================================
// Helpers
// =============================================================================
AppBar _appBar(BuildContext context, String title) => AppBar(
  backgroundColor: AurumTheme.bgOf(context),
  elevation: 0, scrolledUnderElevation: 0,
  leading: IconButton(
    icon: Icon(Icons.arrow_back_ios_new_rounded, color: AurumTheme.textPrimaryOf(context), size: 20),
    onPressed: () => Navigator.pop(context),
  ),
  title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 18, fontWeight: FontWeight.w600)),
);

Widget _sectionLabel(BuildContext context, String label) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
  child: Text(label, style: TextStyle(color: AurumTheme.accentOf(context), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
);

Widget _infoTile(BuildContext context, {
  required IconData icon, required String message, required Color color,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: color.withOpacity(0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withOpacity(0.25)),
    ),
    child: Row(children: [
      Icon(icon, color: color, size: 16),
      const SizedBox(width: 10),
      Expanded(child: Text(message, style: TextStyle(color: color, fontSize: 12))),
    ]),
  );
}
