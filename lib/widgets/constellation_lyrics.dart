// =============================================================================
// FILE: lib/widgets/constellation_lyrics.dart
// PROJECT: Astra Music
//
// "Impressive lyrics" — constellation style. Every word of the active line
// becomes a star, joined to the previous word by a thin line. The current
// word is big and glowing, earlier words shrink and dim, and the camera
// glides toward the active star. Drawn on a transparent canvas, so whatever
// backdrop the lyrics screen already has (artwork gradient etc.) stays.
//
// Sync: position comes from PlayerProvider (coarse 500ms ticks), anchored
// and extrapolated every frame with a Stopwatch, so words land on time and
// a seek snaps instantly. Words are spread across each synced line by
// length (LRC has no per-word times).
// =============================================================================

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import '../models/lyrics.dart';
import '../providers/player_provider.dart';

class ConstellationLyrics extends StatefulWidget {
  final List<LyricLine> lines;

  /// Theme accent (gold in the Aurum theme). Text and stars derive from it.
  final Color accent;

  /// True only when the lyrics sit on a LIGHT backdrop (dark text, no glow).
  final bool isLight;

  const ConstellationLyrics({
    super.key,
    required this.lines,
    required this.accent,
    this.isLight = false,
  });

  @override
  State<ConstellationLyrics> createState() => _ConstellationLyricsState();
}

class _ConstellationLyricsState extends State<ConstellationLyrics>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final PlayerProvider _player;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  final Stopwatch _sw = Stopwatch()..start();
  late _Sim _sim;

  Duration _anchorPos = Duration.zero;
  int _anchorAtMs = 0;
  bool _wasPlaying = false;
  int _lastTickMs = 0;
  int _idle = 0;
  Size? _size;

  // Same lead the other lyrics views use so the highlight lands WITH the vocal.
  static const int _leadMs = 250;
  // Never extrapolate further than this past the last real position update.
  static const int _maxExtrapolateMs = 700;

  @override
  void initState() {
    super.initState();
    _player = context.read<PlayerProvider>();
    _anchorPos = _player.position;
    _wasPlaying = _player.isPlaying;
    _anchorAtMs = _sw.elapsedMilliseconds;
    _player.addListener(_onPlayer);
    _sim = _Sim(_buildLines(widget.lines));
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant ConstellationLyrics old) {
    super.didUpdateWidget(old);
    if (!identical(old.lines, widget.lines)) {
      _sim = _Sim(_buildLines(widget.lines));
    }
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayer);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _onPlayer() {
    final p = _player.position;
    final pl = _player.isPlaying;
    if (p != _anchorPos || pl != _wasPlaying) {
      _anchorPos = p;
      _wasPlaying = pl;
      _anchorAtMs = _sw.elapsedMilliseconds;
    }
  }

  int _posMs(int nowMs) {
    var ms = _anchorPos.inMilliseconds;
    if (_player.isPlaying) {
      ms += math.min(nowMs - _anchorAtMs, _maxExtrapolateMs);
    }
    return ms + _leadMs;
  }

  void _onTick(Duration _) {
    final sz = _size;
    if (sz == null) return;
    // Paused and nothing animating: drop to ~15fps to save battery.
    if (!_player.isPlaying && _sim.parts.isEmpty && (_idle++ % 4 != 0)) return;
    final now = _sw.elapsedMilliseconds;
    final dt = (now - _lastTickMs).clamp(1, 50).toDouble();
    _lastTickMs = now;
    _sim.update(dt, _posMs(now), now.toDouble(), sz);
    _frame.value++;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _size = Size(c.maxWidth, c.maxHeight);
        return RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _ConstellationPainter(
              sim: _sim,
              accent: widget.accent,
              isLight: widget.isLight,
              repaint: _frame,
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Data
// ─────────────────────────────────────────────────────────────────────────────
class _CLine {
  final int startMs;
  final int endMs;
  final List<String> words;
  final List<int> wordMs; // absolute ms each word lights up
  final List<Offset> pts; // normalised 0..1 star positions
  _CLine(this.startMs, this.endMs, this.words, this.wordMs, this.pts);
}

List<_CLine> _buildLines(List<LyricLine> src) {
  final out = <_CLine>[];
  for (var i = 0; i < src.length; i++) {
    final text = src[i].text.trim();
    if (text.isEmpty) continue;
    final words = text.split(RegExp(r'\s+'));
    final start = src[i].time.inMilliseconds;
    final nextStart =
        i + 1 < src.length ? src[i + 1].time.inMilliseconds : start + 6000;
    final end = math.min(nextStart, start + 12000);
    final dur = math.max(end - start, 600);
    var span = math.max((math.min(dur, 8000) * 0.85).round(), words.length * 120);
    span = math.min(span, dur);

    final weights = words.map((w) => (w.length + 2).toDouble()).toList();
    final total = weights.fold<double>(0, (a, b) => a + b);
    final wordMs = <int>[];
    var acc = 0.0;
    for (var k = 0; k < words.length; k++) {
      wordMs.add(start + (acc / total * span).round());
      acc += weights[k];
    }

    final r = math.Random(i * 7919 + 13);
    final n = words.length;
    final perm = List<int>.generate(n, (k) => k)..shuffle(r);
    final pts = <Offset>[];
    for (var k = 0; k < n; k++) {
      final fx = n > 1 ? perm[k] / (n - 1) : 0.5;
      final dir = k % 2 == 0 ? -1.0 : 1.0;
      final x = 0.14 + 0.72 * fx + (r.nextDouble() - 0.5) * 0.05;
      final y = 0.5 + dir * (0.07 + r.nextDouble() * 0.13) + (r.nextDouble() - 0.5) * 0.05;
      pts.add(Offset(x, y));
    }
    out.add(_CLine(start, end, words, wordMs, pts));
  }
  return out;
}

class _Star {
  final double x, y, d, ph;
  const _Star(this.x, this.y, this.d, this.ph);
}

class _Spark {
  double x, y, life = 0;
  final double vx, vy, max;
  _Spark(this.x, this.y, this.vx, this.vy, this.max);
}

// ─────────────────────────────────────────────────────────────────────────────
// Simulation (everything that changes over time lives here, not in paint)
// ─────────────────────────────────────────────────────────────────────────────
class _Sim {
  final List<_CLine> lines;
  final List<_Star> stars;
  final List<_Spark> parts = [];
  final math.Random _rnd = math.Random();

  double camX = 0, camY = 0;
  int li = -1;
  int act = -1;
  int posMs = 0;
  double tMs = 0;
  Size size = Size.zero;
  int _key = -1;

  _Sim(this.lines) : stars = _makeStars();

  static List<_Star> _makeStars() {
    final r = math.Random(42);
    return List<_Star>.generate(
      60,
      (_) => _Star(r.nextDouble(), r.nextDouble(), 0.2 + r.nextDouble() * 0.8,
          r.nextDouble() * 6.283),
    );
  }

  int _findLine(int pos) {
    var lo = 0, hi = lines.length - 1, res = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].startMs <= pos) {
        res = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (res >= 0 && pos < lines[res].endMs) return res;
    return -1;
  }

  void update(double dt, int pos, double t, Size sz) {
    posMs = pos;
    tMs = t;
    size = sz;
    li = lines.isEmpty ? -1 : _findLine(pos);
    act = -1;
    if (li >= 0) {
      final L = lines[li];
      for (var i = 0; i < L.words.length; i++) {
        if (pos >= L.wordMs[i]) act = i;
      }
      final key = li * 64 + act;
      if (key != _key) {
        _key = key;
        if (act >= 0) _burst(L.pts[act].dx * sz.width, L.pts[act].dy * sz.height);
      }
      final tx = act >= 0 ? (sz.width / 2 - L.pts[act].dx * sz.width) * 0.28 : 0.0;
      final ty = act >= 0 ? (sz.height / 2 - L.pts[act].dy * sz.height) * 0.28 : 0.0;
      final k = 1 - math.exp(-dt / 380);
      camX += (tx - camX) * k;
      camY += (ty - camY) * k;
    } else {
      _key = -1;
      final k = 1 - math.exp(-dt / 380);
      camX += (0 - camX) * k;
      camY += (0 - camY) * k;
    }
    for (var i = parts.length - 1; i >= 0; i--) {
      final q = parts[i];
      q.life += dt;
      q.x += q.vx * dt;
      q.y += q.vy * dt;
      if (q.life >= q.max) parts.removeAt(i);
    }
  }

  void _burst(double x, double y) {
    for (var i = 0; i < 12; i++) {
      final a = _rnd.nextDouble() * 6.2832;
      final sp = 0.02 + _rnd.nextDouble() * 0.07;
      parts.add(_Spark(x, y, math.cos(a) * sp, math.sin(a) * sp, 700 + _rnd.nextDouble() * 600));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Painter
// ─────────────────────────────────────────────────────────────────────────────
double _c01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
double _lerp(double a, double b, double t) => a + (b - a) * t;
double _easeOut(double t) {
  final u = 1 - _c01(t);
  return 1 - u * u * u;
}

Color _a(Color c, double a) => c.withAlpha((_c01(a) * 255).round());

class _ConstellationPainter extends CustomPainter {
  final _Sim sim;
  final Color accent;
  final bool isLight;

  _ConstellationPainter({
    required this.sim,
    required this.accent,
    required this.isLight,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  bool shouldRepaint(covariant _ConstellationPainter old) =>
      old.accent != accent || old.isLight != isLight || !identical(old.sim, sim);

  @override
  void paint(Canvas canvas, Size size) {
    final dark = !isLight;
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0 || sim.size == Size.zero) return;

    final deep = isLight
        ? (HSLColor.fromColor(accent).withLightness(0.30).toColor())
        : accent;
    final text = isLight
        ? const Color(0xFF1A1610)
        : (Color.lerp(Colors.white, accent, 0.16) ?? Colors.white);
    final dim = isLight
        ? (HSLColor.fromColor(accent).withLightness(0.26).toColor())
        : (Color.lerp(accent, Colors.white, 0.1) ?? accent);

    final t = sim.tMs;
    // ── ambient dust ──
    for (final s in sim.stars) {
      final y = (s.y * h - t * 0.004 * s.d) % h;
      final x = s.x * w + sim.camX * s.d * 0.4;
      final tw = 0.5 + 0.5 * math.sin(t / 700 + s.ph);
      final al = (0.10 + 0.45 * tw) * s.d * (dark ? 1.0 : 0.7);
      canvas.drawCircle(Offset(x, y), 0.4 + 0.9 * s.d, Paint()..color = _a(deep, al));
    }

    if (sim.li < 0) return;
    final L = sim.lines[sim.li];
    final act = sim.act;
    final n = L.words.length;
    final pos = sim.posMs;
    final tl = (pos - L.startMs).toDouble();
    final dur = (L.endMs - L.startMs).toDouble();

    final fo = math.min(350.0, dur * 0.3);
    final env = _c01(tl / 300) * (1 - _c01((tl - (dur - fo)) / fo));

    final big = _c01((math.min(w, h) * 0.095 - 22) / 14) * 14 + 22; // 22..36
    final small = big * 0.38;
    const pad = 12.0;
    final lineBase = dark ? 0.22 : 0.38;

    canvas.save();
    canvas.translate(sim.camX + math.sin(t / 2600) * 4, sim.camY + math.cos(t / 3100) * 4);

    final dot = Paint();
    for (var i = act + 1; i < n; i++) {
      canvas.drawCircle(Offset(L.pts[i].dx * w, L.pts[i].dy * h), 1.6, dot..color = _a(deep, 0.16 * env));
    }

    // ── constellation lines ──
    final linePaint = Paint()
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var i = 1; i <= act; i++) {
      final p0 = Offset(L.pts[i - 1].dx * w, L.pts[i - 1].dy * h);
      final p1 = Offset(L.pts[i].dx * w, L.pts[i].dy * h);
      final p = _easeOut((pos - L.wordMs[i]) / 380.0);
      final head = Offset(p0.dx + (p1.dx - p0.dx) * p, p0.dy + (p1.dy - p0.dy) * p);
      final extra = i == act ? 0.25 * (1 - p) : 0.0;
      canvas.drawLine(p0, head, linePaint..color = _a(deep, (lineBase + extra) * env));
      if (p < 1) {
        canvas.drawCircle(head, 2, Paint()..color = _a(text, env));
      }
    }

    // ── stars + words ──
    for (var i = 0; i <= act; i++) {
      final px = L.pts[i].dx * w;
      final py = L.pts[i].dy * h;
      final age = (pos - L.wordMs[i]).toDouble();
      final ap = _easeOut(age / 340);
      final sh = i < act ? _easeOut((pos - L.wordMs[i + 1]) / 650.0) : 0.0;
      var fs = _lerp(big * (0.55 + 0.45 * ap), small, sh);
      final alpha = _lerp(1, dark ? 0.55 : 0.7, sh) * ap * env;
      final col = Color.lerp(text, dim, sh) ?? text;

      TextStyle style(double size, {Paint? fg}) => TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            height: 1.0,
            color: fg == null ? _a(col, alpha) : null,
            foreground: fg,
          );

      var tp = TextPainter(
        text: TextSpan(text: L.words[i], style: style(fs)),
        textDirection: TextDirection.ltr,
      )..layout();
      final maxW = w - pad * 2;
      if (tp.width > maxW && tp.width > 0) {
        final ratio = maxW / tp.width;
        tp.dispose();
        fs = fs * ratio;
        tp = TextPainter(
          text: TextSpan(text: L.words[i], style: style(fs)),
          textDirection: TextDirection.ltr,
        )..layout();
      }

      var tx = px;
      if (sh < 1) {
        final sx = px + sim.camX;
        final lo = tp.width / 2 + pad;
        final hi = w - tp.width / 2 - pad;
        final c = lo > hi ? w / 2 : (sx < lo ? lo : (sx > hi ? hi : sx));
        tx = px + (c - sx) * (1 - sh);
      }
      final cy = py - (fs * 0.62 + 8) + (1 - ap) * 10;
      final at = Offset(tx - tp.width / 2, cy - tp.height / 2);

      if (dark && i == act && sh < 0.5 && alpha > 0.05) {
        final g = TextPainter(
          text: TextSpan(
            text: L.words[i],
            style: style(
              fs,
              fg: Paint()
                ..color = _a(accent, 0.75 * alpha)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        g.paint(canvas, Offset(tx - g.width / 2, cy - g.height / 2));
        g.dispose();
      }
      tp.paint(canvas, at);
      tp.dispose();

      // star
      final c = Offset(px, py);
      final sr = _lerp(8, 3.2, sh) * ap;
      if (sr > 0.5) {
        final glowR = sr * 3.4;
        final gA = (dark ? 0.35 : 0.18) * alpha;
        if (i == act) {
          canvas.drawCircle(
            c,
            glowR,
            Paint()
              ..shader = ui.Gradient.radial(
                c,
                glowR,
                [_a(deep, gA), _a(deep, 0)],
              ),
          );
        } else {
          canvas.drawCircle(c, glowR * 0.6, Paint()..color = _a(deep, gA * 0.35));
        }
        _sparkle(canvas, c, sr, i == act ? t / 900 : 0, _a(Color.lerp(text, deep, 0.5) ?? deep, alpha));
      }
      if (i == act) {
        if (age < 800) {
          canvas.drawCircle(
            c,
            _easeOut(age / 800) * 46,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = _a(deep, (1 - age / 800) * 0.45 * env),
          );
        }
        canvas.drawCircle(
          c,
          13 + math.sin(t / 260) * 1.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = _a(deep, 0.3 * env),
        );
      }
    }

    // ── sparks ──
    final sp = Paint();
    for (final q in sim.parts) {
      final a = 1 - q.life / q.max;
      if (a <= 0) continue;
      canvas.drawCircle(Offset(q.x, q.y), 0.4 + 1.6 * a, sp..color = _a(deep, a));
    }

    canvas.restore();
  }

  void _sparkle(Canvas canvas, Offset c, double r, double rot, Color color) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final rad = i.isEven ? r : r * 0.22;
      final ang = rot + i * math.pi / 4 - math.pi / 2;
      final x = c.dx + math.cos(ang) * rad;
      final y = c.dy + math.sin(ang) * rad;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }
}
