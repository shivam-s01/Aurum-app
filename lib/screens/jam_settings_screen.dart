// ═══════════════════════════════════════════════════════════════════════════
// FILE: lib/screens/jam_settings_screen.dart
// DESCRIPTION: Astra Jam settings — display name, auto-approve join requests,
//   blocked people, server address and a connection log (for support).
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/jam_service.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';

class JamSettingsScreen extends StatefulWidget {
  const JamSettingsScreen({super.key});

  @override
  State<JamSettingsScreen> createState() => _JamSettingsScreenState();
}

class _JamSettingsScreenState extends State<JamSettingsScreen> {
  final _jam = JamService.instance;
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _jam.loadSettings().then((_) {
      if (!mounted) return;
      setState(() {
        _nameCtrl.text = _jam.customName;
        _urlCtrl.text = _jam.customServerUrl;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  bool get _hi => Localizations.localeOf(context).languageCode == 'hi';
  String _t(String en, String h) => _hi ? h : en;

  Widget _card(List<Widget> children) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  InputDecoration _dec(String hint) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AurumTheme.dividerOf(context)),
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AurumTheme.textMutedOf(context)),
      counterText: '',
      filled: true,
      fillColor: AurumTheme.bgOf(context),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide(color: AurumTheme.accentOf(context), width: 1.4)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tp = AurumTheme.textPrimaryOf(context);
    final ts = AurumTheme.textSecondaryOf(context);
    final accent = AurumTheme.accentOf(context);

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: tp),
        title: Text(_t('Jam settings', 'Jam settings'),
            style: TextStyle(color: tp, fontSize: 20, fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : ListenableBuilder(
                listenable: _jam,
                builder: (context, _) {
                  final blocked = _jam.blockedUsers;
                  final logs = _jam.logs;
                  return ListView(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    children: [
                      // Display name
                      _card([
                        Text(_t('Your name in a Jam', 'Jam me aapka naam'),
                            style: TextStyle(color: tp, fontSize: 15.5, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(_t('Leave empty to use your account name.', 'Khaali chhodo to account ka naam use hoga.'),
                            style: TextStyle(color: ts, fontSize: 12.5)),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _nameCtrl,
                          maxLength: 14,
                          textCapitalization: TextCapitalization.words,
                          style: TextStyle(color: tp, fontSize: 16),
                          decoration: _dec(_t('Display name', 'Naam')),
                          onChanged: (v) => _jam.setCustomName(v),
                        ),
                      ]),

                      // Auto approve
                      _card([
                        Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_t('Auto-approve join requests', 'Join requests apne aap manzoor'),
                                  style: TextStyle(color: tp, fontSize: 15.5, fontWeight: FontWeight.w800)),
                              const SizedBox(height: 4),
                              Text(
                                _t('When you host, anyone with the code gets in without asking you. Blocked people are still refused.',
                                    'Host hone par code wala koi bhi bina puche andar aa jayega. Block kiye hue log phir bhi nahi aa payenge.'),
                                style: TextStyle(color: ts, fontSize: 12.5, height: 1.35),
                              ),
                            ]),
                          ),
                          Switch(
                            value: _jam.autoApprove,
                            activeColor: accent,
                            onChanged: (v) {
                              AurumHaptics.selection();
                              _jam.setAutoApprove(v);
                            },
                          ),
                        ]),
                      ]),

                      // Blocked
                      _card([
                        Text(_t('Blocked people', 'Block kiye hue log'),
                            style: TextStyle(color: tp, fontSize: 15.5, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(
                          _t('They can’t join your Jam or suggest songs.', 'Ye log aapke Jam me join ya suggest nahi kar sakte.'),
                          style: TextStyle(color: ts, fontSize: 12.5),
                        ),
                        const SizedBox(height: 8),
                        if (blocked.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(_t('Nobody blocked.', 'Kisi ko block nahi kiya.'),
                                style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13.5)),
                          )
                        else
                          for (final name in blocked)
                            Row(key: ValueKey(name), children: [
                              Expanded(child: Text(name, style: TextStyle(color: tp, fontSize: 14.5, fontWeight: FontWeight.w600))),
                              TextButton(
                                onPressed: () {
                                  AurumHaptics.light();
                                  _jam.unblockUser(name);
                                },
                                child: Text(_t('Unblock', 'Unblock'),
                                    style: TextStyle(color: accent, fontWeight: FontWeight.w800)),
                              ),
                            ]),
                      ]),

                      // Server
                      _card([
                        Text(_t('Own server (optional)', 'Apna server (optional)'),
                            style: TextStyle(color: tp, fontSize: 15.5, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(_t('Leave empty to use the default server. Fill this only if you run your own Jam server.', 'Khaali chhodo to default server chalega. Apna Jam server ho tabhi bharo.'),
                            style: TextStyle(color: ts, fontSize: 12.5)),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _urlCtrl,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.url,
                          style: TextStyle(color: tp, fontSize: 14),
                          decoration: _dec('wss://your-server/jam/ws'),
                          onSubmitted: (v) async {
                            await _jam.setServerUrl(v);
                            if (mounted) _urlCtrl.text = _jam.customServerUrl;
                          },
                        ),
                        const SizedBox(height: 6),
                        Row(children: [
                          TextButton(
                            onPressed: () async {
                              await _jam.setServerUrl(_urlCtrl.text);
                              if (mounted) _urlCtrl.text = _jam.customServerUrl;
                            },
                            child: Text(_t('Save', 'Save'), style: TextStyle(color: accent, fontWeight: FontWeight.w800)),
                          ),
                          TextButton(
                            onPressed: () async {
                              await _jam.setServerUrl('');
                              if (mounted) _urlCtrl.text = _jam.customServerUrl;
                            },
                            child: Text(_t('Reset', 'Reset'), style: TextStyle(color: ts, fontWeight: FontWeight.w700)),
                          ),
                        ]),
                      ]),

                      // Log
                      _card([
                        Row(children: [
                          Expanded(
                            child: Text(_t('Connection log', 'Connection log'),
                                style: TextStyle(color: tp, fontSize: 15.5, fontWeight: FontWeight.w800)),
                          ),
                          TextButton(
                            onPressed: logs.isEmpty
                                ? null
                                : () {
                                    Clipboard.setData(ClipboardData(text: logs.join('\n')));
                                    ScaffoldMessenger.of(context)
                                      ..hideCurrentSnackBar()
                                      ..showSnackBar(SnackBar(
                                        content: Text(_t('Log copied', 'Log copy ho gaya')),
                                        behavior: SnackBarBehavior.floating,
                                        duration: const Duration(seconds: 2),
                                      ));
                                  },
                            child: Text(_t('Copy', 'Copy'), style: TextStyle(color: accent, fontWeight: FontWeight.w800)),
                          ),
                          TextButton(
                            onPressed: logs.isEmpty ? null : _jam.clearLogs,
                            child: Text(_t('Clear', 'Clear'), style: TextStyle(color: ts, fontWeight: FontWeight.w700)),
                          ),
                        ]),
                        const SizedBox(height: 6),
                        if (logs.isEmpty)
                          Text(_t('Nothing yet.', 'Abhi kuch nahi.'),
                              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13))
                        else
                          Text(
                            logs.reversed.take(40).join('\n'),
                            style: TextStyle(color: ts, fontSize: 11.5, height: 1.45, fontFamily: 'monospace'),
                          ),
                      ]),
                    ],
                  );
                },
              ),
      ),
    );
  }
}
