import 'package:flutter/material.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/player/application/playback_settings.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/playback_controls.dart';
import 'package:rhythmo/features/settings/presentation/crossfade_setting.dart';
import 'package:rhythmo/features/settings/presentation/loudness_setting.dart';

/// Playback controls backed by the same controller as the now-playing screen.
class PlaybackSettingsSection extends StatelessWidget {
  const PlaybackSettingsSection({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: player,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
                    child: Text(
                      'پخش',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                  Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: ListTileTheme(
                      data: const ListTileThemeData(
                        minTileHeight: 56,
                        minVerticalPadding: 4,
                        horizontalTitleGap: 12,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: Column(
                        children: [
                          ListTile(
                            leading: const Icon(RhythmoIcons.moonStars),
                            title: const Text('زمان‌سنج خواب'),
                            trailing: Text(sleepTimerStatus(player) ?? 'خاموش'),
                            onTap: () => showModalBottomSheet<void>(
                              context: context,
                              useSafeArea: true,
                              isScrollControlled: true,
                              builder: (_) => SleepTimerSheet(player: player),
                            ),
                          ),
                          const SizedBox(height: 4),
                          ListTile(
                            leading: const Icon(RhythmoIcons.gauge),
                            title: const Text('سرعت پخش'),
                            trailing: Text(formatSpeed(player.speed)),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Directionality(
                              textDirection: TextDirection.ltr,
                              child: Slider(
                                key: const ValueKey('playback-speed-slider'),
                                value: playbackSpeeds
                                    .indexOf(player.speed)
                                    .clamp(0, playbackSpeeds.length - 1)
                                    .toDouble(),
                                max: (playbackSpeeds.length - 1).toDouble(),
                                divisions: playbackSpeeds.length - 1,
                                label: formatSpeed(player.speed),
                                semanticFormatterCallback: (value) =>
                                    formatSpeed(playbackSpeeds[value.round()]),
                                onChanged: (value) => player
                                    .setSpeed(playbackSpeeds[value.round()]),
                              ),
                            ),
                          ),
                          if (player.supportsCrossfade)
                            CrossfadeSetting(player: player),
                          LoudnessSetting(player: player),
                          if (player.supportsSilenceSkipping)
                            SwitchListTile(
                              title: const Text('رد کردن سکوت'),
                              subtitle: const Text(
                                'بخش‌های ساکت هنگام پخش رد شوند.',
                              ),
                              value: player.skipSilence,
                              onChanged: (value) => player.setSystemPreferences(
                                  skipSilence: value),
                            ),
                          SwitchListTile(
                            title: const Text('کنترل پخش از سیستم'),
                            subtitle: const Text(
                              'دکمه‌های پخش در اعلان و صفحهٔ قفل',
                            ),
                            value: player.systemControls,
                            onChanged: (value) => player.setSystemPreferences(
                                systemControls: value),
                          ),
                          SwitchListTile(
                            title: const Text('شروع پخش با دستگاه خارجی'),
                            subtitle: const Text(
                              'اجازهٔ شروع پخش با هدست و دکمه‌های سیستم',
                            ),
                            value: player.externalPlayback,
                            onChanged: (value) => player.setSystemPreferences(
                              externalPlayback: value,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
