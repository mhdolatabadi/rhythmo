import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<Uri?> trackNotificationArtwork(Uint8List bytes) async {
  try {
    final root = await getTemporaryDirectory();
    final directory = Directory('${root.path}/rhythmo-covers');
    await directory.create(recursive: true);
    final files = await directory.list().where((e) => e is File).toList();
    // Only derived pictures live here, never original audio.
    while (files.length >= 32) {
      await files.removeAt(0).delete();
    }
    final file = await File(
      '${directory.path}/${DateTime.now().microsecondsSinceEpoch}.jpg',
    ).writeAsBytes(bytes, flush: true);
    return file.uri;
  } catch (_) {
    return null;
  }
}
