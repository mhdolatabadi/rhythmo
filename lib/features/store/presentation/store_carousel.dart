import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/data/store_catalog.dart';

/// The width of one carousel card; its artwork is square.
const storeCarouselCardWidth = 144.0;

/// A row of popular or trending store songs (#284) that scrolls sideways.
/// Tapping a card plays the row from there. It takes no room while it has
/// nothing to show, so a new store doesn't open on an empty shelf.
class StoreCarousel extends StatefulWidget {
  const StoreCarousel({
    super.key,
    required this.controller,
    required this.ranking,
    required this.player,
    this.padding = const EdgeInsets.symmetric(horizontal: RhythmoSpace.lg),
    this.title,
    this.numbered = false,
    this.onAll,
  });

  /// The heading; the ranking's own label by default.
  final String? title;

  /// Big thin rank numerals on the covers (#448).
  final bool numbered;

  /// «همه» at the end of the heading, when set.
  final VoidCallback? onAll;

  final StoreController controller;
  final StoreRanking ranking;
  final PlayerController player;

  /// Around the heading and the row, so the first card lines up with the
  /// page's gutter.
  final EdgeInsets padding;

  @override
  State<StoreCarousel> createState() => _StoreCarouselState();
}

class _StoreCarouselState extends State<StoreCarousel> {
  StoreListing<Track> get _listing => widget.controller.ranked(widget.ranking);

  @override
  void initState() {
    super.initState();
    _listing.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_listing, widget.player]),
      builder: (context, _) {
        final songs = _listing.items;
        // Hold the row's room while the first page loads, so the list
        // under it doesn't jump down under a finger that is about to tap.
        final loading = switch (_listing.status) {
          StoreStatus.idle || StoreStatus.loading => true,
          _ => false,
        };
        if (songs.isEmpty && !loading) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: widget.padding.copyWith(top: RhythmoSpace.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        widget.title ?? widget.ranking.label,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  if (widget.onAll case final open?)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: open,
                      child: const Text('همه'),
                    ),
                ],
              ),
            ),
            SizedBox(height: widget.onAll == null ? RhythmoSpace.sm : 0),
            SizedBox(
              height: storeCarouselCardWidth + 64,
              child: songs.isEmpty
                  ? _Placeholders(padding: widget.padding)
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: widget.padding,
                      itemCount: songs.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(width: RhythmoSpace.md),
                      itemBuilder: (context, index) => _Card(
                        song: songs[index],
                        playing: widget.player.track?.id == songs[index].id,
                        likes: widget.player.favorites.countFor(songs[index]),
                        rank: widget.numbered ? index + 1 : null,
                        onTap: () => widget.player.playFrom(songs, index),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Empty card shapes shown while a row loads.
class _Placeholders extends StatelessWidget {
  const _Placeholders({required this.padding});

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    const side = storeCarouselCardWidth - RhythmoSpace.xs * 2;
    return ExcludeSemantics(
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: padding,
        itemCount: 4,
        separatorBuilder: (_, __) => const SizedBox(width: RhythmoSpace.md),
        itemBuilder: (_, __) => Padding(
          padding: const EdgeInsets.all(RhythmoSpace.xs),
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: side,
              height: side,
              decoration: BoxDecoration(
                color: color,
                borderRadius: RhythmoRadii.surface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.song,
    required this.playing,
    required this.likes,
    required this.onTap,
    this.rank,
  });

  final Track song;
  final bool playing;
  final int likes;
  final VoidCallback onTap;

  /// The place in the ranking, drawn big and thin on the cover.
  final int? rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final artist = song.artist ?? 'خواننده‌ی نامشخص';
    return Semantics(
      button: true,
      label: [
        song.title,
        artist,
        if (rank != null) 'رتبهٔ ${persianDigits(rank!)}',
        if (likes > 0) '${persianDigits(likes)} پسند',
        if (playing) 'در حال پخش',
      ].join('، '),
      excludeSemantics: true,
      child: SizedBox(
        width: storeCarouselCardWidth,
        child: InkWell(
          onTap: onTap,
          borderRadius: RhythmoRadii.surface,
          child: Padding(
            padding: const EdgeInsets.all(RhythmoSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    RhythmoArtworkTile(
                      track: song,
                      seed: song.id,
                      size: storeCarouselCardWidth - RhythmoSpace.xs * 2,
                      active: playing,
                    ),
                    if (rank case final place?)
                      PositionedDirectional(
                        start: RhythmoSpace.sm,
                        bottom: 0,
                        child: Text(
                          persianDigits(place),
                          key: ValueKey('rank-$place'),
                          style: TextStyle(
                            fontSize: 56,
                            height: 1.1,
                            fontWeight: FontWeight.w200,
                            color: colors.onSurface,
                            shadows: const [
                              Shadow(
                                  color: RhythmoColors.shadow, blurRadius: 12),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: RhythmoSpace.sm),
                Text(song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall),
                Row(
                  children: [
                    Expanded(
                      child: Text(artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant)),
                    ),
                    if (likes > 0) ...[
                      Icon(RhythmoIcons.heartFill,
                          size: 12, color: colors.primary),
                      const SizedBox(width: RhythmoSpace.xxs),
                      Text(persianDigits(likes),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
