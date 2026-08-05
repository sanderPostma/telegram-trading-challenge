import 'package:flutter/material.dart';

class Brand {
  static const bg = Color(0xFF0A0A0B);
  static const surface = Color(0xFF141210);
  static const surface2 = Color(0xFF1D1A17);
  static const border = Color(0xFF312A1E);
  static const gold = Color(0xFFF3B93B);
  static const brightGold = Color(0xFFFFD24A);
  static const muted = Color(0xFF8B8578);
  static const danger = Color(0xFFE5534B);
  static const green = Color(0xFF2EBD85);
  static const text = Color(0xFFF7F1E3);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.gold,
    brightness: Brightness.dark,
    surface: Brand.surface,
    primary: Brand.gold,
    secondary: Brand.green,
    error: Brand.danger,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Brand.bg,
    fontFamily: 'Inter',
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontWeight: FontWeight.w700, color: Brand.text),
      titleMedium: TextStyle(fontWeight: FontWeight.w700, color: Brand.text),
      bodyMedium: TextStyle(color: Brand.text),
      labelLarge: TextStyle(fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      color: Brand.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Brand.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Brand.surface2,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Brand.gold, width: 1.4),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
  );
}
