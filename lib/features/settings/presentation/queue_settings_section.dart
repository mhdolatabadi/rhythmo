import 'package:flutter/material.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

/// Preferences for queues created after choosing a track or a play action.
class QueueSettingsSection extends StatelessWidget {
  const QueueSettingsSection({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: player,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
                    child: Text('صف پخش',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: [
                        ListTile(
                          title: const Text('با انتخاب یک آهنگ'),
                          subtitle: Text(player.playOnlySelected
                              ? 'فقط همان آهنگ پخش شود'
                              : 'همهٔ آهنگ‌های فهرست پخش شوند'),
                          onTap: () => showModalBottomSheet<void>(
                            context: context,
                            useSafeArea: true,
                            builder: (sheetContext) => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final single in [false, true])
                                  ListTile(
                                    title: Text(single
                                        ? 'فقط همان آهنگ پخش شود'
                                        : 'همهٔ آهنگ‌های فهرست پخش شوند'),
                                    selected: player.playOnlySelected == single,
                                    onTap: () {
                                      player.setQueuePreferences(
                                          playOnlySelected: single);
                                      Navigator.pop(sheetContext);
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        SwitchListTile(
                          title: const Text('جلوگیری از آهنگ تکراری'),
                          subtitle: const Text(
                              'هر آهنگ فقط یک بار در صف جدید قرار بگیرد.'),
                          value: player.preventDuplicates,
                          onChanged: (value) => player.setQueuePreferences(
                              preventDuplicates: value),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
