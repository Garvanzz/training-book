import 'package:flutter/material.dart';

abstract final class AppColors {
  static const canvas = Color(0xFF0B0E12);
  static const surface = Color(0xFF131820);
  static const surfaceRaised = Color(0xFF1A212B);
  static const surfaceInteractive = Color(0xFF222C38);
  static const border = Color(0xFF2D3947);
  static const text = Color(0xFFF2F5F7);
  static const muted = Color(0xFF9CA9B8);
  static const accent = Color(0xFFB8E85C);
  static const accentInk = Color(0xFF172000);
  static const info = Color(0xFF78B7FF);
  static const warning = Color(0xFFF5C56B);
  static const danger = Color(0xFFFF8383);
}

abstract final class AppTheme {
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
      surface: AppColors.surface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme.copyWith(
        primary: AppColors.accent,
        onPrimary: AppColors.accentInk,
        surface: AppColors.surface,
        onSurface: AppColors.text,
        surfaceContainerHighest: AppColors.surfaceRaised,
        outlineVariant: AppColors.border,
      ),
      fontFamily: 'Microsoft YaHei UI',
      scaffoldBackgroundColor: AppColors.canvas,
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: AppColors.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: const TextStyle(color: AppColors.muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.surfaceInteractive,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.surfaceInteractive,
      ),
      textTheme: Typography.material2021().white.apply(
        fontFamily: 'Microsoft YaHei UI',
        bodyColor: AppColors.text,
        displayColor: AppColors.text,
      ).copyWith(
        headlineSmall: const TextStyle(fontSize: 26, height: 1.25, fontWeight: FontWeight.w700),
        titleLarge: const TextStyle(fontSize: 18, height: 1.3, fontWeight: FontWeight.w700),
        titleMedium: const TextStyle(fontSize: 16, height: 1.35, fontWeight: FontWeight.w600),
        bodyLarge: const TextStyle(fontSize: 14, height: 1.5),
        bodyMedium: const TextStyle(fontSize: 14, height: 1.45),
        bodySmall: const TextStyle(fontSize: 12, height: 1.4, color: AppColors.muted),
        labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}
