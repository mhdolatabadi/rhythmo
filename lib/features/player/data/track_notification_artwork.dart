import 'dart:typed_data';

import 'track_notification_artwork_stub.dart'
    if (dart.library.io) 'track_notification_artwork_io.dart' as platform;

Future<Uri?> trackNotificationArtwork(Uint8List bytes) =>
    platform.trackNotificationArtwork(bytes);
