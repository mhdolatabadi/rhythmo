import 'package:rhythmo/features/library/data/track_artwork.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/presentation/now_playing_screen.dart';

/// Responsive now-playing surface with track identity, playback controls,
/// and progress.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key, required this.player});

  final PlayerController player;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  double? _dragMs;

  static String _format(Duration value) => formatPlaybackTime(value);

  void _openNowPlaying() => openNowPlaying(context, widget.player);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.player,
      builder: (context, _) {
        final player = widget.player;
        final track = player.track;
        if (track == null) return const SizedBox.shrink();

        final status = player.status;
        final durationMs = player.duration?.inMilliseconds ?? 0;
        final positionMs =
            player.position.inMilliseconds.clamp(0, durationMs).toDouble();
        final busy =
            status == PlayerStatus.loading || status == PlayerStatus.buffering;
        final playing =
            status == PlayerStatus.playing || status == PlayerStatus.buffering;

        return Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: GlassSurface(
                radius: 24,
                blur: 24,
                tint: RhythmoColors.primary,
                child: SafeArea(
                  top: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 620;
                      final summary = _TrackSummary(
                        track: track,
                        status: status,
                        onTap: _openNowPlaying,
                        needsTap: player.needsTap,
                      );
                      final controls = _PlaybackControls(
                        player: player,
                        status: status,
                        busy: busy,
                        playing: playing,
                      );

                      if (compact) {
                        return _CompactMiniPlayer(
                          track: track,
                          status: status,
                          player: player,
                          busy: busy,
                          playing: playing,
                          progress: durationMs > 0
                              ? (positionMs / durationMs).clamp(0.0, 1.0)
                              : null,
                          onOpen: _openNowPlaying,
                        );
                      }

                      return Padding(
                        padding:
                            const EdgeInsetsDirectional.fromSTEB(20, 10, 20, 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(child: summary),
                                const SizedBox(width: 24),
                                controls,
                              ],
                            ),
                            const SizedBox(height: 4),
                            Directionality(
                              textDirection: TextDirection.ltr,
                              child: Row(
                                children: [
                                  _TimeLabel(_format(player.position)),
                                  Expanded(
                                    child: Slider(
                                      value: _dragMs ?? positionMs,
                                      max: durationMs > 0
                                          ? durationMs.toDouble()
                                          : 1,
                                      semanticFormatterCallback: (value) =>
                                          _format(
                                        Duration(milliseconds: value.round()),
                                      ),
                                      onChanged: durationMs > 0
                                          ? (value) =>
                                              setState(() => _dragMs = value)
                                          : null,
                                      onChangeEnd: durationMs > 0
                                          ? (value) {
                                              setState(() => _dragMs = null);
                                              player.seek(
                                                Duration(
                                                  milliseconds: value.round(),
                                                ),
                                              );
                                            }
                                          : null,
                                    ),
                                  ),
                                  _TimeLabel(
                                    _format(player.duration ?? Duration.zero),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CompactMiniPlayer extends StatelessWidget {
  const _CompactMiniPlayer({
    required this.track,
    required this.status,
    required this.player,
    required this.busy,
    required this.playing,
    required this.progress,
    required this.onOpen,
  });

  final Track track;
  final PlayerStatus status;
  final PlayerController player;
  final bool busy;
  final bool playing;
  final double? progress;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(10, 4, 8, 8),
          child: Row(
            children: [
              InkWell(
                borderRadius: RhythmoRadii.control,
                onTap: onOpen,
                child: SizedBox.square(
                  dimension: 48,
                  child: Center(
                    child: _MiniArtwork(track: track, status: status, size: 40),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(RhythmoRadii.sm),
                  onTap: onOpen,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _MiniTrackText(
                      track: track,
                      status: status,
                      needsTap: player.needsTap,
                    ),
                  ),
                ),
              ),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'قبلی',
                      onPressed: player.previous,
                      icon: const Icon(RhythmoIcons.skipBackFill),
                    ),
                    if (busy)
                      const SizedBox.square(
                        dimension: 42,
                        child: Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      )
                    else
                      IconButton.filled(
                        tooltip: status == PlayerStatus.error
                            ? 'تلاش دوباره'
                            : playing
                                ? 'توقف'
                                : 'پخش',
                        onPressed: player.toggle,
                        icon: Icon(
                          status == PlayerStatus.error
                              ? RhythmoIcons.arrowsClockwise
                              : playing
                                  ? RhythmoIcons.pauseFill
                                  : RhythmoIcons.playFill,
                        ),
                      ),
                    IconButton(
                      tooltip: 'بعدی',
                      onPressed: player.next,
                      icon: const Icon(RhythmoIcons.skipForwardFill),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (progress case final value?)
          PositionedDirectional(
            start: 18,
            end: 18,
            bottom: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(RhythmoRadii.pill),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 2,
                  backgroundColor: colors.surfaceContainerHighest,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _TrackSummary extends StatelessWidget {
  const _TrackSummary({
    required this.track,
    required this.status,
    required this.onTap,
    this.needsTap = false,
  });

  final Track track;
  final PlayerStatus status;
  final VoidCallback onTap;
  final bool needsTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: RhythmoRadii.control,
      onTap: onTap,
      child: Row(
        children: [
          _MiniArtwork(track: track, status: status, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: _MiniTrackText(
                track: track, status: status, needsTap: needsTap),
          ),
        ],
      ),
    );
  }
}

class _MiniArtwork extends StatelessWidget {
  const _MiniArtwork({
    required this.track,
    required this.status,
    required this.size,
  });

  final Track track;
  final PlayerStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = status == PlayerStatus.error
        ? RhythmoIcons.warningCircle
        : track.isLocal
            ? RhythmoIcons.deviceMobile
            : RhythmoIcons.musicNote;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size >= 44 ? 14 : 12),
        boxShadow: [
          BoxShadow(
            color: RhythmoColors.primary.withValues(alpha: 0.18),
            offset: const Offset(0, 7),
            blurRadius: 18,
          ),
        ],
      ),
      child: TrackCover(track: track, radius: size >= 44 ? 14 : 12, child: Icon(
        icon,
        size: size * 0.36,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      )),
    );
  }
}

class _MiniTrackText extends StatelessWidget {
  const _MiniTrackText({
    required this.track,
    required this.status,
    this.needsTap = false,
  });

  final Track track;
  final PlayerStatus status;

  /// The browser wants a tap before it plays audio.
  final bool needsTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      // The mini player is the scaffold's bottom bar, which may be as tall
      // as the screen; a Column that took all of it covered the library.
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          switch (status) {
            PlayerStatus.error => 'پخش ناموفق بود. دوباره تلاش کن.',
            PlayerStatus.loading ||
            PlayerStatus.buffering =>
              'در حال بارگذاری…',
            _ when needsTap => 'برای پخش، دکمه‌ی پخش را بزن.',
            _ => trackSubtitle(track),
          },
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: status == PlayerStatus.error
                    ? colors.error
                    : colors.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.player,
    required this.status,
    required this.busy,
    required this.playing,
  });

  final PlayerController player;
  final PlayerStatus status;
  final bool busy;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShuffleToggle(player: player),
          IconButton(
            tooltip: 'قبلی',
            onPressed: player.previous,
            icon: const Icon(RhythmoIcons.skipBackFill),
          ),
          const SizedBox(width: 4),
          if (busy)
            Semantics(
              label: 'در حال آماده‌سازی پخش',
              child: const SizedBox.square(
                dimension: 48,
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            )
          else
            IconButton.filled(
              tooltip: status == PlayerStatus.error
                  ? 'تلاش دوباره'
                  : playing
                      ? 'توقف'
                      : 'پخش',
              iconSize: 28,
              onPressed: player.toggle,
              icon: Icon(
                status == PlayerStatus.error
                    ? RhythmoIcons.arrowsClockwise
                    : playing
                        ? RhythmoIcons.pauseFill
                        : RhythmoIcons.playFill,
              ),
            ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'بعدی',
            onPressed: player.next,
            icon: const Icon(RhythmoIcons.skipForwardFill),
          ),
          RepeatToggle(player: player),
        ],
      ),
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      child: Text(
        value,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
