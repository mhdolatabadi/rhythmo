import 'package:rhythmo/features/library/data/track_artwork.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/history/application/recently_played_controller.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

/// «اخیراً پخش‌شده» at the top of the library: the latest tracks as a
/// row of cards, with play-all and a way into the full list. It stays out
/// of the way until something has been played.
class RecentlyPlayedShelf extends StatelessWidget {
  const RecentlyPlayedShelf({
    super.key,
    required this.recent,
    required this.tracks,
    required this.player,
    required this.onOpenAll,
  });

  /// How many cards the shelf shows; the full list has the rest.
  static const maxCards = 12;

  final RecentlyPlayedController recent;

  /// The history as the library shows it, see [resolveRecent].
  final List<Track> Function() tracks;
  final PlayerController player;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([recent, player]),
      builder: (context, _) {
        final all = tracks();
        if (all.isEmpty) return const SizedBox.shrink();
        final shown = all.take(maxCards).toList(growable: false);
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SizedBox(width: 8),
                  Icon(RhythmoIcons.clockCounterClockwise,
                      size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'اخیراً پخش‌شده',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'پخش همهٔ اخیراً پخش‌شده‌ها',
                    onPressed: () => player.playFrom(all, 0),
                    icon: const Icon(RhythmoIcons.playFill),
                  ),
                  TextButton(
                    onPressed: onOpenAll,
                    style:
                        TextButton.styleFrom(minimumSize: const Size(64, 48)),
                    child: const Text('همه'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: _RecentCard.height,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, index) => _RecentCard(
                    track: shown[index],
                    current: player.track?.id == shown[index].id,
                    onTap: () => player.playTapped(all, index),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({
    required this.track,
    required this.current,
    required this.onTap,
  });

  static const double width = 124;
  static const double height = 190;

  final Track track;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final artist = track.artist?.trim();
    final secondary = [
      if (artist != null && artist.isNotEmpty) artist else 'خواننده نامشخص',
      if (track.addedBy case final by?) by,
    ].join(' · ');
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        selected: current,
        label: current ? 'در حال پخش: ${track.title}' : null,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(RhythmoRadii.lg),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: RhythmoRadii.control,
                      gradient: LinearGradient(
                        begin: AlignmentDirectional.topStart,
                        end: AlignmentDirectional.bottomEnd,
                        colors: current
                            ? [colors.primaryContainer, colors.primary]
                            : [
                                colors.surfaceContainerHighest,
                                colors.surfaceContainerHigh,
                              ],
                      ),
                    ),
                    child: TrackCover(
                        track: track,
                        radius: 16,
                        child: Icon(
                          current
                              ? RhythmoIcons.waveformFill
                              : RhythmoIcons.musicNote,
                          size: 36,
                          color: current
                              ? colors.onPrimaryContainer
                              : colors.onSurfaceVariant,
                        )),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: current ? colors.primary : colors.onSurface,
                  ),
                ),
                Text(
                  secondary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
