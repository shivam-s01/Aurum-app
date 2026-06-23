import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../providers/theme_provider.dart';

class SettingsAppearanceScreen extends StatefulWidget {
  const SettingsAppearanceScreen({super.key});
  @override
  State<SettingsAppearanceScreen> createState() => _SettingsAppearanceScreenState();
}

class _SettingsAppearanceScreenState extends State<SettingsAppearanceScreen> {
  // Theme
  bool _dynamicThemeColor = true;
  bool _highRefreshRate = true;
  Color _accentColor = AurumTheme.gold;
  // Player
  String _playerBgStyle = 'Blur';
  bool _dynamicPlayerColor = true;
  String _playerButtonColors = 'Primary';
  String _playerSliderStyle = 'Rounded';
  bool _showBlurredBg = true;
  // Mini Player
  String _miniPlayerBgStyle = 'Follow Theme';
  double _swipeSensitivity = 50.0;
  // Lyrics
  String _lyricsTextPosition = 'Centre';
  double _lyricsTextSize = 16.0;
  double _lyricsLineSpacing = 1.5;
  String _wordAnimationStyle = 'Fade';
  bool _glowingLyrics = true;
  // New
  String _fontStyle = 'Default';
  String _nowPlayingCardStyle = 'Card';
  String _artworkShape = 'Rounded';
  // Animations
  bool _enableAnimations = true;
  bool _backAnimations = true;
  bool _scrollAnimations = true;
  bool _bgGradientAnimation = true;

  static const List<Color> _accentOptions = [
    Color(0xFFB89640), Color(0xFF2196F3), Color(0xFFE91E63),
    Color(0xFF4CAF50), Color(0xFF9C27B0), Color(0xFFFF5722),
    Color(0xFF00BCD4), Color(0xFFFF9800),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _dynamicThemeColor = p.getBool('dynamic_theme_color') ?? true;
      _highRefreshRate = p.getBool('high_refresh_rate') ?? true;
      _accentColor = Color(p.getInt('accent_color') ?? AurumTheme.gold.value);
      _playerBgStyle = p.getString('player_bg_style') ?? 'Blur';
      _dynamicPlayerColor = p.getBool('dynamic_player_color') ?? true;
      _playerButtonColors = p.getString('player_button_colors') ?? 'Primary';
      _playerSliderStyle = p.getString('player_slider_style') ?? 'Rounded';
      _showBlurredBg = p.getBool('show_blurred_bg') ?? true;
      _miniPlayerBgStyle = p.getString('mini_player_bg_style') ?? 'Follow Theme';
      _swipeSensitivity = p.getDouble('swipe_sensitivity') ?? 50.0;
      _lyricsTextPosition = p.getString('lyrics_text_position') ?? 'Centre';
      _lyricsTextSize = p.getDouble('lyrics_text_size') ?? 16.0;
      _lyricsLineSpacing = p.getDouble('lyrics_line_spacing') ?? 1.5;
      _wordAnimationStyle = p.getString('word_animation_style') ?? 'Fade';
      _glowingLyrics = p.getBool('glowing_lyrics') ?? true;
      _enableAnimations = p.getBool('enable_animations') ?? true;
      _backAnimations = p.getBool('back_animations') ?? true;
      _scrollAnimations = p.getBool('scroll_animations') ?? true;
      _bgGradientAnimation = p.getBool('bg_gradient_animation') ?? true;
      _fontStyle           = p.getString('font_style') ?? 'Default';
      _nowPlayingCardStyle = p.getString('now_playing_card_style') ?? 'Card';
      _artworkShape        = p.getString('artwork_shape') ?? 'Rounded';
    });
  }

  Future<void> _save(String key, dynamic value) async {
    final p = await SharedPreferences.getInstance();
    if (value is bool) await p.setBool(key, value);
    if (value is double) await p.setDouble(key, value);
    if (value is int) await p.setInt(key, value);
    if (value is String) await p.setString(key, value);
  }

  @override
  Widget build(BuildContext context) {
    final tp = context.watch<ThemeProvider>();
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, 'Appearance'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          // ── Theme ──
          _sectionLabel('🌙 THEME'),
          _card(context, child: Column(children: [
            _themeTile(context, tp, Icons.dark_mode_rounded, 'Dark', 'Easy on the eyes', AurumThemeMode.dark),
            _divider(context),
            _themeTile(context, tp, Icons.contrast_rounded, 'AMOLED Black', 'Pure black, saves battery', AurumThemeMode.amoled),
            _divider(context),
            _themeTile(context, tp, Icons.light_mode_rounded, 'Light', 'Clean and minimal', AurumThemeMode.light),
            _divider(context),
            _themeTile(context, tp, Icons.phone_android_rounded, 'System Default', 'Follow your phone theme', AurumThemeMode.system),
          ])),
          const SizedBox(height: 8),
          _inlineSwitch(context,
            title: 'Dynamic Theme Color',
            subtitle: 'Extract color from song artwork',
            value: _dynamicThemeColor,
            onChanged: (v) { setState(() => _dynamicThemeColor = v); _save('dynamic_theme_color', v); },
          ),
          _inlineSwitch(context,
            title: 'High Refresh Rate (120Hz)',
            subtitle: 'Smoother UI on supported devices',
            value: _highRefreshRate,
            onChanged: (v) { setState(() => _highRefreshRate = v); _save('high_refresh_rate', v); },
          ),
          // Accent color
          _card(context, child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Accent Color', style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                children: _accentOptions.map((c) {
                  final sel = _accentColor.value == c.value;
                  return GestureDetector(
                    onTap: () { setState(() => _accentColor = c); _save('accent_color', c.value); },
                    child: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: sel ? Border.all(color: Colors.white, width: 2.5) : null,
                        boxShadow: sel ? [BoxShadow(color: c.withOpacity(0.5), blurRadius: 8)] : null,
                      ),
                      child: sel ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                    ),
                  );
                }).toList(),
              ),
            ]),
          )),
          // ── Font Style ──
          _sectionLabel('🔤 FONT STYLE'),
          _buildFontSelector(context),

          // ── Now Playing Card Style ──
          _sectionLabel('🎴 NOW PLAYING CARD'),
          _buildCardStyleSelector(context),

          // ── Artwork Shape ──
          _sectionLabel('🖼️ ARTWORK SHAPE'),
          _buildArtworkShapeSelector(context),

          // ── Player ──
          _sectionLabel('🎭 PLAYER'),
          _dropdownTile(context,
            title: 'Player Background Style',
            subtitle: 'How the player background looks',
            value: _playerBgStyle,
            options: ['Gradient', 'Blur', 'Solid'],
            onChanged: (v) { setState(() => _playerBgStyle = v!); _save('player_bg_style', v!); },
          ),
          _inlineSwitch(context,
            title: 'Dynamic Player Color',
            subtitle: 'Change player color from artwork',
            value: _dynamicPlayerColor,
            onChanged: (v) { setState(() => _dynamicPlayerColor = v); _save('dynamic_player_color', v); },
          ),
          _dropdownTile(context,
            title: 'Player Button Colors',
            subtitle: 'Color of play/skip buttons',
            value: _playerButtonColors,
            options: ['Primary', 'White', 'Accent'],
            onChanged: (v) { setState(() => _playerButtonColors = v!); _save('player_button_colors', v!); },
          ),
          _dropdownTile(context,
            title: 'Player Slider Style',
            subtitle: 'Seek bar appearance',
            value: _playerSliderStyle,
            options: ['Slim', 'Thick', 'Rounded'],
            onChanged: (v) { setState(() => _playerSliderStyle = v!); _save('player_slider_style', v!); },
          ),
          _inlineSwitch(context,
            title: 'Show Blurred Background',
            subtitle: 'Artwork blur behind player',
            value: _showBlurredBg,
            onChanged: (v) { setState(() => _showBlurredBg = v); _save('show_blurred_bg', v); },
          ),
          // ── Mini Player ──
          _sectionLabel('⬇️ MINI PLAYER'),
          _dropdownTile(context,
            title: 'Mini Player Background Style',
            subtitle: 'Appearance of collapsed player',
            value: _miniPlayerBgStyle,
            options: ['Follow Theme', 'Blur', 'Solid'],
            onChanged: (v) { setState(() => _miniPlayerBgStyle = v!); _save('mini_player_bg_style', v!); },
          ),
          _sliderTile(context,
            title: 'Swipe Sensitivity',
            value: _swipeSensitivity,
            min: 0, max: 100, divisions: 10,
            displayValue: '${_swipeSensitivity.toInt()}%',
            onChanged: (v) { setState(() => _swipeSensitivity = v); _save('swipe_sensitivity', v); },
          ),
          // ── Lyrics ──
          _sectionLabel('🎤 LYRICS'),
          _dropdownTile(context,
            title: 'Lyrics Text Position',
            subtitle: 'Alignment of lyrics on screen',
            value: _lyricsTextPosition,
            options: ['Left', 'Centre'],
            onChanged: (v) { setState(() => _lyricsTextPosition = v!); _save('lyrics_text_position', v!); },
          ),
          _sliderTile(context,
            title: 'Lyrics Text Size',
            value: _lyricsTextSize,
            min: 10, max: 28, divisions: 9,
            displayValue: '${_lyricsTextSize.toInt()}sp',
            onChanged: (v) { setState(() => _lyricsTextSize = v); _save('lyrics_text_size', v); },
          ),
          _sliderTile(context,
            title: 'Lyrics Line Spacing',
            value: _lyricsLineSpacing,
            min: 1.0, max: 3.0, divisions: 8,
            displayValue: _lyricsLineSpacing.toStringAsFixed(1),
            onChanged: (v) { setState(() => _lyricsLineSpacing = v); _save('lyrics_line_spacing', v); },
          ),
          _dropdownTile(context,
            title: 'Word Animation Style',
            subtitle: 'How lyrics highlight word by word',
            value: _wordAnimationStyle,
            options: ['None', 'Fade', 'Bounce', 'Slide'],
            onChanged: (v) { setState(() => _wordAnimationStyle = v!); _save('word_animation_style', v!); },
          ),
          _inlineSwitch(context,
            title: 'Glowing Lyrics Effect',
            subtitle: 'Glow on active lyric line',
            value: _glowingLyrics,
            onChanged: (v) { setState(() => _glowingLyrics = v); _save('glowing_lyrics', v); },
          ),
          // ── Animations ──
          _sectionLabel('✨ ANIMATIONS'),
          _inlineSwitch(context,
            title: 'Enable Animations',
            subtitle: 'Master toggle for all animations',
            value: _enableAnimations,
            onChanged: (v) { setState(() => _enableAnimations = v); _save('enable_animations', v); },
          ),
          _inlineSwitch(context,
            title: 'Back Animations',
            subtitle: 'Animate navigation back gesture',
            value: _backAnimations,
            onChanged: (v) { setState(() => _backAnimations = v); _save('back_animations', v); },
          ),
          _inlineSwitch(context,
            title: 'Scroll Animations',
            subtitle: 'Fade in items while scrolling',
            value: _scrollAnimations,
            onChanged: (v) { setState(() => _scrollAnimations = v); _save('scroll_animations', v); },
          ),
          _inlineSwitch(context,
            title: 'Background Gradient Animation',
            subtitle: 'Animated color shift in player',
            value: _bgGradientAnimation,
            onChanged: (v) { setState(() => _bgGradientAnimation = v); _save('bg_gradient_animation', v); },
          ),
        ],
      ),
    );
  }

  // ── Font Selector ────────────────────────────────────────────────────────
  Widget _buildFontSelector(BuildContext context) {
    const fonts = {
      'Default':  'Aa',
      'Rounded':  'Aa',
      'Mono':     'Aa',
    };
    const fontFamilies = {
      'Default': null,
      'Rounded': 'Nunito',
      'Mono':    'RobotoMono',
    };
    return _card(context, child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('App Font', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
        const SizedBox(height: 12),
        Row(
          children: fonts.entries.map((e) {
            final sel = _fontStyle == e.key;
            return Expanded(
              child: GestureDetector(
                onTap: () {
                  setState(() => _fontStyle = e.key);
                  _save('font_style', e.key);
                  context.read<ThemeProvider>().setFontStyle(e.key);
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: sel ? AurumTheme.gold.withOpacity(0.12) : AurumTheme.bgOf(context),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: sel ? AurumTheme.gold.withOpacity(0.6) : AurumTheme.dividerOf(context),
                      width: sel ? 1 : 0.5,
                    ),
                  ),
                  child: Column(children: [
                    Text(
                      e.value,
                      style: TextStyle(
                        fontFamily: fontFamilies[e.key],
                        color: sel ? AurumTheme.gold : AurumTheme.textPrimaryOf(context),
                        fontSize: 22, fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      e.key,
                      style: TextStyle(
                        color: sel ? AurumTheme.gold : AurumTheme.textMutedOf(context),
                        fontSize: 11,
                      ),
                    ),
                  ]),
                ),
              ),
            );
          }).toList(),
        ),
      ]),
    ));
  }

  // ── Now Playing Card Style ────────────────────────────────────────────────
  Widget _buildCardStyleSelector(BuildContext context) {
    const styles = {
      'Compact':   Icons.view_headline_rounded,
      'Card':      Icons.crop_square_rounded,
      'Immersive': Icons.fullscreen_rounded,
    };
    const subtitles = {
      'Compact':   'Small artwork, text beside',
      'Card':      'Balanced artwork + info',
      'Immersive': 'Full-width artwork, minimal UI',
    };
    return _card(context, child: Column(
      children: styles.entries.map((e) {
        final sel = _nowPlayingCardStyle == e.key;
        final isLast = e.key == 'Immersive';
        return Column(children: [
          ListTile(
            onTap: () {
              setState(() => _nowPlayingCardStyle = e.key);
              _save('now_playing_card_style', e.key);
            },
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            leading: Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: sel ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgOf(context),
                borderRadius: BorderRadius.circular(10),
                border: sel ? Border.all(color: AurumTheme.gold.withOpacity(0.5)) : null,
              ),
              child: Icon(e.value, color: sel ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 18),
            ),
            title: Text(e.key,
                style: TextStyle(
                  color: sel ? AurumTheme.gold : AurumTheme.textPrimaryOf(context),
                  fontSize: 14, fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                )),
            subtitle: Text(subtitles[e.key]!,
                style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
            trailing: Icon(
              sel ? Icons.check_circle_rounded : Icons.circle_outlined,
              color: sel ? AurumTheme.gold : AurumTheme.textMutedOf(context),
              size: 20,
            ),
          ),
          if (!isLast) _divider(context),
        ]);
      }).toList(),
    ));
  }

  // ── Artwork Shape ─────────────────────────────────────────────────────────
  Widget _buildArtworkShapeSelector(BuildContext context) {
    const shapes = ['Square', 'Rounded', 'Circle'];
    final previews = {
      'Square':  BorderRadius.circular(4),
      'Rounded': BorderRadius.circular(12),
      'Circle':  BorderRadius.circular(40),
    };
    return _card(context, child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: shapes.map((s) {
          final sel = _artworkShape == s;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() => _artworkShape = s);
                _save('artwork_shape', s);
              },
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: sel ? AurumTheme.gold.withOpacity(0.12) : AurumTheme.bgOf(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: sel ? AurumTheme.gold.withOpacity(0.6) : AurumTheme.dividerOf(context),
                    width: sel ? 1 : 0.5,
                  ),
                ),
                child: Column(children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: sel ? AurumTheme.gold.withOpacity(0.3) : AurumTheme.dividerOf(context),
                      borderRadius: previews[s],
                    ),
                    child: sel ? const Icon(Icons.music_note_rounded, color: AurumTheme.gold, size: 18) : null,
                  ),
                  const SizedBox(height: 8),
                  Text(s,
                      style: TextStyle(
                        color: sel ? AurumTheme.gold : AurumTheme.textMutedOf(context),
                        fontSize: 11,
                      )),
                ]),
              ),
            ),
          );
        }).toList(),
      ),
    ));
  }

  Widget _themeTile(BuildContext context, ThemeProvider tp, IconData icon, String label, String sub, AurumThemeMode mode) {
    final selected = tp.mode == mode;
    return ListTile(
      onTap: () => tp.setMode(mode),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: selected ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgOf(context),
          borderRadius: BorderRadius.circular(10),
          border: selected ? Border.all(color: AurumTheme.gold.withOpacity(0.5)) : null,
        ),
        child: Icon(icon, color: selected ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 18),
      ),
      title: Text(label,
        style: TextStyle(
          color: selected ? AurumTheme.gold : AurumTheme.textPrimaryOf(context),
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        )),
      subtitle: Text(sub, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        color: selected ? AurumTheme.gold : AurumTheme.textMutedOf(context),
        size: 20,
      ),
    );
  }
}

// ── Appearance-specific helpers ────────────────────────────────────
AppBar _appBar(BuildContext context, String title, {List<Widget>? actions}) {
  return AppBar(
    backgroundColor: AurumTheme.bgOf(context),
    elevation: 0,
    scrolledUnderElevation: 0,
    leading: IconButton(
      icon: Icon(Icons.arrow_back_ios_new_rounded, color: AurumTheme.textPrimaryOf(context), size: 20),
      onPressed: () => Navigator.pop(context),
    ),
    title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 18, fontWeight: FontWeight.w600)),
    actions: actions,
  );
}

Widget _sectionLabel(String label) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
  child: Text(label, style: const TextStyle(color: AurumTheme.gold, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
);

Widget _card(BuildContext context, {required Widget child}) => Container(
  margin: const EdgeInsets.only(bottom: 8),
  decoration: BoxDecoration(
    color: AurumTheme.bgCardOf(context),
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
  ),
  child: child,
);

Widget _divider(BuildContext context) => Divider(
  color: AurumTheme.dividerOf(context), height: 0.5, indent: 14, endIndent: 14);

Widget _inlineSwitch(
  BuildContext context, {
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
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
      title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: Switch(value: value, onChanged: onChanged, activeColor: AurumTheme.gold),
    ),
  );
}

Widget _dropdownTile(
  BuildContext context, {
  required String title,
  required String subtitle,
  required String value,
  required List<String> options,
  required ValueChanged<String?> onChanged,
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
      title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: DropdownButton<String>(
        value: value,
        underline: const SizedBox(),
        dropdownColor: AurumTheme.bgCardOf(context),
        style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600),
        icon: Icon(Icons.keyboard_arrow_down_rounded, color: AurumTheme.gold, size: 18),
        items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
        onChanged: onChanged,
      ),
    ),
  );
}

Widget _sliderTile(
  BuildContext context, {
  required String title,
  required double value,
  required double min,
  required double max,
  required int divisions,
  required String displayValue,
  required ValueChanged<double> onChanged,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AurumTheme.bgCardOf(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Column(children: [
        Row(children: [
          Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
          const Spacer(),
          Text(displayValue, style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
        Slider(value: value, min: min, max: max, divisions: divisions, onChanged: onChanged),
      ]),
    ),
  );
}
