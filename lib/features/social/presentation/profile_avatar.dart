import 'package:flutter/material.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';

/// A round profile picture, or the user icon without one.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, this.url, this.size = 40});

  final Uri? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = Icon(RhythmoIcons.user,
        size: size * 0.5, color: colors.onSecondaryContainer);
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        color: colors.secondaryContainer,
        alignment: Alignment.center,
        child: url == null
            ? fallback
            : Image.network(url.toString(),
                width: size,
                height: size,
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (_, __, ___) => fallback),
      ),
    );
  }
}
