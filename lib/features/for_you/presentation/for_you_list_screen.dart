import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/for_you/data/for_you.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';

/// One «برای تو» list (#226). It is read-only: smart playlists update
/// themselves and mixes change once a day, so there is nothing to edit.
class ForYouListScreen extends StatelessWidget {
  const ForYouListScreen({super.key, required this.list, required this.player});

  final ForYouList list;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tracks = list.tracks;
    return Scaffold(
      appBar: AppBar(title: Text(list.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    RhythmoSpace.lg, 0, RhythmoSpace.lg, RhythmoSpace.sm),
                child: Row(
                  children: [
                    Chip(
                      key: const ValueKey('for-you-badge'),
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                          list.smart
                              ? RhythmoIcons.arrowsClockwise
                              : RhythmoIcons.shuffle,
                          size: 16),
                      label: Text(list.smart ? 'هوشمند' : 'امروز'),
                    ),
                    const SizedBox(width: RhythmoSpace.sm),
                    Expanded(
                      child: Text(
                        list.smart
                            ? '${persianDigits(tracks.length)} آهنگ · خودش به‌روز می‌شود'
                            : '${persianDigits(tracks.length)} آهنگ · فردا تازه می‌شود',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    if (tracks.isNotEmpty)
                      IconButton.filled(
                        key: const ValueKey('for-you-play'),
                        tooltip: 'پخش همه',
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                        ),
                        onPressed: () => player.playFrom(tracks, 0),
                        icon: const Icon(RhythmoIcons.playFill),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                      RhythmoSpace.sm,
                      0,
                      RhythmoSpace.sm,
                      MediaQuery.paddingOf(context).bottom + 96),
                  itemCount: tracks.length,
                  itemBuilder: (context, index) {
                    final track = tracks[index];
                    return ListTile(
                      key: ValueKey(track.id),
                      minTileHeight: 64,
                      leading: RhythmoArtworkTile(seed: track.id, track: track),
                      title: Text(track.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(trackSubtitle(track),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => player.playTapped(tracks, index),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
