import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/aurum_theme.dart';
import '../providers/theme_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/premium_gate.dart';
import '../widgets/aurum_pressable.dart';
import '../services/audio_prefs.dart';

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
  // Lyrics
  String _lyricsTextPosition = 'Centre';
  double _lyricsTextSize = 16.0;
  double _lyricsLineSpacing = 1.5;
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
    Color(0xFF6D5DF6), Color(0xFF4F8CFF), Color(0xFFE91E63),
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
      _lyricsTextPosition = p.getString('lyrics_text_position') ?? 'Centre';
      _lyricsTextSize = p.getDouble('lyrics_text_size') ?? 16.0;
      _lyricsLineSpacing = p.getDouble('lyrics_line_spacing') ?? 1.5;
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
        physics: const BouncingScrollPhysics(),
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
              Row(children: [
                Text('Accent Color', style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: AurumTheme.gold.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AurumTheme.gold.withOpacity(0.3)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.login_rounded, color: AurumTheme.gold, size: 10),
                    const SizedBox(width: 3),
                    Text('Extra colors = Sign in', style: TextStyle(color: AurumTheme.gold, fontSize: 9, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ]),
              const SizedBox(height: 12),
              Builder(builder: (context) {
                final isSignedIn = context.watch<AuthProvider>().isSignedIn;
                return Wrap(
                  spacing: 10,
                  children: _accentOptions.asMap().entries.map((entry) {
                    final i = entry.key;
                    final c = entry.value;
                    final isFree = i == 0; // only gold is free
                    final sel = _accentColor.value == c.value;
                    final locked = !isFree && !isSignedIn;
                    return AurumPressable(
                      scaleAmount: 0.88,
                      onTap: () {
                        if (locked) {
                          PremiumGate.show(context,
                            feature: 'Custom Accent Colors',
                            description: 'Sign in with Google to unlock more accent colors.',
                            requiresLoginOnly: true,
                          );
                          return;
                        }
                        setState(() => _accentColor = c);
                        _save('accent_color', c.value);
                        context.read<ThemeProvider>().setAccentColor(c);
                      },
                      child: Stack(children: [
                        Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: locked ? c.withOpacity(0.4) : c,
                            shape: BoxShape.circle,
                            border: sel ? Border.all(color: Colors.white, width: 2.5) : null,
                            boxShadow: sel ? [BoxShadow(color: c.withOpacity(0.5), blurRadius: 8)] : null,
                          ),
                          child: sel ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                        ),
                        if (locked)
                          Positioned(
                            right: 0, bottom: 0,
                            child: Container(
                              width: 13, height: 13,
                              decoration: BoxDecoration(
                                color: AurumTheme.bgCardOf(context),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.lock_rounded, size: 9, color: AurumTheme.gold),
                            ),
                          ),
                      ]),
                    );
                  }).toList(),
                );
              }),
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
            onChanged: (v) { setState(() => _playerBgStyle = v!); _save('player_bg_style', v!); AudioPrefs.setPlayerBgStyle(v); },
          ),
          _inlineSwitch(context,
            title: 'Dynamic Player Color',
            subtitle: 'Change player color from artwork',
            value: _dynamicPlayerColor,
            onChanged: (v) { setState(() => _dynamicPlayerColor = v); _save('dynamic_player_color', v); AudioPrefs.setDynamicPlayerColor(v); },
          ),
          _dropdownTile(context,
            title: 'Player Button Colors',
            subtitle: 'Color of play/skip buttons',
            value: _playerButtonColors,
            options: ['Primary', 'White', 'Accent'],
            onChanged: (v) { setState(() => _playerButtonColors = v!); _save('player_button_colors', v!); context.read<ThemeProvider>().setPlayerButtonColorMode(v); },
          ),
          _dropdownTile(context,
            title: 'Player Slider Style',
            subtitle: 'Seek bar appearance',
            value: _playerSliderStyle,
            options: ['Slim', 'Thick', 'Rounded', 'Waveform'],
            onChanged: (v) { setState(() => _playerSliderStyle = v!); _save('player_slider_style', v!); context.read<ThemeProvider>().setPlayerSliderStyle(v); },
          ),
          _inlineSwitch(context,
            title: 'Show Blurred Background',
            subtitle: 'Artwork blur behind player',
            value: _showBlurredBg,
            onChanged: (v) { setState(() => _showBlurredBg = v); _save('show_blurred_bg', v); AudioPrefs.setShowBlurredBg(v); },
          ),
          // ── Mini Player ──
          // Mini player settings removed — the widget was rewritten to a
          // single fixed, minimal design with no configurable style,
          // background, or swipe sensitivity anymore (see mini_player.dart
          // v4.0 for why: the old style/animation machinery was the source
          // of a class of "mini player disappears, only fixed by app
          // restart" bugs).
          // ── Lyrics ──
          _sectionLabel('🎤 LYRICS'),
          _dropdownTile(context,
            title: 'Lyrics Text Position',
            subtitle: 'Alignment of lyrics on screen',
            value: _lyricsTextPosition,
            options: ['Left', 'Centre'],
            onChanged: (v) { setState(() => _lyricsTextPosition = v!); _save('lyrics_text_position', v!); AudioPrefs.setLyricsPosition(v); },
          ),
          _sliderTile(context,
            title: 'Lyrics Text Size',
            value: _lyricsTextSize,
            min: 10, max: 28, divisions: 9,
            displayValue: '${_lyricsTextSize.toInt()}sp',
            onChanged: (v) { setState(() => _lyricsTextSize = v); _save('lyrics_text_size', v); AudioPrefs.setLyricsTextSize(v); },
          ),
          _sliderTile(context,
            title: 'Lyrics Line Spacing',
            value: _lyricsLineSpacing,
            min: 1.0, max: 3.0, divisions: 8,
            displayValue: _lyricsLineSpacing.toStringAsFixed(1),
            onChanged: (v) { setState(() => _lyricsLineSpacing = v); _save('lyrics_line_spacing', v); AudioPrefs.setLyricsLineSpacing(v); },
          ),
          // NOTE: "Word Animation Style" and "Glowing Lyrics Effect" were
          // removed — Aurum's lyrics are a single static text block (no
          // LRC timestamps / word-level sync), so a per-word highlight or
          // active-line glow has nothing to attach to. Re-add these once
          // synced lyrics are implemented.
          // ── Animations ──
          _sectionLabel('✨ ANIMATIONS'),
          _inlineSwitch(context,
            title: 'Enable Animations',
            subtitle: 'Master toggle for all animations',
            value: _enableAnimations,
            onChanged: (v) { setState(() => _enableAnimations = v); _save('enable_animations', v); AudioPrefs.setEnableAnimations(v); },
          ),
          _inlineSwitch(context,
            title: 'Back Animations',
            subtitle: 'Animate navigation back gesture',
            value: _backAnimations,
            onChanged: (v) { setState(() => _backAnimations = v); _save('back_animations', v); AudioPrefs.setBackAnimations(v); },
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
            onChanged: (v) { setState(() => _bgGradientAnimation = v); _save('bg_gradient_animation', v); AudioPrefs.setBgGradientAnimation(v); },
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
    const premiumFonts = {'Rounded', 'Mono'};

    return Builder(builder: (context) {
      final isSignedIn = context.watch<AuthProvider>().isSignedIn;
      return _card(context, child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('App Font', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: AurumTheme.gold.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AurumTheme.gold.withOpacity(0.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.login_rounded, color: AurumTheme.gold, size: 10),
                const SizedBox(width: 3),
                Text('Rounded & Mono = Sign in', style: TextStyle(color: AurumTheme.gold, fontSize: 9, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(
            children: fonts.entries.map((e) {
              final sel = _fontStyle == e.key;
              final locked = premiumFonts.contains(e.key) && !isSignedIn;
              return Expanded(
                child: AurumPressable(
                  scaleAmount: 0.96,
                  onTap: () {
                    if (locked) {
                      PremiumGate.show(context,
                        feature: '${e.key} Font',
                        description: 'Sign in with Google to unlock this font.',
                        requiresLoginOnly: true,
                      );
                      return;
                    }
                    setState(() => _fontStyle = e.key);
                    _save('font_style', e.key);
                    context.read<ThemeProvider>().setFontStyle(e.key);
                  },
                  child: Stack(children: [
                    Container(
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
                            color: locked
                                ? AurumTheme.textMutedOf(context).withOpacity(0.5)
                                : (sel ? AurumTheme.gold : AurumTheme.textPrimaryOf(context)),
                            fontSize: 22, fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          e.key,
                          style: TextStyle(
                            color: locked
                                ? AurumTheme.textMutedOf(context).withOpacity(0.4)
                                : (sel ? AurumTheme.gold : AurumTheme.textMutedOf(context)),
                            fontSize: 11,
                          ),
                        ),
                      ]),
                    ),
                    if (locked)
                      Positioned(
                        top: 6, right: 14,
                        child: Icon(Icons.lock_rounded, size: 13, color: AurumTheme.gold.withOpacity(0.7)),
                      ),
                  ]),
                ),
              );
            }).toList(),
          ),
        ]),
      ));
    });
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
    // 'Compact' is free; 'Card' and 'Immersive' are premium
    const premiumStyles = {'Card', 'Immersive'};

    return Builder(builder: (context) {
      final isSignedIn = context.watch<AuthProvider>().isSignedIn;
      return _card(context, child: Column(
        children: styles.entries.map((e) {
          final sel = _nowPlayingCardStyle == e.key;
          final isLast = e.key == 'Immersive';
          final locked = premiumStyles.contains(e.key) && !isSignedIn;
          return Column(children: [
            ListTile(
              onTap: () {
                HapticFeedback.selectionClick();
                if (locked) {
                  PremiumGate.show(context,
                    feature: '${e.key} Player Style',
                    description: 'Sign in with Google to unlock the ${e.key} style.',
                    requiresLoginOnly: true,
                  );
                  return;
                }
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
              title: Row(children: [
                Text(e.key,
                    style: TextStyle(
                      color: locked
                          ? AurumTheme.textMutedOf(context)
                          : (sel ? AurumTheme.gold : AurumTheme.textPrimaryOf(context)),
                      fontSize: 14,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                    )),
                if (locked) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AurumTheme.gold.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AurumTheme.gold.withOpacity(0.3)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.workspace_premium_rounded, color: AurumTheme.gold, size: 9),
                      const SizedBox(width: 2),
                      Text('Premium', style: TextStyle(color: AurumTheme.gold, fontSize: 9, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ],
              ]),
              subtitle: Text(subtitles[e.key]!,
                  style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
              trailing: locked
                  ? Icon(Icons.lock_rounded, color: AurumTheme.gold.withOpacity(0.5), size: 18)
                  : Icon(
                      sel ? Icons.check_circle_rounded : Icons.circle_outlined,
                      color: sel ? AurumTheme.gold : AurumTheme.textMutedOf(context),
                      size: 20,
                    ),
            ),
            if (!isLast) _divider(context),
          ]);
        }).toList(),
      ));
    });
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
            child: AurumPressable(
              scaleAmount: 0.96,
              onTap: () {
                setState(() => _artworkShape = s);
                _save('artwork_shape', s);
                AudioPrefs.setArtworkShape(s);
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
      onTap: () { HapticFeedback.selectionClick(); tp.setMode(mode); },
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
