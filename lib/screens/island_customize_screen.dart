import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_prefs.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';

/// Full-screen Dynamic Island customization page — replaces the old
/// bottom sheet (left/center/right dropdown only). Reached by tapping the
/// "Dynamic Island" row in Settings -> Player & Audio. Every control here
/// writes straight to SharedPreferences under dedicated dp-based keys and
/// immediately tells a running overlay to re-apply itself via
/// AudioPrefs.updateIslandCustomization(), so if the Island is already up
/// (song playing, app backgrounded) it visibly updates live while this
/// page is open — same "drag = live preview" contract the old sheet had,
/// just with real X/Y/width/height control instead of a 3-way dropdown.
class IslandCustomizeScreen extends StatefulWidget {
  const IslandCustomizeScreen({super.key});

  @override
  State<IslandCustomizeScreen> createState() => _IslandCustomizeScreenState();
}

class _IslandCustomizeScreenState extends State<IslandCustomizeScreen> {
  static const _kEnabled = 'island_enabled';
  static const _kX = 'island_x_dp';
  static const _kY = 'island_y_dp';
  static const _kWidth = 'island_width_dp';
  static const _kHeight = 'island_height_dp';
  static const _kColor = 'island_accent_color';
  static const _kDoublePrefix = 'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu';

  // Defaults chosen to match the old top_center / 1.0 scale look so
  // existing users see no visual jump the first time they open this page.
  static const double _defaultWidth = 101.0;
  static const double _defaultHeight = 32.0;
  static const int _defaultAccent = 0xFFB89640;

  static const _swatches = <int>[
    0xFFB89640, // Aurum gold (default)
    0xFFE91429, // Spotify red
    0xFF1DB954, // Spotify green
    0xFF3B82F6, // Blue
    0xFFA855F7, // Purple
    0xFFEC4899, // Pink
    0xFFFFFFFF, // White
  ];

  bool _enabled = false;
  double _x = 0;
  double _y = 8;
  double _width = _defaultWidth;
  double _height = _defaultHeight;
  int _accentColor = _defaultAccent;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    // Guard against a corrupt/out-of-range persisted value (e.g. from a
    // future build with a wider range) ever reaching the Slider widget,
    // which throws if value is NaN or outside min/max.
    double safeDouble(Object? raw, double fallback, double min, double max) {
      double? v;
      if (raw is num) {
        v = raw.toDouble();
      } else if (raw is String) {
        v = double.tryParse(raw.replaceFirst(_kDoublePrefix, ''));
      }
      if (v == null || v.isNaN || v.isInfinite) return fallback;
      return v.clamp(min, max);
    }

    setState(() {
      _enabled = p.getBool(_kEnabled) ?? false;
      _x = safeDouble(p.get(_kX), 0, -500, 500);
      _y = safeDouble(p.get(_kY), 8, 0, 900);
      _width = safeDouble(p.get(_kWidth), _defaultWidth, 90, 360);
      _height = safeDouble(p.get(_kHeight), _defaultHeight, 32, 96);
      _accentColor = p.getInt(_kColor) ?? _defaultAccent;
      _loaded = true;
    });
  }

  Future<void> _push() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kX, _x);
    await p.setDouble(_kY, _y);
    await p.setDouble(_kWidth, _width);
    await p.setDouble(_kHeight, _height);
    await p.setInt(_kColor, _accentColor);
    await AudioPrefs.updateIslandCustomization();
  }

  Future<void> _toggleEnabled(bool v) async {
    final applied = await AudioPrefs.setIslandEnabled(v);
    final resolved = applied ? v : false;
    setState(() => _enabled = resolved);
    if (v && !applied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Allow "Display over other apps" to turn this on')),
      );
    }
  }

  Future<void> _resetDefaults() async {
    AurumHaptics.selection();
    setState(() {
      _x = 0;
      _y = 8;
      _width = _defaultWidth;
      _height = _defaultHeight;
      _accentColor = _defaultAccent;
    });
    await _push();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        elevation: 0,
        iconTheme: IconThemeData(color: AurumTheme.textPrimaryOf(context)),
        title: Text('Dynamic Island',
            style: TextStyle(color: AurumTheme.textPrimaryOf(context),
                fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                _enableCard(context),
                const SizedBox(height: 20),
                if (_enabled) ...[
                  _sectionCard(
                    context: context,
                    title: 'Position',
                    children: [
                      _positionStage(context),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _sectionCard(
                    context: context,
                    title: 'Size',
                    children: [
                      _slider(
                        context: context,
                        label: 'Island Width',
                        value: _width,
                        min: 90,
                        max: 360,
                        suffix: 'dp',
                        onChanged: (v) {
                          setState(() => _width = v);
                          _push();
                        },
                      ),
                      _slider(
                        context: context,
                        label: 'Island Height',
                        value: _height,
                        min: 32,
                        max: 96,
                        suffix: 'dp',
                        onChanged: (v) {
                          setState(() => _height = v);
                          _push();
                        },
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _resetDefaults,
                          child: Text('Reset to Defaults',
                              style: TextStyle(color: AurumTheme.accentOf(context),
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _sectionCard(
                    context: context,
                    title: 'Styling & Custom Colors',
                    children: [
                      Text('Background Color',
                          style: TextStyle(color: AurumTheme.textPrimaryOf(context),
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 14,
                        runSpacing: 14,
                        children: _swatches.map((c) => _colorSwatch(context, c)).toList(),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The pill IS the position control: drag it anywhere on this mock of the
  /// top of the phone (up / down / left / right). Same coordinate system as
  /// the real overlay (dp from horizontal center / dp from top), scaled to
  /// fit. Snaps softly to the center line. The real island never draws
  /// inside the app — it only appears once Aurum is minimized.
  Widget _positionStage(BuildContext context) {
    const stageDpH = 320.0; // top slice of the screen shown in the stage
    final screenW = MediaQuery.of(context).size.width;
    final stageW = screenW - 40 - 32; // list padding + card padding
    final scale = stageW / screenW;
    final stageH = stageDpH * scale;

    final maxX = ((screenW - _width) / 2).clamp(0.0, double.infinity);
    final maxY = (stageDpH - _height).clamp(0.0, double.infinity);
    final dx = _x.clamp(-maxX, maxX).toDouble();
    final dy = _y.clamp(0.0, maxY).toDouble();

    final pillW = _width * scale;
    final pillH = _height * scale;
    final accent = Color(_accentColor);
    final centered = dx.abs() < 0.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) {
            var nx = (_x + d.delta.dx / scale).clamp(-maxX, maxX).toDouble();
            final ny = (_y + d.delta.dy / scale).clamp(0.0, maxY).toDouble();
            final wasCentered = _x.abs() < 0.5;
            if (nx.abs() < 6) nx = 0;
            if (nx == 0 && !wasCentered) AurumHaptics.selection();
            setState(() {
              _x = nx;
              _y = ny;
            });
          },
          onPanEnd: (_) => _push(),
          onPanCancel: _push,
          child: Container(
            width: stageW,
            height: stageH,
            decoration: BoxDecoration(
              color: const Color(0xFF050508),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                // center guide
                Positioned(
                  left: stageW / 2 - 0.5,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 1,
                    color: centered ? accent.withOpacity(0.55) : Colors.white10,
                  ),
                ),
                // status-bar hint + camera dot
                const Positioned(
                  left: 14, top: 8,
                  child: Text('9:41',
                      style: TextStyle(color: Colors.white24, fontSize: 10, fontWeight: FontWeight.w600)),
                ),
                const Positioned(
                  right: 14, top: 8,
                  child: Icon(Icons.battery_full_rounded, color: Colors.white24, size: 14),
                ),
                Positioned(
                  left: stageW / 2 - 4,
                  top: 6,
                  child: Container(
                    width: 8, height: 8,
                    decoration: const BoxDecoration(color: Colors.white12, shape: BoxShape.circle),
                  ),
                ),
                // the island (drag me)
                Positioned(
                  left: stageW / 2 - pillW / 2 + dx * scale,
                  top: dy * scale,
                  child: Container(
                    width: pillW,
                    height: pillH,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(pillH / 2),
                      border: Border.all(color: accent.withOpacity(0.55), width: 1.2),
                    ),
                    padding: EdgeInsets.symmetric(horizontal: pillH * 0.22),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          width: pillH * 0.6,
                          height: pillH * 0.6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent.withOpacity(0.22),
                          ),
                          child: Icon(Icons.music_note_rounded,
                              color: accent, size: (pillH * 0.38).clamp(8.0, 18.0)),
                        ),
                        Icon(Icons.graphic_eq_rounded,
                            color: accent, size: (pillH * 0.5).clamp(10.0, 22.0)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text('Drag the island anywhere',
                  style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context).withOpacity(0.6),
                      fontSize: 12)),
            ),
            Text('X ${dx.round()}  •  Y ${dy.round()} dp',
                style: TextStyle(
                    color: AurumTheme.accentOf(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ],
    );
  }

  Widget _enableCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: AurumTheme.accentOf(context).withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.music_note_rounded, color: AurumTheme.accentOf(context)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Enable Dynamic Island',
                    style: TextStyle(color: AurumTheme.textPrimaryOf(context),
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Displays live rotating artwork, squiggly seekbar, and player controls overlay',
                  style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12),
                ),
              ],
            ),
          ),
          Switch(
            value: _enabled,
            activeColor: AurumTheme.accentOf(context),
            onChanged: _toggleEnabled,
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required BuildContext context,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(color: AurumTheme.accentOf(context),
                  fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _slider({
    required BuildContext context,
    required String label,
    required double value,
    required double min,
    required double max,
    required String suffix,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: TextStyle(color: AurumTheme.textPrimaryOf(context),
                      fontSize: 13, fontWeight: FontWeight.w600)),
              Text('${value.round()} $suffix',
                  style: TextStyle(color: AurumTheme.accentOf(context),
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              activeColor: AurumTheme.accentOf(context),
              inactiveColor: AurumTheme.accentOf(context).withOpacity(0.15),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _colorSwatch(BuildContext context, int c) {
    final selected = c == _accentColor;
    return GestureDetector(
      onTap: () {
        AurumHaptics.selection();
        setState(() => _accentColor = c);
        _push();
      },
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: Color(c),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AurumTheme.accentOf(context) : AurumTheme.dividerOf(context),
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(Icons.check_rounded,
                color: c == 0xFFFFFFFF ? Colors.black : Colors.white, size: 18)
            : null,
      ),
    );
  }
}
