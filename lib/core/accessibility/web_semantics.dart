import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';

SemanticsHandle? _webSemantics;

/// Builds the semantics tree from the start on the web.
///
/// Flutter web otherwise renders an empty canvas to screen readers, browser
/// translation, password managers and "find in page" until someone activates
/// the hidden "Enable accessibility" placeholder (#385). Android exposes the
/// tree on demand already, so this only applies on the web.
///
/// Returns whether semantics were switched on by this call.
bool keepWebSemanticsOn({bool isWeb = kIsWeb}) {
  if (!isWeb || _webSemantics != null) return false;
  _webSemantics = SemanticsBinding.instance.ensureSemantics();
  return true;
}

@visibleForTesting
void releaseWebSemantics() {
  _webSemantics?.dispose();
  _webSemantics = null;
}
