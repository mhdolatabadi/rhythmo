import 'package:flutter/foundation.dart';

/// For controllers whose requests can outlive them: an answer that arrives
/// after [dispose], for example once the app is closed, is dropped instead
/// of notifying listeners that are gone.
mixin QuietAfterDispose on ChangeNotifier {
  bool _gone = false;

  @override
  void notifyListeners() {
    if (!_gone) super.notifyListeners();
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}
