import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// rhythmo's design tokens: the only place raw colours, the type scale,
/// spacing, radii, glass levels and motion are defined. Everything else
/// reads them from here, as constants or through [RhythmoTokens] on the theme.
/// DESIGN.md describes how to use them.

/// Colour roles of the dark glass theme. Text roles meet WCAG AA on every
/// surface they are used on; test/design_system_test.dart checks the pairs.
abstract final class RhythmoColors {
  // Canvas and surfaces, darkest first.
  static const background = Color(0xFF070810);
  static const surface = Color(0xFF121522);
  static const surfaceStrong = Color(0xFF191D2D);
  static const surfaceRaised = Color(0xFF23283A);

  /// Translucent containers that let the ambient light through.
  static const containerLow = Color(0xE6121522);
  static const container = Color(0xEB151827);
  static const containerHigh = Color(0xF0191D2D);
  static const field = Color(0xB31B1E2D);
  static const card = Color(0xB31A1D2A);
  static const overlay = Color(0xF21B1E2D);

  // Accents.
  static const primary = Color(0xFFFF626A);

  /// The orange flame of the popular playlists button in the app bar.
  static const fire = Color(0xFFFF8A1F);

  /// The deep end of the brand mark's ember gradient, and the light mark on it.
  static const primaryDeep = Color(0xFFB72E50);
  static const onBrand = Color(0xFFFFF5F5);

  /// The dark tile behind the logo mark, the same as the app icon's.
  static const markTile = Color(0xFF0B0D16);

  /// The deep violet end of the playlist cover gradient.
  static const secondaryDeep = Color(0xFF4E3B8D);
  static const onPrimary = Color(0xFF250005);
  static const primaryContainer = Color(0xFF462026);
  static const onPrimaryContainer = Color(0xFFFFDADB);
  static const secondary = Color(0xFF8D7CFF);
  static const onSecondary = Color(0xFF160F45);
  static const secondaryContainer = Color(0xFF2A2454);
  static const onSecondaryContainer = Color(0xFFE5DFFF);

  /// The check on a verified account.
  static const verified = Color(0xFF1D9BF0);

  // Text and lines.
  static const onSurface = Color(0xFFF5F1F7);
  static const onSurfaceVariant = Color(0xFFD0C8D4);
  static const outline = Color(0xFF8B8290);
  static const outlineVariant = Color(0xFF3C3743);

  /// Hairlines on glass: a stronger one for structural surfaces, a softer
  /// one for cards on top of them.
  static const border = Color(0x33FFFFFF);
  static const softBorder = Color(0x1FFFFFFF);
  static const divider = Color(0x14FFFFFF);

  /// The light glass catches at its top edge.
  static const highlight = Color(0xFFFFFFFF);
  static const shadow = Color(0x73000000);
  static const scrim = Color(0x9E000000);
  static const transparent = Color(0x00000000);

  /// Under the now-playing screen while it is dragged down.
  static const barrier = Color(0x8A000000);

  /// The light theme's seed: a deeper ember that keeps its contrast on
  /// light surfaces. The light scheme is derived from it.
  static const lightSeed = Color(0xFFAD2638);

  // Ambient light behind the app.
  static const ambientTop = Color(0xFF17101D);
  static const ambientMiddle = Color(0xFF090B14);
}

/// Spacing scale, in logical pixels. Groups are tight (xs–sm), sections
/// a step apart (md–lg); the app is compact, so xxl and up are rare. Page gutters are [lg] on phones and [xxl] on desktop.
abstract final class RhythmoSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 48;

  /// The smallest touch target, on every platform.
  static const double target = 48;

  /// The widest a reading column grows on desktop.
  static const double readingWidth = 520;

  /// The widest a settings-style list of rows grows on desktop.
  static const double listWidth = 720;

  /// The widest page content grows on desktop.
  static const double pageWidth = 960;
}

/// Corner radii. Controls are [md], surfaces [lg], large glass panels and
/// dialogs [xl], sheets [sheet]; [pill] is only for small controls.
abstract final class RhythmoRadii {
  /// Thin bars: progress tracks and meters.
  static const double bar = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;
  static const double sheet = 28;
  static const double pill = 999;

  static const BorderRadius control = BorderRadius.all(Radius.circular(md));
  static const BorderRadius surface = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius panel = BorderRadius.all(Radius.circular(xl));
}

/// Motion: a few durations and curves. Every animation goes through
/// [RhythmoMotion.of], so it collapses to nothing under reduce-motion.
abstract final class RhythmoMotion {
  /// State changes on small controls: a press, a level meter.
  static const quick = Duration(milliseconds: 120);

  /// Settling back, small reveals.
  static const short = Duration(milliseconds: 220);

  /// Content swaps and dismissals.
  static const medium = Duration(milliseconds: 260);

  /// A full-screen layer sliding in, such as now playing.
  static const enter = Duration(milliseconds: 360);

  /// Artwork breathing, the playing lyric line scrolling into place.
  static const long = Duration(milliseconds: 420);

  /// The now-playing backdrop's slow drift, repeated while music plays.
  static const ambient = Duration(seconds: 6);

  /// How long a pointer rests before a tooltip shows.
  static const tooltipWait = Duration(milliseconds: 500);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutQuart;
  static const Curve exit = Curves.easeInCubic;

  /// [duration], or zero when the platform asks for reduced motion.
  static Duration of(BuildContext context, Duration duration) =>
      MediaQuery.maybeDisableAnimationsOf(context) == true
          ? Duration.zero
          : duration;
}

/// The type scale: Material roles, set in Vazirmatn with line heights that
/// leave room for Persian diacritics.
abstract final class RhythmoType {
  static const family = 'Vazirmatn';

  /// Sets the scale on [base], in [color] (the scheme's onSurface).
  static TextTheme apply(TextTheme base,
      {Color color = RhythmoColors.onSurface}) {
    TextStyle? style(
            TextStyle? s, double size, FontWeight weight, double height) =>
        s?.copyWith(
          fontFamily: family,
          fontSize: size,
          fontWeight: weight,
          height: height,
          color: color,
        );
    return base.copyWith(
      displaySmall: style(base.displaySmall, 26, FontWeight.w800, 1.3),
      headlineMedium: style(base.headlineMedium, 22, FontWeight.w800, 1.35),
      headlineSmall: style(base.headlineSmall, 20, FontWeight.w800, 1.4),
      titleLarge: style(base.titleLarge, 17, FontWeight.w800, 1.4),
      titleMedium: style(base.titleMedium, 14, FontWeight.w700, 1.45),
      titleSmall: style(base.titleSmall, 13, FontWeight.w700, 1.45),
      bodyLarge: style(base.bodyLarge, 15, FontWeight.w400, 1.6),
      bodyMedium: style(base.bodyMedium, 13, FontWeight.w400, 1.6),
      bodySmall: style(base.bodySmall, 11.5, FontWeight.w400, 1.55),
      labelLarge: style(base.labelLarge, 13, FontWeight.w600, 1.4),
      labelMedium: style(base.labelMedium, 11.5, FontWeight.w500, 1.4),
      labelSmall: style(base.labelSmall, 10.5, FontWeight.w500, 1.4),
    );
  }
}

/// How much a glass surface blurs and lifts. Blur is reserved for a few
/// structural layers; cards on top of them stay flat.
@immutable
class RhythmoGlassLevel {
  const RhythmoGlassLevel({
    required this.blur,
    required this.highlight,
    required this.shadow,
    required this.border,
  });

  /// Backdrop blur sigma; zero draws no backdrop filter.
  final double blur;

  /// Opacity of the light at the top edge.
  final double highlight;
  final bool shadow;
  final Color border;

  /// The mini player and other chrome floating over content.
  static const chrome = RhythmoGlassLevel(
      blur: 24, highlight: 0.16, shadow: true, border: RhythmoColors.border);

  /// Panels and grouped content.
  static const panel = RhythmoGlassLevel(
      blur: 18, highlight: 0.16, shadow: true, border: RhythmoColors.border);

  /// Cards inside a panel or list: no blur, no shadow.
  static const card = RhythmoGlassLevel(
      blur: 0,
      highlight: 0.08,
      shadow: false,
      border: RhythmoColors.softBorder);

  static RhythmoGlassLevel lerp(
          RhythmoGlassLevel a, RhythmoGlassLevel b, double t) =>
      RhythmoGlassLevel(
        blur: lerpDouble(a.blur, b.blur, t)!,
        highlight: lerpDouble(a.highlight, b.highlight, t)!,
        shadow: t < 0.5 ? a.shadow : b.shadow,
        border: Color.lerp(a.border, b.border, t)!,
      );
}

/// The tokens on the theme, for widgets that take them from context:
/// `RhythmoTokens.of(context)`.
@immutable
class RhythmoTokens extends ThemeExtension<RhythmoTokens> {
  const RhythmoTokens({
    this.chrome = RhythmoGlassLevel.chrome,
    this.panel = RhythmoGlassLevel.panel,
    this.card = RhythmoGlassLevel.card,
    this.focusRing = RhythmoColors.primary,
    this.ambientPrimary = RhythmoColors.primary,
    this.ambientSecondary = RhythmoColors.secondary,
  });

  final RhythmoGlassLevel chrome;
  final RhythmoGlassLevel panel;
  final RhythmoGlassLevel card;

  /// The 2 px ring every focusable control shows under keyboard focus.
  final Color focusRing;
  final Color ambientPrimary;
  final Color ambientSecondary;

  static const dark = RhythmoTokens();

  /// The light theme: the glass levels keep their shape, the ring and the
  /// ambient light take the deeper ember.
  static const light = RhythmoTokens(
    focusRing: RhythmoColors.lightSeed,
    ambientPrimary: RhythmoColors.lightSeed,
  );

  static RhythmoTokens of(BuildContext context) =>
      Theme.of(context).extension<RhythmoTokens>() ?? dark;

  @override
  RhythmoTokens copyWith({
    RhythmoGlassLevel? chrome,
    RhythmoGlassLevel? panel,
    RhythmoGlassLevel? card,
    Color? focusRing,
    Color? ambientPrimary,
    Color? ambientSecondary,
  }) =>
      RhythmoTokens(
        chrome: chrome ?? this.chrome,
        panel: panel ?? this.panel,
        card: card ?? this.card,
        focusRing: focusRing ?? this.focusRing,
        ambientPrimary: ambientPrimary ?? this.ambientPrimary,
        ambientSecondary: ambientSecondary ?? this.ambientSecondary,
      );

  @override
  RhythmoTokens lerp(ThemeExtension<RhythmoTokens>? other, double t) {
    if (other is! RhythmoTokens) return this;
    return RhythmoTokens(
      chrome: RhythmoGlassLevel.lerp(chrome, other.chrome, t),
      panel: RhythmoGlassLevel.lerp(panel, other.panel, t),
      card: RhythmoGlassLevel.lerp(card, other.card, t),
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
      ambientPrimary: Color.lerp(ambientPrimary, other.ambientPrimary, t)!,
      ambientSecondary:
          Color.lerp(ambientSecondary, other.ambientSecondary, t)!,
    );
  }
}

/// A dark, saturated colour picked from [seed], standing in for cover art
/// until tracks have it. Every hue stays dark enough for light text on it.
Color artworkTint(String seed) {
  // FNV-1a, so a track keeps its colour across launches.
  var hash = 0x811c9dc5;
  for (final unit in seed.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.42, 0.2).toColor();
}
