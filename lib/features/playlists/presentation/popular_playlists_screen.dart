import 'package:rhythmo/core/persian_digits.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/app/app_configuration.dart';
import 'package:rhythmo/core/links/open_link.dart';
import 'package:rhythmo/core/links/site_page.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/auth/presentation/sign_in_prompt.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/shared_playlist_screen.dart';
import 'package:rhythmo/features/identify/application/identify_controller.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/presentation/store_screen.dart';

/// Playlists their owners made public, most liked first. Link-only
/// playlists are never listed here.
class PopularPlaylistsScreen extends StatefulWidget {
  const PopularPlaylistsScreen({
    super.key,
    required this.controller,
    required this.player,
    this.onSaved,
    this.onSignIn,
    this.openShareToken,
    this.store,
    this.identify,
    this.siteUri = AppConfiguration.sitePage,
    this.openLink = openExternalLink,
  });

  final PlaylistsController controller;
  final PlayerController player;

  /// Passed on to a playlist opened from here, for when it is saved.
  final VoidCallback? onSaved;

  /// Set when this is a guest's home: the app bar offers sign-in, and a
  /// guest who tries to like is asked to sign in.
  final VoidCallback? onSignIn;

  /// A shared playlist link the app was opened with, shown on top at once.
  final String? openShareToken;

  /// The public store, offered in the app bar; null hides it.
  final StoreController? store;

  /// «این آهنگ چیه؟», offered inside the store; null hides it.
  final IdentifyController? identify;

  /// Where the guest's privacy policy link points.
  final SitePageResolver siteUri;

  final LinkOpener openLink;

  @override
  State<PopularPlaylistsScreen> createState() => _PopularPlaylistsScreenState();
}

class _PopularPlaylistsScreenState extends State<PopularPlaylistsScreen> {
  /// The playlist being fetched to play, so its button shows progress.
  String? _playing;

  Future<void> _play(PublicPlaylist playlist) async {
    setState(() => _playing = playlist.shareToken);
    try {
      final shared = await widget.controller.openShared(playlist.shareToken);
      if (!mounted) return;
      if (shared.tracks.isEmpty) {
        _say('این فهرست پخش آهنگی ندارد.');
      } else {
        await widget.player.playFrom(shared.tracks, 0);
      }
    } on SharedPlaylistUnavailable {
      _say('این فهرست پخش دیگر عمومی نیست.');
      await widget.controller.loadPopular();
    } catch (_) {
      _say('پخش این فهرست شروع نشد. دوباره تلاش کن.');
    } finally {
      if (mounted) setState(() => _playing = null);
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void initState() {
    super.initState();
    // After this build: the controller also drives the screen underneath,
    // which must not be marked dirty while this route is being built.
    Future.microtask(() {
      if (mounted) widget.controller.loadPopular();
    });
    final shareToken = widget.openShareToken;
    if (shareToken != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openToken(shareToken);
      });
    }
  }

  Future<void> _open(PublicPlaylist playlist) =>
      _openToken(playlist.shareToken);

  Future<void> _openToken(String shareToken) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SharedPlaylistScreen(
        shareToken: shareToken,
        controller: widget.controller,
        player: widget.player,
        onSaved: widget.onSaved,
        onSignIn: widget.onSignIn,
      ),
    ));
    if (mounted) await widget.controller.loadPopular();
  }

  Future<void> _like(PublicPlaylist playlist) async {
    if (!widget.controller.signedIn) {
      askToSignIn(context, action: 'پسندیدن', onSignIn: widget.onSignIn);
      return;
    }
    final result =
        await widget.controller.setLike(playlist.shareToken, playlist.likes);
    if (!mounted || result == LikeResult.done) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result == LikeResult.gone
          ? 'این فهرست پخش دیگر عمومی نیست.'
          : 'پسندیدن ثبت نشد. دوباره تلاش کن.'),
    ));
    if (result == LikeResult.gone) await widget.controller.loadPopular();
  }

  Future<void> _hide(PublicPlaylist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف از فهرست‌های محبوب؟'),
        content: Text('«${playlist.name}» دیگر در فهرست‌های پخش محبوب '
            'نشان داده نمی‌شود. خود فهرست پخش و لینکش سر جایشان می‌مانند.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final saved = await widget.controller.setPopularHidden(playlist);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(saved
          ? '«${playlist.name}» از فهرست‌های محبوب حذف شد.'
          : 'حذف انجام نشد. دوباره تلاش کن.'),
      action: saved
          ? SnackBarAction(
              label: 'برگرداندن',
              onPressed: () async {
                final restored = await widget.controller
                    .setPopularHidden(playlist, hidden: false);
                if (!restored) _say('برگرداندن انجام نشد. دوباره تلاش کن.');
              },
            )
          : null,
    ));
  }

  Future<void> _delete(PublicPlaylist playlist) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('پاک کردن فهرست پخش؟'),
        content: Text('«${playlist.name}» برای همیشه پاک می‌شود و لینکش '
            'دیگر کار نمی‌کند. آهنگ‌هایش در کتابخانهٔ صاحبانشان می‌مانند. '
            'این کار برگشت‌پذیر نیست.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            child: const Text('پاک کردن'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final deleted = await widget.controller.deletePublic(playlist);
    _say(deleted
        ? '«${playlist.name}» پاک شد.'
        : 'پاک کردن انجام نشد. دوباره تلاش کن.');
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        title: const Text('فهرست‌های پخش محبوب'),
        actions: [
          if (widget.store != null)
            IconButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => StoreScreen(
                    controller: widget.store!,
                    player: widget.player,
                    onSignIn: widget.onSignIn,
                    identify: widget.identify,
                  ),
                ),
              ),
              tooltip: 'استور',
              icon: const Icon(RhythmoIcons.storefront),
            ),
          // Readable before signing up, as the stores expect.
          if (widget.onSignIn != null && !controller.signedIn)
            IconButton(
              onPressed: () => openSitePage(context, '/privacy',
                  siteUri: widget.siteUri, openLink: widget.openLink),
              tooltip: 'حریم خصوصی',
              icon: const Icon(RhythmoIcons.shieldCheck),
            ),
          if (widget.onSignIn != null && !controller.signedIn)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: FilledButton(
                onPressed: widget.onSignIn,
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                child: const Text('ورود / ثبت‌نام'),
              ),
            ),
        ],
      ),
      bottomNavigationBar: MiniPlayer(player: widget.player),
      body: RhythmoBackdrop(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final popular = controller.popular;
            return switch (controller.popularStatus) {
              PlaylistsStatus.loading when popular.isEmpty =>
                const RhythmoStateView.loading(
                    title: 'در حال دریافت فهرست‌های محبوب…'),
              PlaylistsStatus.error when popular.isEmpty =>
                RhythmoStateView.error(
                  icon: RhythmoIcons.cloudSlash,
                  title: 'فهرست‌های پخش محبوب بارگذاری نشد.',
                  message: 'اتصال را بررسی کن و دوباره تلاش کن.',
                  action: FilledButton.icon(
                    onPressed: controller.loadPopular,
                    icon: const Icon(RhythmoIcons.arrowsClockwise),
                    label: const Text('تلاش دوباره'),
                  ),
                ),
              _ when popular.isEmpty => const RhythmoStateView(
                  icon: RhythmoIcons.globe,
                  title: 'هنوز فهرست پخش عمومی‌ای نیست',
                  message: 'وقتی فهرست پخشی را به اشتراک می‌گذاری، «عمومی» '
                      'را انتخاب کن تا اینجا نشان داده شود.',
                ),
              _ => RefreshIndicator(
                  onRefresh: controller.loadPopular,
                  child: _PopularGrid(
                    popular: popular,
                    playing: _playing,
                    isLiking: controller.isLiking,
                    onOpen: _open,
                    onPlay: _play,
                    onLike: _like,
                    onHide: controller.canModeratePopular ? _hide : null,
                    onDelete: controller.canModeratePopular ? _delete : null,
                  ),
                ),
            };
          },
        ),
      ),
    );
  }
}

/// The popular playlists as square tiles, two across on a phone and more
/// on wider screens, inside a centred column.
class _PopularGrid extends StatelessWidget {
  const _PopularGrid({
    required this.popular,
    required this.playing,
    required this.isLiking,
    required this.onOpen,
    required this.onPlay,
    required this.onLike,
    this.onHide,
    this.onDelete,
  });

  final List<PublicPlaylist> popular;

  /// The playlist whose tracks are being fetched to play, if any.
  final String? playing;
  final bool Function(String shareToken) isLiking;
  final ValueChanged<PublicPlaylist> onOpen;
  final ValueChanged<PublicPlaylist> onPlay;
  final ValueChanged<PublicPlaylist> onLike;

  /// Offered to admins only: takes a playlist out of the list, or deletes
  /// it.
  final ValueChanged<PublicPlaylist>? onHide;
  final ValueChanged<PublicPlaylist>? onDelete;

  /// Below the square cover: the title and count beside a 48 px like.
  static const _textHeight =
      RhythmoSpace.sm + RhythmoSpace.target + RhythmoSpace.xs;

  @override
  Widget build(BuildContext context) {
    // The scaffold extends the body under the mini player and reports the
    // player's height, with the system inset, as bottom padding.
    final bottom = MediaQuery.paddingOf(context).bottom + RhythmoSpace.xxl;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.clamp(0.0, RhythmoSpace.pageWidth);
      final gutter = width >= 600 ? RhythmoSpace.xxl : RhythmoSpace.lg;
      final inner = width - gutter * 2;
      final columns = (inner / 200).floor().clamp(2, 5);
      final tile = (inner - RhythmoSpace.md * (columns - 1)) / columns;
      final side = (constraints.maxWidth - width) / 2 + gutter;
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, RhythmoSpace.md, side, bottom),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: RhythmoSpace.lg,
                crossAxisSpacing: RhythmoSpace.md,
                mainAxisExtent: tile + _textHeight,
              ),
              itemCount: popular.length,
              itemBuilder: (context, index) {
                final playlist = popular[index];
                return _PopularTile(
                  playlist: playlist,
                  rank: index + 1,
                  loading: playing == playlist.shareToken,
                  onOpen: () => onOpen(playlist),
                  onPlay: () => onPlay(playlist),
                  onLike: isLiking(playlist.shareToken)
                      ? null
                      : () => onLike(playlist),
                  onHide: onHide == null ? null : () => onHide!(playlist),
                  onDelete: onDelete == null ? null : () => onDelete!(playlist),
                );
              },
            ),
          ),
        ],
      );
    });
  }
}

/// One popular playlist: a mosaic cover with its rank and a play button,
/// then its name, track count and likes. The owner is never shown.
class _PopularTile extends StatelessWidget {
  const _PopularTile({
    required this.playlist,
    required this.rank,
    required this.loading,
    required this.onOpen,
    required this.onPlay,
    required this.onLike,
    this.onHide,
    this.onDelete,
  });

  final PublicPlaylist playlist;
  final int rank;
  final bool loading;
  final VoidCallback onOpen;
  final VoidCallback onPlay;
  final VoidCallback? onLike;
  final VoidCallback? onHide;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = '${persianDigits(playlist.trackCount)} آهنگ';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: Stack(
            children: [
              Positioned.fill(
                child: Semantics(
                  button: true,
                  label: 'رتبهٔ ${persianDigits(rank)}: ${playlist.name}، '
                      '$count',
                  excludeSemantics: true,
                  child: Material(
                    clipBehavior: Clip.antiAlias,
                    shape: const RoundedRectangleBorder(
                        borderRadius: RhythmoRadii.surface),
                    child: InkWell(
                      onTap: onOpen,
                      child: _MosaicCover(
                          seed: playlist.shareToken,
                          tiles: playlist.trackCount),
                    ),
                  ),
                ),
              ),
              PositionedDirectional(
                top: RhythmoSpace.sm,
                start: RhythmoSpace.sm,
                child: _RankBadge(rank: rank),
              ),
              if (onHide != null || onDelete != null)
                PositionedDirectional(
                  top: RhythmoSpace.xs,
                  end: RhythmoSpace.xs,
                  child: PopupMenuButton<_AdminAction>(
                    tooltip: 'مدیریت ${playlist.name}',
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(RhythmoSpace.target),
                      backgroundColor: RhythmoColors.scrim,
                      foregroundColor: RhythmoColors.onSurface,
                    ),
                    icon: const Icon(RhythmoIcons.dotsThreeVertical),
                    onSelected: (action) => switch (action) {
                      _AdminAction.hide => onHide?.call(),
                      _AdminAction.delete => onDelete?.call(),
                    },
                    itemBuilder: (context) => [
                      if (onHide != null)
                        const PopupMenuItem(
                          value: _AdminAction.hide,
                          child: ListTile(
                            leading: Icon(RhythmoIcons.eyeSlash),
                            title: Text('حذف از محبوب‌ها'),
                          ),
                        ),
                      if (onDelete != null)
                        PopupMenuItem(
                          value: _AdminAction.delete,
                          child: ListTile(
                            leading:
                                Icon(RhythmoIcons.trash, color: scheme.error),
                            title: Text('پاک کردن فهرست پخش',
                                style: TextStyle(color: scheme.error)),
                          ),
                        ),
                    ],
                  ),
                ),
              PositionedDirectional(
                bottom: RhythmoSpace.sm,
                end: RhythmoSpace.sm,
                child: IconButton.filled(
                  tooltip: 'پخش ${playlist.name}',
                  onPressed:
                      loading || playlist.trackCount == 0 ? null : onPlay,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(RhythmoSpace.target),
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  ),
                  icon: loading
                      ? SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: scheme.onPrimary),
                        )
                      : const Icon(RhythmoIcons.playFill),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: RhythmoSpace.sm),
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onOpen,
                borderRadius: RhythmoRadii.control,
                child: Padding(
                  padding:
                      const EdgeInsetsDirectional.only(start: RhythmoSpace.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        playlist.isOwner ? 'فهرست پخش خودت · $count' : count,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            PlaylistLikeButton(
              likes: playlist.likes,
              onPressed: onLike,
              compact: true,
            ),
          ],
        ),
      ],
    );
  }
}

enum _AdminAction { hide, delete }

/// The playlist's place in the list, on its cover.
class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = rank <= 3;
    return Container(
      constraints: const BoxConstraints(minWidth: 32),
      padding: const EdgeInsets.symmetric(
          horizontal: RhythmoSpace.sm, vertical: RhythmoSpace.xxs),
      decoration: BoxDecoration(
        color: top ? theme.colorScheme.primary : RhythmoColors.scrim,
        borderRadius: BorderRadius.circular(RhythmoRadii.pill),
      ),
      child: Text(
        persianDigits(rank),
        textAlign: TextAlign.center,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
          color: top ? theme.colorScheme.onPrimary : RhythmoColors.onSurface,
        ),
      ),
    );
  }
}

/// A cover made of up to four tinted squares, one per track, seeded by the
/// playlist so it keeps its look. The API lists no artwork for popular
/// playlists yet, so the tints stand in for it.
class _MosaicCover extends StatelessWidget {
  const _MosaicCover({required this.seed, required this.tiles});

  final String seed;
  final int tiles;

  @override
  Widget build(BuildContext context) {
    Widget square(int i) => ColoredBox(
          color: artworkTint('$seed-$i'),
          child: Center(
            child: Icon(RhythmoIcons.musicNotes,
                color: RhythmoColors.onSurface.withValues(alpha: 0.32)),
          ),
        );
    final count = tiles.clamp(1, 4);
    if (count < 4) {
      // Fewer than four tracks: one tint, so the cover never looks broken.
      return square(0);
    }
    return Column(
      children: [
        for (final row in const [0, 2])
          Expanded(
            child: Row(
              children: [
                for (final column in const [0, 1])
                  Expanded(child: square(row + column)),
              ],
            ),
          ),
      ],
    );
  }
}
