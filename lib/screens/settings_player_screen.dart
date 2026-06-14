import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';

class SettingsPlayerScreen extends StatefulWidget {
  final AudioHandler? audioHandler;
  const SettingsPlayerScreen({super.key, this.audioHandler});
  @override
  State<SettingsPlayerScreen> createState() => _SettingsPlayerScreenState();
}

class _SettingsPlayerScreenState extends State<SettingsPlayerScreen> {
  // Playback
  String _streamQuality = 'Auto';
  bool _dataSaver = false;
  bool _gapless = true;
  double _playbackSpeed = 1.0;
  // Behavior
  bool _keepQueue = true;
  bool _stopOnSwipe = false;
  bool _pauseOnCall = true; // UI only — audio_session handles this natively
  bool _shakeToSkip = false;
  bool _swipeToChange = true;
  double _historyDuration = 50;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _streamQuality = p.getString('stream_quality') ?? 'Auto';
      _dataSaver = p.getBool('data_saver') ?? false;
      _gapless = p.getBool('gapless') ?? true;
      _playbackSpeed = p.getDouble('playback_speed') ?? 1.0;
      _keepQueue = p.getBool('keep_queue') ?? true;
      _stopOnSwipe = p.getBool('stop_on_swipe') ?? false;
      _pauseOnCall = p.getBool('pause_on_call') ?? true;
      _shakeToSkip = p.getBool('shake_to_skip') ?? false;
      _swipeToChange = p.getBool('swipe_to_change') ?? true;
      _historyDuration = (p.getInt('history_duration') ?? 50).toDouble();
    });
  }

  Future<void> _save(String key, dynamic value) async {
    final p = await SharedPreferences.getInstance();
    if (value is bool) await p.setBool(key, value);
    if (value is double) await p.setDouble(key, value);
    if (value is int) await p.setInt(key, value);
    if (value is String) await p.setString(key, value);
  }

  /// Tell audio handler to reload settings immediately
  Future<void> _notifyHandler() async {
    await widget.audioHandler?.customAction('reloadSettings');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, 'Player & Audio'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          _sectionLabel('🔊 PLAYBACK'),
          _dropdownTile(context,
            icon: Icons.high_quality_rounded,
            title: 'Stream Quality',
            subtitle: 'Audio bitrate for online streaming',
            value: _streamQuality,
            options: ['Auto', 'Low', 'Medium', 'High'],
            onChanged: (v) { setState(() => _streamQuality = v!); _save('stream_quality', v!); },
          ),
          _switchTile(context,
            icon: Icons.data_saver_on_rounded,
            title: 'Data Saver',
            subtitle: 'Force low quality on mobile data',
            value: _dataSaver,
            onChanged: (v) { setState(() => _dataSaver = v); _save('data_saver', v); },
          ),
          _switchTile(context,
            icon: Icons.remove_done_rounded,
            title: 'Gapless Playback',
            subtitle: 'No silence between tracks',
            value: _gapless,
            onChanged: (v) { setState(() => _gapless = v); _save('gapless', v); },
          ),
          // Playback speed
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      color: AurumTheme.gold.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.speed_rounded, color: AurumTheme.gold, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Playback Speed',
                      style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
                    Text('Adjust how fast audio plays',
                      style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
                  ])),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AurumTheme.gold.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _playbackSpeed == 1.0 ? 'Normal' : '${_playbackSpeed}×',
                      style: const TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                Slider(
                  value: _playbackSpeed,
                  min: 0.25, max: 2.0, divisions: 7,
                  onChanged: (v) => setState(() => _playbackSpeed = v),
                  onChangeEnd: (v) async {
                    await _save('playback_speed', v);
                    await _notifyHandler(); // instantly applies to player
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: ['0.25×', '0.5×', '0.75×', '1×', '1.25×', '1.5×', '1.75×', '2×']
                    .map((l) => Text(l, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 9)))
                    .toList(),
                ),
              ]),
            ),
          ),

          const SizedBox(height: 16),
          _sectionLabel('🎛️ EQUALIZER'),
          _navTile(context,
            icon: Icons.graphic_eq_rounded,
            title: 'Equalizer',
            subtitle: '10-band EQ with presets',
            onTap: () => Navigator.of(context).push(_slideRoute(const _EqualizerScreen())),
          ),

          const SizedBox(height: 16),
          _sectionLabel('🎮 BEHAVIOR'),
          _switchTile(context,
            icon: Icons.queue_music_rounded,
            title: 'Keep Player Queue on Reopen',
            subtitle: 'Restore queue after closing app',
            value: _keepQueue,
            onChanged: (v) { setState(() => _keepQueue = v); _save('keep_queue', v); },
          ),
          _switchTile(context,
            icon: Icons.clear_all_rounded,
            title: 'Stop on Swipe from Recents',
            subtitle: 'Stop playback when app is swiped away',
            value: _stopOnSwipe,
            onChanged: (v) { setState(() => _stopOnSwipe = v); _save('stop_on_swipe', v); },
          ),
          _switchTile(context,
            icon: Icons.call_rounded,
            title: 'Pause on Incoming Call',
            subtitle: 'Auto-pauses when phone rings',
            value: _pauseOnCall,
            onChanged: (v) { setState(() => _pauseOnCall = v); _save('pause_on_call', v); },
          ),
          _switchTile(context,
            icon: Icons.vibration_rounded,
            title: 'Shake to Skip Song',
            subtitle: 'Shake phone to go to next track',
            value: _shakeToSkip,
            onChanged: (v) async {
              setState(() => _shakeToSkip = v);
              await _save('shake_to_skip', v);
              await _notifyHandler(); // instantly enables/disables accelerometer
            },
          ),
          _switchTile(context,
            icon: Icons.swipe_rounded,
            title: 'Swipe to Change Song',
            subtitle: 'Swipe on player artwork to skip',
            value: _swipeToChange,
            onChanged: (v) { setState(() => _swipeToChange = v); _save('swipe_to_change', v); },
          ),
          // History duration
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Column(children: [
                Row(children: [
                  Text('History Duration',
                    style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
                  const Spacer(),
                  Text('${_historyDuration.toInt()} songs',
                    style: const TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
                Slider(
                  value: _historyDuration,
                  min: 10, max: 100, divisions: 9,
                  onChanged: (v) { setState(() => _historyDuration = v); _save('history_duration', v.toInt()); },
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Equalizer Screen ───────────────────────────────────────────────────────
class _EqualizerScreen extends StatefulWidget {
  const _EqualizerScreen();
  @override
  State<_EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<_EqualizerScreen> {
  static const _bands = ['32Hz','64Hz','125Hz','250Hz','500Hz','1kHz','2kHz','4kHz','8kHz','16kHz'];
  static const _presets = {
    'Flat':       [0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],
    'Rock':       [4.0,3.0,1.0,0.0,-1.0,-1.0,0.0,2.0,3.0,4.0],
    'Pop':        [-1.0,0.0,2.0,3.0,3.0,2.0,1.0,0.0,-1.0,-2.0],
    'Jazz':       [3.0,2.0,1.0,2.0,-1.0,-1.0,0.0,1.0,2.0,3.0],
    'Bass Boost': [6.0,5.0,4.0,2.0,0.0,0.0,0.0,0.0,0.0,0.0],
    'Vocal':      [-2.0,-1.0,0.0,2.0,4.0,4.0,3.0,2.0,1.0,0.0],
    'Electronic': [5.0,4.0,1.0,0.0,-2.0,1.0,0.0,2.0,4.0,5.0],
  };

  List<double> _values = List.filled(10, 0.0);
  String _selectedPreset = 'Flat';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _selectedPreset = p.getString('eq_preset') ?? 'Flat';
      _values = List.generate(10, (i) => p.getDouble('eq_band_$i') ?? 0.0);
    });
  }

  Future<void> _saveValues() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('eq_preset', _selectedPreset);
    for (int i = 0; i < 10; i++) await p.setDouble('eq_band_$i', _values[i]);
  }

  void _applyPreset(String name) {
    setState(() { _selectedPreset = name; _values = List.from(_presets[name]!); });
    _saveValues();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, 'Equalizer', actions: [
        TextButton(
          onPressed: () => _applyPreset('Flat'),
          child: const Text('Reset', style: TextStyle(color: AurumTheme.gold, fontSize: 14)),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          _sectionLabel('PRESETS'),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: _presets.keys.map((preset) {
              final sel = _selectedPreset == preset;
              return GestureDetector(
                onTap: () => _applyPreset(preset),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgCardOf(context),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: sel ? AurumTheme.gold.withOpacity(0.6) : AurumTheme.dividerOf(context),
                      width: sel ? 1 : 0.5,
                    ),
                  ),
                  child: Text(preset, style: TextStyle(
                    color: sel ? AurumTheme.gold : AurumTheme.textSecondaryOf(context),
                    fontSize: 13, fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  )),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
          _sectionLabel('10-BAND EQ'),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
            ),
            child: Column(
              children: List.generate(10, (i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(width: 44,
                    child: Text(_bands[i],
                      style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11),
                      textAlign: TextAlign.right)),
                  Expanded(
                    child: Slider(
                      value: _values[i], min: -12, max: 12, divisions: 24,
                      onChanged: (v) { setState(() { _values[i] = v; _selectedPreset = 'Custom'; }); },
                      onChangeEnd: (_) => _saveValues(),
                    ),
                  ),
                  SizedBox(width: 38,
                    child: Text(
                      '${_values[i] >= 0 ? '+' : ''}${_values[i].toStringAsFixed(0)}dB',
                      style: TextStyle(
                        color: _values[i] == 0 ? AurumTheme.textMutedOf(context) : AurumTheme.gold,
                        fontSize: 10, fontWeight: FontWeight.w600,
                      ),
                    )),
                ]),
              )),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared helpers ─────────────────────────────────────────────────────────
AppBar _appBar(BuildContext context, String title, {List<Widget>? actions}) => AppBar(
  backgroundColor: AurumTheme.bgOf(context),
  elevation: 0, scrolledUnderElevation: 0,
  leading: IconButton(
    icon: Icon(Icons.arrow_back_ios_new_rounded, color: AurumTheme.textPrimaryOf(context), size: 20),
    onPressed: () => Navigator.pop(context),
  ),
  title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 18, fontWeight: FontWeight.w600)),
  actions: actions,
);

Widget _sectionLabel(String label) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
  child: Text(label, style: const TextStyle(color: AurumTheme.gold, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
);

Widget _switchTile(BuildContext context, {
  required IconData icon, required String title, required String subtitle,
  required bool value, required ValueChanged<bool> onChanged,
}) => Container(
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

Widget _dropdownTile(BuildContext context, {
  required IconData icon, required String title, required String subtitle,
  required String value, required List<String> options, required ValueChanged<String?> onChanged,
}) => Container(
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
      value: value, underline: const SizedBox(),
      dropdownColor: AurumTheme.bgCardOf(context),
      style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600),
      icon: Icon(Icons.keyboard_arrow_down_rounded, color: AurumTheme.gold, size: 18),
      items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
      onChanged: onChanged,
    ),
  ),
);

Widget _navTile(BuildContext context, {
  required IconData icon, required String title, required String subtitle, required VoidCallback onTap,
}) => Container(
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
      decoration: BoxDecoration(color: AurumTheme.gold.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
      child: Icon(icon, color: AurumTheme.gold, size: 18),
    ),
    title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
    subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
    trailing: Icon(Icons.chevron_right_rounded, color: AurumTheme.textMutedOf(context), size: 20),
  ),
);

PageRouteBuilder _slideRoute(Widget screen) => PageRouteBuilder(
  pageBuilder: (_, animation, __) => screen,
  transitionsBuilder: (_, animation, __, child) {
    final tween = Tween(begin: const Offset(1.0, 0.0), end: Offset.zero)
        .chain(CurveTween(curve: Curves.easeOutCubic));
    return SlideTransition(position: animation.drive(tween), child: child);
  },
  transitionDuration: const Duration(milliseconds: 280),
  reverseTransitionDuration: const Duration(milliseconds: 250),
);
