import 'package:flutter/material.dart';

/// Every play action is white with dark text, the same light as the
/// player's play button, so playing looks the same wherever it starts.
/// [base] adds sizes or padding; the colours always win.
ButtonStyle rhythmoPlayStyle(BuildContext context, [ButtonStyle? base]) {
  final colors = Theme.of(context).colorScheme;
  return FilledButton.styleFrom(
    backgroundColor: colors.onSurface,
    foregroundColor: colors.surface,
    iconColor: colors.surface,
  ).merge(base);
}
