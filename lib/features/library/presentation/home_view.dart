import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/history/application/recently_played_controller.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/notifications/application/notifications_controller.dart';
import 'package:rhythmo/features/notifications/data/notifications.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';

/// How many tracks the «تازه اضافه‌شده» shelf and «اخیرا شنیدی» show.
const homeShelfLength = 12;
const homeRecentLength = 12;

/// The widest «خانه»'s content grows, matching the library's list.
const homeMaxWidth = 880.0;

/// How many new songs from followed channels «خانه» shows.
const homeChannelLength = 3;

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

/// «خانه»: the ways to find new music (popular playlists, گنجینه, «این آهنگ
/// چیه؟»), what to pick up again, new songs from followed channels, the
/// newest tracks and a rail of what was played lately. No greeting (#447).
class HomeView extends StatelessWidget {
  const HomeView({
    super.key,
    required this.header,
    required this.player,
    required this.changes,
    required this.tracks,
    required this.onAddMusic,
    this.recent,
    this.notifications,
    this.onOpenNotifications,
    this.onOpenChannel,
    this.onPopular,
    this.onStore,
    this.onIdentify,
    this.onFriends,
  });

  /// The app bar, as a sliver.
  final Widget header;
  final PlayerController player;

  /// The library's changes, which the shelves follow.
  final Listenable changes;
  final List<Track> Function() tracks;
  final VoidCallback onAddMusic;
  final RecentlyPlayedController? recent;

  /// Opens popular playlists, گنجینه and song identification; a null one
  /// hides its card.
  final VoidCallback? onPopular;
  final VoidCallback? onStore;
  final VoidCallback? onIdentify;

  /// Opens «فعالیت دوستان» (#228); null hides it.
  final VoidCallback? onFriends;

  /// The notices from followed channels; null hides «تازه از کانال‌هایت».
  final NotificationsController? notifications;

  /// Opens «اعلان‌ها», from the section's «همه».
  final VoidCallback? onOpenNotifications;

  /// Opens a channel by its share token, from one of its notices.
  final ValueChanged<String>? onOpenChannel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        changes,
        player,
        if (recent != null) recent,
        if (notifications != null) notifications,
      ]),
      builder: (context, _) {
        final library = tracks();
        final played =
            (recent?.tracks ?? const <Track>[]).take(homeRecentLength).toList();
        final newest = newestTracks(library);
        final resume = player.track ?? played.firstOrNull;
        final notices =
            (notifications?.notifications ?? const <PlaylistNotification>[])
                .take(homeChannelLength)
                .toList();
        final discover = [
          if (onPopular case final open?)
            _DiscoverCard('محبوب‌ها', RhythmoIcons.fire, open),
          if (onStore case final open?)
            _DiscoverCard('گنجینه', RhythmoIcons.vinylRecord, open),
          if (onIdentify case final open?)
            _DiscoverCard('این آهنگ چیه؟', RhythmoIcons.microphoneStage, open),
          if (onFriends case final open?)
            _DiscoverCard('دوستان', RhythmoIcons.users, open),
        ];
        // As wide as «موسیقی من»'s list: 880 px at most, centred.
        final width = MediaQuery.sizeOf(context).width;
        final gutter = width >= 900
            ? ((width - homeMaxWidth) / 2).clamp(40.0, double.infinity)
            : RhythmoSpace.lg;
        return CustomScrollView(
          slivers: [
            header,
            SliverPadding(
              padding: EdgeInsets.fromLTRB(gutter, RhythmoSpace.sm, gutter,
                  MediaQuery.paddingOf(context).bottom + 24),
              sliver: SliverList.list(
                children: [
                  // Ways to find new music sit right under the header, as
                  // small chips: a door, not a section.
                  if (discover.isNotEmpty) ...[
                    Wrap(
                      spacing: RhythmoSpace.sm,
                      runSpacing: RhythmoSpace.sm,
                      children: discover,
                    ),
                  ],
                  const SizedBox(height: RhythmoSpace.lg),
                  if (resume == null && library.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: RhythmoSpace.xxxl),
                      child: RhythmoStateView(
                        icon: RhythmoIcons.musicNote,
                        title: '«موسیقی من» هنوز خالی است.',
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
                  if (notices.isNotEmpty) ...[
                    _Heading('تازه از کانال‌هایت', onAll: onOpenNotifications),
                    for (final notice in notices)
                      _ChannelNotice(
                        notice: notice,
                        onTap: () {
                          notifications?.markOpened(notice);
                          onOpenChannel?.call(notice.shareToken);
                        },
                      ),
                  ],
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
                    const _Heading('اخیرا شنیدی'),
                    SizedBox(
                      height: _ShelfItem.railHeight,
                      child: ListView.separated(
                        key: const ValueKey('home-recent'),
                        scrollDirection: Axis.horizontal,
                        itemCount: played.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: RhythmoSpace.md),
                        itemBuilder: (context, index) => _ShelfItem(
                          track: played[index],
                          size: _ShelfItem.railSize,
                          onTap: () => player.playFrom(played, index),
                        ),
                      ),
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

/// A section title (18 px, 600) with an optional «همه» at the end.
class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.onAll});

  final String title;
  final VoidCallback? onAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: RhythmoSpace.lg, bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          if (onAll case final open?)
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurfaceVariant,
                minimumSize: const Size(48, 48),
              ),
              onPressed: open,
              child: const Text('همه'),
            ),
        ],
      ),
    );
  }
}

/// A new song from a followed channel: the channel's name and what came,
/// with a coral dot while unread.
class _ChannelNotice extends StatelessWidget {
  const _ChannelNotice({required this.notice, required this.onTap});

  final PlaylistNotification notice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final what = notice.trackCount == 1 && notice.trackTitle != null
        ? notice.trackTitle!
        : '${persianDigits(notice.trackCount)} آهنگ تازه';
    return InkWell(
      borderRadius: RhythmoRadii.control,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Row(
          children: [
            RhythmoArtworkTile(seed: notice.shareToken, size: 48),
            const SizedBox(width: RhythmoSpace.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(what,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: 15, fontWeight: FontWeight.w500)),
                  Text(notice.playlistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13, color: colors.onSurfaceVariant)),
                ],
              ),
            ),
            if (!notice.read)
              Container(
                key: const ValueKey('unread-dot'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: colors.primary, shape: BoxShape.circle),
              ),
          ],
        ),
      ),
    );
  }
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

/// One cover on a shelf, with its title and artist.
class _ShelfItem extends StatelessWidget {
  const _ShelfItem({required this.track, required this.onTap, this.size = 88});

  static const double height = 88 + 44;

  /// «اخیرا شنیدی»'s covers are 148 px.
  static const double railSize = 148;
  static const double railHeight = railSize + 48;

  final Track track;
  final VoidCallback onTap;
  final double size;

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

/// A way to find new music on «خانه»: a small chip with an icon and a name.
class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard(this.label, this.icon, this.onTap);

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: RhythmoSpace.target),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
                RhythmoSpace.md, 0, RhythmoSpace.lg, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: RhythmoSpace.sm),
                Text(label, style: theme.textTheme.labelLarge),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
