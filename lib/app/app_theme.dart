import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/tokens.dart';

abstract final class RhythmoTheme {
  static const _seed = RhythmoColors.primary;
  static const _controlRadius = RhythmoRadii.md;
  static const _surfaceRadius = RhythmoRadii.lg;

  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData light() => _build(Brightness.light);

  static final _darkScheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  ).copyWith(
    primary: RhythmoColors.primary,
    onPrimary: RhythmoColors.onPrimary,
    primaryContainer: RhythmoColors.primaryContainer,
    onPrimaryContainer: RhythmoColors.onPrimaryContainer,
    secondary: RhythmoColors.secondary,
    onSecondary: RhythmoColors.onSecondary,
    secondaryContainer: RhythmoColors.secondaryContainer,
    onSecondaryContainer: RhythmoColors.onSecondaryContainer,
    surface: RhythmoColors.background,
    surfaceContainerLowest: RhythmoColors.background,
    surfaceContainerLow: RhythmoColors.containerLow,
    surfaceContainer: RhythmoColors.container,
    surfaceContainerHigh: RhythmoColors.containerHigh,
    surfaceContainerHighest: RhythmoColors.surfaceRaised,
    onSurface: RhythmoColors.onSurface,
    onSurfaceVariant: RhythmoColors.onSurfaceVariant,
    outline: RhythmoColors.outline,
    outlineVariant: RhythmoColors.outlineVariant,
  );

  /// The light scheme is Material's own, seeded from a deeper ember so the
  /// accent keeps its contrast on light surfaces.
  static final _lightScheme = ColorScheme.fromSeed(
    seedColor: RhythmoColors.lightSeed,
    brightness: Brightness.light,
  );

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = dark ? _darkScheme : _lightScheme;
    final material = ThemeData(
      brightness: brightness,
      colorScheme: colors,
      fontFamily: RhythmoType.family,
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
    );
    final tokens = dark ? RhythmoTokens.dark : RhythmoTokens.light;
    final base = material.copyWith(
      textTheme: RhythmoType.apply(material.textTheme, color: colors.onSurface),
      extensions: [tokens],
      focusColor: colors.primary.withValues(alpha: 0.24),
    );

    // Translucent glass on the dark canvas; plain tonal containers in light.
    final card = dark ? RhythmoColors.card : colors.surfaceContainerLow;
    final overlay = dark ? RhythmoColors.overlay : colors.surfaceContainerHigh;
    final field = dark ? RhythmoColors.field : colors.surfaceContainerLow;
    final softBorder = dark ? RhythmoColors.softBorder : colors.outlineVariant;
    final divider = dark ? RhythmoColors.divider : colors.outlineVariant;

    // Keyboard focus draws a 2 px ring on every button, on top of the
    // state layer, so it shows on any surface.
    WidgetStateProperty<BorderSide?> ring(BorderSide? rest) =>
        WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.focused)
                ? BorderSide(color: tokens.focusRing, width: 2)
                : rest);

    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_controlRadius),
    );
    final surfaceShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_surfaceRadius),
    );
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(_controlRadius),
      borderSide: BorderSide(color: colors.outlineVariant),
    );

    return base.copyWith(
      scaffoldBackgroundColor: colors.surface,
      canvasColor: colors.surface,
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface.withValues(alpha: dark ? 0.58 : 0.96),
        foregroundColor: colors.onSurface,
        surfaceTintColor: RhythmoColors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        shape: Border(
          bottom: BorderSide(color: divider),
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        surfaceTintColor: RhythmoColors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: surfaceShape.copyWith(
          side: BorderSide(
            color: softBorder,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: overlay,
        surfaceTintColor: RhythmoColors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: RhythmoRadii.panel,
        ),
        titleTextStyle: base.textTheme.headlineSmall?.copyWith(
          color: colors.onSurface,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: base.textTheme.bodyLarge?.copyWith(
          color: colors.onSurfaceVariant,
          height: 1.6,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: overlay,
        surfaceTintColor: RhythmoColors.transparent,
        elevation: 6,
        shape: surfaceShape,
        position: PopupMenuPosition.under,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.inverseSurface,
        contentTextStyle: base.textTheme.bodyMedium?.copyWith(
          color: colors.onInverseSurface,
        ),
        actionTextColor: colors.inversePrimary,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_controlRadius),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: RhythmoColors.transparent,
        indicator: BoxDecoration(
          borderRadius: BorderRadius.circular(RhythmoRadii.pill),
          color: colors.primary.withValues(alpha: 0.18),
          border: Border.all(color: colors.primary.withValues(alpha: 0.42)),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        // The pill is the only selection mark: no rectangular hover or
        // press box across the tab's full hit area. Keyboard focus keeps a
        // faint tint so it stays visible.
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? colors.primary.withValues(alpha: 0.12)
              : RhythmoColors.transparent,
        ),
        labelColor: colors.onSurface,
        unselectedLabelColor: colors.onSurfaceVariant,
        labelStyle: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: base.textTheme.labelLarge,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: colors.surfaceContainerHigh.withValues(alpha: 0.7),
        selectedColor: colors.secondary.withValues(alpha: 0.2),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.7),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RhythmoRadii.sm),
        ),
        padding: const EdgeInsets.symmetric(
            horizontal: RhythmoSpace.sm, vertical: RhythmoSpace.xxs),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        minVerticalPadding: 6,
        minLeadingWidth: 32,
        horizontalTitleGap: 12,
        iconColor: colors.onSurfaceVariant,
        textColor: colors.onSurface,
        selectedColor: colors.onSecondaryContainer,
        selectedTileColor: colors.secondaryContainer,
        shape: controlShape,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: field,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        errorBorder: outline.copyWith(
          borderSide: BorderSide(color: colors.error),
        ),
        focusedErrorBorder: outline.copyWith(
          borderSide: BorderSide(color: colors.error, width: 2),
        ),
        labelStyle: TextStyle(color: colors.onSurfaceVariant),
        hintStyle: TextStyle(color: colors.onSurfaceVariant),
        errorStyle: TextStyle(color: colors.error),
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(field),
        surfaceTintColor:
            const WidgetStatePropertyAll(RhythmoColors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shadowColor: const WidgetStatePropertyAll(RhythmoColors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_surfaceRadius),
            side: BorderSide(color: colors.outlineVariant),
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        constraints: const BoxConstraints(minHeight: 48),
        hintStyle: WidgetStatePropertyAll(
          base.textTheme.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
        ),
        textStyle: WidgetStatePropertyAll(
          base.textTheme.bodyLarge?.copyWith(color: colors.onSurface),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          side: ring(null),
          minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: WidgetStatePropertyAll(
            base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          shape: WidgetStatePropertyAll(controlShape),
          side: ring(BorderSide(color: colors.outline)),
          textStyle: WidgetStatePropertyAll(
            base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
      // Text buttons are quiet: light text, not ember, so the one ember
      // action on a screen stands out.
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.disabled)
                  ? colors.onSurface.withValues(alpha: 0.38)
                  : colors.onSurface),
          overlayColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.pressed)
                  ? colors.onSurface.withValues(alpha: 0.12)
                  : states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.focused)
                      ? colors.onSurface.withValues(alpha: 0.08)
                      : null),
          side: ring(null),
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          shape: WidgetStatePropertyAll(controlShape),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          side: ring(null),
          minimumSize: const WidgetStatePropertyAll(Size.square(48)),
          iconSize: const WidgetStatePropertyAll(20),
          shape: const WidgetStatePropertyAll(CircleBorder()),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        elevation: 3,
        focusElevation: 4,
        hoverElevation: 4,
        highlightElevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RhythmoRadii.lg),
        ),
      ),
      // Settings controls are white when on, as the dock's selected item
      // is, so ember stays the one light on a screen.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.surface
              : colors.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.onSurface
              : colors.surfaceContainerHighest,
        ),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: colors.onSurface,
        inactiveTrackColor: colors.surfaceContainerHighest,
        thumbColor: colors.onSurface,
        overlayColor: colors.onSurface.withValues(alpha: 0.12),
        trackHeight: 3,
      ),
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(RhythmoRadii.xs),
        thickness: const WidgetStatePropertyAll(6),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? colors.outline
              : colors.outlineVariant,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceContainerHigh,
        surfaceTintColor: RhythmoColors.transparent,
        modalBackgroundColor: colors.surfaceContainerHigh,
        modalBarrierColor: RhythmoColors.scrim,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(RhythmoRadii.sheet)),
        ),
        showDragHandle: true,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.primary,
        linearTrackColor: colors.surfaceContainerHighest,
        circularTrackColor: colors.surfaceContainerHighest,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.inverseSurface,
          borderRadius: BorderRadius.circular(RhythmoRadii.xs),
        ),
        textStyle: base.textTheme.bodySmall?.copyWith(
          color: colors.onInverseSurface,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        waitDuration: RhythmoMotion.tooltipWait,
      ),
    );
  }
}
