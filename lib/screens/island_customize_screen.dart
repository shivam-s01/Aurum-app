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
    double safeDouble(double? v, double fallback, double min, double max) {
      if (v == null || v.isNaN || v.isInfinite) return fallback;
      return v.clamp(min, max);
    }

    setState(() {
      _enabled = p.getBool(_kEnabled) ?? false;
      _x = safeDouble(p.getDouble(_kX), 0, -150, 150);
      _y = safeDouble(p.getDouble(_kY), 8, 0, 300);
      _width = safeDouble(p.getDouble(_kWidth), _defaultWidth, 90, 360);
      _height = safeDouble(p.getDouble(_kHeight), _defaultHeight, 32, 96);
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
          // Live mock preview — the real overlay is intentionally hidden
          // while Aurum itself is in the foreground (it would otherwise
          // draw on top of this very screen), so dragging a slider here
          // has nothing on-screen to visibly move. This mock strip mirrors
          // the pill's exact X/Y/width/height/color in real time instead,
          // giving the same "drag = see it move" feedback the sliders are
          // supposed to provide, without needing the real overlay visible.
          if (_enabled) _livePreview(context),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                _enableCard(context),
                const SizedBox(height: 20),
                if (_enabled) ...[
                  _sectionCard(
                    context: context,
                    title: 'Position & Size Adjustment',
                    children: [
                      _slider(
                        context: context,
                        label: 'Horizontal Position (X)',
                        value: _x,
                        min: -150,
                        max: 150,
                        suffix: 'dp',
                        onChanged: (v) {
                          setState(() => _x = v);
                          _push();
                        },
                      ),
                      _slider(
                        context: context,
                        label: 'Vertical Position (Y)',
                        value: _y,
                        min: 0,
                        max: 300,
                        suffix: 'dp',
                        onChanged: (v) {
                          setState(() => _y = v);
                          _push();
                        },
                      ),
                      const Divider(height: 32),
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

  /// Mock pill strip that mirrors the real overlay's X/Y/width/height/color
  /// live as the sliders move. Sized down to fit inline at the top of this
  /// screen (a fixed 90dp-tall stage, matching the real overlay's Y-slider
  /// max of 300dp scaled to fit) rather than 1:1 physical dp, since the
  /// real pill sits above the status bar/camera cutout, which this screen
  /// doesn't have room to reproduce full-scale.
  Widget _livePreview(BuildContext context) {
    const stageHeight = 96.0;
    const stageMaxY = 300.0; // matches the Y slider's own max
    final screenWidth = MediaQuery.of(context).size.width;
    // Scale factor so the widest possible pill (360dp) and the tallest
    // possible Y offset (300dp) both stay inside the stage without needing
    // per-frame clamping logic beyond a simple min().
    final scale = (stageHeight / stageMaxY).clamp(0.0, 1.0);

    final previewWidth = (_width * scale).clamp(24.0, screenWidth - 32);
    final previewHeight = (_height * scale).clamp(12.0, stageHeight);
    final previewY = (_y * scale).clamp(0.0, stageHeight - previewHeight);
    final previewX = _x * scale;

    return Container(
      height: stageHeight,
      width: double.infinity,
      color: Colors.black,
      child: Stack(
        children: [
          Positioned(
            top: previewY,
            left: (screenWidth / 2) - (previewWidth / 2) + previewX,
            child: Container(
              width: previewWidth,
              height: previewHeight,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(previewHeight / 2),
                border: Border.all(color: Color(_accentColor), width: 1.5),
              ),
              child: Center(
                child: Icon(Icons.graphic_eq_rounded,
                    color: Color(_accentColor), size: (previewHeight * 0.5).clamp(10.0, 20.0)),
              ),
            ),
          ),
        ],
      ),
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
