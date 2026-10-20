import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/auth/presentation/sign_in_prompt.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';

/// The way into «پسندیده‌ها»: pinned at the top of the playlists tab.
class LikedSongsEntry extends StatelessWidget {
  const LikedSongsEntry({
    super.key,
    required this.favorites,
    required this.libraryTracks,
    required this.onOpen,
  });

  final FavoriteTracks favorites;
  final List<Track> libraryTracks;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: favorites,
      builder: (context, _) {
        final count = favorites.likedFrom(libraryTracks).length;
        return Material(
          color: scheme.secondaryContainer,
          shape:
              const RoundedRectangleBorder(borderRadius: RhythmoRadii.surface),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: RhythmoSpace.lg, vertical: RhythmoSpace.md),
                child: Row(
                  children: [
                    Container(
                      width: RhythmoSpace.target,
                      height: RhythmoSpace.target,
                      decoration: BoxDecoration(
                        color: scheme.secondary,
                        borderRadius: RhythmoRadii.control,
                      ),
                      child: Icon(RhythmoIcons.heartFill,
                          color: scheme.onSecondary),
                    ),
                    const SizedBox(width: RhythmoSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'پسندیده‌ها',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: scheme.onSecondaryContainer,
                            ),
                          ),
                          Text(
                            count == 0
                                ? 'آهنگ‌هایی که می‌پسندی اینجا جمع می‌شوند'
                                : '${persianDigits(count)} آهنگ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSecondaryContainer),
                          ),
                        ],
                      ),
                    ),
                    Icon(RhythmoIcons.caretLeft,
                        color: scheme.onSecondaryContainer),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// «پسندیده‌ها»: every song the listener liked, most recently liked
/// first, playable and shuffleable like a playlist. Unliking a song here
/// takes it off the list.
class LikedSongsScreen extends StatelessWidget {
  const LikedSongsScreen({
    super.key,
    required this.player,
    required this.libraryTracks,
  });

  final PlayerController player;

  /// The library, for its copies of the listener's own tracks and for
  /// likes kept only on this device.
  final List<Track> libraryTracks;

  @override
  Widget build(BuildContext context) {
    final favorites = player.favorites;
    return Scaffold(
      extendBody: true,
      appBar: AppBar(title: const Text('پسندیده‌ها')),
      bottomNavigationBar: MiniPlayer(player: player),
      body: RhythmoBackdrop(
        child: ListenableBuilder(
          listenable: Listenable.merge([favorites, player]),
          builder: (context, _) {
            final songs = favorites.likedFrom(libraryTracks);
            if (songs.isEmpty) {
              return const RhythmoStateView(
                icon: RhythmoIcons.heart,
                title: 'هنوز آهنگی را نپسندیده‌ای',
                message: 'روی قلب کنار هر آهنگ بزن تا اینجا بیاید.',
              );
            }
            return Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: RhythmoSpace.pageWidth),
                child: ListView.builder(
                  padding: EdgeInsets.only(
                    top: RhythmoSpace.sm,
                    bottom:
                        MediaQuery.paddingOf(context).bottom + RhythmoSpace.lg,
                  ),
                  itemCount: songs.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(RhythmoSpace.lg,
                            RhythmoSpace.sm, RhythmoSpace.lg, RhythmoSpace.md),
                        child: Wrap(
                          spacing: RhythmoSpace.sm,
                          runSpacing: RhythmoSpace.sm,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            FilledButton.icon(
                              onPressed: () => player.playFrom(songs, 0),
                              icon: const Icon(RhythmoIcons.playFill),
                              label: const Text('پخش همه'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () => player.playShuffled(songs),
                              icon: const Icon(RhythmoIcons.shuffle),
                              label: const Text('پخش تصادفی'),
                            ),
                            Text('${persianDigits(songs.length)} آهنگ',
                                style: Theme.of(context).textTheme.bodyMedium),
                          ],
                        ),
                      );
                    }
                    final song = songs[index - 1];
                    return RhythmoTrackRow(
                      track: song,
seed: song.id,
                      title: song.title,
                      subtitle: song.artist ?? 'خواننده‌ی نامشخص',
                      active: player.track?.id == song.id,
                      onTap: () => player.playTapped(songs, index - 1),
                      trailing: LikeButton(track: song, favorites: favorites),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A 48 px heart that likes or unlikes [track], filled while liked, with
/// the like count beside it when [showCount] and anyone likes the song.
class LikeButton extends StatelessWidget {
  const LikeButton({
    super.key,
    required this.track,
    required this.favorites,
    this.showCount = false,
    this.onSignIn,
  });

  final Track track;
  final FavoriteTracks favorites;
  final bool showCount;

  /// Opens sign-in, for a guest who likes a store song.
  final VoidCallback? onSignIn;

  Future<void> _toggle(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await favorites.toggleTrack(track);
    switch (result) {
      case TrackLikeResult.done:
        break;
      case TrackLikeResult.needsAccount:
        if (context.mounted) {
          askToSignIn(context, action: 'پسندیدن', onSignIn: onSignIn);
        }
      case TrackLikeResult.failed:
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
              content: Text('پسندیدن ثبت نشد. دوباره تلاش کن.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: favorites,
      builder: (context, _) {
        final liked = favorites.contains(track.id);
        final count = favorites.countFor(track);
        final colors = Theme.of(context).colorScheme;
        final icon = Icon(
          liked ? RhythmoIcons.heartFill : RhythmoIcons.heart,
          color: liked ? colors.primary : null,
        );
        final label = liked ? 'نپسندیدن' : 'پسندیدن';
        if (!showCount || count == 0) {
          return IconButton(
            tooltip: label,
            isSelected: liked,
            onPressed: () => _toggle(context),
            icon: icon,
          );
        }
        return Semantics(
          label: '$label، ${persianDigits(count)} پسند',
          button: true,
          excludeSemantics: true,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              minimumSize: const Size(RhythmoSpace.target, RhythmoSpace.target),
            ),
            onPressed: () => _toggle(context),
            icon: icon,
            label: Text(persianDigits(count)),
          ),
        );
      },
    );
  }
}
