import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rhythmo/features/player/data/equalizer.dart';

/// The listener's equalizer (#224): what the sheet shows and changes, kept
/// on this device and applied to the engine. Stored files never change.
class EqualizerController extends ChangeNotifier {
  EqualizerController(this._engine, this._store);

  final EqualizerEngine _engine;
  final EqualizerStore _store;

  EqualizerSettings _settings = const EqualizerSettings();
  bool _changed = false;

  EqualizerSettings get settings => _settings;

  /// Whether this device can shape the sound; the equalizer is hidden
  /// where it cannot.
  bool get supported => _engine.supportsEqualizer;

  /// Restores the saved equalizer; a change made meanwhile wins.
  Future<void> load() async {
    if (!supported) return;
    final saved = await _store.read();
    if (_changed) return;
    _settings = saved;
    await _engine.setEqualizer(saved);
    notifyListeners();
  }

  Future<void> setEnabled(bool enabled) => _update(_settings.copyWith(
        enabled: enabled,
        // Turning it on with nothing chosen yet starts from a preset that
        // is heard, not the flat one.
        preset: enabled && _settings.preset == EqualizerPreset.flat
            ? EqualizerPreset.bass
            : null,
      ));

  Future<void> setPreset(EqualizerPreset preset) => _update(_settings.copyWith(
        preset: preset,
        enabled: preset != EqualizerPreset.flat,
        // Custom starts from what was heard so far.
        customGainsDb: preset == EqualizerPreset.custom &&
                _settings.preset != EqualizerPreset.custom
            ? List.of(_settings.gainsDb)
            : null,
      ));

  /// Moves one custom band; any other preset becomes «سفارشی» from it.
  Future<void> setBand(int band, double gainDb) {
    final gains = List.of(_settings.gainsDb);
    gains[band] = gainDb.clamp(-maxBandGainDb, maxBandGainDb).toDouble();
    return _update(_settings.copyWith(
      enabled: true,
      preset: EqualizerPreset.custom,
      customGainsDb: gains,
    ));
  }

  Future<void> _update(EqualizerSettings next) async {
    _changed = true;
    _settings = next;
    notifyListeners();
    await _engine.setEqualizer(next);
    try {
      await _store.write(next);
    } catch (error) {
      debugPrint('Equalizer not saved: $error');
    }
  }
}
