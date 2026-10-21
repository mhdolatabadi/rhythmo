import 'package:rhythmo/features/library/data/track_artwork.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/tokens.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';

/// A square stand-in for cover art, tinted from [seed] so every track keeps
/// its own colour.
class RhythmoArtworkTile extends StatelessWidget {
  const RhythmoArtworkTile({
    super.key,
    required this.seed,
    this.size = 44,
    this.icon = RhythmoIcons.musicNote,
    this.active = false,
    this.track,
  });

  final String seed;
  final double size;
  final IconData icon;

  /// The track playing now: drawn in the primary container colour.
  final bool active;
  final Track? track;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: active ? colors.primaryContainer : artworkTint(seed),
        borderRadius: BorderRadius.circular(size * 0.27),
      ),
      child: track == null
          ? Icon(
              active ? RhythmoIcons.waveformFill : icon,
              size: size * 0.45,
              color:
                  active ? colors.onPrimaryContainer : colors.onSurfaceVariant,
            )
          : TrackCover(
              track: track!,
              radius: size * 0.27,
              child: Icon(
                active ? RhythmoIcons.waveformFill : icon,
                size: size * 0.45,
                color: active
                    ? colors.onPrimaryContainer
                    : colors.onSurfaceVariant,
              ),
            ),
    );
  }
}

/// One track in a list: artwork, title, the artist (or where it plays
/// from) and supporting detail such as the file size, then actions. Long
/// titles in any script end in an ellipsis; the row is at least 64 px.
class RhythmoTrackRow extends StatelessWidget {
  const RhythmoTrackRow({
    super.key,
    required this.seed,
    required this.title,
    required this.subtitle,
    this.detail,
    this.track,
    this.active = false,
    this.leadingIcon = RhythmoIcons.musicNote,
    this.onTap,
    this.trailing,
  });

  /// The track's id, which picks its artwork colour.
  final String seed;
  final String title;
  final String subtitle;

  /// Supporting information after the subtitle, such as «۳٫۲ مگابایت».
  final String? detail;
  final bool active;
  final Track? track;
  final IconData leadingIcon;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final line = detail == null ? subtitle : '$subtitle · $detail';
    return ListTile(
      minTileHeight: 64,
      contentPadding: const EdgeInsetsDirectional.fromSTEB(
          RhythmoSpace.lg, 0, RhythmoSpace.xs, 0),
      onTap: onTap,
      selected: active,
      leading: RhythmoArtworkTile(
          seed: seed, icon: leadingIcon, active: active, track: track),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }
}
