import 'package:flutter/material.dart';
import 'package:rhythmo/features/social/data/social.dart';
import 'package:rhythmo/features/social/presentation/profile_screen.dart';

/// Public profiles and following (#228), for every screen: a playlist's
/// owner, settings and the home all open profiles through it.
class Social {
  const Social({
    required this.api,
    required this.token,
    required this.openPlaylist,
    this.openSong,
  });

  final SocialApi api;

  /// The signed-in account's token; null for a guest.
  final String? Function() token;

  /// Opens a public playlist by its share token.
  final void Function(BuildContext context, String shareToken) openPlaylist;

  /// Opens a store song by its entry id; null where the store is off.
  final void Function(BuildContext context, String entryId)? openSong;

  Future<void> openProfile(BuildContext context, String handle) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(handle: handle, social: this),
      ));
}

class SocialScope extends InheritedWidget {
  const SocialScope({super.key, required this.social, required super.child});

  final Social social;

  static Social? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SocialScope>()?.social;

  @override
  bool updateShouldNotify(SocialScope oldWidget) => social != oldWidget.social;
}
