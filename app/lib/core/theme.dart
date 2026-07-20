import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/theme_extension.dart';

class AppTheme {
  // Shared Colors
  static const Color primary = Color(0xFF6366F1); // Indigo 500
  static const Color secondary = Color(0xFF10B981); // Emerald 500
  static const Color accent = Color(0xFFEAB308); // Yellow 500
  static const Color error = Color(0xFFEF4444); // Red 500

  static ThemeData get darkTheme {
    const Color background = Color(0xFF0F172A); // Slate 900
    const Color surface = Color(0xFF1E293B); // Slate 800
    const Color surfaceHighlight = Color(0xFF334155); // Slate 700
    const Color textPrimary = Color(0xFFF8FAFC); // Slate 50
    const Color textSecondary = Color(0xFF94A3B8); // Slate 400

    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        secondary: secondary,
        surface: surface,
        error: error,
        onPrimary: Colors.white,
        onSurface: textPrimary,
      ),
      extensions: const <ThemeExtension<dynamic>>[
        AppThemeExtension(
          primaryGradientStart: Color(0xFF818CF8),
          primaryGradientEnd: Color(0xFF6366F1),
          surfaceHighlight: surfaceHighlight,
        ),
      ],
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme).copyWith(
        bodyLarge: GoogleFonts.inter(color: textPrimary, fontSize: 16),
        bodyMedium: GoogleFonts.inter(color: textSecondary, fontSize: 14),
        titleLarge: GoogleFonts.inter(color: textPrimary, fontSize: 20, fontWeight: FontWeight.bold),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: surfaceHighlight, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: const TextStyle(color: textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: surfaceHighlight, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  static ThemeData get lightTheme {
    const Color background = Color(0xFFF8FAFC); // Slate 50
    const Color surface = Color(0xFFFFFFFF); // White
    const Color surfaceHighlight = Color(0xFFE2E8F0); // Slate 200
    const Color textPrimary = Color(0xFF0F172A); // Slate 900
    const Color textSecondary = Color(0xFF64748B); // Slate 500

    return ThemeData.light().copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.light(
        primary: primary,
        secondary: secondary,
        surface: surface,
        error: error,
        onPrimary: Colors.white,
        onSurface: textPrimary,
      ),
      extensions: const <ThemeExtension<dynamic>>[
        AppThemeExtension(
          primaryGradientStart: Color(0xFF818CF8), // Keep same primary gradient vibe
          primaryGradientEnd: Color(0xFF6366F1),
          surfaceHighlight: surfaceHighlight,
        ),
      ],
      textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme).copyWith(
        bodyLarge: GoogleFonts.inter(color: textPrimary, fontSize: 16),
        bodyMedium: GoogleFonts.inter(color: textSecondary, fontSize: 14),
        titleLarge: GoogleFonts.inter(color: textPrimary, fontSize: 20, fontWeight: FontWeight.bold),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: surfaceHighlight, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: const TextStyle(color: textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: surfaceHighlight, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }
}
