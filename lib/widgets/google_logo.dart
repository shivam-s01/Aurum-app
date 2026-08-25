// =============================================================================
// PROJECT: Astra Music
// DESCRIPTION: The official Google "G" mark, drawn with CustomPainter using
//   Google's published brand colors (#4285F4 blue, #34A853 green, #FBBC05
//   yellow, #EA4335 red) and standard four-quadrant geometry — the same
//   mark used on Google's own pre-approved "Sign in with Google" button
//   assets (see developers.google.com/identity/branding-guidelines).
//
//   WHY A PAINTER INSTEAD OF A BUNDLED PNG/SVG:
//   - Zero asset weight added to the APK (a few hundred bytes of Dart code
//     vs. a bundled image file per density bucket).
//   - Renders pixel-perfect at any size/DPI — no upscaling blur on large
//     displays, no wasted resolution on small ones.
//   - Matches this app's existing pattern of vector-drawn brand marks
//     rather than bitmap assets for iconography.
// =============================================================================

import 'package:flutter/material.dart';

/// The Google "G" logomark. Use at 18-24px inside a Sign in with Google
/// button per Google's branding guidelines (icon + "Sign in with Google"
/// text, never the bare mark alone as the only sign-in indicator).
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleLogoPainter()),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  // Official Google brand colors.
  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 48.0; // native art is authored on a 48x48 grid
    canvas.save();
    canvas.scale(s, s);

    final paint = Paint()..style = PaintingStyle.fill;

    // Blue: right-side arc + the horizontal crossbar of the "G".
    paint.color = _blue;
    final blue = Path()
      ..moveTo(45.12, 24.5)
      ..cubicTo(45.12, 22.74, 44.96, 21.06, 44.68, 19.44)
      ..lineTo(24, 19.44)
      ..lineTo(24, 29.02)
      ..lineTo(35.94, 29.02)
      ..cubicTo(35.42, 31.78, 33.84, 34.12, 31.48, 35.68)
      ..lineTo(31.48, 41.7)
      ..lineTo(39.1, 41.7)
      ..cubicTo(43.52, 37.62, 45.12, 31.62, 45.12, 24.5)
      ..close();
    canvas.drawPath(blue, paint);

    // Green: bottom arc.
    paint.color = _green;
    final green = Path()
      ..moveTo(24, 46)
      ..cubicTo(30.48, 46, 35.92, 43.86, 39.1, 41.7)
      ..lineTo(31.48, 35.68)
      ..cubicTo(29.34, 37.1, 26.62, 37.94, 24, 37.94)
      ..cubicTo(17.7, 37.94, 12.36, 33.72, 10.46, 28.02)
      ..lineTo(2.6, 28.02)
      ..lineTo(2.6, 34.22)
      ..cubicTo(6.76, 41.44, 14.76, 46, 24, 46)
      ..close();
    canvas.drawPath(green, paint);

    // Yellow: left arc.
    paint.color = _yellow;
    final yellow = Path()
      ..moveTo(10.46, 28.02)
      ..cubicTo(9.98, 26.6, 9.7, 25.08, 9.7, 23.5)
      ..cubicTo(9.7, 21.92, 9.98, 20.4, 10.46, 18.98)
      ..lineTo(10.46, 12.78)
      ..lineTo(2.6, 12.78)
      ..cubicTo(0.94, 16.02, 0, 19.66, 0, 23.5)
      ..cubicTo(0, 27.34, 0.94, 30.98, 2.6, 34.22)
      ..lineTo(10.46, 28.02)
      ..close();
    canvas.drawPath(yellow, paint);

    // Red: top arc.
    paint.color = _red;
    final red = Path()
      ..moveTo(24, 9.06)
      ..cubicTo(27.02, 9.06, 29.72, 10.1, 31.84, 12.12)
      ..lineTo(39.24, 4.72)
      ..cubicTo(35.9, 1.62, 30.48, 0, 24, 0)
      ..cubicTo(14.76, 0, 6.76, 4.56, 2.6, 11.78)
      ..lineTo(10.46, 18.98)
      ..cubicTo(12.36, 13.28, 17.7, 9.06, 24, 9.06)
      ..close();
    canvas.drawPath(red, paint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GoogleLogoPainter oldDelegate) => false;
}
