import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';

class AurumLoader extends StatefulWidget {
  final double size;
  final Color? color;

  const AurumLoader({super.key, this.size = 36, this.color});

  @override
  State<AurumLoader> createState() => _AurumLoaderState();
}

class _AurumLoaderState extends State<AurumLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _rotate;
  late Animation<double> _breathe;
  late Animation<double> _morph;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _rotate = Tween(begin: 0.0, end: 2 * math.pi).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.linear),
    );

    _breathe = Tween(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 1.0, curve: Curves.easeInOut),
      ),
    );

    _morph = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AurumTheme.gold;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => Transform.scale(
          scale: _breathe.value,
          child: Transform.rotate(
            angle: _rotate.value,
            child: CustomPaint(
              painter: _BlobPainter(
                color: color,
                morphValue: _morph.value,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  final Color color;
  final double morphValue;

  _BlobPainter({required this.color, required this.morphValue});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = color.withOpacity(0.25)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;

    // Morph between circle and blob using sin waves
    final path = Path();
    const points = 120;
    for (int i = 0; i <= points; i++) {
      final angle = (i / points) * 2 * math.pi;
      final wave1 = math.sin(angle * 3 + morphValue * 2 * math.pi) * 0.12;
      final wave2 = math.cos(angle * 2 + morphValue * 2 * math.pi) * 0.08;
      final radius = r * (0.75 + wave1 + wave2);
      final x = cx + radius * math.cos(angle);
      final y = cy + radius * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    // Glow layer
    canvas.drawPath(path, glowPaint);
    // Main blob
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BlobPainter old) =>
      old.morphValue != morphValue || old.color != color;
}

// ── Convenience wrappers ──

class AurumLoaderSmall extends StatelessWidget {
  const AurumLoaderSmall({super.key});
  @override
  Widget build(BuildContext context) =>
      const AurumLoader(size: 24);
}

class AurumLoaderLarge extends StatelessWidget {
  const AurumLoaderLarge({super.key});
  @override
  Widget build(BuildContext context) =>
      const AurumLoader(size: 52);
}

class AurumLoaderScreen extends StatelessWidget {
  const AurumLoaderScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const Center(child: AurumLoader(size: 48));
  }
}
