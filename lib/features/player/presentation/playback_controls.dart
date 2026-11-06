import 'package:flutter/material.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/player/application/playback_settings.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';

/// The sleep timer's choices, in minutes.
const sleepTimerMinutes = [15, 30, 45, 60];

/// `۱٫۲۵×`, as the speed is shown.
String formatSpeed(double speed) {
  final text = speed == speed.roundToDouble()
      ? speed.toInt().toString()
      : speed.toString().replaceFirst(RegExp(r'0+$'), '');
  return '${persianDigits(text.replaceAll('.', '٫'))}×';
}

/// `۱۵ دقیقه`, or `۱ ساعت` for sixty.
String formatSleepChoice(int minutes) => minutes % 60 == 0
    ? '${persianDigits(minutes ~/ 60)} ساعت'
    : '${persianDigits(minutes)} دقیقه';

/// What the sleep timer will do, for the now-playing header; null when off.
String? sleepTimerStatus(PlayerController player) {
  if (player.sleepsAtTrackEnd) return 'توقف در پایان آهنگ';
  final remaining = player.sleepRemaining;
  if (remaining == null) return null;
  return 'توقف تا ${formatPlaybackTime(remaining)}';
}

/// Opens the sleep timer choices; filled while a timer is set.
class SleepTimerButton extends StatelessWidget {
  const SleepTimerButton({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final active = player.sleepTimerActive;
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: switch (sleepTimerStatus(player)) {
        final status? => 'زمان‌سنج خواب: $status',
        null => 'زمان‌سنج خواب',
      },
      isSelected: active,
      color: active ? colors.primary : null,
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => SleepTimerSheet(player: player),
      ),
      icon: Icon(active ? RhythmoIcons.moonStarsFill : RhythmoIcons.moonStars),
    );
  }
}

/// Picks when playback pauses by itself, or cancels the timer.
class SleepTimerSheet extends StatelessWidget {
  const SleepTimerSheet({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final status = sleepTimerStatus(player);
        void pick(VoidCallback choose) {
          choose();
          Navigator.of(context).pop();
        }

        return SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewPaddingOf(context).bottom + 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SheetHeading(
                title: 'زمان‌سنج خواب',
                subtitle: status == null
                    ? 'موسیقی در پایان آرام کم می‌شود و پخش متوقف می‌شود.'
                    : '$status · موسیقی در پایان آرام کم می‌شود.',
              ),
              for (final minutes in sleepTimerMinutes)
                _ChoiceTile(
                  label: formatSleepChoice(minutes),
                  onTap: () => pick(
                      () => player.setSleepTimer(Duration(minutes: minutes))),
                ),
              _ChoiceTile(
                label: 'پایان همین آهنگ',
                selected: player.sleepsAtTrackEnd,
                onTap: () => pick(player.setSleepAtTrackEnd),
              ),
              if (player.sleepTimerActive) ...[
                const Divider(indent: 24, endIndent: 24),
                ListTile(
                  minTileHeight: 56,
                  contentPadding:
                      const EdgeInsetsDirectional.symmetric(horizontal: 24),
                  leading: const Icon(RhythmoIcons.x),
                  iconColor: theme.colorScheme.error,
                  textColor: theme.colorScheme.error,
                  title: const Text('لغو زمان‌سنج'),
                  onTap: () => pick(player.cancelSleepTimer),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Shows the playback speed; opens the speed choices.
class SpeedButton extends StatelessWidget {
  const SpeedButton({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final changed = player.speed != 1;
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'سرعت پخش',
      // The rate alone, as audio players show it, tinted once changed.
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: changed ? colors.primary : colors.onSurfaceVariant,
          backgroundColor:
              changed ? colors.primary.withValues(alpha: 0.12) : null,
        ),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          builder: (_) => SpeedSheet(player: player),
        ),
        child: Text(
          formatSpeed(player.speed),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// Picks the playback speed from [playbackSpeeds].
class SpeedSheet extends StatelessWidget {
  const SpeedSheet({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom + 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHeading(
              title: 'سرعت پخش',
              subtitle: 'زیر و بمی صدا تغییر نمی‌کند و برای دفعه‌های بعد '
                  'هم به خاطر می‌ماند.',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Directionality(
                // Slow to fast, left to right, like the seek bar.
                textDirection: TextDirection.ltr,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final speed in playbackSpeeds)
                      ChoiceChip(
                        label: Text(formatSpeed(speed)),
                        tooltip: speed == 1 ? 'سرعت عادی' : null,
                        selected: player.speed == speed,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        onSelected: (_) => player.setSpeed(speed),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHeading extends StatelessWidget {
  const _SheetHeading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 56,
      contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 24),
      selected: selected,
      title: Text(label),
      trailing: selected ? const Icon(RhythmoIcons.check) : null,
      onTap: onTap,
    );
  }
}
