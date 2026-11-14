import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The bands the presets and the custom sliders are set on, in Hz. A device
/// with other bands (Android reports its own) gets the curve through these
/// points, read off at its band centres.
const equalizerBands = <double>[60, 230, 910, 3600, 14000];

/// The most a band moves either way, in dB.
const maxBandGainDb = 12.0;

/// The equalizer's presets (#224).
enum EqualizerPreset {
  flat('تخت (خاموش)', [0, 0, 0, 0, 0]),
  bass('بیس بیشتر', [6, 4, 0, 0, 0]),
  vocal('صدای خواننده', [-2, -1, 3, 4, 1]),
  pop('پاپ', [-1, 2, 4, 2, -1]),
  rock('راک', [5, 3, -1, 3, 5]),
  classical('کلاسیک', [3, 1, -1, 1, 3]),
  traditional('سنتی', [1, 2, 3, 2, 0]),
  soft('آرام', [2, 1, 0, -2, -3]),
  custom('سفارشی', [0, 0, 0, 0, 0]);

  const EqualizerPreset(this.label, this.gainsDb);

  final String label;

  /// Gains at [equalizerBands]; [custom] uses the listener's own.
  final List<double> gainsDb;
}

/// The listener's equalizer, kept per device. Off, or the flat preset,
/// leaves the sound untouched.
class EqualizerSettings {
  const EqualizerSettings({
    this.enabled = false,
    this.preset = EqualizerPreset.flat,
    this.customGainsDb = const [0, 0, 0, 0, 0],
  });

  final bool enabled;
  final EqualizerPreset preset;
  final List<double> customGainsDb;

  /// The gains now in effect at [equalizerBands].
  List<double> get gainsDb =>
      preset == EqualizerPreset.custom ? customGainsDb : preset.gainsDb;

  /// Whether the sound is changed at all.
  bool get active => enabled && gainsDb.any((gain) => gain != 0);

  /// How far the output is turned down so boosted bands do not clip: the
  /// highest boost, so the loudest band is never above the original.
  double get headroomDb => active ? gainsDb.fold(0.0, math.max) : 0;

  /// The gain at [hz], through the band points on a log-frequency scale.
  double gainAt(double hz) {
    final gains = gainsDb;
    if (hz <= equalizerBands.first) return gains.first;
    if (hz >= equalizerBands.last) return gains.last;
    for (var i = 1; i < equalizerBands.length; i++) {
      final high = equalizerBands[i];
      if (hz > high) continue;
      final low = equalizerBands[i - 1];
      final t =
          (math.log(hz) - math.log(low)) / (math.log(high) - math.log(low));
      return gains[i - 1] + (gains[i] - gains[i - 1]) * t;
    }
    return gains.last;
  }

  EqualizerSettings copyWith({
    bool? enabled,
    EqualizerPreset? preset,
    List<double>? customGainsDb,
  }) =>
      EqualizerSettings(
        enabled: enabled ?? this.enabled,
        preset: preset ?? this.preset,
        customGainsDb: customGainsDb ?? this.customGainsDb,
      );

  Map<String, Object> toJson() => {
        'enabled': enabled,
        'preset': preset.name,
        'custom': customGainsDb,
      };

  /// Reads saved settings, dropping what the app no longer offers.
  factory EqualizerSettings.fromJson(Object? json) {
    if (json is! Map) return const EqualizerSettings();
    final custom = json['custom'];
    return EqualizerSettings(
      enabled: json['enabled'] == true,
      preset: EqualizerPreset.values.firstWhere(
        (preset) => preset.name == json['preset'],
        orElse: () => EqualizerPreset.flat,
      ),
      customGainsDb: custom is List && custom.length == equalizerBands.length
          ? [
              for (final gain in custom)
                gain is num
                    ? gain.toDouble().clamp(-maxBandGainDb, maxBandGainDb)
                    : 0.0,
            ]
          : const [0, 0, 0, 0, 0],
    );
  }
}

/// Where [EqualizerSettings] are kept between launches.
abstract interface class EqualizerStore {
  Future<EqualizerSettings> read();
  Future<void> write(EqualizerSettings settings);
}

class MemoryEqualizerStore implements EqualizerStore {
  EqualizerSettings settings = const EqualizerSettings();

  @override
  Future<EqualizerSettings> read() async => settings;

  @override
  Future<void> write(EqualizerSettings settings) async =>
      this.settings = settings;
}

/// Keeps the equalizer on this device only, as it suits this device's
/// speakers or headphones.
class SecureEqualizerStore implements EqualizerStore {
  SecureEqualizerStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'rhythmo.equalizer';

  final FlutterSecureStorage _storage;

  @override
  Future<EqualizerSettings> read() async {
    try {
      final raw = await _storage.read(key: _key);
      return raw == null
          ? const EqualizerSettings()
          : EqualizerSettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return const EqualizerSettings();
    }
  }

  @override
  Future<void> write(EqualizerSettings settings) =>
      _storage.write(key: _key, value: jsonEncode(settings.toJson()));
}

/// An engine that can shape the sound on this device.
abstract interface class EqualizerEngine {
  bool get supportsEqualizer;

  /// Applies [settings]; inactive settings take the equalizer out of the
  /// path entirely.
  Future<void> setEqualizer(EqualizerSettings settings);
}
