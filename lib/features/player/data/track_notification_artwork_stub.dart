import 'dart:typed_data';

Future<Uri?> trackNotificationArtwork(Uint8List bytes) async =>
    Uri.dataFromBytes(bytes, mimeType: 'image/jpeg');
