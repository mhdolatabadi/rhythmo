import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Lets the user choose a cover image; null when they cancel. The server
/// checks and shrinks it, so only the size is bounded here.
Future<Uint8List?> pickCoverImage() async {
  final file = await FilePicker.pickFile(type: FileType.image);
  if (file == null) return null;
  final bytes = await file.xFile.readAsBytes();
  if (!kIsWeb) {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {
      // Desktop platforms have nothing to clear.
    }
  }
  return bytes;
}
