import 'package:flutter/material.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/playlists/application/device_playlist_import.dart';
import 'package:rhythmo/features/playlists/data/device_playlist_source.dart';

/// Asks which of [found] playlists to bring into rhythmo and imports them,
/// then says how it went. Playlists whose name is among [existingNames]
/// start unticked, so asking again does not make copies.
Future<void> offerDevicePlaylistImport(
  BuildContext context, {
  required DevicePlaylistImporter importer,
  required List<DevicePlaylist> found,
  required Set<String> existingNames,
  required List<Track> Function() cloud,
  required List<Track> Function() device,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final chosen = await showDialog<List<DevicePlaylist>>(
    context: context,
    builder: (_) => DevicePlaylistImportDialog(
        playlists: found, existingNames: existingNames),
  );
  if (chosen == null || chosen.isEmpty) {
    // «حالا نه» counts as an answer: the offer does not come back.
    await importer.markOffered(found);
    return;
  }
  final result =
      await importer.import(chosen, cloud: cloud(), device: device());
  await importer.markOffered(found);
  messenger.showSnackBar(SnackBar(content: Text(importMessage(result))));
}

String importMessage(DevicePlaylistImportResult result) {
  final parts = <String>[
    if (result.imported > 0)
      '${persianDigits(result.imported)} فهرست پخش با '
          '${persianDigits(result.tracks)} آهنگ به ریتمو آمد.'
    else
      'فهرست پخشی وارد نشد.',
    if (result.missing > 0)
      '${persianDigits(result.missing)} آهنگ دیگر روی گوشی نبود.',
    if (result.failed > 0)
      '${persianDigits(result.failed)} فهرست پخش وارد نشد؛ دوباره تلاش کن.',
  ];
  return parts.join(' ');
}

/// Shown when there is nothing to import: Samsung Music keeps playlists to
/// itself until they are exported.
Future<void> showNoDevicePlaylists(BuildContext context) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('فهرست پخشی پیدا نشد'),
        content: const Text(
            'روی این گوشی فهرست پخشی پیدا نکردیم. در سامسونگ موزیک از '
            'تنظیمات، «مدیریت فهرست‌های پخش» را باز کن و فهرست‌ها را خروجی '
            'بگیر، بعد دوباره اینجا «وارد کردن از گوشی» را بزن.'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('باشه'),
          ),
        ],
      ),
    );

class DevicePlaylistImportDialog extends StatefulWidget {
  const DevicePlaylistImportDialog({
    super.key,
    required this.playlists,
    this.existingNames = const {},
  });

  final List<DevicePlaylist> playlists;
  final Set<String> existingNames;

  @override
  State<DevicePlaylistImportDialog> createState() =>
      _DevicePlaylistImportDialogState();
}

class _DevicePlaylistImportDialogState
    extends State<DevicePlaylistImportDialog> {
  late final Set<String> _selected = {
    for (final playlist in widget.playlists)
      if (!_exists(playlist)) playlist.id,
  };

  bool _exists(DevicePlaylist playlist) =>
      widget.existingNames.contains(playlist.name.trim());

  @override
  Widget build(BuildContext context) {
    final samsung = widget.playlists.every((p) => p.fromSamsungMusic);
    return AlertDialog(
      title: Text(
          samsung ? 'فهرست‌های پخش سامسونگ موزیک' : 'فهرست‌های پخش روی گوشی'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(samsung
                ? 'این فهرست‌ها را در سامسونگ موزیک ساخته‌ای. کدام‌ها را به ریتمو بیاوریم؟'
                : 'این فهرست‌ها را روی گوشی پیدا کردیم. کدام‌ها را به ریتمو بیاوریم؟'),
            const SizedBox(height: 4),
            Text(
              'آهنگ‌هایی که آپلود نکرده‌ای فقط روی همین گوشی در فهرست می‌مانند.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final playlist in widget.playlists)
                    CheckboxListTile(
                      value: _selected.contains(playlist.id),
                      title: Text(playlist.name,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text([
                        '${persianDigits(playlist.trackIds.length)} آهنگ',
                        if (!samsung && playlist.fromSamsungMusic)
                          'سامسونگ موزیک',
                        if (_exists(playlist)) 'هم‌نامش در ریتمو هست',
                      ].join(' · ')),
                      onChanged: (checked) => setState(() {
                        if (checked ?? false) {
                          _selected.add(playlist.id);
                        } else {
                          _selected.remove(playlist.id);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const <DevicePlaylist>[]),
          child: const Text('حالا نه'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, [
                    for (final playlist in widget.playlists)
                      if (_selected.contains(playlist.id)) playlist,
                  ]),
          child: Text(_selected.isEmpty
              ? 'وارد کن'
              : 'وارد کردن ${persianDigits(_selected.length)} فهرست'),
        ),
      ],
    );
  }
}
