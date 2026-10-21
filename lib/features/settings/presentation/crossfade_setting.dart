import 'package:flutter/material.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/player/application/playback_settings.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

/// `خاموش`, or `۴ ثانیه`.
String formatCrossfade(Duration value) => value == Duration.zero
    ? 'خاموش'
    : '${persianDigits(value.inSeconds)} ثانیه';

/// How long the end of each track overlaps the next, from off to
/// [maxCrossfade]. Only shown where the player can overlap tracks.
class CrossfadeSetting extends StatelessWidget {
  const CrossfadeSetting({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final seconds = player.crossfade.inSeconds;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 1),
            ListTile(
              leading: const Icon(RhythmoIcons.waveform),
              title: const Text('هم‌پوشانی آهنگ‌ها'),
              subtitle: Text(
                seconds == 0
                    ? 'پخش بی‌فاصله، بدون هم‌پوشانی'
                    : 'پایان هر آهنگ ${formatCrossfade(player.crossfade)} '
                        'با شروع آهنگ بعدی درهم می‌آمیزد.',
              ),
              trailing: Text(
                formatCrossfade(player.crossfade),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: seconds == 0
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Directionality(
                // Off to longest, left to right, like the seek bar.
                textDirection: TextDirection.ltr,
                child: Slider(
                  value: seconds.toDouble(),
                  max: maxCrossfade.inSeconds.toDouble(),
                  divisions: maxCrossfade.inSeconds,
                  label: formatCrossfade(player.crossfade),
                  semanticFormatterCallback: (value) =>
                      formatCrossfade(Duration(seconds: value.round())),
                  onChanged: (value) =>
                      player.setCrossfade(Duration(seconds: value.round())),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
