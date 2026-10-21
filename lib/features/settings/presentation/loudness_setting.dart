import 'package:flutter/material.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/data/loudness.dart';

/// Loudness normalization: on by default, per track or per album. Only the
/// playback volume changes; the files stay exactly as uploaded.
class LoudnessSetting extends StatelessWidget {
  const LoudnessSetting({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final mode = player.loudness;
        final on = mode != LoudnessMode.off;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(RhythmoIcons.speakerHigh),
              title: const Text('یکسان‌سازی بلندی صدا'),
              subtitle: Text(
                on
                    ? 'بلندی یکسان، بدون تغییر فایل'
                    : 'هر آهنگ با همان بلندی که ضبط شده پخش می‌شود.',
              ),
              value: on,
              onChanged: (value) => player.setLoudness(
                value ? LoudnessMode.track : LoudnessMode.off,
              ),
            ),
            if (on)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
                child: SegmentedButton<LoudnessMode>(
                  segments: const [
                    ButtonSegment(
                      value: LoudnessMode.track,
                      label: Text('هر آهنگ'),
                      tooltip: 'همه‌ی آهنگ‌ها به یک بلندی',
                    ),
                    ButtonSegment(
                      value: LoudnessMode.album,
                      label: Text('هر آلبوم'),
                      tooltip: 'تفاوت آهنگ‌های یک آلبوم حفظ می‌شود',
                    ),
                  ],
                  selected: {mode},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    minimumSize: WidgetStatePropertyAll(Size(0, 48)),
                  ),
                  onSelectionChanged: (selection) =>
                      player.setLoudness(selection.single),
                ),
              ),
          ],
        );
      },
    );
  }
}
