import 'package:rhythmo/features/library/data/track_artwork.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/format_size.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/auth/presentation/sign_in_prompt.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/lyrics/presentation/lyrics_sheet.dart';
import 'package:rhythmo/features/player/application/play_queue.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/playback_controls.dart';

/// The widest the now-playing column grows on desktop.
const nowPlayingMaxWidth = 520.0;

/// Opens the full-screen player over the current page. It slides up, and
/// swiping it down (or the close button, or back) slides it away; with
/// reduced motion it appears and disappears without sliding.
Future<void> openNowPlaying(BuildContext context, PlayerController player) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      // The page underneath shows while the screen is dragged down.
      opaque: false,
      barrierColor: RhythmoColors.barrier,
      transitionDuration: reduceMotion ? Duration.zero : RhythmoMotion.enter,
      reverseTransitionDuration:
          reduceMotion ? Duration.zero : RhythmoMotion.medium,
      pageBuilder: (_, __, ___) => NowPlayingScreen(player: player),
      transitionsBuilder: (_, animation, __, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: animation,
            curve: RhythmoMotion.emphasized,
            reverseCurve: RhythmoMotion.exit,
          ),
        ),
        child: child,
      ),
    ),
  );
}

/// The artist, or where the track plays from when it has none.
String trackSubtitle(Track track) {
  final artist = track.artist?.trim();
  if (artist != null && artist.isNotEmpty) return artist;
  return track.isLocal ? 'روی دستگاه' : 'روی سرور';
}

/// `m:ss`, as players show positions.
String formatPlaybackTime(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return persianDigits('$minutes:$seconds');
}

/// The track's artwork colour, see [artworkTint].
Color trackTint(Track track) => artworkTint(track.id);

/// WCAG contrast ratio between two opaque colors.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

/// Full-screen player over the still aurora: artwork, title and like, the
/// next track, seek bar, transport controls and tools. Nothing on it moves
/// by itself.
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key, required this.player});

  final PlayerController player;

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen>
    with SingleTickerProviderStateMixin {
  double? _seekMs;

  /// How far the screen has been dragged down to close it.
  double _drag = 0;
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: RhythmoMotion.short,
  )..addListener(() => setState(() => _drag = _settleFrom * _settle.value));
  double _settleFrom = 0;
  bool _closing = false;

  PlayerController get _player => widget.player;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// Likes or unlikes the playing song, and says when that didn't work.
  Future<void> _like(Track track) async {
    final result = await _player.favorites.toggleTrack(track);
    if (!mounted) return;
    switch (result) {
      case TrackLikeResult.done:
        break;
      case TrackLikeResult.needsAccount:
        askToSignIn(context, action: 'پسندیدن');
      case TrackLikeResult.failed:
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
              content: Text('پسندیدن ثبت نشد. دوباره تلاش کن.')));
    }
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _settle.stop();
    setState(() => _drag = max(0, _drag + details.delta.dy));
  }

  void _onDragEnd(DragEndDetails details) {
    final height = MediaQuery.sizeOf(context).height;
    if (_drag > height * 0.2 || details.velocity.pixelsPerSecond.dy > 900) {
      _close();
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _drag = 0);
      return;
    }
    _settleFrom = _drag;
    _settle.value = 1;
    _settle.animateTo(0, curve: RhythmoMotion.standard);
  }

  void _openQueue() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => QueueSheet(player: _player),
    );
  }

  void _openLyrics() {
    final lyrics = _player.lyrics;
    if (lyrics != null) openLyrics(context, _player, lyrics);
  }

  void _openDetails(Track track) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (_) => _TrackDetailsSheet(track: track),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_player, _player.favorites]),
      builder: (context, _) {
        final track = _player.track;
        if (track == null) {
          // Playback stopped (for example on logout); nothing to show.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _close();
          });
          return const SizedBox.shrink();
        }
        final tint = trackTint(track);
        return Transform.translate(
          offset: Offset(0, _drag),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: RhythmoBackdrop(
              child: Material(
                type: MaterialType.transparency,
                child: SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: nowPlayingMaxWidth),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(RhythmoSpace.lg, 0,
                            RhythmoSpace.lg, RhythmoSpace.sm),
                        child: LayoutBuilder(
                          builder: (context, constraints) =>
                              _layout(context, constraints, track, tint),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _layout(
    BuildContext context,
    BoxConstraints constraints,
    Track track,
    Color tint,
  ) {
    final header = _Header(
      player: _player,
      onClose: _close,
      onMore: () => _openDetails(track),
    );
    final next = _player.upcoming.firstOrNull;
    final title = _TitleRow(
      track: track,
      liked: _player.favorites.contains(track.id),
      onLike: () => _like(track),
    );
    final details = <Widget>[
      if (next != null) _UpNext(track: next, onQueue: _openQueue),
      const SizedBox(height: RhythmoSpace.xs),
      _SeekBar(
        player: _player,
        dragMs: _seekMs,
        onDrag: (value) => setState(() => _seekMs = value),
        onDragEnd: (value) {
          setState(() => _seekMs = null);
          _player.seek(Duration(milliseconds: value.round()));
        },
      ),
      _Transport(player: _player),
      const SizedBox(height: RhythmoSpace.xs),
      _BottomRow(
        player: _player,
        upcoming: _player.upcoming.length,
        onQueue: _openQueue,
        onLyrics: _player.lyrics == null ? null : _openLyrics,
      ),
    ];

    // Short landscape windows: drop the artwork and scroll; the close
    // button still dismisses.
    if (constraints.maxHeight < 460) {
      return SingleChildScrollView(
        child: Column(children: [header, title, ...details]),
      );
    }
    return Column(
      children: [
        header,
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(
                top: RhythmoSpace.xs, bottom: RhythmoSpace.md),
            child: LayoutBuilder(
              builder: (context, box) => Center(
                child: NowPlayingArtwork(
                  track: track,
                  status: _player.status,
                  tint: tint,
                  // A little narrower than the column, as on the design.
                  size: min(box.maxWidth * 0.8, box.maxHeight),
                ),
              ),
            ),
          ),
        ),
        title,
        const SizedBox(height: RhythmoSpace.lg),
        ...details,
      ],
    );
  }
}

/// Close, the heading with the sleep timer's countdown under it, and the
/// track details button, which also balances the close button.
class _Header extends StatelessWidget {
  const _Header({
    required this.player,
    required this.onClose,
    required this.onMore,
  });

  final PlayerController player;
  final VoidCallback onClose;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sleep = sleepTimerStatus(player);
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            tooltip: 'بستن',
            onPressed: onClose,
            icon: const Icon(RhythmoIcons.caretDown),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'در حال پخش',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (sleep != null)
                  Text(
                    sleep,
                    key: const ValueKey('sleep-status'),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'جزئیات آهنگ',
            onPressed: onMore,
            icon: const Icon(RhythmoIcons.dotsThreeVertical),
          ),
        ],
      ),
    );
  }
}

/// The large square artwork. It holds still whether playing or paused.
class NowPlayingArtwork extends StatelessWidget {
  const NowPlayingArtwork({
    super.key,
    required this.track,
    required this.status,
    required this.tint,
    required this.size,
  });

  final Track track;
  final PlayerStatus status;
  final Color tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = RhythmoRadii.lg;
    final icon = status == PlayerStatus.error
        ? RhythmoIcons.warningCircle
        : track.isLocal
            ? RhythmoIcons.deviceMobile
            : RhythmoIcons.musicNote;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            Color.lerp(tint, RhythmoColors.highlight, 0.14)!,
            Theme.of(context).brightness == Brightness.dark
                ? Color.lerp(tint, RhythmoColors.background, 0.35)!
                : colors.primaryContainer,
          ],
        ),
        border: Border.all(color: RhythmoColors.softBorder),
        boxShadow: const [
          BoxShadow(
            color: RhythmoColors.shadow,
            offset: Offset(0, 16),
            blurRadius: 32,
            spreadRadius: -12,
          ),
        ],
      ),
      child: TrackCover(
          track: track,
          radius: radius,
          child: Icon(
            icon,
            size: size * 0.28,
            color: colors.onSurface.withValues(alpha: 0.72),
          )),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({
    required this.track,
    required this.liked,
    required this.onLike,
  });

  final Track track;
  final bool liked;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                trackSubtitle(track),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Semantics(
          toggled: liked,
          child: IconButton(
            tooltip: liked ? 'برداشتن از پسندیده‌ها' : 'پسندیدن',
            isSelected: liked,
            onPressed: onLike,
            iconSize: 24,
            color: liked ? theme.colorScheme.primary : null,
            icon: Icon(liked ? RhythmoIcons.heartFill : RhythmoIcons.heart),
          ),
        ),
      ],
    );
  }
}

class _SeekBar extends StatelessWidget {
  const _SeekBar({
    required this.player,
    required this.dragMs,
    required this.onDrag,
    required this.onDragEnd,
  });

  final PlayerController player;
  final double? dragMs;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onDragEnd;

  @override
  Widget build(BuildContext context) {
    final durationMs = player.duration?.inMilliseconds ?? 0;
    final positionMs =
        player.position.inMilliseconds.clamp(0, durationMs).toDouble();
    final shown = dragMs ?? positionMs;
    return Directionality(
      // Time runs left to right, as on every player, even in Persian.
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
            ),
            child: Slider(
              value: shown,
              max: durationMs > 0 ? durationMs.toDouble() : 1,
              semanticFormatterCallback: (value) => formatPlaybackTime(
                Duration(milliseconds: value.round()),
              ),
              onChanged: durationMs > 0 ? onDrag : null,
              onChangeEnd: durationMs > 0 ? onDragEnd : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Time(Duration(milliseconds: shown.round())),
                _Time(player.duration ?? Duration.zero),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Time extends StatelessWidget {
  const _Time(this.value);

  final Duration value;

  @override
  Widget build(BuildContext context) {
    return Text(
      formatPlaybackTime(value),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// The play button's diameter.
const _playSize = 64.0;

class _Transport extends StatelessWidget {
  const _Transport({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final status = player.status;
    final busy =
        status == PlayerStatus.loading || status == PlayerStatus.buffering;
    final playing =
        status == PlayerStatus.playing || status == PlayerStatus.buffering;
    final colors = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ShuffleToggle(player: player),
          IconButton(
            tooltip: 'قبلی',
            iconSize: 26,
            onPressed: player.previous,
            icon: const Icon(RhythmoIcons.skipBackFill),
          ),
          SizedBox.square(
            dimension: _playSize,
            child: busy
                ? Semantics(
                    label: 'در حال آماده‌سازی پخش',
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: colors.primary,
                      ),
                    ),
                  )
                : IconButton.filled(
                    tooltip: status == PlayerStatus.error
                        ? 'تلاش دوباره'
                        : playing
                            ? 'توقف'
                            : 'پخش',
                    iconSize: 28,
                    // The one bright control: white on the dark aurora.
                    style: IconButton.styleFrom(
                      shape: const CircleBorder(),
                      fixedSize: const Size.square(_playSize),
                      backgroundColor: colors.onSurface,
                      foregroundColor: colors.surface,
                    ),
                    onPressed: player.toggle,
                    icon: Icon(
                      status == PlayerStatus.error
                          ? RhythmoIcons.arrowsClockwise
                          : playing
                              ? RhythmoIcons.pauseFill
                              : RhythmoIcons.playFill,
                    ),
                  ),
          ),
          IconButton(
            tooltip: 'بعدی',
            iconSize: 26,
            onPressed: player.next,
            icon: const Icon(RhythmoIcons.skipForwardFill),
          ),
          RepeatToggle(player: player),
        ],
      ),
    );
  }
}

class _BottomRow extends StatelessWidget {
  const _BottomRow({
    required this.player,
    required this.upcoming,
    required this.onQueue,
    required this.onLyrics,
  });

  final PlayerController player;
  final int upcoming;
  final VoidCallback onQueue;

  /// Opens «متن آهنگ»; null hides the button where there is no server.
  final VoidCallback? onLyrics;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Gives way first on a narrow phone, so speed and details still fit.
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onQueue,
              icon: const Icon(RhythmoIcons.playlist),
              label: Text(
                upcoming == 0
                    ? 'صف پخش'
                    // Not «·»: beside Persian digits it reads as a zero.
                    : 'صف پخش (${persianDigits(upcoming)})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        SpeedButton(player: player),
        if (onLyrics != null)
          IconButton(
            tooltip: 'متن آهنگ',
            onPressed: onLyrics,
            icon: const Icon(RhythmoIcons.quotes),
          ),
        SleepTimerButton(player: player),
      ],
    );
  }
}

/// «بعدی در صف»: the track that plays next, as one compact row. Tapping it
/// opens the queue.
class _UpNext extends StatelessWidget {
  const _UpNext({required this.track, required this.onQueue});

  final Track track;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'بعدی در صف',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        RhythmoTrackRow(
          key: const ValueKey('up-next'),
          track: track,
          seed: track.id,
          title: track.title,
          subtitle: trackSubtitle(track),
          contentPadding: EdgeInsets.zero,
          onTap: onQueue,
        ),
      ],
    );
  }
}

/// Shuffle on or off, shown with both color and a filled background.
class ShuffleToggle extends StatelessWidget {
  const ShuffleToggle({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) => _ModeToggle(
        tooltip: player.shuffle ? 'پخش تصادفی: روشن' : 'پخش تصادفی',
        icon: player.shuffle ? RhythmoIcons.shuffleFill : RhythmoIcons.shuffle,
        active: player.shuffle,
        onPressed: player.toggleShuffle,
      );
}

/// Cycles repeat off → all → one.
class RepeatToggle extends StatelessWidget {
  const RepeatToggle({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) => _ModeToggle(
        tooltip: switch (player.repeat) {
          QueueRepeat.off => 'تکرار: خاموش',
          QueueRepeat.all => 'تکرار: همه',
          QueueRepeat.one => 'تکرار: همین آهنگ',
        },
        icon: switch (player.repeat) {
          QueueRepeat.off => RhythmoIcons.repeat,
          QueueRepeat.all => RhythmoIcons.repeatFill,
          QueueRepeat.one => RhythmoIcons.repeatOnceFill,
        },
        active: player.repeat != QueueRepeat.off,
        onPressed: player.cycleRepeat,
      );
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      isSelected: active,
      onPressed: onPressed,
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(
          active ? colors.onSecondaryContainer : colors.onSurfaceVariant,
        ),
        backgroundColor: WidgetStatePropertyAll(
          active ? colors.secondaryContainer : RhythmoColors.transparent,
        ),
      ),
      icon: Icon(icon),
    );
  }
}

/// The «صف پخش» sheet: the current track and what plays after it. Tapping
/// an upcoming track plays it; the sheet stays open and follows along.
class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FractionallySizedBox(
      heightFactor: 0.75,
      child: ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final current = player.track;
          final upcoming = player.upcoming;
          return RhythmoSheetFrame(
            title: 'صف پخش',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (current != null)
                  RhythmoTrackRow(
                    track: current,
                    seed: current.id,
                    title: current.title,
                    subtitle: 'در حال پخش · ${trackSubtitle(current)}',
                    active: true,
                  ),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                      RhythmoSpace.xxl,
                      RhythmoSpace.md,
                      RhythmoSpace.xxl,
                      RhythmoSpace.xs),
                  child: Text(
                    upcoming.isEmpty
                        ? 'بعدی'
                        : 'بعدی · ${persianDigits(upcoming.length)} آهنگ',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: upcoming.isEmpty
                      ? const RhythmoStateView(
                          icon: RhythmoIcons.playlist,
                          title: 'آهنگ دیگری در صف نیست.',
                          message:
                              'آهنگ بعدی را از «موسیقی من» یا فهرست پخش انتخاب کنید.',
                        )
                      : ListView.builder(
                          padding: rhythmoListBottomPadding(context),
                          itemCount: upcoming.length,
                          itemBuilder: (context, index) {
                            final track = upcoming[index];
                            return RhythmoTrackRow(
                              track: track,
                              seed: track.id,
                              title: track.title,
                              subtitle: trackSubtitle(track),
                              onTap: () => player.skipTo(index),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TrackDetailsSheet extends StatelessWidget {
  const _TrackDetailsSheet({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String?)>[
      ('عنوان', track.title),
      ('هنرمند', track.artist),
      ('آلبوم', track.album),
      ('نام فایل', track.fileName),
      ('حجم', formatSize(track.sizeBytes)),
      (
        'منبع',
        track.isLocal
            ? 'روی دستگاه'
            : track.importedFrom == null
                ? 'روی سرور'
                : 'واردشده از ${track.importedFrom}'
      ),
    ];
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewPaddingOf(context).bottom + RhythmoSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const RhythmoSectionHeader(
            title: 'جزئیات آهنگ',
            padding: EdgeInsetsDirectional.fromSTEB(
                RhythmoSpace.xxl, 0, RhythmoSpace.xxl, RhythmoSpace.sm),
          ),
          for (final (label, value) in rows)
            if (value?.trim().isNotEmpty == true)
              ListTile(
                contentPadding: const EdgeInsetsDirectional.symmetric(
                    horizontal: RhythmoSpace.xxl),
                title: Text(label),
                subtitle:
                    Text(value!, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
        ],
      ),
    );
  }
}
