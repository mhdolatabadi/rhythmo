import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rhythmo/features/player/data/loudness.dart';

/// The playback speeds offered, slowest first. Pitch is kept at every speed.
const playbackSpeeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

/// The longest crossfade the settings offer.
const maxCrossfade = Duration(seconds: 8);

/// Listening preferences kept between sessions.
class PlaybackSettings {
  const PlaybackSettings({
    this.speed = 1,
    this.crossfade = Duration.zero,
    this.loudness = LoudnessMode.track,
    this.playOnlySelected = false,
    this.preventDuplicates = false,
    this.skipSilence = false,
    this.systemControls = true,
    this.externalPlayback = true,
    this.volume = 1,
    this.muted = false,
  });

  /// The listener's own volume from 0 to 1, below the device's.
  final double volume;
  final bool muted;

  /// Applies to tapping a row; explicit play-all actions keep the whole list.
  final bool playOnlySelected;
  final bool preventDuplicates;
  final bool skipSilence;
  final bool systemControls;
  final bool externalPlayback;

  final double speed;

  /// How long consecutive tracks overlap; zero is off.
  final Duration crossfade;

  /// Loudness normalization; on, per track, unless the listener turns it off.
  final LoudnessMode loudness;

  /// Reads saved settings, dropping values the app no longer offers.
  factory PlaybackSettings.fromJson(Object? json) {
    if (json is! Map) return const PlaybackSettings();
    final speed = json['speed'];
    final crossfadeMs = json['crossfadeMs'];
    return PlaybackSettings(
      playOnlySelected: json['playOnlySelected'] == true,
      preventDuplicates: json['preventDuplicates'] == true,
      skipSilence: json['skipSilence'] == true,
      systemControls: json['systemControls'] is bool
          ? json['systemControls'] as bool
          : true,
      externalPlayback: json['externalPlayback'] is bool
          ? json['externalPlayback'] as bool
          : true,
      speed: speed is num && playbackSpeeds.contains(speed.toDouble())
          ? speed.toDouble()
          : 1,
      crossfade: crossfadeMs is int
          ? Duration(
              milliseconds: crossfadeMs.clamp(0, maxCrossfade.inMilliseconds))
          : Duration.zero,
      loudness: LoudnessMode.values.firstWhere(
        (mode) => mode.name == json['loudness'],
        orElse: () => LoudnessMode.track,
      ),
      volume: json['volume'] is num
          ? (json['volume'] as num).toDouble().clamp(0.0, 1.0)
          : 1,
      muted: json['muted'] == true,
    );
  }

  Map<String, Object> toJson() => {
        'speed': speed,
        'crossfadeMs': crossfade.inMilliseconds,
        'loudness': loudness.name,
        'playOnlySelected': playOnlySelected,
        'preventDuplicates': preventDuplicates,
        'skipSilence': skipSilence,
        'systemControls': systemControls,
        'externalPlayback': externalPlayback,
        'volume': volume,
        'muted': muted,
      };

  PlaybackSettings copyWith(
          {double? speed,
          Duration? crossfade,
          bool? playOnlySelected,
          bool? preventDuplicates,
          bool? skipSilence,
          bool? systemControls,
          bool? externalPlayback,
          double? volume,
          bool? muted,
          LoudnessMode? loudness}) =>
      PlaybackSettings(
        playOnlySelected: playOnlySelected ?? this.playOnlySelected,
        preventDuplicates: preventDuplicates ?? this.preventDuplicates,
        skipSilence: skipSilence ?? this.skipSilence,
        systemControls: systemControls ?? this.systemControls,
        externalPlayback: externalPlayback ?? this.externalPlayback,
        speed: speed ?? this.speed,
        crossfade: crossfade ?? this.crossfade,
        loudness: loudness ?? this.loudness,
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
      );
}

/// Where [PlaybackSettings] are kept between launches.
abstract interface class PlaybackSettingsStore {
  Future<PlaybackSettings> read();
  Future<void> write(PlaybackSettings settings);
}

/// Keeps playback settings on this device, next to the session token.
class SecurePlaybackSettingsStore implements PlaybackSettingsStore {
  SecurePlaybackSettingsStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'nafir.playback_settings';

  final FlutterSecureStorage _storage;

  @override
  Future<PlaybackSettings> read() async {
    final raw = await _storage.read(key: _key);
    return raw == null
        ? const PlaybackSettings()
        : PlaybackSettings.fromJson(jsonDecode(raw));
  }

  @override
  Future<void> write(PlaybackSettings settings) =>
      _storage.write(key: _key, value: jsonEncode(settings.toJson()));
}

class MemoryPlaybackSettingsStore implements PlaybackSettingsStore {
  MemoryPlaybackSettingsStore([this.settings = const PlaybackSettings()]);

  PlaybackSettings settings;

  @override
  Future<PlaybackSettings> read() async => settings;

  @override
  Future<void> write(PlaybackSettings settings) async =>
      this.settings = settings;
}
