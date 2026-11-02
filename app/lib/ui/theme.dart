import 'package:flutter/material.dart';

/// Field look: white background, hunter green bar, big touch targets,
/// outlined cards and Inter type. Only a light theme: the screens are read
/// outdoors, where a white page is easiest to see.
///
/// Palette: hunter green (bars, main buttons, OK), sunflower gold (selected
/// menu item, add buttons, highlights), rust brown (problems, aborted) and
/// dark garnet (grounded, near miss).
class AppPalette {
  static const green = Color(0xFF3F563E);
  static const white = Color(0xFFFBFFFE);
  static const garnet = Color(0xFF6B0504);
  static const rust = Color(0xFFA3320B);
  static const gold = Color(0xFFE6AF2E);

  static const text = Color(0xFF1B241C);
  static const muted = Color(0xFF5E6A5E);
  static const line = Color(0xFFD5DED4);
  static const greenContainer = Color(0xFFE4EBE3);
  static const goldContainer = Color(0xFFFBEFD2);
  static const rustContainer = Color(0xFFF7E2D8);
  static const garnetContainer = Color(0xFFF2DCDB);
}

class AppTheme {
  static ThemeData light() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppPalette.green,
      onPrimary: Colors.white,
      primaryContainer: AppPalette.greenContainer,
      onPrimaryContainer: AppPalette.green,
      secondary: AppPalette.gold,
      onSecondary: AppPalette.text,
      secondaryContainer: AppPalette.goldContainer,
      onSecondaryContainer: Color(0xFF5C4300),
      tertiary: AppPalette.rust,
      onTertiary: Colors.white,
      tertiaryContainer: AppPalette.rustContainer,
      onTertiaryContainer: AppPalette.rust,
      error: AppPalette.garnet,
      onError: Colors.white,
      errorContainer: AppPalette.garnetContainer,
      onErrorContainer: AppPalette.garnet,
      surface: AppPalette.white,
      onSurface: AppPalette.text,
      onSurfaceVariant: AppPalette.muted,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Colors.white,
      surfaceContainer: Color(0xFFF4F8F3),
      surfaceContainerHigh: Color(0xFFEEF3ED),
      surfaceContainerHighest: AppPalette.greenContainer,
      outline: Color(0xFF8A968A),
      outlineVariant: AppPalette.line,
      inverseSurface: AppPalette.text,
      onInverseSurface: AppPalette.white,
      inversePrimary: AppPalette.gold,
    );
    final base = ThemeData(
      colorScheme: scheme,
      brightness: Brightness.light,
      fontFamily: 'Inter',
      visualDensity: VisualDensity.standard,
    );
    final text = base.textTheme;
    TextStyle? heading(TextStyle? s, [FontWeight w = FontWeight.w700]) =>
        s?.copyWith(fontWeight: w, letterSpacing: -0.2);
    final shape12 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    const label = TextStyle(
      fontFamily: 'Inter',
      fontSize: 15,
      fontWeight: FontWeight.w600,
    );
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text.copyWith(
        headlineSmall: heading(text.headlineSmall),
        titleLarge: heading(text.titleLarge)?.copyWith(fontSize: 21),
        titleMedium: heading(
          text.titleMedium,
          FontWeight.w600,
        )?.copyWith(fontSize: 17),
      ),
      extensions: const [CheckColors.light],
      appBarTheme: AppBarTheme(
        backgroundColor: AppPalette.green,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: heading(text.titleLarge)
            ?.copyWith(color: Colors.white, fontSize: 20),
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
          textStyle: label.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      // Dialog buttons (Cancel, Delete, ...) as easy to hit as the others.
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: shape12,
          textStyle: label,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: shape12,
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outlineVariant, width: 2),
        ),
      ),
      // Add / report buttons stand out in gold on the white page.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppPalette.gold,
        foregroundColor: AppPalette.text,
        extendedTextStyle: label.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        labelStyle: label.copyWith(color: scheme.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        shape: shape12,
        side: BorderSide(color: scheme.outlineVariant, width: 2),
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.primary,
        secondaryLabelStyle: label.copyWith(color: scheme.onPrimary),
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
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: AppPalette.gold,
        selectedIconTheme: const IconThemeData(color: AppPalette.text),
        unselectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle: label.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
        unselectedLabelTextStyle: label.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
        ),
      ),
      navigationDrawerTheme: NavigationDrawerThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: AppPalette.gold,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primaryContainer,
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
    ok: AppPalette.green,
    okContainer: AppPalette.greenContainer,
    problem: AppPalette.rust,
    problemContainer: AppPalette.rustContainer,
    skipped: AppPalette.muted,
    skippedContainer: Color(0xFFECEFEB),
  );

  static CheckColors of(BuildContext context) =>
      Theme.of(context).extension<CheckColors>()!;

  @override
  CheckColors copyWith() => this;

  @override
  CheckColors lerp(CheckColors? other, double t) =>
      t < 0.5 || other == null ? this : other;
}
