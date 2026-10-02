import 'package:flutter/material.dart';

import '../theme_pack.dart';

const _colors = AppColorTokens(
  paperBase: Color(0xFFF3EBDD),
  paperRaised: Color(0xFFFBF7EE),
  paperPressed: Color(0xFFE7DBC6),
  inkPrimary: Color(0xFF1F2621),
  inkMuted: Color(0xFF655F54),
  jade: Color(0xFF315B4B),
  jadePressed: Color(0xFF24463A),
  cinnabar: Color(0xFFB44737),
  bronze: Color(0xFF917751),
  divider: Color(0xFFCFC2AC),
  danger: Color(0xFFA9362C),
);

const _typography = TypographyThemeTokens(
  displayFontFamily: 'LXGWWenKaiScreen',
  bodyFontFamily: 'NotoSansSC',
  fontFamilyFallback: ['NotoSansSC', 'sans-serif'],
);

const _spacing = SpacingThemeTokens(
  extraSmall: 4,
  small: 8,
  medium: 16,
  large: 24,
  extraLarge: 32,
  minimumTapTarget: 48,
);

const _shapes = ShapeThemeTokens(
  controlRadius: 12,
  panelRadius: 18,
  dialogRadius: 24,
  borderWidth: 1,
);

final ThemePack modernEasternThemePack = ThemePack(
  id: 'modern_eastern',
  schemaVersion: 1,
  displayName: '现代东方棋艺',
  colors: _colors,
  typography: _typography,
  spacing: _spacing,
  shapes: _shapes,
  board: const BoardThemeTokens(
    surfaceColor: Color(0xFFE8D8BA),
    gridColor: Color(0xFF493E32),
    frameColor: Color(0xFF917751),
    selectionColor: Color(0xFFB44737),
    validMoveColor: Color(0xFF315B4B),
    lastMoveColor: Color(0xFF917751),
    gridLineWidth: 1.5,
    frameLineWidth: 3,
    cornerRadius: 8,
    selectionMarker: BoardMarkerShape.doubleCorners,
    validMoveMarker: BoardMarkerShape.dotAndTick,
    lastMoveMarker: BoardMarkerShape.endpointBrackets,
  ),
  pieces: const PieceThemeTokens(
    inkSide: PieceVisualTokens(
      surfaceColor: Color(0xFF1F2621),
      highlightColor: Color(0xFF4B534D),
      borderColor: Color(0xFF0D120F),
      markerColor: Color(0xFFCFC2AC),
      marker: PieceMarkerShape.fourPointSeal,
    ),
    jadeSide: PieceVisualTokens(
      surfaceColor: Color(0xFFF0E9D8),
      highlightColor: Color(0xFFFFFFFF),
      borderColor: Color(0xFF315B4B),
      markerColor: Color(0xFF315B4B),
      marker: PieceMarkerShape.concentricRing,
    ),
    radiusRatio: 0.35,
    shadowColor: Color(0x47000000),
    shadowOffset: Offset(1.5, 2),
    shadowBlurRadius: 3,
  ),
  motion: const MotionThemeTokens(
    pageTransitionDuration: Duration(milliseconds: 200),
    moveDuration: Duration(milliseconds: 320),
    captureDuration: Duration(milliseconds: 680),
    stateChangeDuration: Duration(milliseconds: 150),
    firstPlayerDuration: Duration(milliseconds: 420),
    pageCurve: Curves.easeOutCubic,
    moveCurve: Curves.easeOutCubic,
    captureCurve: Curves.easeInOutCubic,
    selectionPulseEnabled: true,
    particlesEnabled: true,
  ),
  audio: const AudioThemeTokens(
    select: 'assets/sounds/select.wav',
    move: 'assets/sounds/move.wav',
    capture: 'assets/sounds/capture.wav',
    win: 'assets/sounds/win.wav',
    lose: 'assets/sounds/lose.wav',
    click: 'assets/sounds/click.wav',
    mainMusic: 'assets/sounds/music/main.wav',
    gameplayMusic: 'assets/sounds/music/gameplay.wav',
  ),
  themeData: _buildThemeData(),
);

ThemeData _buildThemeData() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: _colors.jade,
    brightness: Brightness.light,
    primary: _colors.jade,
    secondary: _colors.cinnabar,
    surface: _colors.paperRaised,
    error: _colors.danger,
  );

  final baseTextTheme = ThemeData(
    useMaterial3: true,
    fontFamily: _typography.bodyFontFamily,
  ).textTheme.apply(
        bodyColor: _colors.inkPrimary,
        displayColor: _colors.inkPrimary,
      );
  TextStyle? display(TextStyle? style) => style?.copyWith(
        fontFamily: _typography.displayFontFamily,
        fontFamilyFallback: _typography.fontFamilyFallback,
        fontWeight: FontWeight.w600,
      );

  final textTheme = baseTextTheme.copyWith(
    displayLarge: display(baseTextTheme.displayLarge),
    displayMedium: display(baseTextTheme.displayMedium),
    displaySmall: display(baseTextTheme.displaySmall),
    headlineLarge: display(baseTextTheme.headlineLarge),
    headlineMedium: display(baseTextTheme.headlineMedium),
    headlineSmall: display(baseTextTheme.headlineSmall),
    titleLarge: display(baseTextTheme.titleLarge),
  );

  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(_shapes.controlRadius),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: _colors.paperBase,
    dividerColor: _colors.divider,
    fontFamily: _typography.bodyFontFamily,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: _colors.inkPrimary,
      centerTitle: true,
      elevation: 0,
      titleTextStyle: textTheme.titleLarge,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        backgroundColor: _colors.jade,
        foregroundColor: _colors.paperRaised,
        shape: controlShape,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: _colors.inkPrimary,
        side: BorderSide(color: _colors.bronze),
        shape: controlShape,
      ),
    ),
    cardTheme: CardThemeData(
      color: _colors.paperRaised,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_shapes.panelRadius),
        side: BorderSide(color: _colors.divider),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: _colors.paperRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_shapes.dialogRadius),
        side: BorderSide(color: _colors.divider),
      ),
    ),
    dividerTheme: DividerThemeData(color: _colors.divider, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _colors.paperRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_shapes.controlRadius),
        borderSide: BorderSide(color: _colors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_shapes.controlRadius),
        borderSide: BorderSide(color: _colors.jade, width: 2),
      ),
    ),
  );
}
