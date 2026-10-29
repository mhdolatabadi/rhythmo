import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/history/application/recently_played_controller.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';

/// How many tracks the «تازه اضافه‌شده» shelf and the recent rows show.
const homeShelfLength = 12;
const homeRecentLength = 5;

/// «صبح بخیر» and so on, for the hour of [now].
String homeGreeting(DateTime now) => switch (now.hour) {
      >= 5 && < 12 => 'صبح بخیر',
      >= 12 && < 17 => 'روز بخیر',
      >= 17 && < 20 => 'عصر بخیر',
      _ => 'شب بخیر',
    };

/// The library's newest tracks first; those without a date go last.
List<Track> newestTracks(List<Track> tracks, {int limit = homeShelfLength}) {
  final dated = [...tracks]..sort((a, b) {
      final x = a.addedAt;
      final y = b.addedAt;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
  return dated.take(limit).toList();
}

/// «خانه»: a greeting, what to pick up again, the newest tracks and what
/// was played lately. Everything on it plays with one tap.
class HomeView extends StatelessWidget {
  const HomeView({
    super.key,
    required this.header,
    required this.player,
    required this.changes,
    required this.tracks,
    required this.onAddMusic,
    this.recent,
    this.now,
  });

  /// The app bar, as a sliver.
  final Widget header;
  final PlayerController player;

  /// The library's changes, which the shelves follow.
  final Listenable changes;
  final List<Track> Function() tracks;
  final VoidCallback onAddMusic;
  final RecentlyPlayedController? recent;

  /// The clock for the greeting; the real one by default.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable:
          Listenable.merge([changes, player, if (recent != null) recent]),
      builder: (context, _) {
        final library = tracks();
        final played =
            (recent?.tracks ?? const <Track>[]).take(homeRecentLength).toList();
        final newest = newestTracks(library);
        final resume = player.track ?? played.firstOrNull;
        return CustomScrollView(
          slivers: [
            header,
            SliverPadding(
              padding: EdgeInsets.fromLTRB(RhythmoSpace.lg, RhythmoSpace.sm,
                  RhythmoSpace.lg, MediaQuery.paddingOf(context).bottom + 24),
              sliver: SliverList.list(
                children: [
                  Text(
                    homeGreeting((now ?? DateTime.now)()),
                    style: theme.textTheme.headlineMedium,
                  ),
                  const SizedBox(height: RhythmoSpace.md),
                  if (resume == null && library.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: RhythmoSpace.xxxl),
                      child: RhythmoStateView(
                        icon: RhythmoIcons.musicNote,
                        title: 'کتابخانه‌ات هنوز خالی است.',
                        message: 'آهنگ‌هایت را اضافه کن تا اینجا پیدا شوند.',
                        action: FilledButton.icon(
                          onPressed: onAddMusic,
                          icon: const Icon(RhythmoIcons.plus),
                          label: const Text('افزودن موسیقی'),
                        ),
                      ),
                    ),
                  if (resume != null)
                    _ResumeCard(
                      track: resume,
                      player: player,
                      onPlay: () => player.track?.id == resume.id
                          ? player.toggle()
                          : player.playFrom(played, 0),
                    ),
                  if (newest.isNotEmpty) ...[
                    const _Heading('تازه اضافه‌شده'),
                    SizedBox(
                      height: _ShelfItem.height,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: newest.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: RhythmoSpace.sm),
                        itemBuilder: (context, index) => _ShelfItem(
                          track: newest[index],
                          onTap: () => player.playFrom(newest, index),
                        ),
                      ),
                    ),
                  ],
                  if (played.isNotEmpty) ...[
                    const _Heading('اخیراً پخش‌شده'),
                    for (final (index, track) in played.indexed)
                      RhythmoTrackRow(
                        track: track,
                        seed: track.id,
                        title: track.title,
                        subtitle: trackSubtitle(track),
                        active: player.track?.id == track.id,
                        contentPadding: EdgeInsets.zero,
                        onTap: () => player.playFrom(played, index),
                      ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(
            top: RhythmoSpace.lg, bottom: RhythmoSpace.sm),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );
}

/// «ادامه بده»: the playing track, or the last one played, with the white
/// play button. Tapping the card opens the player once something plays.
class _ResumeCard extends StatelessWidget {
  const _ResumeCard({
    required this.track,
    required this.player,
    required this.onPlay,
  });

  final Track track;
  final PlayerController player;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final current = player.track?.id == track.id;
    final playing = current &&
        (player.status == PlayerStatus.playing ||
            player.status == PlayerStatus.buffering);
    return GlassSurface(
      key: const ValueKey('home-resume'),
      radius: RhythmoRadii.lg,
      blur: 0,
      shadow: false,
      child: InkWell(
        borderRadius: RhythmoRadii.surface,
        onTap: current ? () => openNowPlaying(context, player) : onPlay,
        child: Padding(
          padding: const EdgeInsets.all(RhythmoSpace.sm),
          child: Row(
            children: [
              RhythmoArtworkTile(seed: track.id, track: track, size: 56),
              const SizedBox(width: RhythmoSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ادامه بده',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      trackSubtitle(track),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filled(
                tooltip: playing ? 'توقف' : 'پخش',
                style: IconButton.styleFrom(
                  backgroundColor: colors.onSurface,
                  foregroundColor: colors.surface,
                ),
                onPressed: onPlay,
                icon: Icon(
                    playing ? RhythmoIcons.pauseFill : RhythmoIcons.playFill),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One cover on the «تازه اضافه‌شده» shelf, with its title and artist.
class _ShelfItem extends StatelessWidget {
  const _ShelfItem({required this.track, required this.onTap});

  static const double size = 88;
  static const double height = size + 44;

  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: size,
      child: InkWell(
        borderRadius: RhythmoRadii.control,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RhythmoArtworkTile(seed: track.id, track: track, size: size),
            const SizedBox(height: RhythmoSpace.xs),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge,
            ),
            Text(
              trackSubtitle(track),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
