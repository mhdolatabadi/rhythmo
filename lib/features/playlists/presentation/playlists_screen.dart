import 'package:rhythmo/core/search_text.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/collab_sheet.dart';
import 'package:rhythmo/features/playlists/presentation/shared_playlist_screen.dart';
import 'package:rhythmo/features/likes/presentation/liked_songs_screen.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/data/store_catalog.dart';
import 'package:rhythmo/features/store/presentation/store_carousel.dart';

/// Joins the collaborative playlist with [collabToken] and opens it, or
/// says why it couldn't.
Future<void> joinCollabPlaylist(
  BuildContext context, {
  required String collabToken,
  required PlaylistsController controller,
  required List<Track> libraryTracks,
  required PlayerController player,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  try {
    final playlist = await controller.join(collabToken);
    messenger.showSnackBar(SnackBar(
        content: Text(playlist.isOwner
            ? 'این فهرست پخش خودت است.'
            : 'به «${playlist.name}» پیوستی؛ حالا می‌توانی آهنگ‌هایت را اضافه کنی.')));
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => PlaylistDetailScreen(
        playlistId: playlist.id,
        controller: controller,
        libraryTracks: libraryTracks,
        player: player,
      ),
    ));
  } on SharedPlaylistUnavailable {
    messenger.showSnackBar(
        const SnackBar(content: Text('این لینک دعوت اشتباه است یا باطل شده.')));
  } catch (_) {
    messenger.showSnackBar(
        const SnackBar(content: Text('پیوستن ناموفق بود. دوباره تلاش کن.')));
  }
}

/// The playlists overview on its own screen.
class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({
    super.key,
    required this.controller,
    required this.libraryTracks,
    required this.player,
  });

  final PlaylistsController controller;
  final List<Track> libraryTracks;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('فهرست‌های پخش')),
      body: PlaylistsView(
        controller: controller,
        libraryTracks: libraryTracks,
        player: player,
      ),
    );
  }
}

/// The user's playlists with actions to make one and open a share link.
/// It is the «فهرست‌های پخش» tab of the library.
class PlaylistsView extends StatefulWidget {
  const PlaylistsView({
    super.key,
    required this.controller,
    required this.libraryTracks,
    required this.player,
    this.onSharedSaved,
    this.underHeader = false,
    this.store,
  });

  final PlaylistsController controller;
  final List<Track> libraryTracks;
  final PlayerController player;

  /// The public store; null hides its carousels.
  final StoreController? store;

  /// Called after a shared playlist was saved, bringing its tracks along.
  final VoidCallback? onSharedSaved;

  /// Whether this is a tab under a pinned NestedScrollView header, whose
  /// overlap the list has to make room for.
  final bool underHeader;

  @override
  State<PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<PlaylistsView> {
  @override
  void initState() {
    super.initState();
    widget.controller.load();
  }

  Future<void> _create() async {
    final name = await _askName(context, 'فهرست پخش جدید');
    if (name == null) return;
    final playlist = await widget.controller.create(name);
    if (!mounted) return;
    if (playlist == null) {
      _message('ساخت فهرست پخش ناموفق بود.');
      return;
    }
    _open(playlist);
  }

  Future<void> _open(Playlist playlist) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlaylistDetailScreen(
        playlistId: playlist.id,
        controller: widget.controller,
        libraryTracks: widget.libraryTracks,
        player: widget.player,
      ),
    ));
    widget.controller.load();
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Opens a playlist someone shared, from a pasted link.
  Future<void> _openLink() async {
    final field = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('باز کردن لینک اشتراک'),
        content: TextField(
          controller: field,
          autofocus: true,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
              hintText: 'لینک فهرست پخش یا دعوت را اینجا بچسبان'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('باز کن'),
          ),
        ],
      ),
    );
    field.dispose();
    if (input == null || !mounted) return;
    final collabToken = collabTokenFrom(input);
    if (collabToken != null) {
      await joinCollabPlaylist(context,
          collabToken: collabToken,
          controller: widget.controller,
          libraryTracks: widget.libraryTracks,
          player: widget.player);
      return;
    }
    final token = shareTokenFrom(input);
    if (token == null) {
      _message('این لینک فهرست پخش ریتمو نیست.');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SharedPlaylistScreen(
        shareToken: token,
        controller: widget.controller,
        player: widget.player,
        onSaved: widget.onSharedSaved,
      ),
    ));
  }

  void _openLiked() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LikedSongsScreen(
          player: widget.player, libraryTracks: widget.libraryTracks),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final actions = Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LikedSongsEntry(
            favorites: widget.player.favorites,
            libraryTracks: widget.libraryTracks,
            onOpen: _openLiked,
          ),
          if (widget.store case final store?)
            for (final ranking in StoreRanking.values.reversed)
              StoreCarousel(
                controller: store,
                ranking: ranking,
                player: widget.player,
                padding: EdgeInsets.zero,
              ),
          const SizedBox(height: RhythmoSpace.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: _create,
                icon: const Icon(RhythmoIcons.listPlus),
                label: const Text('فهرست پخش جدید'),
              ),
              IconButton(
                tooltip: 'باز کردن لینک اشتراک',
                onPressed: _openLink,
                icon: const Icon(RhythmoIcons.link),
              ),
            ],
          ),
        ],
      ),
    );
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final content = switch (widget.controller.status) {
          PlaylistsStatus.loading => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
          PlaylistsStatus.error => SliverFillRemaining(
              hasScrollBody: false,
              child: _Retry(
                onRetry: () async {
                  await widget.controller.load();
                },
              ),
            ),
          PlaylistsStatus.loaded => widget.controller.playlists.isEmpty
              ? SliverFillRemaining(
                  hasScrollBody: false,
                  child: _PlaylistEmptyState(
                    message: 'هنوز فهرست پخشی نساخته‌ای.',
                    action: 'ساخت اولین فهرست پخش',
                    onPressed: _create,
                  ),
                )
              : _PlaylistsOverview(
                  playlists: widget.controller.playlists,
                  onOpen: _open,
                ),
        };
        return RefreshIndicator(
          onRefresh: () async {
            await widget.controller.load();
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Centered at most 900 px wide on large screens.
              final side = ((constraints.maxWidth - 900) / 2)
                  .clamp(0.0, double.infinity);
              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  if (widget.underHeader)
                    SliverOverlapInjector(
                      handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                          context),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: side),
                    sliver: SliverMainAxisGroup(
                      slivers: [SliverToBoxAdapter(child: actions), content],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// The way into the popular playlists: an orange flame in the app bar.
class PopularPlaylistsButton extends StatelessWidget {
  const PopularPlaylistsButton({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'فهرست‌های پخش محبوب',
      onPressed: onOpen,
      icon: const Icon(RhythmoIcons.fire, color: RhythmoColors.fire),
    );
  }
}

class _PlaylistsOverview extends StatelessWidget {
  const _PlaylistsOverview({
    required this.playlists,
    required this.onOpen,
  });

  final List<Playlist> playlists;
  final void Function(Playlist playlist) onOpen;

  @override
  Widget build(BuildContext context) {
    final featured = playlists.take(3).toList(growable: false);
    return SliverPadding(
      // Room at the bottom for the mini player.
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 112),
      sliver: SliverList.list(
        children: [
          if (featured.isNotEmpty) ...[
            SizedBox(
              // The 148 px cover plus a title and a count line.
              height: 208,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: featured.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (context, index) {
                  final playlist = featured[index];
                  return _PlaylistFeatureCard(
                    playlist: playlist,
                    onTap: () => onOpen(playlist),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
          ],
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
            child: Text(
              'همهٔ فهرست‌های پخش',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          for (final playlist in playlists)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: _PlaylistCover(
                  trackCount: playlist.displayTrackCount, size: 56),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (playlist.shareToken != null)
                    const Padding(
                      padding: EdgeInsetsDirectional.only(start: 6),
                      child: Tooltip(
                        message: 'با لینک به اشتراک گذاشته شده',
                        child: Icon(RhythmoIcons.linkSimple, size: 16),
                      ),
                    ),
                ],
              ),
              subtitle: Text(
                  '${persianDigits(playlist.displayTrackCount)} قطعه موسیقی'),
              trailing: const Icon(RhythmoIcons.caretLeft),
              onTap: () => onOpen(playlist),
            ),
        ],
      ),
    );
  }
}

class _PlaylistFeatureCard extends StatelessWidget {
  const _PlaylistFeatureCard({
    required this.playlist,
    required this.onTap,
  });

  final Playlist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 148,
      child: InkWell(
        borderRadius: BorderRadius.circular(RhythmoRadii.xl),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PlaylistCover(trackCount: playlist.displayTrackCount, size: 148),
            const SizedBox(height: 10),
            Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            Text(
              '${persianDigits(playlist.displayTrackCount)} قطعه موسیقی',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlaylistDetailScreen extends StatefulWidget {
  const PlaylistDetailScreen({
    super.key,
    required this.playlistId,
    required this.controller,
    required this.libraryTracks,
    required this.player,
  });

  final String playlistId;
  final PlaylistsController controller;
  final List<Track> libraryTracks;
  final PlayerController player;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  Playlist? playlist;
  bool loading = true;

  /// A change is on its way to the server; the page stays in place.
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await widget.controller.loadPlaylist(widget.playlistId);
    if (!mounted) return;
    setState(() {
      playlist = loaded;
      loading = false;
    });
  }

  /// Picks which of the user's own tracks are in the playlist. Tracks
  /// other members added aren't in the user's library, so they stay as they
  /// are; picked tracks keep their place, and new ones go at the end.
  Future<void> _selectTracks() async {
    final current = playlist;
    if (current == null) return;
    final own = widget.libraryTracks.map((track) => track.id).toSet();
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _TrackPicker(
        tracks: widget.libraryTracks,
        selected: {
          for (final track in current.tracks)
            if (own.contains(track.id)) track.id
        },
      ),
    );
    if (selected == null) return;
    final kept = [
      for (final track in current.tracks)
        if (!own.contains(track.id) || selected.contains(track.id)) track.id
    ];
    await _save([
      ...kept,
      for (final id in selected)
        if (!kept.contains(id)) id
    ]);
  }

  Future<void> _removeTrack(Track track) async {
    final current = playlist;
    if (current == null) return;
    await _save([
      for (final item in current.tracks)
        if (item.id != track.id) item.id
    ]);
  }

  Future<void> _collab() async {
    final current = playlist;
    if (current == null) return;
    await showCollabSheet(context,
        playlist: current, controller: widget.controller);
    if (mounted) await _load();
  }

  Future<void> _leave() async {
    final current = playlist;
    if (current == null) return;
    final confirmed = await showRhythmoConfirm(
      context,
      title: 'ترک فهرست پخش؟',
      message:
          'آهنگ‌هایی که به این فهرست پخش اضافه کرده‌ای از آن بیرون می‌روند؛ در کتابخانه‌ات می‌مانند.',
      confirmLabel: 'ترک',
      destructive: true,
    );
    if (!confirmed) return;
    final left = await widget.controller.leave(current.id);
    if (!mounted) return;
    if (left) {
      Navigator.pop(context);
    } else {
      _message('ترک فهرست پخش ناموفق بود.');
    }
  }

  Future<void> _save(List<String> ids) async {
    setState(() => saving = true);
    final saved = await widget.controller.replaceTracks(widget.playlistId, ids);
    if (!mounted) return;
    setState(() {
      playlist = saved ?? playlist;
      saving = false;
    });
    if (saved == null) {
      _message('ذخیرهٔ فهرست پخش ناموفق بود.');
      // Show what the server has, not the change it refused.
      await _load();
    }
  }

  Future<void> _share() async {
    final current = playlist;
    if (current == null) return;
    await showShareSheet(context,
        playlist: current, controller: widget.controller);
    if (mounted) await _load();
  }

  Future<void> _rename() async {
    final current = playlist;
    if (current == null) return;
    final name = await _askName(
      context,
      'تغییر نام فهرست پخش',
      initialValue: current.name,
    );
    if (name == null) return;
    if (await widget.controller.rename(current.id, name)) {
      await _load();
    } else {
      _message('تغییر نام ناموفق بود.');
    }
  }

  Future<void> _delete() async {
    final current = playlist;
    if (current == null) return;
    final confirmed = await showRhythmoConfirm(
      context,
      title: 'حذف فهرست پخش؟',
      message: 'آهنگ‌های کتابخانه حذف نمی‌شوند.',
      confirmLabel: 'حذف',
      destructive: true,
    );
    if (!confirmed) return;
    final deleted = await widget.controller.delete(current.id);
    if (!mounted) return;
    if (deleted) {
      Navigator.pop(context);
    } else {
      _message('حذف فهرست پخش ناموفق بود.');
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final current = playlist;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: RhythmoColors.transparent,
        bottom: saving
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
        actions: [
          if (current != null)
            PopupMenuButton<_PlaylistAction>(
              tooltip: 'گزینه‌های فهرست پخش',
              icon: const Icon(RhythmoIcons.dotsThreeVertical),
              onSelected: (action) => switch (action) {
                _PlaylistAction.rename => _rename(),
                _PlaylistAction.delete => _delete(),
                _PlaylistAction.leave => _leave(),
              },
              itemBuilder: (context) {
                final danger = Theme.of(context).colorScheme.error;
                // A member adds and removes their own tracks; the rest is
                // the owner's.
                return current.isOwner
                    ? [
                        const PopupMenuItem(
                          value: _PlaylistAction.rename,
                          child: _MenuRow(
                            icon: RhythmoIcons.pencilSimple,
                            label: 'تغییر نام',
                          ),
                        ),
                        PopupMenuItem(
                          value: _PlaylistAction.delete,
                          child: _MenuRow(
                            icon: RhythmoIcons.trash,
                            label: 'حذف فهرست پخش',
                            color: danger,
                          ),
                        ),
                      ]
                    : [
                        PopupMenuItem(
                          value: _PlaylistAction.leave,
                          child: _MenuRow(
                            icon: RhythmoIcons.signOut,
                            label: 'ترک فهرست پخش',
                            color: danger,
                          ),
                        ),
                      ];
              },
            ),
          const SizedBox(width: RhythmoSpace.sm),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: RhythmoBackdrop(
        child: loading
            ? const RhythmoStateView.loading(
                title: 'در حال بارگذاری فهرست پخش…')
            : current == null
                ? _Retry(onRetry: _load)
                : ListenableBuilder(
                    listenable: widget.player,
                    builder: (context, _) => _PlaylistBody(
                      playlist: current,
                      playingId: widget.player.track?.id,
                      saving: saving,
                      onPlay: () => widget.player.playFrom(current.tracks, 0),
                      onShuffle: () =>
                          widget.player.playShuffled(current.tracks),
                      onCollab: current.isOwner ? _collab : null,
                      onShare: current.isOwner ? _share : null,
                      onSelectTracks: _selectTracks,
                      onTapTrack: (index) =>
                          widget.player.playTapped(current.tracks, index),
                      onRemoveTrack: _removeTrack,
                      onReorder: _reorder,
                    ),
                  ),
      ),
    );
  }

  void _reorder(int oldIndex, int newIndex) {
    final current = playlist;
    if (current == null) return;
    final tracks = List<Track>.from(current.tracks);
    tracks.insert(newIndex, tracks.removeAt(oldIndex));
    setState(() => playlist = current.withTracks(tracks));
    _save(tracks.map((track) => track.id).toList());
  }
}

enum _PlaylistAction { rename, delete, leave }

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: RhythmoSpace.md),
          Text(label, style: TextStyle(color: color)),
        ],
      );
}

/// The playlist page: a hero with the cover and the play controls, then the
/// tracks under a heading that holds the add action. Everything sits in one
/// centred column so nothing touches the window edges, and nothing floats
/// over the list.
class _PlaylistBody extends StatelessWidget {
  const _PlaylistBody({
    required this.playlist,
    required this.playingId,
    required this.saving,
    required this.onPlay,
    required this.onShuffle,
    required this.onCollab,
    required this.onShare,
    required this.onSelectTracks,
    required this.onTapTrack,
    required this.onRemoveTrack,
    required this.onReorder,
  });

  final Playlist playlist;
  final String? playingId;
  final bool saving;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final VoidCallback? onCollab;
  final VoidCallback? onShare;
  final VoidCallback onSelectTracks;
  final void Function(int index) onTapTrack;
  final void Function(Track track) onRemoveTrack;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    final tracks = playlist.tracks;
    return LayoutBuilder(builder: (context, constraints) {
      final gutter = constraints.maxWidth > RhythmoSpace.pageWidth + 48
          ? (constraints.maxWidth - RhythmoSpace.pageWidth) / 2
          : RhythmoSpace.lg;
      final side = EdgeInsets.symmetric(horizontal: gutter);
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: side.add(EdgeInsets.only(
                top: MediaQuery.paddingOf(context).top + kToolbarHeight)),
            sliver: SliverToBoxAdapter(
              child: _PlaylistDetailHeader(
                playlist: playlist,
                onPlay: onPlay,
                onShuffle: onShuffle,
                onCollab: onCollab,
                onShare: onShare,
              ),
            ),
          ),
          SliverPadding(
            padding: side,
            sliver: SliverToBoxAdapter(
              child: RhythmoSectionHeader(
                title: 'آهنگ‌ها',
                padding: const EdgeInsetsDirectional.fromSTEB(RhythmoSpace.sm,
                    RhythmoSpace.xxl, RhythmoSpace.xs, RhythmoSpace.sm),
                trailing: FilledButton.tonalIcon(
                  onPressed: saving ? null : onSelectTracks,
                  icon: const Icon(RhythmoIcons.plus, size: 20),
                  label: const Text('مدیریت آهنگ‌ها'),
                ),
              ),
            ),
          ),
          if (tracks.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _PlaylistEmptyState(
                message: 'برای این فهرست پخش آهنگ انتخاب کن.',
                action: 'انتخاب از کتابخانه',
                onPressed: onSelectTracks,
              ),
            )
          else
            SliverPadding(
              padding: side.add(
                  rhythmoListBottomPadding(context, extra: RhythmoSpace.xxxl)),
              sliver: SliverReorderableList(
                itemCount: tracks.length,
                onReorderItem: onReorder,
                proxyDecorator: (child, index, animation) => Material(
                  color: RhythmoColors.surfaceRaised,
                  elevation: 8,
                  shadowColor: RhythmoColors.shadow,
                  borderRadius: RhythmoRadii.control,
                  child: child,
                ),
                itemBuilder: (context, index) {
                  final track = tracks[index];
                  return _PlaylistTrackRow(
                    key: ValueKey(track.id),
                    index: index,
                    track: track,
                    playing: track.id == playingId,
                    onTap: () => onTapTrack(index),
                    onRemove: playlist.canRemove(track) && !saving
                        ? () => onRemoveTrack(track)
                        : null,
                    canRemove: playlist.canRemove(track),
                  );
                },
              ),
            ),
        ],
      );
    });
  }
}

class _PlaylistDetailHeader extends StatelessWidget {
  const _PlaylistDetailHeader({
    required this.playlist,
    required this.onPlay,
    required this.onShuffle,
    required this.onCollab,
    required this.onShare,
  });

  final Playlist playlist;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  /// Owner-only: null hides the control.
  final VoidCallback? onCollab;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final empty = playlist.tracks.isEmpty;
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 600;
      final align = wide ? CrossAxisAlignment.start : CrossAxisAlignment.center;
      final textAlign = wide ? TextAlign.start : TextAlign.center;
      final eyebrow =
          playlist.isCollaborative ? 'فهرست پخش مشترک' : 'فهرست پخش';
      final details = Column(
        crossAxisAlignment: align,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            eyebrow,
            style: theme.textTheme.labelLarge?.copyWith(color: colors.primary),
          ),
          const SizedBox(height: RhythmoSpace.xs),
          Text(
            playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign,
            style: (wide
                    ? theme.textTheme.displaySmall
                    : theme.textTheme.headlineMedium)
                ?.copyWith(fontWeight: FontWeight.w800, height: 1.3),
          ),
          const SizedBox(height: RhythmoSpace.sm),
          Text(
            [
              '${persianDigits(playlist.displayTrackCount)} قطعه موسیقی',
              if (!playlist.isOwner && playlist.owner != null)
                'از ${playlist.owner}'
              else if (playlist.members.isNotEmpty)
                'مشترک با ${persianDigits(playlist.members.length)} نفر',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: RhythmoSpace.xl),
          Wrap(
            alignment: wide ? WrapAlignment.start : WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: RhythmoSpace.sm,
            runSpacing: RhythmoSpace.sm,
            children: [
              FilledButton.icon(
                onPressed: empty ? null : onPlay,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(112, RhythmoSpace.target),
                ),
                icon: const Icon(RhythmoIcons.playFill, size: 20),
                label: const Text('پخش'),
              ),
              IconButton.filledTonal(
                tooltip: 'پخش تصادفی',
                onPressed: empty ? null : onShuffle,
                icon: const Icon(RhythmoIcons.shuffle),
              ),
              if (onCollab != null)
                IconButton.outlined(
                  tooltip: 'دعوت دوستان و مدیریت اعضا',
                  onPressed: onCollab,
                  icon: Icon(playlist.collabToken == null
                      ? RhythmoIcons.userPlus
                      : RhythmoIcons.users),
                ),
              if (onShare != null)
                IconButton.outlined(
                  tooltip: 'اشتراک‌گذاری',
                  onPressed: onShare,
                  icon: Icon(playlist.shareToken == null
                      ? RhythmoIcons.shareNetwork
                      : RhythmoIcons.link),
                ),
            ],
          ),
        ],
      );
      final cover = _PlaylistCover(
        trackCount: playlist.displayTrackCount,
        size: wide ? 184 : 152,
        showCount: false,
      );
      return Container(
        padding: EdgeInsets.all(wide ? RhythmoSpace.xxl : RhythmoSpace.xl),
        decoration: BoxDecoration(
          borderRadius: RhythmoRadii.panel,
          border: Border.all(color: RhythmoColors.softBorder),
          gradient: LinearGradient(
            begin: AlignmentDirectional.topStart
                .resolve(Directionality.of(context)),
            end: AlignmentDirectional.bottomEnd
                .resolve(Directionality.of(context)),
            colors: [
              colors.primary.withValues(alpha: 0.16),
              colors.secondary.withValues(alpha: 0.08),
              colors.surface.withValues(alpha: 0.35),
            ],
            stops: const [0, 0.5, 1],
          ),
        ),
        child: wide
            ? Row(
                children: [
                  cover,
                  const SizedBox(width: RhythmoSpace.xxl),
                  Expanded(child: details),
                ],
              )
            : Column(
                children: [
                  cover,
                  const SizedBox(height: RhythmoSpace.xl),
                  details,
                ],
              ),
      );
    });
  }
}

class _PlaylistCover extends StatelessWidget {
  const _PlaylistCover({
    required this.trackCount,
    required this.size,
    this.showCount = true,
  });

  final int trackCount;
  final double size;

  /// Off where the count is written beside the cover.
  final bool showCount;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size > 100 ? 24 : 18),
        gradient: const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [RhythmoColors.primary, RhythmoColors.secondaryDeep],
        ),
        boxShadow: [
          BoxShadow(
            color: RhythmoColors.primary.withValues(alpha: 0.2),
            offset: const Offset(0, 10),
            blurRadius: 24,
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            trackCount == 0 ? RhythmoIcons.playlist : RhythmoIcons.musicNotes,
            size: size * 0.36,
            color: RhythmoColors.onBrand,
          ),
          if (showCount)
            PositionedDirectional(
              end: 10,
              bottom: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: 0.66),
                  borderRadius: BorderRadius.circular(RhythmoRadii.pill),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  child: Text(
                    persianDigits(trackCount),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One track on the playlist page: its number, artwork, title and artist,
/// then a quiet remove button and the handle that drags it to a new place.
class _PlaylistTrackRow extends StatelessWidget {
  const _PlaylistTrackRow({
    super.key,
    required this.index,
    required this.track,
    required this.playing,
    required this.onTap,
    required this.onRemove,
    required this.canRemove,
  });

  final int index;
  final Track track;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final bool canRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final artist = track.artist?.trim().isNotEmpty == true
        ? track.artist!
        : 'خواننده نامشخص';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RhythmoSpace.xxs),
      child: Material(
        color: playing
            ? colors.primaryContainer.withValues(alpha: 0.45)
            : RhythmoColors.transparent,
        borderRadius: RhythmoRadii.control,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(RhythmoSpace.sm,
                  RhythmoSpace.sm, RhythmoSpace.xs, RhythmoSpace.sm),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      persianDigits(index + 1),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color:
                            playing ? colors.primary : colors.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: RhythmoSpace.sm),
                  RhythmoArtworkTile(seed: track.id, active: playing),
                  const SizedBox(width: RhythmoSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: playing ? colors.primary : null,
                          ),
                        ),
                        Text(
                          [
                            artist,
                            if (track.addedBy case final who?) 'افزوده‌ی $who',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (canRemove)
                    IconButton(
                      tooltip: 'حذف از فهرست پخش',
                      onPressed: onRemove,
                      color: colors.onSurfaceVariant,
                      icon: const Icon(RhythmoIcons.x, size: 20),
                    ),
                  ReorderableDragStartListener(
                    index: index,
                    child: Tooltip(
                      message: 'برای جابه‌جایی بکش',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: SizedBox.square(
                          dimension: RhythmoSpace.target,
                          child: Icon(
                            RhythmoIcons.dotsSixVertical,
                            size: 22,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackPicker extends StatefulWidget {
  const _TrackPicker({required this.tracks, required this.selected});

  final List<Track> tracks;
  final Set<String> selected;

  @override
  State<_TrackPicker> createState() => _TrackPickerState();
}

class _TrackPickerState extends State<_TrackPicker> {
  late final Set<String> selected = {...widget.selected};
  String query = '';

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks
        .where((track) => matchesSearch(query, [track.title, track.artist]))
        .toList();
    return AlertDialog(
      title: const Text('انتخاب آهنگ‌های فهرست پخش'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              decoration: const InputDecoration(
                labelText: 'جست‌وجوی عنوان یا هنرمند',
                prefixIcon: Icon(RhythmoIcons.magnifyingGlass),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text('${persianDigits(selected.length)} آهنگ انتخاب شده'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: widget.tracks.isEmpty
                  ? const Center(child: Text('کتابخانه خالی است.'))
                  : tracks.isEmpty
                      ? const Center(
                          child: Text('آهنگی با این جست‌وجو پیدا نشد.'))
                      : ListView.builder(
                          itemCount: tracks.length,
                          itemBuilder: (context, index) {
                            final track = tracks[index];
                            return CheckboxListTile(
                              value: selected.contains(track.id),
                              title: Text(track.title,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: track.artist?.trim().isNotEmpty == true
                                  ? Text(track.artist!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)
                                  : null,
                              onChanged: (checked) {
                                setState(() {
                                  if (checked ?? false) {
                                    selected.add(track.id);
                                  } else {
                                    selected.remove(track.id);
                                  }
                                });
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('انصراف'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, selected),
          child: const Text('ذخیره'),
        ),
      ],
    );
  }
}

Future<String?> _askName(
  BuildContext context,
  String title, {
  String initialValue = '',
}) async {
  final controller = TextEditingController(text: initialValue);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 200,
        decoration: const InputDecoration(labelText: 'نام'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('انصراف'),
        ),
        FilledButton(
          onPressed: () {
            final name = controller.text.trim();
            if (name.isNotEmpty) Navigator.pop(context, name);
          },
          child: const Text('ذخیره'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

class _Retry extends StatelessWidget {
  const _Retry({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(RhythmoIcons.arrowsClockwise),
          label: const Text('تلاش دوباره'),
        ),
      );
}

/// A consistent, actionable first step for empty playlists.
class _PlaylistEmptyState extends StatelessWidget {
  const _PlaylistEmptyState({
    required this.message,
    required this.action,
    required this.onPressed,
  });

  final String message;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => RhythmoStateView(
        icon: RhythmoIcons.playlist,
        title: message,
        action: FilledButton.icon(
          onPressed: onPressed,
          icon: const Icon(RhythmoIcons.plus),
          label: Text(action),
        ),
      );
}
