import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_motion.dart';

// ═══════════════════════════════════════════════════════════════════════════
// AurumPromoScreen — one-time, full-screen animated promo (sign-in / playlist
// import). Replaces the tiny coach-tip bubbles that most people never noticed.
//
// Design rules (low-end phones, battery, zero annoyance):
//   • ONE AnimationController drives everything (no per-widget controllers)
//   • hero rings / orbit are a single CustomPainter bound to the controller
//     via `repaint:` — no widget rebuilds per frame, no BackdropFilter, no
//     blur layers, no saveLayer
//   • text / chips / button only use Fade/Slide/Scale transitions
//     (compositor-only, cheap)
//   • opaque route → Flutter stops painting the screens underneath
//   • auto-closes by itself after [AurumPromoScreen.totalDuration] (~5.5s);
//     a tap anywhere skips it instantly; the CTA pill runs the real action
//   • never shown when animations are off or Battery Saver is active
//     (see AurumPromoScreen.canShow)
// ═══════════════════════════════════════════════════════════════════════════

class AurumPromoData {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<(IconData, String)> chips;
  final String ctaLabel;

  /// Icon + short label drawn ON the real button's spot, so people see
  /// exactly where the feature lives ("Sign in from here").
  final IconData pointerIcon;
  final String pointerLabel;

  /// Optional benefit rows (icon, heading, short text). When present they
  /// replace the chips — easier to read for the sign-in pitch.
  final List<(IconData, String, String)> highlights;

  const AurumPromoData({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.chips,
    required this.ctaLabel,
    required this.pointerIcon,
    required this.pointerLabel,
    this.highlights = const [],
  });

  static const signIn = AurumPromoData(
    icon: Icons.auto_awesome_rounded,
    title: 'Unlock Astra AI',
    subtitle: 'Sign in and your recommendations go next level.',
    chips: [],
    highlights: [
      (
        Icons.auto_awesome_rounded,
        'Smarter picks',
        'Astra AI learns your taste with every song you play.'
      ),
      (
        Icons.cloud_sync_rounded,
        'Always in sync',
        'Your data syncs, so playlists and features are never missing.'
      ),
    ],
    ctaLabel: 'Sign in',
    pointerIcon: Icons.person_rounded,
    pointerLabel: 'Sign in from here',
  );

  static const importPlaylist = AurumPromoData(
    icon: Icons.cloud_download_rounded,
    title: 'Import any playlist',
    subtitle: 'Bring your Spotify & YouTube playlists to Astra in seconds.',
    chips: [
      (Icons.link_rounded, 'Paste a link'),
      (Icons.auto_fix_high_rounded, 'Auto-matched'),
      (Icons.bolt_rounded, 'Just in sec'),
    ],
    ctaLabel: 'Import now',
    pointerIcon: Icons.cloud_download_rounded,
    pointerLabel: 'Import from here',
  );
}

/// Opaque fade route. Resolves to `true` when the CTA was tapped, otherwise
/// `false` / `null` (skipped, auto-closed or back-pressed).
class AurumPromoRoute extends PageRouteBuilder<bool> {
  AurumPromoRoute(AurumPromoData data, {Rect? anchor})
      : super(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 240),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (_, __, ___) =>
              AurumPromoScreen(data: data, anchor: anchor),
          transitionsBuilder: (_, animation, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          ),
        );
}

class AurumPromoScreen extends StatefulWidget {
  final AurumPromoData data;

  /// Global rect of the real button this promo is about. When given, the
  /// promo marks that exact spot (ghost button + pulse + label) so people
  /// know where to tap afterwards.
  final Rect? anchor;
  const AurumPromoScreen({super.key, required this.data, this.anchor});

  /// Whole promo, start to auto-close. 5.5s: everything is on screen by ~2.6s,
  /// then ~3s to read it. The Skip button / a tap anywhere ends it at any time.
  static const totalDuration = Duration(milliseconds: 5500);

  /// False when the user turned animations off or Battery Saver is active —
  /// the promo is then skipped entirely (nothing is marked as seen).
  static bool get canShow => AurumMotion.enabled;

  @override
  State<AurumPromoScreen> createState() => _AurumPromoScreenState();
}

class _AurumPromoScreenState extends State<AurumPromoScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _disc;
  late final Animation<double> _title;
  late final Animation<double> _sub;
  late final Animation<double> _cta;
  late final Animation<double> _ptr;
  late final Animation<double> _ptrLabel;
  late final Animation<double> _skip;
  late final List<Animation<double>> _chips;
  late final List<Animation<double>> _rows;
  bool _closed = false;

  Animation<double> _iv(double a, double b, [Curve curve = Curves.easeOutCubic]) =>
      CurvedAnimation(parent: _c, curve: Interval(a, b, curve: curve));

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: AurumPromoScreen.totalDuration);
    _disc = _iv(0.00, 0.13, Curves.easeOutBack);
    _title = _iv(0.05, 0.18);
    _sub = _iv(0.10, 0.23);
    _rows = [
      for (var i = 0; i < widget.data.highlights.length; i++)
        _iv(0.16 + i * 0.05, 0.29 + i * 0.05),
    ];
    _chips = [
      for (var i = 0; i < widget.data.chips.length; i++)
        _iv(0.16 + i * 0.04, 0.29 + i * 0.04),
    ];
    _cta = _iv(0.35, 0.47);
    _skip = _iv(0.08, 0.18);
    _ptr = _iv(0.13, 0.25, Curves.easeOutBack);
    _ptrLabel = _iv(0.18, 0.31);

    AurumHaptics.light();
    _c.forward().whenComplete(() {
      if (mounted) _close(false);
    });
  }

  void _close(bool action) {
    if (_closed || !mounted) return;
    _closed = true;
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) {
      Navigator.of(context).pop(action);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _fadeUp(Animation<double> a, Widget child, {double dy = 14}) {
    return FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween<Offset>(begin: Offset(0, dy / 40), end: Offset.zero)
            .animate(a),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final accentLight = AurumTheme.accentLightOf(context);
    final bg = AurumTheme.bgOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final d = widget.data;
    // Short phones: smaller hero so the column never overflows.
    final mq = MediaQuery.of(context);
    final hero = mq.size.height < 640 ? 180.0 : 240.0;
    final a = widget.anchor;
    // Keep the hero clear of the marked button + its label.
    final topPad = a == null
        ? 0.0
        : math.min(math.max(0.0, a.bottom + 56 - mq.padding.top),
            mq.size.height * 0.35);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: bg,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _close(false),
          child: Stack(
            children: [
              // Soft accent glow — a plain RadialGradient (no blur, no
              // shader-heavy effects), painted once.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, -0.35),
                        radius: 0.95,
                        colors: [
                          accent.withOpacity(dark ? 0.24 : 0.16),
                          bg,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: SafeArea(
                child: Column(
                  children: [
                    SizedBox(height: topPad),
                    Expanded(
                      child: Center(
                        child: FittedBox(
                          // scales the block down on short screens instead of
                          // ever overflowing
                          fit: BoxFit.scaleDown,
                          child: SizedBox(
                            width: mq.size.width,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                    // ── Hero: rings + orbit + disc ──
                    RepaintBoundary(
                      child: SizedBox(
                        width: hero,
                        height: hero,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _HeroPainter(
                                  t: _c,
                                  color: accent,
                                  lightColor: accentLight,
                                  discRadius: 48,
                                ),
                              ),
                            ),
                            ScaleTransition(
                              scale: _disc,
                              child: Container(
                                width: 96,
                                height: 96,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient:
                                      AurumTheme.accentGradientOf(context),
                                  boxShadow: [
                                    BoxShadow(
                                      color: accent.withOpacity(0.38),
                                      blurRadius: 26,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: Icon(d.icon,
                                    color: Colors.white, size: 44),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    _fadeUp(
                      _title,
                      Text(
                        d.title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _fadeUp(
                      _sub,
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 36),
                        child: Text(
                          d.subtitle,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AurumTheme.textMutedOf(context),
                            fontSize: 15,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (d.highlights.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: Column(
                          children: [
                            for (var i = 0; i < d.highlights.length; i++)
                              Padding(
                                padding: EdgeInsets.only(
                                    bottom:
                                        i == d.highlights.length - 1 ? 0 : 10),
                                child: _fadeUp(
                                  _rows[i],
                                  _HighlightRow(
                                    icon: d.highlights[i].$1,
                                    heading: d.highlights[i].$2,
                                    text: d.highlights[i].$3,
                                    accent: accent,
                                  ),
                                  dy: 12,
                                ),
                              ),
                          ],
                        ),
                      )
                    else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < d.chips.length; i++)
                            _fadeUp(
                              _chips[i],
                              _Chip(
                                icon: d.chips[i].$1,
                                label: d.chips[i].$2,
                                accent: accent,
                              ),
                              dy: 10,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    _fadeUp(
                      _cta,
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          AurumHaptics.medium();
                          _close(true);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 32, vertical: 14),
                          decoration: BoxDecoration(
                            gradient: AurumTheme.accentGradientOf(context),
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: Text(
                            d.ctaLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Explicit Skip button (a tap anywhere also skips) + a thin
                    // countdown bar that shows it closes by itself.
                    FadeTransition(
                      opacity: _skip,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          AurumHaptics.selection();
                          _close(false);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 26, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                                color: AurumTheme.textMutedOf(context)
                                    .withOpacity(0.45)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Skip',
                                style: TextStyle(
                                  color: AurumTheme.textSecondaryOf(context),
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.arrow_forward_rounded,
                                  size: 16,
                                  color: AurumTheme.textSecondaryOf(context)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(64, 0, 64, 18),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: AnimatedBuilder(
                          animation: _c,
                          builder: (_, __) => LinearProgressIndicator(
                            value: 1 - _c.value,
                            minHeight: 3,
                            backgroundColor: accent.withOpacity(0.14),
                            valueColor: AlwaysStoppedAnimation(accent),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                ),
              ),
              if (a != null) ..._pointer(context, a, accent, mq.size),
            ],
          ),
        ),
      ),
    );
  }

  /// Ghost copy of the real button at its exact on-screen spot, pulse rings
  /// and a small "…from here" label with an arrow. Tapping the ghost runs the
  /// action, same as the CTA.
  List<Widget> _pointer(BuildContext context, Rect a, Color accent, Size screen) {
    final d = widget.data;
    const labelW = 150.0;
    final cx = a.center.dx;
    final left = (cx - labelW / 2).clamp(16.0, screen.width - labelW - 16.0);
    final arrowLeft = (cx - left - 6).clamp(14.0, labelW - 26.0);
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _PointerPainter(t: _c, anchor: a, color: accent),
            ),
          ),
        ),
      ),
      Positioned.fromRect(
        rect: a,
        child: ScaleTransition(
          scale: _ptr,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              AurumHaptics.medium();
              _close(true);
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: AurumTheme.accentGradientOf(context),
              ),
              child: Icon(d.pointerIcon,
                  color: Colors.white, size: a.shortestSide * 0.5),
            ),
          ),
        ),
      ),
      Positioned(
        left: left.toDouble(),
        top: a.bottom + 10,
        width: labelW,
        child: IgnorePointer(
          child: _fadeUp(
            _ptrLabel,
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 5),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    d.pointerLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Positioned(
                  left: arrowLeft.toDouble(),
                  top: 0,
                  child: Transform.rotate(
                    angle: math.pi / 4,
                    child: Container(width: 11, height: 11, color: accent),
                  ),
                ),
              ],
            ),
            dy: 10,
          ),
        ),
      ),
    ];
  }
}

class _HighlightRow extends StatelessWidget {
  final IconData icon;
  final String heading;
  final String text;
  final Color accent;
  const _HighlightRow({
    required this.icon,
    required this.heading,
    required this.text,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withOpacity(0.24)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  heading,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  const _Chip({required this.icon, required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pulsing rings + a rotating arc + 3 orbiting dots. Driven straight off the
/// controller (`super(repaint: t)`) so no widget rebuilds happen per frame.
/// Paint objects are reused; only canvas primitives are drawn.
class _HeroPainter extends CustomPainter {
  final Animation<double> t;
  final Color color;
  final Color lightColor;
  final double discRadius;

  final Paint _ring = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  final Paint _arc = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.5
    ..strokeCap = StrokeCap.round;
  final Paint _dot = Paint();
  final Paint _spark = Paint();
  // unit 4-point sparkle, built once and only scaled/translated per frame
  static final Path _star = Path()
    ..moveTo(0, -1)
    ..quadraticBezierTo(0.14, -0.14, 1, 0)
    ..quadraticBezierTo(0.14, 0.14, 0, 1)
    ..quadraticBezierTo(-0.14, 0.14, -1, 0)
    ..quadraticBezierTo(-0.14, -0.14, 0, -1)
    ..close();
  static const _sparks = <(double, double, double)>[
    // angle, radius factor, size
    (-0.9, 0.93, 8.0),
    (0.5, 0.97, 6.0),
    (2.2, 0.92, 7.0),
    (3.6, 0.96, 5.0),
    (5.2, 0.9, 6.5),
  ];

  _HeroPainter({
    required this.t,
    required this.color,
    required this.lightColor,
    required this.discRadius,
  }) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    final c = size.center(Offset.zero);
    final maxR = size.shortestSide / 2;
    // everything fades in over the first 10% of the timeline
    final appear = Curves.easeOut.transform((v / 0.10).clamp(0.0, 1.0));
    if (appear <= 0) return;

    // 3 expanding rings, 2 full cycles over the promo
    for (var i = 0; i < 3; i++) {
      final phase = (v * 5.0 + i / 3.0) % 1.0;
      final r = discRadius + (maxR - discRadius) * Curves.easeOut.transform(phase);
      final a = (1.0 - phase) * 0.5 * appear;
      _ring.color = color.withOpacity(a);
      canvas.drawCircle(c, r, _ring);
    }

    // rotating arc just outside the disc
    final arcR = discRadius + 10;
    _arc.color = lightColor.withOpacity(0.85 * appear);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: arcR),
      v * 2 * math.pi * 3.8,
      math.pi / 2,
      false,
      _arc,
    );

    // twinkling sparkles (5 tiny paths — cheap)
    for (var i = 0; i < _sparks.length; i++) {
      final sp = _sparks[i];
      final tw = 0.5 + 0.5 * math.sin(v * 2 * math.pi * 5 + i * 1.7);
      _spark.color = Colors.white.withOpacity(0.15 + 0.7 * tw * appear);
      canvas.save();
      canvas.translate(c.dx + math.cos(sp.$1) * maxR * sp.$2,
          c.dy + math.sin(sp.$1) * maxR * sp.$2);
      final k = sp.$3 * (0.6 + 0.4 * tw);
      canvas.scale(k, k);
      canvas.drawPath(_star, _spark);
      canvas.restore();
    }

    // 3 orbiting dots
    final orbitR = discRadius + 34;
    for (var i = 0; i < 3; i++) {
      final ang = -v * 2 * math.pi * 2.6 + i * (2 * math.pi / 3);
      _dot.color = lightColor.withOpacity(0.9 * appear);
      canvas.drawCircle(
        c + Offset(math.cos(ang), math.sin(ang)) * orbitR,
        3.2,
        _dot,
      );
    }
  }

  @override
  bool shouldRepaint(_HeroPainter old) =>
      old.color != color || old.lightColor != lightColor;
}

/// Two soft pulse rings around the marked button (starts at ~36% of the
/// timeline, together with the ghost button).
class _PointerPainter extends CustomPainter {
  final Animation<double> t;
  final Rect anchor;
  final Color color;
  final Paint _p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5;

  _PointerPainter({required this.t, required this.anchor, required this.color})
      : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    final appear = Curves.easeOut.transform(((v - 0.13) / 0.10).clamp(0.0, 1.0));
    if (appear <= 0) return;
    final r0 = anchor.shortestSide / 2;
    for (var i = 0; i < 2; i++) {
      final ph = (v * 7.5 + i / 2.0) % 1.0;
      _p.color = color.withOpacity((1.0 - ph) * 0.6 * appear);
      canvas.drawCircle(
          anchor.center, r0 + 4 + 20 * Curves.easeOut.transform(ph), _p);
    }
  }

  @override
  bool shouldRepaint(_PointerPainter old) =>
      old.color != color || old.anchor != anchor;
}
