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
  });

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
        if (songs.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: widget.padding.copyWith(top: RhythmoSpace.lg),
              child: Semantics(
                header: true,
                child: Text(
                  widget.ranking.label,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: RhythmoSpace.sm),
            SizedBox(
              height: storeCarouselCardWidth + 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: widget.padding,
                itemCount: songs.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: RhythmoSpace.md),
                itemBuilder: (context, index) => _Card(
                  song: songs[index],
                  playing: widget.player.track?.id == songs[index].id,
                  likes: widget.player.favorites.countFor(songs[index]),
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

class _Card extends StatelessWidget {
  const _Card({
    required this.song,
    required this.playing,
    required this.likes,
    required this.onTap,
  });

  final Track song;
  final bool playing;
  final int likes;
  final VoidCallback onTap;

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
                RhythmoArtworkTile(
                  track: song,
seed: song.id,
                  size: storeCarouselCardWidth - RhythmoSpace.xs * 2,
                  active: playing,
                ),
                const SizedBox(height: RhythmoSpace.sm),
                Text(song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
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
