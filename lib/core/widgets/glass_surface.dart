import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/tokens.dart';

/// The canvas: night with the ambient light rising from its top corner.
const rhythmoAmbientGradient = LinearGradient(
  begin: Alignment.topRight,
  end: Alignment.bottomLeft,
  colors: [
    RhythmoColors.ambientTop,
    RhythmoColors.ambientMiddle,
    RhythmoColors.background,
  ],
  stops: [0, 0.48, 1],
);

/// The aurora behind primary app surfaces: ember light from the top corner
/// and violet from the opposite side, settling into night at the bottom.
/// It is still; nothing in it moves.
class RhythmoBackdrop extends StatelessWidget {
  const RhythmoBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: dark
            ? rhythmoAmbientGradient
            : LinearGradient(colors: [
                Theme.of(context).colorScheme.surfaceContainerLow,
                Theme.of(context).colorScheme.surface,
              ]),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (dark) const IgnorePointer(child: _AmbientLight()),
          child,
        ],
      ),
    );
  }
}

class _AmbientLight extends StatelessWidget {
  const _AmbientLight();

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        children: [
          PositionedDirectional(
            top: -150,
            end: -130,
            child: _Glow(
              size: 420,
              color: RhythmoColors.primary.withValues(alpha: 0.26),
            ),
          ),
          PositionedDirectional(
            top: 220,
            start: -190,
            child: _Glow(
              size: 440,
              color: RhythmoColors.secondary.withValues(alpha: 0.2),
            ),
          ),
          // Night rises from the bottom so text and the mini player keep
          // their contrast over the light.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    RhythmoColors.transparent,
                    RhythmoColors.ambientMiddle,
                  ],
                  stops: [0.45, 1],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 72, sigmaY: 72),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// A bounded glass layer. Reserve blur for structural surfaces instead of
/// repeating it for every list row.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = 20,
    this.blur = 18,
    this.tint,
    this.borderColor,
    this.shadow = true,
  });

  /// A surface at one of the glass levels in [RhythmoGlassLevel].
  GlassSurface.level(
    RhythmoGlassLevel level, {
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = RhythmoRadii.xl,
    this.tint,
  })  : blur = level.blur,
        borderColor = level.border,
        shadow = level.shadow;

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final double blur;
  final Color? tint;
  final Color? borderColor;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget surface = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            // A faint sheen, not a glare: the glass stays calm.
            (tint ?? RhythmoColors.highlight).withValues(alpha: 0.07),
            RhythmoColors.highlight.withValues(alpha: 0.03),
            (dark ? RhythmoColors.surface : scheme.surfaceContainerLow)
                .withValues(alpha: 0.9),
          ],
          stops: const [0, 0.45, 1],
        ),
        border: Border.all(color: borderColor ?? scheme.outlineVariant),
        boxShadow: shadow
            ? const [
                BoxShadow(
                  color: RhythmoColors.shadow,
                  offset: Offset(0, 12),
                  blurRadius: 32,
                ),
              ]
            : null,
      ),
      child: child,
    );
    if (blur > 0) {
      surface = ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: surface,
        ),
      );
    }
    return Padding(padding: margin ?? EdgeInsets.zero, child: surface);
  }
}
