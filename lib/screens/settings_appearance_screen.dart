import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/aurum_theme.dart';
import '../providers/theme_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/premium_gate.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_loader.dart';
import '../services/audio_prefs.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../widgets/aurum_settings_tile.dart' show AurumStaggerItem;

class SettingsAppearanceScreen extends StatefulWidget {
  const SettingsAppearanceScreen({super.key});
  @override
  State<SettingsAppearanceScreen> createState() => _SettingsAppearanceScreenState();
}

class _SettingsAppearanceScreenState extends State<SettingsAppearanceScreen> {
  // Theme
  bool _highRefreshRate = true;
  Color _accentColor = AurumTheme.gold;
  // Player
  String _playerBgStyle = 'Blur';
  bool _dynamicPlayerColor = true;
  String _playerButtonColors = 'Primary';
  String _playerSliderStyle = 'Rounded';
  // SPEED FIX (Spotify-level lightweight): these three local fallback
  // defaults must match their AudioPrefs notifier counterparts exactly
  // (showBlurredBgNotifier, navBarBlurSigmaNotifier,
  // miniPlayerBlurSigmaNotifier — see audio_prefs.dart). This screen's
  // own _loadPrefs() only overwrites them once SharedPreferences finishes
  // loading (see the p.getDouble(...) ?? fallback calls a few lines
  // below) — until that resolves, whatever's hardcoded here is what a
  // first-ever-open of this settings screen actually shows. Leaving
  // these at the OLD defaults (true/24.0/14.0) after the notifiers were
  // changed to the new lightweight defaults would show the slider at 24
  // for a moment before snapping down once prefs load — a visible,
  // confusing flash of the wrong value on a screen about performance
  // settings specifically. Keeping both sides in sync avoids that.
  bool _showBlurredBg = false;
  double _navBarBlurSigma = 0.0;
  double _miniPlayerBlurSigma = 0.0;
  String _navBarStyle = 'Floating';
  // Lyrics
  String _lyricsTextPosition = 'Centre';
  double _lyricsTextSize = 16.0;
  double _lyricsLineSpacing = 1.5;
  bool _showLyricsOnPlayer = true;
  LyricsViewMode _lyricsViewMode = LyricsViewMode.inline;
  // New
  String _fontStyle = 'Default';
  // Guards against a rapid second font tap starting a second transition
  // (and a second dialog) while the first one is still loading/pending —
  // without this, fast double-taps on two different fonts could stack
  // two showDialog calls and leave one scrim orphaned on screen.
  bool _fontTransitionInFlight = false;
  String _artworkShape = 'Rounded';
  // Animations
  bool _enableAnimations = true;
  bool _backAnimations = true;
  bool _scrollAnimations = true;
  bool _bgGradientAnimation = true;

  // FIX (toggle flash): every field above defaults to `true`/some default
  // BEFORE _load() has actually read SharedPreferences (that read is async,
  // so the very first build() always paints with these hardcoded defaults
  // for at least one frame). If the user had actually turned a setting OFF
  // previously, the toggle would render ON for that first frame, then snap
  // to OFF the instant _load()'s setState lands a moment later — reading as
  // "I open settings and it looks on, then it turns off by itself."
  // _loaded gates the real content behind a tiny loader until the actual
  // saved values are in hand, so the screen only ever paints once, with the
  // correct values already in place — no flash, no snap.
  bool _loaded = false;

  // Curated to 6: gold (free) + 5 premium accents, chosen for maximum
  // visual separation against the dark theme and clean contrast with
  // white iconography/text drawn on top of the selected swatch.
  static const List<Color> _accentOptions = [
    AurumTheme.gold,       // free
    Color(0xFF6D5DF6),     // violet
    Color(0xFF4F8CFF),     // azure
    Color(0xFFE91E63),     // rose
    Color(0xFF2ECC71),     // emerald
    Color(0xFFFF7A45),     // amber-orange
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    // FIX: setState() was called unconditionally right after an await
    // gap. If the user backs out of this screen before
    // SharedPreferences.getInstance() resolves (easy to do — Settings
    // screens are quick to bounce off of), this widget is already
    // disposed by the time the await returns, and calling setState() on
    // a disposed State throws "setState() called after dispose()" —
    // a real, if intermittent, crash. Guarding with `mounted` is the
    // standard fix: if the widget's gone, there's nothing to update.
    if (!mounted) return;
    setState(() {
      _highRefreshRate = p.getBool('high_refresh_rate') ?? true;
      _accentColor = Color(p.getInt('accent_color') ?? AurumTheme.gold.value);
      _playerBgStyle = p.getString('player_bg_style') ?? 'Blur';
      _dynamicPlayerColor = p.getBool('dynamic_player_color') ?? true;
      _playerButtonColors = p.getString('player_button_colors') ?? 'Primary';
      _playerSliderStyle = p.getString('player_slider_style') ?? 'Rounded';
      // SPEED FIX (Spotify-level lightweight): fallback defaults here
      // matched to the new AudioPrefs notifier defaults (false/0.0/0.0)
      // — see the matching comment on the field declarations above for
      // why these three must always stay in sync. A user who has never
      // touched these settings (no saved SharedPreferences key yet) now
      // gets the lightweight blur-off experience by default, same as
      // every other entry point in the app — not just on first app
      // launch, but every time this specific key was never explicitly
      // set.
      _showBlurredBg = p.getBool('show_blurred_bg') ?? false;
      _navBarBlurSigma = p.getDouble('nav_bar_blur_sigma') ?? 0.0;
      _miniPlayerBlurSigma = p.getDouble('mini_player_blur_sigma') ?? 0.0;
      _navBarStyle = p.getString('nav_bar_style') ?? 'Floating';
      _lyricsTextPosition = p.getString('lyrics_text_position') ?? 'Centre';
      _lyricsTextSize = p.getDouble('lyrics_text_size') ?? 16.0;
      _lyricsLineSpacing = p.getDouble('lyrics_line_spacing') ?? 1.5;
      _showLyricsOnPlayer = p.getBool('show_lyrics_on_player') ?? true;
      _lyricsViewMode = LyricsViewMode
          .values[p.getInt('lyrics_view_mode') ?? LyricsViewMode.inline.index];
      _enableAnimations = p.getBool('enable_animations') ?? true;
      _backAnimations = p.getBool('back_animations') ?? true;
      _scrollAnimations = p.getBool('scroll_animations') ?? true;
      _bgGradientAnimation = p.getBool('bg_gradient_animation') ?? true;
      _fontStyle           = p.getString('font_style') ?? 'Default';
      _artworkShape        = p.getString('artwork_shape') ?? 'Rounded';
      _loaded = true;
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
    final l10n = AppLocalizations.of(context)!;
    final tp = context.watch<ThemeProvider>();

    // See _loaded's declaration above: skip painting the (possibly wrong)
    // hardcoded defaults for a frame — show a tiny loader instead until the
    // real saved values are ready, then paint once, correctly.
    if (!_loaded) {
      return Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        appBar: _appBar(context, l10n.settingsAppearance),
        body: const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: _appBar(context, l10n.settingsAppearance),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          // ── Theme ──
          // Every major section on this screen is wrapped in the same
          // AurumStaggerItem entrance used by every other Settings screen
          // (Privacy/Storage/Language/Notifications/About/Player/main
          // Settings list) — one section per stagger slot keeps the
          // cascade timing identical across all of Settings.
          AurumStaggerItem(index: 0, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionLabel(l10n.saTheme),
          _card(context, child: Column(children: [
            _themeTile(context, tp, Icons.wallpaper_rounded, 'Dynamic Color',
                tp.dynamicDark != null
                    ? 'Matches your wallpaper (Material You)'
                    : 'Requires Android 12 or newer',
                AurumThemeMode.dynamic,
                disabled: tp.dynamicDark == null),
            _divider(context),
            _themeTile(context, tp, Icons.dark_mode_rounded, l10n.saThemeDark, l10n.saThemeDarkDesc, AurumThemeMode.dark),
            _divider(context),
            _themeTile(context, tp, Icons.contrast_rounded, l10n.saThemeAmoled, l10n.saThemeAmoledDesc, AurumThemeMode.amoled),
            _divider(context),
            _themeTile(context, tp, Icons.light_mode_rounded, l10n.saThemeLight, l10n.saThemeLightDesc, AurumThemeMode.light),
            _divider(context),
            _themeTile(context, tp, Icons.phone_android_rounded, l10n.saThemeSystem, l10n.saThemeSystemDesc, AurumThemeMode.system),
          ])),
          const SizedBox(height: 8),
          _inlineSwitch(context,
            title: l10n.saHighRefreshRate,
            subtitle: l10n.saHighRefreshRateSubtitle,
            value: _highRefreshRate,
            onChanged: (v) {
              setState(() => _highRefreshRate = v);
              _save('high_refresh_rate', v);
              AudioPrefs.pushHighRefreshRateToNative(v);
            },
          ),
          ])),
          // Accent color
          AurumStaggerItem(index: 1, child:
          _card(context, child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(l10n.saAccentColor, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
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
                    Text(l10n.saExtraColorsSignIn, style: TextStyle(color: AurumTheme.gold, fontSize: 9, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ]),
              const SizedBox(height: 14),
              Builder(builder: (context) {
                final isSignedIn = context.watch<AuthProvider>().isSignedIn;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: _accentOptions.asMap().entries.map((entry) {
                    final i = entry.key;
                    final c = entry.value;
                    final isFree = i == 0; // only gold is free
                    final sel = _accentColor.value == c.value;
                    final locked = !isFree && !isSignedIn;
                    return AurumPressable(
                      scaleAmount: 0.9,
                      onTap: () {
                        if (locked) {
                          PremiumGate.show(context,
                            feature: l10n.saCustomAccentColorsFeature,
                            description: l10n.saCustomAccentColorsDesc,
                            requiresLoginOnly: true,
                          );
                          return;
                        }
                        setState(() => _accentColor = c);
                        _save('accent_color', c.value);
                        context.read<ThemeProvider>().setAccentColor(c);
                      },
                      // Flat solid fill, thin ring on selection — no
                      // gradient, no glow shadow, no glass sheen. Matches
                      // the same restrained treatment as the rest of the
                      // redesigned Settings screens.
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: locked ? c.withOpacity(0.32) : c,
                          border: sel
                              ? Border.all(color: AurumTheme.textPrimaryOf(context), width: 2)
                              : null,
                        ),
                        child: sel
                            ? const Icon(Icons.check_rounded, color: Colors.white, size: 17)
                            : (locked
                                ? Icon(Icons.lock_rounded, size: 13, color: Colors.white.withOpacity(0.85))
                                : null),
                      ),
                    );
                  }).toList(),
                );
              }),
            ]),
          )),
          ),
          // ── Font Style ──
          AurumStaggerItem(index: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionLabel(l10n.saFontStyle),
          _buildFontSelector(context),

          // ── Artwork Shape ──
          _sectionLabel(l10n.saArtworkShape),
          _buildArtworkShapeSelector(context),
          ])),

          // ── Player ──
          AurumStaggerItem(index: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionLabel(l10n.saPlayer),
          _dropdownTile(context,
            title: 'Nav Bar & Mini Player Style',
            subtitle: 'Floating: rounded, blurred capsule. Docked: classic flat bar, edge-to-edge, no blur.',
            value: _navBarStyle,
            options: const ['Floating', 'Docked'],
            onChanged: (v) { setState(() => _navBarStyle = v!); _save('nav_bar_style', v!); AudioPrefs.setNavBarStyle(v); },
          ),
          _dropdownTile(context,
            title: l10n.saPlayerBgStyle,
            subtitle: l10n.saPlayerBgStyleSubtitle,
            value: _playerBgStyle,
            options: const ['Gradient', 'Blur', 'Solid'],
            onChanged: (v) { setState(() => _playerBgStyle = v!); _save('player_bg_style', v!); AudioPrefs.setPlayerBgStyle(v); },
          ),
          _inlineSwitch(context,
            title: l10n.saDynamicPlayerColor,
            subtitle: l10n.saDynamicPlayerColorSubtitle,
            value: _dynamicPlayerColor,
            onChanged: (v) { setState(() => _dynamicPlayerColor = v); _save('dynamic_player_color', v); AudioPrefs.setDynamicPlayerColor(v); },
          ),
          _dropdownTile(context,
            title: l10n.saPlayerButtonColors,
            subtitle: l10n.saPlayerButtonColorsSubtitle,
            value: _playerButtonColors,
            options: const ['Primary', 'White', 'Accent'],
            onChanged: (v) { setState(() => _playerButtonColors = v!); _save('player_button_colors', v!); context.read<ThemeProvider>().setPlayerButtonColorMode(v); },
          ),
          _sliderStylePickerTile(context,
            title: l10n.saPlayerSliderStyle,
            subtitle: l10n.saPlayerSliderStyleSubtitle,
            value: _playerSliderStyle,
            onChanged: (v) { setState(() => _playerSliderStyle = v); _save('player_slider_style', v); context.read<ThemeProvider>().setPlayerSliderStyle(v); },
          ),
          _inlineSwitch(context,
            title: l10n.saShowBlurredBg,
            subtitle: l10n.saShowBlurredBgSubtitle,
            value: _showBlurredBg,
            onChanged: (v) { setState(() => _showBlurredBg = v); _save('show_blurred_bg', v); AudioPrefs.setShowBlurredBg(v); },
          ),
          // Blur intensity controls for the two persistent frosted-glass
          // surfaces (nav bar, mini player) — both run their BackdropFilter
          // blur on every frame they're visible, which is real ongoing
          // GPU/battery cost on weaker devices. Letting users dial this
          // down (or to 0 — fully flat, cheapest possible) trades the
          // frosted look for cooler/longer-lasting playback, without
          // forcing that tradeoff on everyone.
          _sliderTile(context,
            title: l10n.saNavBarBlur,
            value: _navBarBlurSigma,
            min: 0, max: 24, divisions: 24,
            displayValue: _navBarBlurSigma <= 0 ? 'Off' : _navBarBlurSigma.toInt().toString(),
            onChanged: (v) { setState(() => _navBarBlurSigma = v); AudioPrefs.setNavBarBlurSigma(v); },
          ),
          _sliderTile(context,
            title: l10n.saMiniPlayerBlur,
            value: _miniPlayerBlurSigma,
            min: 0, max: 14, divisions: 14,
            displayValue: _miniPlayerBlurSigma <= 0 ? 'Off' : _miniPlayerBlurSigma.toInt().toString(),
            onChanged: (v) { setState(() => _miniPlayerBlurSigma = v); AudioPrefs.setMiniPlayerBlurSigma(v); },
          ),
          // ── Mini Player ──
          // Mini player settings removed — the widget was rewritten to a
          // single fixed, minimal design with no configurable style,
          // background, or swipe sensitivity anymore (see mini_player.dart
          // v4.0 for why: the old style/animation machinery was the source
          // of a class of "mini player disappears, only fixed by app
          // restart" bugs).
          ])),
          // ── Lyrics ──
          AurumStaggerItem(index: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionLabel(l10n.saLyrics),
          _inlineSwitch(context,
            title: l10n.saShowLyricsOnPlayer,
            subtitle: l10n.saShowLyricsOnPlayerSubtitle,
            value: _showLyricsOnPlayer,
            onChanged: (v) {
              setState(() {
                _showLyricsOnPlayer = v;
                // Mutually exclusive with Immersive below: turning the
                // inline strip ON while Immersive is also on doesn't
                // make sense (Immersive already opens full-screen from
                // the same button) — so switching this on turns
                // Immersive off, same as toggling Immersive on turns
                // this off further down.
                if (v && _lyricsViewMode == LyricsViewMode.fullscreen) {
                  _lyricsViewMode = LyricsViewMode.inline;
                  _save('lyrics_view_mode', LyricsViewMode.inline.index);
                  AudioPrefs.setLyricsViewMode(LyricsViewMode.inline);
                }
              });
              _save('show_lyrics_on_player', v);
              AudioPrefs.setShowLyricsOnPlayer(v);
            },
          ),
          // "Immersive Lyrics" — a plain switch styled exactly like
          // every other _inlineSwitch on this screen (Show Lyrics on
          // Player above, Blur toggles elsewhere). Deliberately NOT
          // visually highlighted/badged as a "new" feature — it should
          // read as an ordinary setting a user might casually toggle,
          // not something calling extra attention to itself. Turning
          // this ON automatically turns the inline strip above OFF, and
          // vice versa — only one lyrics display mode can be active at
          // a time.
          _inlineSwitch(context,
            title: l10n.saLyricsViewMode,
            subtitle: l10n.saLyricsViewModeSubtitle,
            value: _lyricsViewMode == LyricsViewMode.fullscreen,
            onChanged: (v) {
              final mode = v ? LyricsViewMode.fullscreen : LyricsViewMode.inline;
              setState(() {
                _lyricsViewMode = mode;
                if (v && _showLyricsOnPlayer) {
                  _showLyricsOnPlayer = false;
                  _save('show_lyrics_on_player', false);
                  AudioPrefs.setShowLyricsOnPlayer(false);
                }
              });
              _save('lyrics_view_mode', mode.index);
              AudioPrefs.setLyricsViewMode(mode);
            },
          ),
          _dropdownTile(context,
            title: l10n.saLyricsTextPosition,
            subtitle: l10n.saLyricsTextPositionSubtitle,
            value: _lyricsTextPosition,
            options: const ['Left', 'Centre'],
            onChanged: (v) { setState(() => _lyricsTextPosition = v!); _save('lyrics_text_position', v!); AudioPrefs.setLyricsPosition(v); },
          ),
          _sliderTile(context,
            title: l10n.saLyricsTextSize,
            value: _lyricsTextSize,
            min: 10, max: 28, divisions: 9,
            displayValue: '${_lyricsTextSize.toInt()}sp',
            onChanged: (v) { setState(() => _lyricsTextSize = v); _save('lyrics_text_size', v); AudioPrefs.setLyricsTextSize(v); },
          ),
          _sliderTile(context,
            title: l10n.saLyricsLineSpacing,
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
          ])),
          // ── Animations ──
          AurumStaggerItem(index: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionLabel(l10n.saAnimations),
          _inlineSwitch(context,
            title: l10n.saEnableAnimations,
            subtitle: l10n.saEnableAnimationsSubtitle,
            value: _enableAnimations,
            onChanged: (v) { setState(() => _enableAnimations = v); _save('enable_animations', v); AudioPrefs.setEnableAnimations(v); },
          ),
          _inlineSwitch(context,
            title: l10n.saBackAnimations,
            subtitle: l10n.saBackAnimationsSubtitle,
            value: _backAnimations,
            onChanged: (v) { setState(() => _backAnimations = v); _save('back_animations', v); AudioPrefs.setBackAnimations(v); },
          ),
          _inlineSwitch(context,
            title: l10n.saScrollAnimations,
            subtitle: l10n.saScrollAnimationsSubtitle,
            value: _scrollAnimations,
            onChanged: (v) { setState(() => _scrollAnimations = v); _save('scroll_animations', v); AudioPrefs.setScrollAnimations(v); },
          ),
          _inlineSwitch(context,
            title: l10n.saBgGradientAnimation,
            subtitle: l10n.saBgGradientAnimationSubtitle,
            value: _bgGradientAnimation,
            onChanged: (v) { setState(() => _bgGradientAnimation = v); _save('bg_gradient_animation', v); AudioPrefs.setBgGradientAnimation(v); },
          ),
          ])),
        ],
      ),
    );
  }

  // ── Font Selector ────────────────────────────────────────────────────────
  Widget _buildFontSelector(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const fonts = {
      'Default':  'Aa',
      'Rounded':  'Aa',
      'Mono':     'Aa',
      'Sans':     'Aa',
      'Serif':    'Aa',
    };
    const premiumFonts = {'Rounded', 'Mono', 'Sans', 'Serif'};

    // Preview glyph style per font. These are Google Fonts, downloaded/
    // cached at runtime — passing a bare `fontFamily: 'Manrope'` string
    // does nothing without the font bundled as a static asset (it was
    // silently falling back to the default font for every preview card,
    // including the pre-existing Rounded/Mono ones). GoogleFonts.getFont
    // resolves the actual cached/downloading font correctly.
    TextStyle previewStyle(String key, {required Color color}) {
      const base = TextStyle(fontSize: 22, fontWeight: FontWeight.w700);
      switch (key) {
        case 'Rounded': return GoogleFonts.nunito(textStyle: base, color: color);
        case 'Mono':    return GoogleFonts.robotoMono(textStyle: base, color: color);
        case 'Sans':    return GoogleFonts.manrope(textStyle: base, color: color);
        case 'Serif':   return GoogleFonts.playfairDisplay(textStyle: base, color: color);
        default:        return base.copyWith(color: color);
      }
    }

    return Builder(builder: (context) {
      final isSignedIn = context.watch<AuthProvider>().isSignedIn;
      return _card(context, child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(l10n.saAppFont, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
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
                Text(l10n.saRoundedMonoSignIn, style: TextStyle(color: AurumTheme.gold, fontSize: 9, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(
            children: fonts.entries.map((e) {
              final sel = _fontStyle == e.key;
              final locked = premiumFonts.contains(e.key) && !isSignedIn;
              final isLast = e.key == fonts.keys.last;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: isLast ? 0 : 6),
                  child: AurumPressable(
                    scaleAmount: 0.96,
                    onTap: () {
                      if (locked) {
                        PremiumGate.show(context,
                          feature: l10n.saFontUnlockFeature(e.key),
                          description: l10n.saFontUnlockDesc,
                          requiresLoginOnly: true,
                        );
                        return;
                      }
                      if (_fontStyle == e.key) return;
                      if (_fontTransitionInFlight) return;
                      _applyFontWithTransition(context, e.key);
                    },
                    child: Stack(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
                        decoration: BoxDecoration(
                          color: sel ? AurumTheme.gold.withOpacity(0.12) : AurumTheme.bgOf(context),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: sel ? AurumTheme.gold.withOpacity(0.6) : AurumTheme.dividerOf(context),
                            width: sel ? 1 : 0.5,
                          ),
                        ),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              e.value,
                              style: previewStyle(
                                e.key,
                                color: locked
                                    ? AurumTheme.textMutedOf(context).withOpacity(0.5)
                                    : (sel ? AurumTheme.gold : AurumTheme.textPrimaryOf(context)),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            e.key,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: locked
                                  ? AurumTheme.textMutedOf(context).withOpacity(0.4)
                                  : (sel ? AurumTheme.gold : AurumTheme.textMutedOf(context)),
                              fontSize: 10.5,
                            ),
                          ),
                        ]),
                      ),
                      if (locked)
                        Positioned(
                          top: 6, right: 6,
                          child: Icon(Icons.lock_rounded, size: 12, color: AurumTheme.gold.withOpacity(0.7)),
                        ),
                    ]),
                  ),
                ),
              );
            }).toList(),
          ),
        ]),
      ));
    });
  }

  // ── Font change transition ─────────────────────────────────────────────
  // Applying a Google Font swaps the entire app TextTheme, which used to
  // happen instantly on tap — felt cheap/abrupt for something this
  // visually large. Now shows a brief M3 loading state (dim scrim +
  // circular progress) before committing the change, matching how
  // premium apps (Spotify/YT Music settings) gate heavier theme changes
  // behind a beat of feedback instead of an instant jump-cut.
  Future<void> _applyFontWithTransition(BuildContext context, String fontKey) async {
    _fontTransitionInFlight = true;
    AurumHaptics.light();
    final themeProvider = context.read<ThemeProvider>();

    // Capture the dialog's own Navigator via a dedicated context passed
    // out through the builder, instead of reusing the tile's `context`
    // to pop later. If the user backs out of this screen while the font
    // is still loading, the screen's own BuildContext/State becomes
    // invalid, but the dialog route is independent of it — popping via
    // this screen's `context` after the screen unmounts would either
    // throw or (with rootNavigator:true) risk popping the wrong route
    // entirely. Grabbing the dialog's context off its own builder keeps
    // the pop scoped to exactly the route we opened.
    BuildContext? dialogContext;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (dCtx) {
        dialogContext = dCtx;
        return const _FontLoadingOverlay();
      },
    );

    // Wait for the actual font to finish loading — not a fixed timer.
    // GoogleFonts.pendingFonts() resolves only once the requested font's
    // HTTP fetch (or cache read) has completed and it's ready to render,
    // so the dialog now tracks real load state instead of guessing a
    // duration: fast connections/cached fonts close quickly, slow
    // connections keep the spinner up until the font is actually ready
    // — either way the font never applies before it can render, so
    // there's no flash-to-fallback-font frame once the dialog closes.
    //
    // A small minimum floor keeps the spinner from strobing on/off in a
    // single frame when the font is already cached, which reads as a
    // glitch rather than "smooth" — 350ms is short enough to still feel
    // instant, long enough to always render as a deliberate beat.
    final loadFont = () {
      switch (fontKey) {
        case 'Rounded': return GoogleFonts.pendingFonts([GoogleFonts.nunito()]);
        case 'Mono':    return GoogleFonts.pendingFonts([GoogleFonts.robotoMono()]);
        case 'Sans':    return GoogleFonts.pendingFonts([GoogleFonts.manrope()]);
        case 'Serif':   return GoogleFonts.pendingFonts([GoogleFonts.playfairDisplay()]);
        default:        return Future<List<String>>.value(const []);
      }
    }();
    final minFloor = Future.delayed(const Duration(milliseconds: 350));

    // If the font fetch ever fails (offline, blocked network, etc.) fall
    // back to just the floor delay instead of hanging the dialog open
    // forever — the font still applies (GoogleFonts silently falls back
    // to the platform default glyphs when it can't fetch), so the user
    // always gets an unstuck UI even without a network.
    await Future.wait([
      loadFont.catchError((_) => <String>[]),
      minFloor,
    ]);

    // Only touch this screen's own state if it's still alive — but the
    // dialog must close regardless of whether the settings screen is
    // still mounted, otherwise navigating away mid-transition leaves an
    // undismissable scrim stuck on top of whatever screen the user is
    // now on.
    // themeProvider.setFontStyle() already persists to SharedPreferences
    // internally (see theme_provider.dart) — a separate _save() call here
    // would just be a redundant second write to the same key on every
    // font change.
    if (mounted) setState(() => _fontStyle = fontKey);
    themeProvider.setFontStyle(fontKey);

    // Prefer popping via the dialog's own captured context (scoped to
    // exactly the route we opened). Fall back to the tile's context only
    // if the dialog somehow never reported one back — belt-and-braces
    // against ever leaving the scrim stuck on screen.
    if (dialogContext != null && dialogContext!.mounted) {
      Navigator.of(dialogContext!).pop();
    } else if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    _fontTransitionInFlight = false;
  }

  // ── Artwork Shape ─────────────────────────────────────────────────────────
  Widget _buildArtworkShapeSelector(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const shapes = ['Square', 'Rounded', 'Circle']; // internal keys — persisted, matched by AudioPrefs
    final labels = {
      'Square': l10n.saShapeSquare,
      'Rounded': l10n.saShapeRounded,
      'Circle': l10n.saShapeCircle,
    };
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
                  Text(labels[s]!,
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

  Widget _themeTile(BuildContext context, ThemeProvider tp, IconData icon, String label, String sub, AurumThemeMode mode, {bool disabled = false}) {
    final selected = tp.mode == mode && !disabled;
    return ListTile(
      onTap: disabled ? null : () { AurumHaptics.selection(); tp.setMode(mode); },
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: selected ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgOf(context),
          borderRadius: BorderRadius.circular(10),
          border: selected ? Border.all(color: AurumTheme.gold.withOpacity(0.5)) : null,
        ),
        child: Icon(icon, color: disabled ? AurumTheme.textMutedOf(context).withOpacity(0.4) : (selected ? AurumTheme.gold : AurumTheme.textMutedOf(context)), size: 18),
      ),
      title: Text(label,
        style: TextStyle(
          color: disabled ? AurumTheme.textMutedOf(context).withOpacity(0.5) : (selected ? AurumTheme.gold : AurumTheme.textPrimaryOf(context)),
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        )),
      subtitle: Text(sub, style: TextStyle(color: AurumTheme.textMutedOf(context).withOpacity(disabled ? 0.6 : 1), fontSize: 12)),
      trailing: disabled
          ? null
          : Icon(
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


// ─────────────────────────────────────────────────────────────────────────────
// Player Slider Style — tap-to-open bottom sheet, 2x2 grid of live-preview
// cards. Each card renders a mini "stage" that mirrors the real full player
// backdrop (dark artwork-blur gradient) with the seekbar drawn using the
// EXACT track/thumb geometry used in full_player_screen.dart's _SeekBar,
// so what the user sees here is what they'll get, not an approximation.
// Flat matte cards, no glow/shadow — border-only selected state, muted
// title that brightens on select. Tap applies + closes immediately.
Widget _sliderStylePickerTile(
  BuildContext context, {
  required String title,
  required String subtitle,
  required String value,
  required ValueChanged<String> onChanged,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AurumTheme.bgCardOf(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
    ),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          AurumHaptics.selection();
          _showSliderStyleSheet(context, value, onChanged);
        },
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          title: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500)),
          subtitle: Text(subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(value, style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: 2),
            Icon(Icons.keyboard_arrow_down_rounded, color: AurumTheme.gold, size: 18),
          ]),
        ),
      ),
    ),
  );
}

void _showSliderStyleSheet(
  BuildContext context,
  String current,
  ValueChanged<String> onChanged,
) {
  // FIX: routed through showAurumModalBottomSheet (lib/utils/aurum_sheet.dart)
  // so the scrim always has an explicit barrierColor.
  showAurumModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetCtx) => _SliderStyleSheet(current: current, onChanged: onChanged),
  );
}

class _SliderStyleSheet extends StatefulWidget {
  final String current;
  final ValueChanged<String> onChanged;
  const _SliderStyleSheet({required this.current, required this.onChanged});
  @override
  State<_SliderStyleSheet> createState() => _SliderStyleSheetState();
}

class _SliderStyleSheetState extends State<_SliderStyleSheet>
    with SingleTickerProviderStateMixin {
  late String _selected = widget.current;
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  static const _styles = ['Slim', 'Thick', 'Rounded', 'Waveform'];

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _select(String style) {
    if (_selected == style) return;
    AurumHaptics.selection();
    setState(() => _selected = style);
    widget.onChanged(style);
    Future.delayed(const Duration(milliseconds: 130), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 0),
        padding: EdgeInsets.fromLTRB(16, 10, 16, 12 + bottomInset),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 34, height: 3.5,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AurumTheme.textMutedOf(context).withAlpha(60),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l10n.saPlayerSliderStyle,
              style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 3),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l10n.saPlayerSliderStyleSubtitle,
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12.5)),
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.28,
            children: _styles.map((s) => _SliderStyleCard(
              style: s,
              selected: _selected == s,
              ticker: _ticker,
              onTap: () => _select(s),
            )).toList(),
          ),
          const SizedBox(height: 14),
          Text('Tap a style to apply instantly',
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 10.5, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

class _SliderStyleCard extends StatelessWidget {
  final String style;
  final bool selected;
  final AnimationController ticker;
  final VoidCallback onTap;
  const _SliderStyleCard({
    required this.style,
    required this.selected,
    required this.ticker,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final mutedTitle = AurumTheme.textMutedOf(context);
    final brightTitle = AurumTheme.textPrimaryOf(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: const Color(0xFF0B0B11),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? AurumTheme.gold.withAlpha(90) : Colors.white.withAlpha(14),
          width: selected ? 1.0 : 0.7,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Mini "stage" — flat dark surface, same tone as the real
              // full player's base backdrop. No gradient/glow: a real
              // player screen reads as a calm dark surface, not a
              // decorative purple glow — that's what read as "AI-made".
              Expanded(
                child: Container(
                  color: const Color(0xFF0C0C13),
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.72,
                    child: AnimatedBuilder(
                      animation: ticker,
                      // Isolates this tiny animating preview into its own
                      // compositing layer so the repeating ticker only
                      // repaints this small strip, not the whole card tree
                      // around it — cheap insurance on low-end GPUs.
                      builder: (_, __) => RepaintBoundary(
                        child: Opacity(
                          opacity: _sweepOpacity(ticker.value),
                          child: _miniPreview(style, ticker.value),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.white.withAlpha(10), width: 0.6)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Expanded(
                    child: Text(style,
                      style: TextStyle(
                        color: selected ? brightTitle : mutedTitle,
                        fontSize: 12.5, fontWeight: FontWeight.w600,
                        letterSpacing: -0.05,
                      )),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 16, height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? AurumTheme.gold : Colors.transparent,
                      border: Border.all(
                        color: selected ? AurumTheme.gold : Colors.white.withAlpha(36),
                        width: 1.3,
                      ),
                    ),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 130),
                      opacity: selected ? 1 : 0,
                      child: const Icon(Icons.check_rounded, size: 11, color: Color(0xFF050508)),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Forward-only progress: 0 → 1 then hard-resets to 0, matching how a
  // real seek bar actually behaves (plays forward, never rewinds on its
  // own). A sine-based back-and-forth here read as the slider glitching
  // in reverse, so this stays strictly monotonic within each loop.
  // Small opacity dip right at the reset point hides the jump-cut instead
  // of showing a visible snap back to the start.
  double _sweep(double t) => t;

  double _sweepOpacity(double t) {
    // Fade out over the last ~6% and fade back in over the first ~6% of
    // each loop, so the 1→0 reset happens while invisible.
    if (t > 0.94) return (1.0 - t) / 0.06;
    if (t < 0.06) return t / 0.06;
    return 1.0;
  }

  Widget _miniPreview(String style, double t) {
    final progress = _sweep(t);

    if (style == 'Waveform') {
      return SizedBox(
        height: 20,
        child: CustomPaint(
          painter: _MiniWavePainter(progress: progress, scrollX: t * 26),
          size: const Size(double.infinity, 20),
        ),
      );
    }

    double trackHeight;
    double thumbRadius;
    switch (style) {
      case 'Slim':
        trackHeight = 1.5; thumbRadius = 4.0; break;
      case 'Thick':
        trackHeight = 5.5; thumbRadius = 6.0; break;
      case 'Rounded':
      default:
        trackHeight = 3.0; thumbRadius = 5.0;
    }

    return SizedBox(
      height: 20,
      child: LayoutBuilder(builder: (_, c) {
        final w = c.maxWidth;
        final thumbX = (w * progress).clamp(thumbRadius, w - thumbRadius);
        return Stack(alignment: Alignment.centerLeft, children: [
          Container(
            height: trackHeight,
            width: w,
            decoration: BoxDecoration(color: Colors.white.withAlpha(40), borderRadius: BorderRadius.circular(trackHeight)),
          ),
          Container(
            height: trackHeight,
            width: thumbX,
            decoration: BoxDecoration(color: Colors.white.withAlpha(235), borderRadius: BorderRadius.circular(trackHeight)),
          ),
          Positioned(
            left: (thumbX - thumbRadius).clamp(0.0, w - thumbRadius * 2),
            child: Container(
              width: thumbRadius * 2,
              height: thumbRadius * 2,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            ),
          ),
        ]);
      }),
    );
  }
}

// Mirrors full_player_screen.dart's _WaveformPainter math (10% amplitude,
// same wavelength ratio, flat unplayed tail, playhead dot) at miniature
// scale so the waveform preview isn't a stand-in shape but the same curve.
class _MiniWavePainter extends CustomPainter {
  final double progress;
  final double scrollX;
  const _MiniWavePainter({required this.progress, required this.scrollX});

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final progressX = size.width * progress;
    final maxAmp = size.height * 0.16; // matches the real player's calm "barely there" ripple
    const wavelength = 15.0;
    final k = (2 * math.pi) / wavelength;

    const gap = 4.0;
    if (progressX + gap < size.width) {
      final trackPaint = Paint()
        ..color = Colors.white.withAlpha(40)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(progressX + gap, centerY), Offset(size.width - 3, centerY), trackPaint);
    }

    final activePath = Path();
    bool started = false;
    for (double x = 0; x <= progressX; x += 1.5) {
      final y = centerY + math.sin(k * (x - scrollX)) * maxAmp;
      if (!started) { activePath.moveTo(x, y); started = true; } else { activePath.lineTo(x, y); }
    }
    final activePaint = Paint()
      ..color = Colors.white.withAlpha(235)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(activePath, activePaint);

    final headY = centerY + math.sin(k * (progressX - scrollX)) * maxAmp;
    canvas.drawCircle(Offset(progressX, headY), 2.6, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _MiniWavePainter old) =>
      old.progress != progress || old.scrollX != scrollX;
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

// ── Font change loading overlay ──────────────────────────────────────────
// Uses the app's own AurumM3Loader — the same fluid morphing M3 bar shown
// under the search bar and on the home feed while content loads — so this
// reads as the same "Aurum is working" moment everywhere instead of
// introducing a second, different-looking spinner just for fonts.
// Purely presentational; the actual font apply/save happens in
// _applyFontWithTransition once the real font load resolves.
class _FontLoadingOverlay extends StatelessWidget {
  const _FontLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(40),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 32),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 24, offset: const Offset(0, 8)),
          ],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
            width: 120,
            child: AurumM3Loader(height: 3),
          ),
          const SizedBox(height: 18),
          Text(
            AppLocalizations.of(context)!.saApplyingFont,
            style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ]),
      ),
    );
  }
}
