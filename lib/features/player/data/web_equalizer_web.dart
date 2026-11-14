import 'dart:js_interop';

import 'package:rhythmo/features/player/data/equalizer.dart';

extension type _WebEqualizer(JSObject _) implements JSObject {
  external void set(JSArray<JSNumber> frequencies, JSArray<JSNumber> gains,
      double headroomDb);
  external void off();
}

@JS('rhythmoEqualizer')
external _WebEqualizer? get _equalizer;

/// Whether this browser can route the audio through Web Audio.
bool get webEqualizerAvailable => _equalizer != null;

void applyWebEqualizer(EqualizerSettings settings) {
  final equalizer = _equalizer;
  if (equalizer == null) return;
  if (!settings.active) {
    equalizer.off();
    return;
  }
  equalizer.set(
    [for (final hz in equalizerBands) hz.toJS].toJS,
    [for (final db in settings.gainsDb) db.toJS].toJS,
    settings.headroomDb,
  );
}
