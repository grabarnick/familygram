import 'package:material_ui/material_ui.dart';

/// Design tokens from the approved Familygram design.
class Fg {
  static const accent = Color(0xFF0F7B6C);
  static const accentDark = Color(0xFF0A5C51);
  static const accentTint = Color(0xFFE3F3EF);
  static const bubbleOut = Color(0xFFD9F2EC);
  static const bubbleIn = Color(0xFFFFFFFF);
  static const chatBg = Color(0xFFEFEBE4);
  static const text = Color(0xFF1A1A1A);
  static const secondary = Color(0xFF6B6B6B);
  static const divider = Color(0xFFEDEDEC);
  static const field = Color(0xFFF1F1F0);
  static const danger = Color(0xFFDC2626);

  // Dark variants.
  static const bubbleOutDark = Color(0xFF1F4A42);
  static const bubbleInDark = Color(0xFF242626);
  static const chatBgDark = Color(0xFF121413);

  /// Avatar palette (deterministic per id).
  static const avatarColors = [
    Color(0xFF0F7B6C),
    Color(0xFFC2410C),
    Color(0xFF1D4ED8),
    Color(0xFF7C3AED),
    Color(0xFFB45309),
    Color(0xFF475569),
    Color(0xFFBE185D),
  ];

  /// Width at which the app switches to the two-pane (web/tablet) layout.
  static const wideBreakpoint = 900.0;
}

/// Theme-aware colors for chat surfaces.
extension FgColors on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
  Color get chatBg => isDark ? Fg.chatBgDark : Fg.chatBg;
  Color get bubbleOut => isDark ? Fg.bubbleOutDark : Fg.bubbleOut;
  Color get bubbleIn => isDark ? Fg.bubbleInDark : Fg.bubbleIn;
  Color get secondaryText =>
      isDark ? const Color(0xFFA3A3A3) : Fg.secondary;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: Fg.accent,
    brightness: brightness,
  ).copyWith(
    primary: dark ? const Color(0xFF4FC3AE) : Fg.accent,
    surface: dark ? const Color(0xFF181A19) : Colors.white,
  );
  return ThemeData(
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
    ),
    dividerTheme: DividerThemeData(
      color: dark ? const Color(0xFF2A2C2B) : Fg.divider,
      space: 1,
      thickness: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF242626) : Fg.field,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
  );
}
