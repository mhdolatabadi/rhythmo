import 'package:flutter/material.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';

/// Hands the signed-in listener's playlists to screens opened from anywhere,
/// such as the full-screen player, so they can offer «افزودن به فهرست پخش».
class PlaylistsScope extends InheritedWidget {
  const PlaylistsScope(
      {super.key, required this.controller, required super.child});

  final PlaylistsController controller;

  static PlaylistsController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlaylistsScope>()?.controller;

  @override
  bool updateShouldNotify(PlaylistsScope oldWidget) =>
      controller != oldWidget.controller;
}

const _createAction = '__create_playlist__';

void _message(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Asks which playlist (or a new one) and adds [track] to it, saying how
/// that went.
Future<void> addTrackToPlaylist(
        BuildContext context, PlaylistsController controller, Track track) =>
    addTracksToPlaylist(context, controller, [track]);

/// Asks which playlist (or a new one) and adds [tracks] to it in order,
/// saying how that went.
Future<void> addTracksToPlaylist(BuildContext context,
    PlaylistsController controller, List<Track> tracks) async {
  if (tracks.isEmpty) return;
  final loaded = await controller.load();
  if (!context.mounted) return;
  if (!loaded) {
    _message(context, 'دریافت فهرست‌های پخش ناموفق بود.');
    return;
  }

  var playlistId = controller.playlists.isEmpty
      ? await _createPlaylist(context, controller)
      : await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('افزودن به فهرست پخش'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, _createAction),
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(RhythmoIcons.plus),
                  title: Text('فهرست پخش جدید'),
                ),
              ),
              const Divider(height: 1),
              for (final playlist in controller.playlists)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, playlist.id),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(RhythmoIcons.playlist),
                    title: Text(playlist.name),
                    subtitle: Text(
                        '${persianDigits(playlist.displayTrackCount)} قطعه موسیقی'),
                  ),
                ),
            ],
          ),
        );

  if (!context.mounted || playlistId == null) return;
  if (playlistId == _createAction) {
    playlistId = await _createPlaylist(context, controller);
    if (!context.mounted || playlistId == null) return;
  }

  if (tracks.length == 1) {
    final result = await controller.addDeviceTrack(playlistId, tracks.single);
    if (!context.mounted) return;
    switch (result) {
      case AddTrackResult.added:
        _message(context, 'آهنگ به فهرست پخش اضافه شد.');
      case AddTrackResult.alreadyPresent:
        _message(context, 'این آهنگ از قبل در فهرست پخش است.');
      case AddTrackResult.failure:
        _message(context, 'افزودن آهنگ به فهرست پخش ناموفق بود.');
    }
    return;
  }

  var added = 0, present = 0, failed = 0;
  for (final track in tracks) {
    switch (await controller.addDeviceTrack(playlistId, track)) {
      case AddTrackResult.added:
        added++;
      case AddTrackResult.alreadyPresent:
        present++;
      case AddTrackResult.failure:
        failed++;
    }
  }
  if (!context.mounted) return;
  _message(
      context,
      [
        if (added > 0) '${persianDigits(added)} آهنگ به فهرست پخش اضافه شد.',
        if (present > 0) '${persianDigits(present)} آهنگ از قبل در آن بود.',
        if (failed > 0) 'افزودن ${persianDigits(failed)} آهنگ ناموفق بود.',
      ].join(' '));
}

Future<String?> _createPlaylist(
  BuildContext context,
  PlaylistsController controller,
) async {
  final nameController = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('فهرست پخش جدید'),
      content: TextField(
        controller: nameController,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: 'نام فهرست پخش'),
        onSubmitted: (value) {
          final name = value.trim();
          if (name.isNotEmpty) Navigator.pop(context, name);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('انصراف'),
        ),
        FilledButton(
          onPressed: () {
            final name = nameController.text.trim();
            if (name.isNotEmpty) Navigator.pop(context, name);
          },
          child: const Text('ساخت'),
        ),
      ],
    ),
  );
  if (!context.mounted || name == null) return null;

  final playlist = await controller.create(name);
  if (!context.mounted) return null;
  if (playlist == null) {
    _message(context, 'ساخت فهرست پخش ناموفق بود.');
    return null;
  }
  return playlist.id;
}
