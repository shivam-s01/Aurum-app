import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../services/audio_prefs.dart';

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
  String _lockDelay       = 'After 10 min';
  bool   _dontLockPlaying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _appLock         = p.getBool('app_lock_enabled')    ?? false;
      _biometricLock   = p.getBool('biometric_lock')      ?? false;
      _incognitoMode   = p.getBool('incognito_mode')      ?? false;
      _hideListenStats = p.getBool('hide_listen_stats')   ?? false;
      _appLockPin      = p.getString('app_lock_pin')      ?? '';
      _lockDelay       = p.getString('lock_delay_label')  ?? 'After 10 min';
      _dontLockPlaying = p.getBool('dont_lock_while_playing') ?? false;
    });
  }

  Future<void> _save(String key, dynamic value) async {
    final p = await SharedPreferences.getInstance();
    if (value is bool)   await p.setBool(key, value);
    if (value is String) await p.setString(key, value);
  }

  // ── PIN Setup Sheet ────────────────────────────────────────────────────────
  void _showPinSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, 'Privacy'),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [

          // ── APP LOCK ──────────────────────────────────────────────────
          _sectionLabel('🔒 APP LOCK'),
          _switchTile(context,
            icon: Icons.lock_rounded,
            title: 'App Lock',
            subtitle: _appLockPin.isEmpty
                ? 'Set a PIN to lock the app'
                : 'PIN is set — tap to change',
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
            _navTile(context,
              icon: Icons.pin_rounded,
              title: _appLockPin.isEmpty ? 'Set PIN' : 'Change PIN',
              subtitle: _appLockPin.isEmpty
                  ? 'Required to enable App Lock'
                  : 'Change your 4-digit PIN',
              onTap: () { HapticFeedback.lightImpact(); _showPinSheet(context); },
            ),
            _switchTile(context,
              icon: Icons.fingerprint_rounded,
              title: 'Biometric Unlock',
              subtitle: 'Use fingerprint instead of PIN',
              value: _biometricLock,
              onChanged: (v) {
                setState(() => _biometricLock = v);
                _save('biometric_lock', v);
              },
            ),
            _dropdownTile(context,
              icon: Icons.timer_rounded,
              title: 'Auto-Lock After',
              subtitle: 'How long in background before locking',
              value: _lockDelay,
              options: const ['Immediately', 'After 1 min', 'After 5 min', 'After 10 min', 'After 30 min'],
              onChanged: (v) async {
                setState(() => _lockDelay = v!);
                await _save('lock_delay_label', v!);
                const delays = {
                  'Immediately': 0, 'After 1 min': 1, 'After 5 min': 5,
                  'After 10 min': 10, 'After 30 min': 30,
                };
                final p = await SharedPreferences.getInstance();
                await p.setInt('lock_delay_mins', delays[v] ?? 10);
              },
            ),
            _switchTile(context,
              icon: Icons.music_note_rounded,
              title: 'Don\'t Lock While Playing',
              subtitle: 'App won\'t lock as long as a song is playing',
              value: _dontLockPlaying,
              onChanged: (v) {
                setState(() => _dontLockPlaying = v);
                _save('dont_lock_while_playing', v);
              },
            ),
          ],

          // ── INCOGNITO ─────────────────────────────────────────────────
          _sectionLabel('🕵️ INCOGNITO'),
          _switchTile(context,
            icon: Icons.visibility_off_rounded,
            title: 'Incognito Mode',
            subtitle: 'Songs won\'t appear in history or affect recommendations',
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
              message: 'Incognito is ON — listening history is paused and recommendations won\'t update.',
              color: AurumTheme.gold,
            ),
          _switchTile(context,
            icon: Icons.bar_chart_rounded,
            title: 'Hide Listening Stats',
            subtitle: 'Don\'t track play counts or time listened',
            value: _hideListenStats,
            onChanged: (v) {
              setState(() => _hideListenStats = v);
              _save('hide_listen_stats', v);
              AudioPrefs.setHideListenStats(v);
            },
          ),

          // ── CLEAR DATA ────────────────────────────────────────────────
          _sectionLabel('🗑️ CLEAR DATA'),
          _dangerTile(context,
            icon: Icons.history_rounded,
            title: 'Clear Listening History',
            subtitle: 'Remove all recently played songs',
            onTap: () { HapticFeedback.mediumImpact(); _confirmClear(context, 'Listening History', () async {
              final p = await SharedPreferences.getInstance();
              await p.remove('recently_played');
            }); },
          ),
          _dangerTile(context,
            icon: Icons.recommend_rounded,
            title: 'Reset Recommendations',
            subtitle: 'Clear affinity scores and start fresh',
            onTap: () { HapticFeedback.mediumImpact(); _confirmClear(context, 'Recommendations', () async {
              final p = await SharedPreferences.getInstance();
              final keys = p.getKeys().where((k) => k.startsWith('affinity_'));
              for (final k in keys) await p.remove(k);
            }); },
          ),
          _dangerTile(context,
            icon: Icons.delete_sweep_rounded,
            title: 'Clear All App Data',
            subtitle: 'Reset everything — playlists, settings, history',
            onTap: () { HapticFeedback.heavyImpact(); _confirmClear(context, 'All App Data', () async {
              final p = await SharedPreferences.getInstance();
              await p.clear();
            }); },
            isDanger: true,
          ),
        ],
      ),
    );
  }

  void _confirmClear(BuildContext context, String title, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AurumTheme.bgCardOf(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Clear $title?',
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text('This cannot be undone.',
          style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: AurumTheme.textSecondaryOf(context)))),
          TextButton(
            onPressed: () { Navigator.pop(context); onConfirm(); },
            child: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
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

  @override
  void dispose() {
    _step1Controller.dispose();
    _step2Controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_step1Controller.text.length < 4) {
      setState(() => _error = 'PIN must be 4 digits');
      return;
    }
    setState(() { _step2 = true; _error = ''; });
  }

  void _confirm() {
    if (_step1Controller.text != _step2Controller.text) {
      setState(() => _error = 'PINs don\'t match. Try again.');
      _step2Controller.clear();
      return;
    }
    widget.onSave(_step1Controller.text);
    Navigator.pop(context);
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
          Text(
            _step2 ? 'Confirm PIN' : (widget.currentPin.isEmpty ? 'Set PIN' : 'Change PIN'),
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 18, fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _step2 ? 'Enter the PIN again to confirm' : 'Choose a 4-digit PIN',
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _step2 ? _step2Controller : _step1Controller,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            autofocus: true,
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
                borderSide: const BorderSide(color: AurumTheme.gold),
              ),
              errorText: _error.isEmpty ? null : _error,
            ),
            onSubmitted: (_) => _step2 ? _confirm() : _next(),
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
                  child: const Text('Remove PIN', style: TextStyle(color: Colors.redAccent)),
                ),
              ),
            if (widget.currentPin.isNotEmpty && !_step2) const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _step2 ? _confirm : _next,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AurumTheme.gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: Text(_step2 ? 'Confirm' : 'Next',
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

Widget _sectionLabel(String label) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
  child: Text(label, style: const TextStyle(color: AurumTheme.gold, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
);

Widget _switchTile(BuildContext context, {
  required IconData icon, required String title, required String subtitle,
  required bool value, required ValueChanged<bool> onChanged,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AurumTheme.bgCardOf(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
    ),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: value ? AurumTheme.gold.withOpacity(0.12) : AurumTheme.bgOf(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: value ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 18),
      ),
      title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: Switch(value: value, onChanged: onChanged, activeColor: AurumTheme.gold),
    ),
  );
}

Widget _navTile(BuildContext context, {
  required IconData icon, required String title, required String subtitle,
  required VoidCallback onTap,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AurumTheme.bgCardOf(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
    ),
    child: ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: AurumTheme.gold.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: AurumTheme.gold, size: 18),
      ),
      title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: Icon(Icons.chevron_right_rounded, color: AurumTheme.textMutedOf(context), size: 20),
    ),
  );
}

Widget _dangerTile(BuildContext context, {
  required IconData icon, required String title, required String subtitle,
  required VoidCallback onTap, bool isDanger = false,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AurumTheme.bgCardOf(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: isDanger ? Colors.redAccent.withOpacity(0.3) : AurumTheme.dividerOf(context),
        width: isDanger ? 1 : 0.5,
      ),
    ),
    child: ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: Colors.redAccent, size: 18),
      ),
      title: Text(title, style: TextStyle(
        color: isDanger ? Colors.redAccent : AurumTheme.textPrimaryOf(context),
        fontSize: 14, fontWeight: FontWeight.w500,
      )),
      subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: Icon(Icons.chevron_right_rounded, color: AurumTheme.textMutedOf(context), size: 20),
    ),
  );
}

Widget _dropdownTile(BuildContext context, {
  required IconData icon, required String title, required String subtitle,
  required String value, required List<String> options, required ValueChanged<String?> onChanged,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AurumTheme.bgCardOf(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
    ),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(color: AurumTheme.gold.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: AurumTheme.gold, size: 18),
      ),
      title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: DropdownButton<String>(
        value: value,
        underline: const SizedBox(),
        dropdownColor: AurumTheme.bgCardOf(context),
        style: TextStyle(color: AurumTheme.gold, fontSize: 12, fontWeight: FontWeight.w600),
        icon: Icon(Icons.keyboard_arrow_down_rounded, color: AurumTheme.gold, size: 18),
        items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
        onChanged: onChanged,
      ),
    ),
  );
}

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
