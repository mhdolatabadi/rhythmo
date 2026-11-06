import 'package:rhythmo/core/persian_digits.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/core/format_size.dart';

/// How much of the account's cloud storage is used, for the account screen.
class StorageUsageCard extends StatelessWidget {
  const StorageUsageCard({
    super.key,
    required this.usedBytes,
    required this.limitBytes,
  });

  final int usedBytes;

  /// Zero or less when the server did not report a limit.
  final int limitBytes;

  /// From this share on, the card warns that the account is filling up.
  static const nearlyFull = 0.9;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final known = limitBytes > 0;
    final progress = known ? (usedBytes / limitBytes).clamp(0.0, 1.0) : 0.0;
    final percent = (progress * 100).round();
    final warning = !known
        ? null
        : usedBytes >= limitBytes
            ? 'فضای حسابت پر است. برای افزودن آهنگ تازه، چند آهنگ را حذف کن.'
            : progress >= nearlyFull
                ? 'فضای حسابت تقریباً پر است.'
                : null;
    // A flat card on `surface`, like every settings group (#449).
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: RhythmoRadii.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Semantics(
          label: 'فضای ابری مصرف‌شده',
          value: known ? '${persianDigits(percent)} درصد' : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(RhythmoIcons.cloud, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'فضای ابری',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      known
                          ? '${formatSize(usedBytes)} از ${formatSize(limitBytes)}'
                          : '${formatSize(usedBytes)} مصرف‌شده',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              if (known) ...[
                const SizedBox(height: 12),
                // A thin violet-to-coral bar; red only when it warns.
                ClipRRect(
                  borderRadius: BorderRadius.circular(RhythmoRadii.pill),
                  child: Stack(
                    children: [
                      Container(
                          height: 4, color: colors.surfaceContainerHighest),
                      ShaderMask(
                        key: const ValueKey('storage-gradient'),
                        blendMode: BlendMode.srcIn,
                        shaderCallback: (bounds) => LinearGradient(
                          begin: AlignmentDirectional.centerStart
                              .resolve(Directionality.of(context)),
                          end: AlignmentDirectional.centerEnd
                              .resolve(Directionality.of(context)),
                          colors: warning == null
                              ? [colors.secondary, colors.primary]
                              : [colors.error, colors.error],
                        ).createShader(bounds),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          color: colors.onSurface,
                          backgroundColor: Colors.transparent,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (warning != null) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(RhythmoIcons.warning, size: 18, color: colors.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        warning,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colors.error),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
