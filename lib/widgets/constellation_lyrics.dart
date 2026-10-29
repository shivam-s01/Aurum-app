// =============================================================================
// FILE: lib/widgets/constellation_lyrics.dart
// PROJECT: Astra Music
//
// "Impressive lyrics" — constellation style. Every word of the active line
// becomes a star, joined to the previous word by a thin line. The current
// word is big and glowing, earlier words shrink and dim, and the camera
// glides toward the active star. Drawn over a living night-sky (parallax
// stars, drifting nebula glow, rare shooting stars) on a transparent canvas,
// so the screen's own backdrop still shows through.
//
// SYNC (no bump): PlayerProvider reports position in coarse 500ms ticks and
// the native engine sometimes corrects it a little BACKWARDS. Painting that
// directly makes words/stars snap back. Instead we keep our own display
// clock that only ever moves forward while playing and gently speeds up or
// slows down (0.6x-1.6x) to converge on the real position. Only a genuine
// seek (a jump > 0.9s) snaps instantly.
// =============================================================================

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import '../models/lyrics.dart';
import '../providers/player_provider.dart';
import '../services/audio_prefs.dart';

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

  // Last real position from the provider + when we received it.
  Duration _anchorPos = Duration.zero;
  int _anchorAtMs = 0;
  bool _wasPlaying = false;

  // Our own forward-only display clock (ms, includes the lead).
  double _disp = 0;
  bool _inited = false;
  bool _needSnap = false;

  int _lastTickMs = 0;
  int _idle = 0;
  int _skip = 0;
  bool _reduceMotion = false;
  Size? _size;

  // Same lead the other lyrics views use so the highlight lands WITH the vocal.
  static const double _leadMs = 250;
  // Never extrapolate further than this past the last real position update.
  static const int _maxExtrapolateMs = 700;
  // A jump bigger than this between what we expected and what the player
  // reports is a real seek, not jitter.
  static const int _seekJumpMs = 900;

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
      _sim.dispose();
      _sim = _Sim(_buildLines(widget.lines));
      _needSnap = true;
    }
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayer);
    _ticker.dispose();
    _frame.dispose();
    _sim.dispose();
    super.dispose();
  }

  double _estimate(int nowMs) {
    var ms = _anchorPos.inMilliseconds.toDouble();
    if (_player.isPlaying) {
      ms += math.min(nowMs - _anchorAtMs, _maxExtrapolateMs).toDouble();
    }
    return ms + _leadMs;
  }

  void _onPlayer() {
    final now = _sw.elapsedMilliseconds;
    final p = _player.position;
    final pl = _player.isPlaying;
    if (p == _anchorPos && pl == _wasPlaying) return;
    // What we thought the position was a moment ago (no lead) vs what the
    // player says now. A big gap = seek / song restart / app resume.
    final expected = _estimate(now) - _leadMs;
    if ((p.inMilliseconds - expected).abs() > _seekJumpMs) _needSnap = true;
    _anchorPos = p;
    _wasPlaying = pl;
    _anchorAtMs = now;
  }

  void _onTick(Duration _) {
    final sz = _size;
    if (sz == null) return;
    final playing = _player.isPlaying;
    final lite = _reduceMotion || AudioPrefs.batterySaverActiveNotifier.value;
    // Battery saver / reduce-motion: ~30fps.
    if (lite && (_skip++ & 1) == 1) return;
    // Paused and fully settled: only refresh occasionally.
    if (!playing && _sim.parts.isEmpty && _sim.settled && (_idle++ % 6 != 0)) {
      return;
    }
    final now = _sw.elapsedMilliseconds;
    final dt = (now - _lastTickMs).clamp(1, 50).toDouble();
    _lastTickMs = now;

    final est = _estimate(now);
    if (!_inited || _needSnap) {
      _disp = est;
      _inited = true;
      _needSnap = false;
    } else {
      final diff = est - _disp;
      if (diff.abs() > 1500) {
        _disp = est; // safety net: far off for any reason
      } else if (playing) {
        // Forward-only: speed up / slow down gently, never step back.
        final rate = (1 + diff / 1200).clamp(0.6, 1.6).toDouble();
        _disp += dt * rate;
      } else if (diff > 0) {
        _disp += diff * 0.2;
      }
    }

    _sim.update(dt, _disp.round(), playing, lite, sz);
    _frame.value++;
  }

  @override
  Widget build(BuildContext context) {
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
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
    var span =
        math.max((math.min(dur, 8000) * 0.85).round(), words.length * 120);
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
      final y = 0.5 +
          dir * (0.07 + r.nextDouble() * 0.13) +
          (r.nextDouble() - 0.5) * 0.05;
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

class _Shoot {
  double x, y, l = 0;
  final double vx, vy, m;
  _Shoot(this.x, this.y, this.vx, this.vy, this.m);
}

// ─────────────────────────────────────────────────────────────────────────────
// Simulation (everything that changes over time lives here, not in paint)
// ─────────────────────────────────────────────────────────────────────────────
class _Sim {
  final List<_CLine> lines;
  final List<_Star> stars;
  final List<_Spark> parts = [];
  final math.Random _rnd = math.Random();
  _Shoot? shoot;
  double _shootIn = 9000;

  // Render caches. A word's text only needs laying out again when its size
  // or colour actually changes, and a gradient only when its radius/alpha
  // changes, so steady frames re-use everything instead of rebuilding it.
  final Map<int, TextPainter> tpCache = {};
  final Map<int, TextPainter> glowCache = {};
  final Map<int, ui.Shader> shCache = {};
  int _cacheLi = -2;

  void _clearText() {
    for (final t in tpCache.values) {
      t.dispose();
    }
    for (final t in glowCache.values) {
      t.dispose();
    }
    tpCache.clear();
    glowCache.clear();
  }

  void dispose() {
    _clearText();
    shCache.clear();
  }

  double camX = 0, camY = 0;
  int li = -1;
  int act = -1;
  int posMs = 0;
  double amb = 0; // ambient clock: advances only while playing
  bool lite = false;
  bool settled = false;
  Size size = Size.zero;
  int _key = -1;

  _Sim(this.lines) : stars = _makeStars();

  static List<_Star> _makeStars() {
    final r = math.Random(42);
    return List<_Star>.generate(
      72,
      (i) => _Star(r.nextDouble(), r.nextDouble(), 0.2 + r.nextDouble() * 0.8,
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

  void update(double dt, int pos, bool playing, bool isLite, Size sz) {
    posMs = pos;
    size = sz;
    lite = isLite;
    if (playing) amb += dt;

    li = lines.isEmpty ? -1 : _findLine(pos);
    // Safe point to evict caches: update() always runs before paint().
    if (li != _cacheLi || tpCache.length > 160 || glowCache.length > 40) {
      _clearText();
      _cacheLi = li;
    }
    if (shCache.length > 40) shCache.clear();
    act = -1;
    var tx = 0.0, ty = 0.0;
    if (li >= 0) {
      final L = lines[li];
      for (var i = 0; i < L.words.length; i++) {
        if (pos >= L.wordMs[i]) act = i;
      }
      final key = li * 64 + act;
      if (key != _key) {
        _key = key;
        if (act >= 0 && !lite) {
          _burst(L.pts[act].dx * sz.width, L.pts[act].dy * sz.height);
        }
      }
      if (act >= 0) {
        tx = (sz.width / 2 - L.pts[act].dx * sz.width) * 0.2;
        ty = (sz.height / 2 - L.pts[act].dy * sz.height) * 0.2;
      }
    } else {
      _key = -1;
    }
    final k = 1 - math.exp(-dt / 520);
    camX += (tx - camX) * k;
    camY += (ty - camY) * k;
    settled = (tx - camX).abs() < 0.3 && (ty - camY).abs() < 0.3;

    for (var i = parts.length - 1; i >= 0; i--) {
      final q = parts[i];
      q.life += dt;
      q.x += q.vx * dt;
      q.y += q.vy * dt;
      if (q.life >= q.max) parts.removeAt(i);
    }

    // Rare shooting star (dark sky only, never in lite mode).
    if (!lite && playing) {
      final s = shoot;
      if (s == null) {
        _shootIn -= dt;
        if (_shootIn <= 0) {
          final w = sz.width, h = sz.height;
          final sc = w / 340;
          shoot = _Shoot(w * (0.35 + _rnd.nextDouble() * 0.65),
              h * _rnd.nextDouble() * 0.45, -0.55 * sc, 0.3 * sc, 700);
          _shootIn = 14000 + _rnd.nextDouble() * 12000;
        }
      } else {
        s.l += dt;
        s.x += s.vx * dt;
        s.y += s.vy * dt;
        if (s.l >= s.m) shoot = null;
      }
    }
  }

  void _burst(double x, double y) {
    for (var i = 0; i < 12; i++) {
      final a = _rnd.nextDouble() * 6.2832;
      final sp = 0.02 + _rnd.nextDouble() * 0.07;
      parts.add(_Spark(x, y, math.cos(a) * sp, math.sin(a) * sp,
          700 + _rnd.nextDouble() * 600));
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

  // One reusable Paint/Path for the whole frame (drawn immediately, so
  // sharing is safe) instead of allocating dozens per frame.
  final Paint _p = Paint();
  // Used ONLY for gradient draws and never has its colour changed, so it
  // behaves exactly like a fresh Paint() would (opaque, shader-only).
  final Paint _sp = Paint();
  final Path _path = Path();

  // Theme colours depend only on accent + isLight, so compute them once.
  late final Color _deep = isLight
      ? HSLColor.fromColor(accent).withLightness(0.30).toColor()
      : accent;
  late final Color _text = isLight
      ? const Color(0xFF1A1610)
      : (Color.lerp(Colors.white, accent, 0.16) ?? Colors.white);
  late final Color _dim = isLight
      ? HSLColor.fromColor(accent).withLightness(0.26).toColor()
      : (Color.lerp(accent, Colors.white, 0.1) ?? accent);

  _ConstellationPainter({
    required this.sim,
    required this.accent,
    required this.isLight,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  bool shouldRepaint(covariant _ConstellationPainter old) =>
      old.accent != accent || old.isLight != isLight || !identical(old.sim, sim);

  Paint _fill(Color c) => _p
    ..shader = null
    ..style = PaintingStyle.fill
    ..color = c;

  Paint _stroke(Color c, double w) => _p
    ..shader = null
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..color = c;

  // Cached text layout. Size is quantised to 0.1px (invisible) so a word
  // that is not animating hits the cache every frame.
  TextPainter _tpFor(int i, String word, int fq, Color color) {
    final key = (i * 2048 + fq) * 4294967296 + color.value;
    var tp = sim.tpCache[key];
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(
          text: word,
          style: TextStyle(
            fontSize: fq / 10.0,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            height: 1.0,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      sim.tpCache[key] = tp;
    }
    return tp;
  }

  TextPainter _glowFor(int i, String word, int fq, Color color) {
    final key = (i * 2048 + fq) * 4294967296 + color.value;
    var tp = sim.glowCache[key];
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(
          text: word,
          style: TextStyle(
            fontSize: fq / 10.0,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            height: 1.0,
            foreground: Paint()
              ..color = color
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      sim.glowCache[key] = tp;
    }
    return tp;
  }

  // Radial glow with a cached shader. The gradient is built around the
  // origin and the canvas is translated to [c], so moving glows (drifting
  // nebula, following star) never need a new shader.
  void _radial(Canvas canvas, int slot, Offset c, double r, Color col, double al) {
    final rq = (r * 4).round();
    if (rq <= 0) return;
    final ai = (_c01(al) * 255).round();
    final key = ((slot * 8192 + rq) * 256 + ai) * 16777216 + (col.value & 0xFFFFFF);
    var sh = sim.shCache[key];
    if (sh == null) {
      sh = ui.Gradient.radial(
        Offset.zero,
        rq / 4.0,
        [col.withAlpha(ai), col.withAlpha(0)],
      );
      sim.shCache[key] = sh;
    }
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.drawCircle(
      Offset.zero,
      rq / 4.0,
      _sp..shader = sh,
    );
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final dark = !isLight;
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0 || sim.size == Size.zero) return;
    final lite = sim.lite;
    final deep = _deep, text = _text, dim = _dim;

    final t = sim.amb;
    _space(canvas, size, t, deep, dark, lite);

    if (sim.li < 0) {
      _intro(canvas, size, t, deep);
      return;
    }
    final L = sim.lines[sim.li];
    final act = sim.act;
    final n = L.words.length;
    final pos = sim.posMs;
    final tl = (pos - L.startMs).toDouble();
    final dur = (L.endMs - L.startMs).toDouble();

    final fo = math.min(350.0, dur * 0.3);
    final env = _c01(tl / 240) * (1 - _c01((tl - (dur - fo)) / fo));

    var big = _c01((math.min(w, h) * 0.095 - 22) / 14) * 14 + 22; // 22..36
    if (n > 10) {
      big *= 0.78;
    } else if (n > 7) {
      big *= 0.9;
    }
    final small = big * 0.38;
    const pad = 12.0;
    final lineBase = dark ? 0.22 : 0.38;

    canvas.save();
    canvas.translate(
        sim.camX + math.sin(t / 2600) * 3, sim.camY + math.cos(t / 3100) * 3);

    final upcoming = _a(deep, 0.16 * env);
    for (var i = act + 1; i < n; i++) {
      canvas.drawCircle(
          Offset(L.pts[i].dx * w, L.pts[i].dy * h), 1.6, _fill(upcoming));
    }

    // ── constellation lines ──
    for (var i = 1; i <= act; i++) {
      final p0 = Offset(L.pts[i - 1].dx * w, L.pts[i - 1].dy * h);
      final p1 = Offset(L.pts[i].dx * w, L.pts[i].dy * h);
      final p = _easeOut((pos - L.wordMs[i]) / 380.0);
      final head =
          Offset(p0.dx + (p1.dx - p0.dx) * p, p0.dy + (p1.dy - p0.dy) * p);
      final extra = i == act ? 0.25 * (1 - p) : 0.0;
      canvas.drawLine(
          p0, head, _stroke(_a(deep, (lineBase + extra) * env), 1));
      if (p < 1) {
        canvas.drawCircle(head, 2, _fill(_a(text, env)));
      }
    }

    // ── stars + words ──
    final maxW = w - pad * 2;
    for (var i = 0; i <= act; i++) {
      final px = L.pts[i].dx * w;
      final py = L.pts[i].dy * h;
      final age = (pos - L.wordMs[i]).toDouble();
      final ap = _easeOut(age / 340);
      final sh = i < act ? _easeOut((pos - L.wordMs[i + 1]) / 650.0) : 0.0;
      var fs = _lerp(big * (0.55 + 0.45 * ap), small, sh);
      final alpha = _lerp(1, dark ? 0.55 : 0.7, sh) * ap * env;
      final col = _a(Color.lerp(text, dim, sh) ?? text, alpha);

      var fq = math.max(1, (fs * 10).round());
      var tp = _tpFor(i, L.words[i], fq, col);
      if (tp.width > maxW && tp.width > 0) {
        fs = fs * maxW / tp.width;
        fq = math.max(1, (fs * 10).round());
        tp = _tpFor(i, L.words[i], fq, col);
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

      if (dark && !lite && i == act && sh < 0.5 && alpha > 0.05) {
        final g = _glowFor(i, L.words[i], fq, _a(accent, 0.75 * alpha));
        g.paint(canvas, Offset(tx - g.width / 2, cy - g.height / 2));
      }
      tp.paint(canvas, Offset(tx - tp.width / 2, cy - tp.height / 2));

      // star
      final c = Offset(px, py);
      final sr = _lerp(8, 3.2, sh) * ap;
      if (sr > 0.5) {
        final glowR = sr * 3.4;
        final gA = (dark ? 0.35 : 0.18) * alpha;
        if (i == act && !lite) {
          _radial(canvas, 2, c, glowR, deep, gA);
        } else {
          canvas.drawCircle(c, glowR * 0.6, _fill(_a(deep, gA * 0.35)));
        }
        _sparkle(canvas, c, sr, i == act ? t / 900 : 0,
            _a(Color.lerp(text, deep, 0.5) ?? deep, alpha));
      }
      if (i == act) {
        if (age < 800 && !lite) {
          canvas.drawCircle(
            c,
            _easeOut(age / 800) * 46,
            _stroke(_a(deep, (1 - age / 800) * 0.45 * env), 1),
          );
        }
        canvas.drawCircle(
          c,
          13 + math.sin(t / 260) * 1.5,
          _stroke(_a(deep, 0.3 * env), 1),
        );
      }
    }

    // ── sparks ──
    for (final q in sim.parts) {
      final a = 1 - q.life / q.max;
      if (a <= 0) continue;
      canvas.drawCircle(Offset(q.x, q.y), 0.4 + 1.6 * a, _fill(_a(deep, a)));
    }

    canvas.restore();
  }

  // Night sky: drifting nebula glow, parallax stars, rare shooting star.
  void _space(Canvas canvas, Size size, double t, Color deep, bool dark, bool lite) {
    final w = size.width, h = size.height;
    final mx = math.max(w, h);

    // Deliberately subtle and single-hue (the theme accent only): the
    // lyrics sit on the player's own artwork gradient, so anything louder
    // or multi-coloured would fight it.
    const bx = [0.22, 0.80];
    const by = [0.30, 0.62];
    const br = [0.80, 0.75];
    final ba = dark ? const [0.085, 0.065] : const [0.04, 0.03];
    for (var i = 0; i < 2; i++) {
      final drift = lite ? 0.0 : 18.0;
      final ox = bx[i] * w + math.sin(t / 5200 + i * 2.1) * drift - sim.camX * 0.25;
      final oy = by[i] * h + math.cos(t / 6100 + i * 1.3) * drift - sim.camY * 0.25;
      final r = br[i] * mx;
      final breathe = lite ? 1.0 : 0.88 + 0.12 * math.sin(t / 4200 + i);
      _radial(canvas, i, Offset(ox, oy), r, deep, ba[i] * breathe);
    }

    final count = lite ? 24 : 46;
    for (var i = 0; i < count; i++) {
      final s = sim.stars[i];
      final y = (s.y * h - t * 0.004 * s.d) % h;
      final x = (s.x * w + sim.camX * s.d * 0.4) % w;
      final tw = lite ? 0.6 : 0.5 + 0.5 * math.sin(t / 700 + s.ph);
      final al = (0.07 + 0.36 * tw) * s.d * (dark ? 1.0 : 0.6);
      canvas.drawCircle(Offset(x, y), 0.4 + 0.9 * s.d, _fill(_a(deep, al)));
    }

    final s = sim.shoot;
    if (s != null && dark) {
      final a = 1 - s.l / s.m;
      final head = Offset(s.x, s.y);
      final len = math.sqrt(s.vx * s.vx + s.vy * s.vy);
      final tail = Offset(s.x - s.vx / len * 70, s.y - s.vy / len * 70);
      canvas.drawLine(
        head,
        tail,
        Paint()
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(
            head,
            tail,
            [_a(Colors.white, a * 0.55), _a(deep, 0)],
          ),
      );
    }
  }

  // Before the first line / in instrumental gaps: three breathing stars.
  void _intro(Canvas canvas, Size size, double t, Color deep) {
    final cx = size.width / 2, cy = size.height * 0.46;
    for (var k = -1; k <= 1; k++) {
      final s = 0.5 + 0.5 * math.sin(t / 420 - k * 0.9);
      _sparkle(canvas, Offset(cx + k * 26, cy), 3 + 4 * s, t / 1400,
          _a(deep, 0.3 + 0.55 * s));
    }
  }

  void _sparkle(Canvas canvas, Offset c, double r, double rot, Color color) {
    final path = _path..reset();
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
    canvas.drawPath(path, _fill(color));
  }
}
