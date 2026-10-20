import 'package:rhythmo/core/persian_digits.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/app/app_configuration.dart';
import 'package:rhythmo/features/auth/presentation/sign_in_prompt.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';

/// A playlist someone shared by link: its tracks can be played, not changed.
class SharedPlaylistScreen extends StatefulWidget {
  const SharedPlaylistScreen({
    super.key,
    required this.shareToken,
    required this.controller,
    required this.player,
    this.onSaved,
    this.onSignIn,
  });

  final String shareToken;
  final PlaylistsController controller;
  final PlayerController player;

  /// Called after the playlist was saved to the account, for example to
  /// reload the library the copied tracks now belong to.
  final VoidCallback? onSaved;

  /// Opens sign-in, for a guest who tries to like or save.
  final VoidCallback? onSignIn;

  @override
  State<SharedPlaylistScreen> createState() => _SharedPlaylistScreenState();
}

enum _Load { loading, loaded, unavailable, failed }

class _SharedPlaylistScreenState extends State<SharedPlaylistScreen> {
  _Load _state = _Load.loading;
  SharedPlaylist? _playlist;
  bool _saving = false;

  Future<void> _save() async {
    if (!widget.controller.signedIn) {
      askToSignIn(context,
          action: 'افزودن به کتابخانه', onSignIn: widget.onSignIn);
      return;
    }
    setState(() => _saving = true);
    final result = await widget.controller.saveShared(widget.shareToken);
    if (!mounted) return;
    setState(() => _saving = false);
    if (result == SaveSharedResult.saved) widget.onSaved?.call();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(switch (result) {
        SaveSharedResult.saved =>
          'به فهرست‌های پخش و کتابخانه‌ات اضافه شد. این نسخه مال خودت است.',
        SaveSharedResult.alreadyYours => 'این فهرست پخش خودت است.',
        SaveSharedResult.noSpace =>
          'فضای کافی در حسابت نیست. چند آهنگ را حذف کن و دوباره امتحان کن.',
        SaveSharedResult.uploadsDisabled =>
          'افزودن آهنگ فعلاً غیرفعال است. کمی بعد دوباره امتحان کن.',
        SaveSharedResult.gone => 'این فهرست پخش دیگر به اشتراک گذاشته نمی‌شود.',
        SaveSharedResult.failed => 'افزودن ناموفق بود. دوباره تلاش کن.',
      }),
    ));
  }

  Future<void> _like() async {
    if (!widget.controller.signedIn) {
      askToSignIn(context, action: 'پسندیدن', onSignIn: widget.onSignIn);
      return;
    }
    final playlist = _playlist;
    if (playlist == null) return;
    final result = await widget.controller.setLike(
      widget.shareToken,
      playlist.likes,
      onChange: (likes) {
        if (mounted) setState(() => _playlist = _playlist?.withLikes(likes));
      },
    );
    if (!mounted || result == LikeResult.done) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result == LikeResult.gone
          ? 'این فهرست پخش دیگر به اشتراک گذاشته نمی‌شود.'
          : 'پسندیدن ثبت نشد. دوباره تلاش کن.'),
    ));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = _Load.loading);
    try {
      final playlist = await widget.controller.openShared(widget.shareToken);
      if (!mounted) return;
      setState(() {
        _playlist = playlist;
        _state = _Load.loaded;
      });
    } on SharedPlaylistUnavailable {
      if (mounted) setState(() => _state = _Load.unavailable);
    } catch (_) {
      if (mounted) setState(() => _state = _Load.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _playlist;
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        title: Text(
          playlist?.name ?? 'فهرست پخش اشتراکی',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      bottomNavigationBar: MiniPlayer(player: widget.player),
      body: RhythmoBackdrop(
        child: switch (_state) {
          _Load.loading =>
            const RhythmoStateView.loading(title: 'در حال بارگذاری فهرست پخش…'),
          _Load.unavailable => const _Message(
              icon: RhythmoIcons.linkBreak,
              text:
                  'این لینک اشتباه است یا صاحبش اشتراک‌گذاری را لغو کرده است.',
            ),
          _Load.failed => _Message(
              icon: RhythmoIcons.cloudSlash,
              text: 'بارگذاری فهرست پخش ناموفق بود.',
              action: FilledButton.icon(
                onPressed: _load,
                icon: const Icon(RhythmoIcons.arrowsClockwise),
                label: const Text('تلاش دوباره'),
              ),
            ),
          _Load.loaded => ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => _Contents(
                playlist: playlist!,
                player: widget.player,
                saving: _saving,
                onSave: playlist.isOwner ? null : _save,
                onLike: widget.controller.isLiking(widget.shareToken)
                    ? null
                    : _like,
              ),
            ),
        },
      ),
    );
  }
}

class _Contents extends StatelessWidget {
  const _Contents({
    required this.playlist,
    required this.player,
    required this.saving,
    this.onSave,
    this.onLike,
  });

  final SharedPlaylist playlist;
  final PlayerController player;
  final bool saving;

  /// Likes or unlikes it; null while a like is on its way.
  final VoidCallback? onLike;

  /// Saves a copy to the account; null for the owner's own playlist.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final tracks = playlist.tracks;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassSurface(
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              padding: const EdgeInsets.all(16),
              radius: 24,
              tint: Theme.of(context).colorScheme.primary,
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      borderRadius: RhythmoRadii.surface,
                      gradient: LinearGradient(
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                        colors: [
                          Theme.of(context).colorScheme.primary,
                          Theme.of(context).colorScheme.secondary,
                        ],
                      ),
                    ),
                    child: const Icon(RhythmoIcons.playlist),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          playlist.isOwner
                              ? 'فهرست پخش خودت، که با لینک به اشتراک گذاشته‌ای'
                              : 'اشتراک‌گذاری‌شده توسط ${playlist.owner}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            '${persianDigits(tracks.length)} آهنگ',
                            if (playlist.isOwner)
                              playlist.isPublic ? 'عمومی' : 'فقط با لینک',
                          ].join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (tracks.isNotEmpty)
                    FilledButton.icon(
                      onPressed: () => player.playFrom(tracks, 0),
                      icon: const Icon(RhythmoIcons.playFill),
                      label: const Text('پخش همه'),
                    ),
                  PlaylistLikeButton(likes: playlist.likes, onPressed: onLike),
                  if (onSave != null && tracks.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: saving ? null : onSave,
                      icon: saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(RhythmoIcons.plusCircle),
                      label: const Text('افزودن به حساب من'),
                    ),
                ],
              ),
            ),
            if (tracks.isEmpty)
              const Expanded(
                child: _Message(
                  icon: RhythmoIcons.musicNotesMinus,
                  text: 'این فهرست پخش فعلاً آهنگی ندارد.',
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                  itemCount: tracks.length,
                  itemBuilder: (context, index) {
                    final track = tracks[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: GlassSurface(
                        blur: 0,
                        shadow: false,
                        radius: 18,
                        tint: Theme.of(context).colorScheme.secondary,
                        child: ListTile(
                          leading: const Icon(RhythmoIcons.musicNote),
                          title: Text(track.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: track.artist == null
                              ? null
                              : Text(track.artist!,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => player.playTapped(tracks, index),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Likes or unlikes a shared playlist. The heart is filled when liked and
/// the words say so too, so the state never rests on color alone.
class PlaylistLikeButton extends StatelessWidget {
  const PlaylistLikeButton({
    super.key,
    required this.likes,
    required this.onPressed,
    this.compact = false,
  });

  final PlaylistLikes likes;

  /// Null while a like is on its way.
  final VoidCallback? onPressed;

  /// Shows only the heart and the count, for a row in a list.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final liked = likes.liked;
    final count = likes.likeCount;
    final color = liked ? Theme.of(context).colorScheme.primary : null;
    final icon =
        Icon(liked ? RhythmoIcons.heartFill : RhythmoIcons.heart, color: color);
    final tooltip = liked ? 'برداشتن پسند' : 'پسندیدن این فهرست پخش';
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: liked
            ? 'پسندیده‌ای، ${persianDigits(count)} پسند'
            : 'نپسندیده‌ای، ${persianDigits(count)} پسند',
        toggled: liked,
        excludeSemantics: true,
        button: true,
        enabled: onPressed != null,
        onTap: onPressed,
        child: compact
            ? TextButton.icon(
                onPressed: onPressed,
                icon: icon,
                label: Text(persianDigits(count)),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              )
            : OutlinedButton.icon(
                onPressed: onPressed,
                icon: icon,
                label: Text(liked
                    ? 'پسندیدی · ${persianDigits(count)}'
                    : 'پسندیدن · ${persianDigits(count)}'),
              ),
      ),
    );
  }
}

/// A state of the shared playlist with nothing to list, drawn as the
/// shared [RhythmoStateView]; a failure to load is an error.
class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => action != null
      ? RhythmoStateView.error(icon: icon, title: text, action: action)
      : RhythmoStateView(icon: icon, title: text);
}

/// Lets the owner share a playlist by link, copy it, or stop sharing.
Future<void> showShareSheet(
  BuildContext context, {
  required Playlist playlist,
  required PlaylistsController controller,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // Lets the sheet grow with its content and scroll on short screens.
    isScrollControlled: true,
    builder: (_) => _ShareSheet(playlist: playlist, controller: controller),
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.playlist, required this.controller});

  final Playlist playlist;
  final PlaylistsController controller;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  late String? _token = widget.playlist.shareToken;
  late bool _public = widget.playlist.isPublic;

  /// Listing it publicly waits for an admin's approval (#322).
  late bool _pending = widget.playlist.publicPending;
  late final bool _rejected = widget.playlist.publicReview == 'rejected';
  bool _busy = false;
  String? _error;

  /// Creates the link with the chosen visibility, or changes the visibility
  /// of the link there is; the link itself stays the same.
  Future<void> _share({required bool public, required String failure}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final shared =
        await widget.controller.share(widget.playlist.id, public: public);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (shared == null) {
        _error = failure;
      } else {
        _token = shared.shareToken;
        _public = shared.isPublic;
        _pending = shared.pending;
      }
    });
  }

  Future<void> _choose(bool public) async {
    if (public == (_public || _pending)) return;
    if (_token == null) {
      setState(() => _public = public);
      return;
    }
    await _share(
        public: public, failure: 'تغییر نمایش ناموفق بود. دوباره تلاش کن.');
  }

  Future<void> _unshare() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.controller.unshare(widget.playlist.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _token = null;
        _public = false;
        _pending = false;
      } else {
        _error = 'لغو اشتراک ناموفق بود. دوباره تلاش کن.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final token = _token;
    final origin = AppConfiguration.apiBaseUri;
    final link = token == null
        ? null
        : origin == null
            ? token
            : sharedPlaylistLink(origin, token, public: _public).toString();
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'اشتراک‌گذاری «${widget.playlist.name}»',
              style: theme.textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Text(
              link == null
                  ? 'با لینک اشتراک، هر کسی که حساب ریتمو دارد می‌تواند این فهرست پخش را ببیند و آهنگ‌هایش را پخش کند. هر وقت بخواهی می‌توانی لینک را باطل کنی.'
                  : 'هر کسی که این لینک را دارد و وارد ریتمو شده، این فهرست پخش را می‌بیند و پخش می‌کند.',
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(RhythmoIcons.linkSimple),
                  label: Text('فقط با لینک'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(RhythmoIcons.globe),
                  label: Text('عمومی'),
                ),
              ],
              selected: {_public || _pending},
              onSelectionChanged:
                  _busy ? null : (selected) => _choose(selected.single),
              style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(0, 48)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _pending
                  ? 'در انتظار تأیید مدیر است. تا تأیید نشود، در هیچ فهرستی نمی‌آید و فقط کسی که لینک را دارد پیدایش می‌کند.'
                  : _public
                      ? 'در «فهرست‌های پخش محبوب» به همه‌ی کاربران ریتمو نشان داده می‌شود و می‌توانند آن را بپسندند.'
                      : _rejected
                          ? 'مدیر درخواست قبلی عمومی شدن را نپذیرفت. می‌توانی دوباره درخواست بدهی.'
                          : 'در هیچ فهرستی نمی‌آید؛ فقط کسی که لینک را دارد پیدایش می‌کند. عمومی شدن حساب‌های تأییدنشده با تأیید مدیر است.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (link != null) ...[
              Directionality(
                textDirection: TextDirection.ltr,
                child: SelectableText(link, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('لینک کپی شد.')));
                },
                icon: const Icon(RhythmoIcons.copy),
                label: const Text('کپی لینک'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _busy ? null : _unshare,
                icon: const Icon(RhythmoIcons.linkBreak),
                label: const Text('لغو اشتراک (لینک فعلی باطل می‌شود)'),
              ),
            ] else
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _share(
                        public: _public,
                        failure: 'ساخت لینک ناموفق بود. دوباره تلاش کن.'),
                icon: const Icon(RhythmoIcons.linkSimple),
                label: const Text('ساخت لینک اشتراک'),
              ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error,
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
    );
  }
}
