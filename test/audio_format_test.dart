import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/data/track.dart';

void main() {
  test('the quality badge reads like a music app\'s', () {
    AudioFormat? format(Map<String, dynamic> json) =>
        AudioFormat.fromJson(json);

    expect(format({'codec': 'MP3', 'bitrateKbps': 320})!.label, 'MP3 · 320');
    expect(
        format({'codec': 'FLAC', 'bitDepth': 24, 'sampleRate': 48000})!.label,
        'FLAC · 24/48');
    expect(
        format({'codec': 'FLAC', 'bitDepth': 16, 'sampleRate': 44100})!.label,
        'FLAC · 16/44.1');
    expect(format({'codec': 'Opus'})!.label, 'Opus');
    expect(format({'codec': ''}), isNull);
    expect(AudioFormat.fromJson(null), isNull);
  });

  test('tracks read their format and length from the API', () {
    final track = Track.fromJson({
      'id': 't',
      'title': 'T',
      'contentType': 'audio/flac',
      'sizeBytes': 10,
      'durationMs': 201000,
      'audio': {'codec': 'FLAC', 'bitDepth': 16, 'sampleRate': 44100},
    });
    expect(track.audio!.lossless, isTrue);
    expect(track.duration, const Duration(seconds: 201));
    final unknown = Track.fromJson(
        {'id': 'u', 'title': 'U', 'contentType': 'audio/mpeg', 'sizeBytes': 1});
    expect(unknown.audio, isNull);
    expect(unknown.duration, isNull);
  });
}
