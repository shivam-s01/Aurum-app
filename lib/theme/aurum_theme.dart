import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AurumTheme {
  static const Color gold = Color(0xFFB89640);
  static const Color goldLight = Color(0xFFD4AF5A);
  static const Color goldDark = Color(0xFF8A6F2A);
  static const Color bg = Color(0xFF050508);
  static const Color bgCard = Color(0xFF0D0D14);
  static const Color bgElevated = Color(0xFF12121C);
  static const Color bgSurface = Color(0xFF1A1A28);
  static const Color textPrimary = Color(0xFFF0EBD8);
  static const Color textSecondary = Color(0xFF8A8A9A);
  static const Color textMuted = Color(0xFF4A4A5E);
  static const Color divider = Color(0xFF1E1E2E);

  static ThemeData get theme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: gold,
        secondary: goldLight,
        surface: bgCard,
        background: bg,
        onPrimary: bg,
        onSurface: textPrimary,
      ),
      textTheme: GoogleFonts.soraTextTheme(ThemeData.dark().textTheme).copyWith(
        displayLarge: GoogleFonts.sora(
          color: textPrimary,
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        displayMedium: GoogleFonts.sora(
          color: textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: GoogleFonts.sora(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: GoogleFonts.sora(
          color: textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: GoogleFonts.sora(
          color: textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
        bodyMedium: GoogleFonts.sora(
          color: textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
        labelSmall: GoogleFonts.sora(
          color: textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w400,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: textPrimary),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: bgCard,
        selectedItemColor: gold,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: gold,
        inactiveTrackColor: bgSurface,
        thumbColor: gold,
        overlayColor: gold.withOpacity(0.2),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      iconTheme: const IconThemeData(color: textSecondary),
      dividerColor: divider,
    );
  }

  // Gold gradient
  static const LinearGradient goldGradient = LinearGradient(
    colors: [goldDark, gold, goldLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient bgGradient = LinearGradient(
    colors: [bg, bgCard],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static BoxDecoration get cardDecoration => BoxDecoration(
    color: bgCard,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: divider, width: 0.5),
  );

  static BoxDecoration get goldCardDecoration => BoxDecoration(
    color: bgCard,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: gold.withOpacity(0.3), width: 0.5),
    boxShadow: [
      BoxShadow(
        color: gold.withOpacity(0.08),
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ],
  );
}
