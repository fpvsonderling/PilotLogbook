import 'package:flutter/material.dart';

/// Field look: teal bar, big touch targets, outlined cards, Barlow type, and
/// green / orange for OK / problem. Light and dark follow the system.
class AppTheme {
  static const brand = Color(0xFF00838F);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: brand,
      brightness: brightness,
      primary: dark ? const Color(0xFF2BB3BF) : brand,
      surface: dark ? const Color(0xFF101A1C) : const Color(0xFFF7F9F9),
      surfaceContainerLow: dark
          ? const Color(0xFF142023)
          : const Color(0xFFFFFFFF),
      outlineVariant: dark ? const Color(0xFF2A3A3D) : const Color(0xFFD3DDDD),
    );
    final base = ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: 'Barlow',
      visualDensity: VisualDensity.standard,
    );
    final text = base.textTheme;
    TextStyle? display(TextStyle? s, [FontWeight w = FontWeight.w700]) =>
        s?.copyWith(fontFamily: 'Barlow Condensed', fontWeight: w);
    final shape12 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text.copyWith(
        headlineSmall: display(text.headlineSmall),
        titleLarge: display(text.titleLarge),
        titleMedium: display(
          text.titleMedium,
          FontWeight.w600,
        )?.copyWith(fontSize: 19),
      ),
      extensions: [dark ? CheckColors.dark : CheckColors.light],
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? const Color(0xFF0E6C75) : brand,
        foregroundColor: Colors.white,
        elevation: 0,
        titleTextStyle: display(text.titleLarge)
            ?.copyWith(color: Colors.white, fontSize: 22),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: shape12,
          textStyle: const TextStyle(
            fontFamily: 'Barlow',
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: shape12,
          side: BorderSide(color: scheme.outlineVariant, width: 2),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        extendedTextStyle: const TextStyle(
          fontFamily: 'Barlow',
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        labelStyle: TextStyle(
          color: scheme.onSurface,
          fontFamily: 'Barlow',
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        shape: shape12,
        side: BorderSide(color: scheme.outlineVariant, width: 2),
        selectedColor: scheme.primary,
        secondaryLabelStyle: TextStyle(
          fontFamily: 'Barlow',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: scheme.onPrimary,
        ),
        checkmarkColor: scheme.onPrimary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primaryContainer,
        selectedLabelTextStyle: TextStyle(
          fontFamily: 'Barlow',
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    );
  }
}

/// OK and problem colors for checks and status chips.
class CheckColors extends ThemeExtension<CheckColors> {
  const CheckColors({
    required this.ok,
    required this.okContainer,
    required this.problem,
    required this.problemContainer,
    required this.skipped,
    required this.skippedContainer,
  });

  final Color ok;
  final Color okContainer;
  final Color problem;
  final Color problemContainer;
  final Color skipped;
  final Color skippedContainer;

  static const light = CheckColors(
    ok: Color(0xFF1B8A4B),
    okContainer: Color(0xFFE3F4EA),
    problem: Color(0xFFB4570B),
    problemContainer: Color(0xFFFDEEDD),
    skipped: Color(0xFF6B7A7C),
    skippedContainer: Color(0xFFE9EEEE),
  );

  static const dark = CheckColors(
    ok: Color(0xFF4CC97F),
    okContainer: Color(0xFF12301F),
    problem: Color(0xFFF2A25A),
    problemContainer: Color(0xFF3A2510),
    skipped: Color(0xFF9AABAD),
    skippedContainer: Color(0xFF1E2B2E),
  );

  static CheckColors of(BuildContext context) =>
      Theme.of(context).extension<CheckColors>()!;

  @override
  CheckColors copyWith() => this;

  @override
  CheckColors lerp(CheckColors? other, double t) =>
      t < 0.5 || other == null ? this : other;
}
