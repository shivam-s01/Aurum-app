// =============================================================================
// FILE: lib/screens/support_developer_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: "Support developer" page — reached from the very bottom of
//   Settings. Radial-equalizer emblem, Instagram link, and an "I'll help"
//   button that opens the UPI donation page.
//
//   This is a SEPARATE screen. The existing Astra Plus (PremiumScreen) and
//   every route that points to it are NOT touched.
//
//   PERFORMANCE
//   • ONE AnimationController (24 s seamless loop) drives everything.
//   • Motion lives in CustomPainters (`repaint:`) — the widget tree is never
//     rebuilt per frame. No BackdropFilter / blur layers.
//   • Every animated layer sits in its own RepaintBoundary.
//   • Respects Settings -> Appearance -> Animations and the OS
//     "remove animations" flag (freezes on a nice still frame).
//
//   THEME: all colour comes from AurumTheme helpers, so every preset,
//   Material You and light/dark mode matches. Body text inherits the app font.
// =============================================================================

import '../services/analytics_service.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/audio_prefs.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../utils/constants.dart';
import '../widgets/aurum_pressable.dart';

const double _tau = math.pi * 2;
const String _kVersion = '2.3.2';

class SupportDeveloperScreen extends StatefulWidget {
  const SupportDeveloperScreen({super.key});

  @override
  State<SupportDeveloperScreen> createState() => _SupportDeveloperScreenState();
}

class _SupportDeveloperScreenState extends State<SupportDeveloperScreen>
    with TickerProviderStateMixin {
  late final AnimationController _clock; // ambient loop
  late final AnimationController _enter; // staggered entrance
  late final AnimationController _burst; // tap-the-emblem pulse
  late final List<Animation<double>> _rv;
  bool _reduce = false;

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.logScreen('Support Developer');
    _clock = AnimationController(vsync: this, duration: const Duration(seconds: 24));
    _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _burst = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _rv = [
      for (final s in const [0.0, 0.14, 0.28, 0.42, 0.56, 0.70])
        CurvedAnimation(
          parent: _enter,
          curve: Interval(s, math.min(1.0, s + 0.34), curve: Curves.easeOutCubic),
        ),
    ];
    AudioPrefs.enableAnimationsNotifier.addListener(_syncMotion);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncMotion();
  }

  void _syncMotion() {
    final on = AudioPrefs.enableAnimationsNotifier.value && !_reduce;
    if (on) {
      if (!_clock.isAnimating) _clock.repeat();
      if (_enter.value == 0) _enter.forward();
    } else {
      _clock.stop();
      _clock.value = 0.22; // pleasant frozen frame
      _enter.value = 1.0;
    }
  }

  @override
  void dispose() {
    AudioPrefs.enableAnimationsNotifier.removeListener(_syncMotion);
    _clock.dispose();
    _enter.dispose();
    _burst.dispose();
    super.dispose();
  }

  Future<void> _open(String url, {bool inApp = false}) async {
    AurumHaptics.light();
    final uri = Uri.parse(url);
    try {
      if (inApp && await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return;
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  void _pulse() {
    AurumHaptics.medium();
    if (AudioPrefs.enableAnimationsNotifier.value && !_reduce) {
      _burst.forward(from: 0);
    }
  }

  Widget _reveal(int i, Widget child) => FadeTransition(
        opacity: _rv[i],
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
              .animate(_rv[i]),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final light = AurumTheme.accentLightOf(context);
    final deep = AurumTheme.accentDarkOf(context);
    final bg = AurumTheme.bgOf(context);
    final card = AurumTheme.bgCardOf(context);
    final txt = AurumTheme.textPrimaryOf(context);
    final muted = AurumTheme.textMutedOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
        ? Colors.white
        : const Color(0xFF111111);

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _AuroraPainter(
                  clock: _clock,
                  a: accent,
                  b: light,
                  c: deep,
                  dark: dark,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Semantics(
                      button: true,
                      label: 'Close',
                      child: AurumPressable(
                        onTap: () => Navigator.maybePop(context),
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: txt.withValues(alpha: 0.07),
                            border: Border.all(color: txt.withValues(alpha: 0.06), width: 0.5),
                          ),
                          child: Icon(Icons.close_rounded, color: txt, size: 21),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: c.maxHeight - 8),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 460),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _reveal(0, _emblem(accent, light, deep)),
                                _reveal(1, _brand(accent, light, txt)),
                                const SizedBox(height: 22),
                                _reveal(2, _card(card, accent, light, txt, muted)),
                                const SizedBox(height: 24),
                                _reveal(3, _tipText(muted)),
                                const SizedBox(height: 16),
                                _reveal(4, _helpButton(accent, light, deep, onAccent)),
                                const SizedBox(height: 12),
                                _reveal(
                                  4,
                                  Text(
                                    'I want Astra to keep improving.',
                                    style: TextStyle(
                                      color: muted.withValues(alpha: 0.85),
                                      fontSize: 13.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _reveal(5, _footer(muted)),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Emblem: radial equalizer + ripples + scalloped badge ────────────────
  Widget _emblem(Color a, Color b, Color c) {
    const s = 236.0;
    return Semantics(
      button: true,
      label: 'Astra Music logo',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _pulse,
        child: SizedBox(
          width: s,
          height: s,
          child: Stack(
            alignment: Alignment.center,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  size: const Size(s, s),
                  painter: _EmblemPainter(clock: _clock, burst: _burst, a: a, b: b),
                ),
              ),
              // Slow-rotating scalloped badge (cached layer, GPU rotation).
              RepaintBoundary(
                child: RotationTransition(
                  turns: _clock,
                  child: CustomPaint(
                    size: const Size(96, 96),
                    painter: _BadgePainter(a: a, b: b, c: c),
                  ),
                ),
              ),
              const Icon(Icons.music_note_rounded, color: Colors.white, size: 38),
            ],
          ),
        ),
      ),
    );
  }

  Widget _brand(Color a, Color b, Color txt) {
    return Column(
      children: [
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) => LinearGradient(colors: [b, a]).createShader(r),
          child: Text(
            'Astra Music',
            maxLines: 1,
            style: GoogleFonts.inter(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.9,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Crafting symphonies in code.',
          style: TextStyle(
            color: txt.withValues(alpha: 0.78),
            fontSize: 15.5,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  // ── Card: handle pill + Instagram ───────────────────────────────────────
  Widget _card(Color card, Color a, Color b, Color txt, Color muted) {
    return CustomPaint(
      foregroundPainter: _HairlinePainter(a: a, b: b, radius: 28),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          color: card.withValues(alpha: 0.72),
        ),
        child: Column(
          children: [
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _clock,
                builder: (_, __) {
                  final g = 0.5 + 0.5 * math.sin(_tau * 8 * _clock.value);
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(40),
                      color: a.withValues(alpha: 0.08),
                      border: Border.all(
                        color: a.withValues(alpha: 0.18 + 0.14 * g),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(colors: [b, a]),
                            boxShadow: [
                              BoxShadow(
                                color: a.withValues(alpha: 0.30 + 0.40 * g),
                                blurRadius: 6 + 8 * g,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          AppConstants.handle,
                          style: TextStyle(
                            color: txt,
                            fontSize: 16.5,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.1,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            Semantics(
              button: true,
              label: 'Open Instagram',
              child: AurumPressable(
                scaleAmount: 0.96,
                onTap: () => _open(AppConstants.instagram),
                child: Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: a.withValues(alpha: 0.07),
                    border: Border.all(color: a.withValues(alpha: 0.16), width: 0.8),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 38,
                        height: 38,
                        child: CustomPaint(painter: _InstagramPainter()),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'Follow on Instagram',
                          style: TextStyle(
                            color: txt,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(Icons.north_east_rounded, color: a, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tipText(Color muted) => Text(
        'Enjoying Astra? A small tip keeps the music playing.',
        textAlign: TextAlign.center,
        style: TextStyle(color: muted, fontSize: 14.5, height: 1.4),
      );

  // ── "I'll help" → opens the UPI donation page ───────────────────────────
  Widget _helpButton(Color a, Color b, Color c, Color on) {
    return Semantics(
      button: true,
      label: "I'll help",
      child: AurumPressable(
        scaleAmount: 0.95,
        onTap: () => _open(AppConstants.support, inApp: true),
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _clock,
            builder: (_, __) {
              final t = _clock.value;
              final glow = 0.5 + 0.5 * math.sin(_tau * 8 * t);
              final beat =
                  math.pow(math.max(0.0, math.sin(_tau * 12 * t)), 4).toDouble();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(40),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [b, a, c],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: a.withValues(alpha: 0.28 + 0.22 * glow),
                      blurRadius: 18 + 12 * glow,
                      spreadRadius: glow * 1.5,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.scale(
                      scale: 1 + 0.22 * beat,
                      child: Icon(Icons.favorite_rounded, color: on, size: 21),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      "I'll help",
                      style: TextStyle(
                        color: on,
                        fontSize: 18.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _footer(Color muted) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AurumPressable(
          onTap: () => _open(AppConstants.github),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(children: [
              Icon(Icons.terminal_rounded, size: 18, color: muted),
              const SizedBox(width: 7),
              Text('GitHub', style: TextStyle(color: muted, fontSize: 13.5)),
            ]),
          ),
        ),
        const SizedBox(width: 14),
        Text('v$_kVersion',
            style: TextStyle(color: muted.withValues(alpha: 0.8), fontSize: 13.5)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Painters
// ─────────────────────────────────────────────────────────────────────────────

/// Gradient hairline border.
class _HairlinePainter extends CustomPainter {
  _HairlinePainter({required this.a, required this.b, required this.radius});
  final Color a, b;
  final double radius;

  @override
  void paint(Canvas canvas, Size s) {
    final r = RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(radius))
        .deflate(0.5);
    canvas.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            a.withValues(alpha: 0.55),
            a.withValues(alpha: 0.08),
            b.withValues(alpha: 0.35),
          ],
        ).createShader(Offset.zero & s),
    );
  }

  @override
  bool shouldRepaint(_HairlinePainter o) => o.a != a || o.b != b;
}

/// 12-petal scalloped badge (same silhouette as the Astra app icon) in the
/// live theme accent. Static — rotation is a GPU transform.
class _BadgePainter extends CustomPainter {
  _BadgePainter({required this.a, required this.b, required this.c});
  final Color a, b, c;

  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width / 2, cy = s.height / 2;
    final base = s.width * 0.43, amp = s.width * 0.055;
    final path = Path();
    for (int i = 0; i <= 240; i++) {
      final th = i / 240 * _tau;
      final r = base + amp * math.cos(12 * th);
      final x = cx + r * math.cos(th), y = cy + r * math.sin(th);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    path.close();
    canvas.drawShadow(path, a.withValues(alpha: 0.55), 10, true);
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [b, a, c],
        ).createShader(Offset.zero & s),
    );
  }

  @override
  bool shouldRepaint(_BadgePainter o) => o.a != a || o.b != b || o.c != c;
}

/// Radial equalizer ring + expanding sound ripples + orbiting spark.
class _EmblemPainter extends CustomPainter {
  _EmblemPainter({
    required this.clock,
    required this.burst,
    required this.a,
    required this.b,
  }) : super(repaint: Listenable.merge([clock, burst]));

  final Animation<double> clock, burst;
  final Color a, b;

  static const int _bars = 48;

  @override
  void paint(Canvas canvas, Size s) {
    final t = clock.value;
    final k = 1.0 + 1.6 * math.sin(math.pi * burst.value); // tap boost
    final c = s.center(Offset.zero);
    final maxR = s.width / 2;

    // Ripples (3, evenly phased, 3 s period)
    final rp = Paint()..style = PaintingStyle.stroke;
    for (int i = 0; i < 3; i++) {
      final p = (t * 8 + i / 3) % 1.0;
      final r = 54 + (maxR - 54) * Curves.easeOutCubic.transform(p);
      rp
        ..strokeWidth = 1.4 * (1 - p) + 0.3
        ..color = a.withValues(alpha: (1 - p) * 0.38);
      canvas.drawCircle(c, r, rp);
    }

    // Radial equalizer bars
    final bp = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3.2;
    const inner = 60.0;
    for (int i = 0; i < _bars; i++) {
      final th = i / _bars * _tau - math.pi / 2;
      final wave = math.sin(_tau * 6 * t + i * 0.55).abs() * 0.55 +
          math.sin(_tau * 10 * t - i * 0.9).abs() * 0.30 +
          0.15;
      final len = (5 + 24 * wave) * k;
      final w01 = math.min(1.0, wave);
      final cs = math.cos(th), sn = math.sin(th);
      bp.color = Color.lerp(a, b, w01)!.withValues(alpha: 0.35 + 0.5 * w01);
      canvas.drawLine(
        Offset(c.dx + cs * inner, c.dy + sn * inner),
        Offset(c.dx + cs * (inner + len), c.dy + sn * (inner + len)),
        bp,
      );
    }

    // Orbiting spark
    final ang = _tau * 2 * t - math.pi / 2;
    final orb = Offset(c.dx + math.cos(ang) * 98, c.dy + math.sin(ang) * 98);
    canvas.drawCircle(orb, 5, Paint()..color = b.withValues(alpha: 0.25));
    canvas.drawCircle(orb, 2.4, Paint()..color = b);
  }

  @override
  bool shouldRepaint(_EmblemPainter o) => o.a != a || o.b != b;
}

/// Instagram glyph (brand gradient tile) — drawn in code, no asset needed.
class _InstagramPainter extends CustomPainter {
  const _InstagramPainter();

  @override
  void paint(Canvas canvas, Size s) {
    final tile = RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(s.width * 0.3));
    canvas.drawRRect(
      tile,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF), Color(0xFF515BD4)],
          stops: [0.0, 0.4, 0.75, 1.0],
        ).createShader(Offset.zero & s),
    );
    final w = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.07;
    final inset = s.width * 0.25;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(inset, inset, s.width - inset * 2, s.height - inset * 2),
        Radius.circular(s.width * 0.17),
      ),
      w,
    );
    canvas.drawCircle(s.center(Offset.zero), s.width * 0.135, w);
    canvas.drawCircle(
      Offset(s.width * 0.69, s.height * 0.31),
      s.width * 0.036,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_InstagramPainter o) => false;
}

class _Fly {
  const _Fly(this.x, this.phase, this.speed, this.size, this.drift, this.ph);
  final double x, phase, size, drift, ph;
  final int speed;
}

/// Full-screen ambient background: aurora orbs, two flowing waves, rising
/// fireflies. Seamless 24 s loop (all frequencies are integers).
class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.clock,
    required this.a,
    required this.b,
    required this.c,
    required this.dark,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final Color a, b, c;
  final bool dark;

  static final List<_Fly> _flies = () {
    final r = math.Random(7);
    return List.generate(
      14,
      (_) => _Fly(r.nextDouble(), r.nextDouble(), 1 + r.nextInt(2),
          1.1 + r.nextDouble() * 2.0, 6 + r.nextDouble() * 14, r.nextDouble() * _tau),
    );
  }();

  @override
  void paint(Canvas canvas, Size s) {
    final t = clock.value;
    final w = s.width, h = s.height;
    final k = dark ? 1.0 : 0.55;

    void orb(double x, double y, double r, Color col, double o) {
      final ctr = Offset(x, y);
      canvas.drawCircle(
        ctr,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [col.withValues(alpha: o), col.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: ctr, radius: r)),
      );
    }

    orb(w * (0.50 + 0.22 * math.sin(_tau * t)), h * (0.20 + 0.05 * math.cos(_tau * 2 * t)),
        w * 0.95, a, 0.30 * k);
    orb(w * (0.90 + 0.10 * math.cos(_tau * t + 1.2)), h * (0.55 + 0.07 * math.sin(_tau * t)),
        w * 0.85, b, 0.18 * k);
    orb(w * (0.10 + 0.14 * math.sin(_tau * 2 * t + 2.0)), h * (0.85 + 0.03 * math.sin(_tau * t)),
        w * 0.85, c, 0.26 * k);

    for (int i = 0; i < 2; i++) {
      final base = h * (0.86 + i * 0.05);
      final amp = 12.0 + i * 7;
      final freq = 1.4 + i * 0.7;
      final ph = _tau * (i == 0 ? t * 2 : -t * 3);
      final path = Path()..moveTo(0, h);
      for (double x = 0; x <= w + 10; x += 10) {
        path.lineTo(x, base + amp * math.sin(x / w * _tau * freq + ph));
      }
      path
        ..lineTo(w, h)
        ..close();
      final col = i == 0 ? a : b;
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              col.withValues(alpha: (0.16 - i * 0.05) * k),
              col.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromLTWH(0, base - amp, w, h - base + amp)),
      );
    }

    final p = Paint();
    for (final f in _flies) {
      final prog = (t * f.speed + f.phase) % 1.0;
      final y = h * (1.04 - 1.08 * prog);
      final x = f.x * w + math.sin(_tau * t * f.speed * 2 + f.ph) * f.drift;
      p.color = b.withValues(alpha: math.sin(math.pi * prog) * 0.55 * k);
      canvas.drawCircle(Offset(x, y), f.size, p);
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter o) =>
      o.a != a || o.b != b || o.c != c || o.dark != dark;
}
