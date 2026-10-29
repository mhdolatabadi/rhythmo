import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/identify/data/snippet_recorder.dart';
import 'package:rhythmo/features/library/data/track.dart';

enum IdentifyPhase {
  /// Explains what happens before the microphone is asked for.
  ready,

  /// No microphone here, or the browser has no `getUserMedia`.
  unsupported,

  /// The listener (or the system) said no to the microphone.
  permissionDenied,
  listening,
  searching,
  found,
  notFound,
  failed,
}

/// «این آهنگ چیه؟»: records a snippet, sends it to the server, and holds
/// the answer. The snippet is never kept: once sent, it is dropped.
class IdentifyController extends ChangeNotifier {
  IdentifyController({
    required IdentifyApi api,
    required SnippetRecorder recorder,
    required String? Function() token,
    this.onSaved,
  })  : _api = api,
        _recorder = recorder,
        _token = token;

  final IdentifyApi _api;
  final SnippetRecorder _recorder;
  final String? Function() _token;

  /// Called after a found song is added to the library.
  final Future<void> Function()? onSaved;

  IdentifyPhase _phase = IdentifyPhase.ready;
  double _level = 0;
  SongMatch? _match;
  String? _error;
  bool _saving = false;
  bool _saved = false;
  int _attempt = 0;

  IdentifyPhase get phase => _phase;

  /// Microphone loudness while listening, 0 to 1.
  double get level => _level;
  SongMatch? get match => _match;

  /// A Persian explanation of the last failure.
  String? get error => _error;
  bool get saving => _saving;

  /// Whether the found song was added to the library.
  bool get saved => _saved;

  /// Without an account, snippets are matched against the public store
  /// only, and a found song can be played but not added.
  bool get signedIn => _token() != null;

  /// Back to the explanation, for example when the screen opens again.
  void reset() {
    if (_phase == IdentifyPhase.listening) unawaited(_recorder.cancel());
    _attempt++;
    _phase = IdentifyPhase.ready;
    _match = null;
    _error = null;
    _saved = false;
    _level = 0;
    notifyListeners();
  }

  /// Asks for the microphone, listens for [snippetLength], and looks the
  /// snippet up.
  Future<void> listen() async {
    if (_phase == IdentifyPhase.listening ||
        _phase == IdentifyPhase.searching) {
      return;
    }
    final attempt = ++_attempt;
    _match = null;
    _error = null;
    _saved = false;
    if (!await _recorder.isSupported()) {
      return _set(attempt, IdentifyPhase.unsupported);
    }
    if (!await _recorder.requestPermission()) {
      return _set(attempt, IdentifyPhase.permissionDenied);
    }
    if (attempt != _attempt) return;
    _level = 0;
    _set(attempt, IdentifyPhase.listening);
    final Uint8List snippet;
    try {
      snippet = await _recorder.record(snippetLength, onLevel: (level) {
        if (attempt != _attempt) return;
        _level = level;
        notifyListeners();
      });
    } on RecordingCancelled {
      return;
    } catch (_) {
      _error = 'ضبط صدا انجام نشد. دسترسی میکروفون را بررسی کنید.';
      return _set(attempt, IdentifyPhase.failed);
    }
    if (attempt != _attempt) return;
    _set(attempt, IdentifyPhase.searching);
    try {
      final match = await _api.identifySong(_token(), snippet);
      if (attempt != _attempt) return;
      _match = match;
      _set(attempt,
          match == null ? IdentifyPhase.notFound : IdentifyPhase.found);
    } on ApiException catch (error) {
      _error = switch (error.code) {
        'snippet_too_short' ||
        'invalid_snippet' =>
          'صدای کافی ضبط نشد. نزدیک‌تر به منبع صدا دوباره امتحان کنید.',
        'rate_limited' => 'چند دقیقه دیگر دوباره امتحان کنید.',
        'identify_busy' ||
        'identify_unavailable' =>
          'شناسایی آهنگ الان در دسترس نیست. کمی بعد امتحان کنید.',
        _ => 'جستجو انجام نشد. اتصال اینترنت را بررسی کنید.',
      };
      _set(attempt, IdentifyPhase.failed);
    } catch (_) {
      _error = 'جستجو انجام نشد. اتصال اینترنت را بررسی کنید.';
      _set(attempt, IdentifyPhase.failed);
    }
  }

  /// Stops listening early and goes back to the start.
  Future<void> cancel() async {
    await _recorder.cancel();
    reset();
  }

  /// Adds the found song, from someone else's playlist, to the library.
  /// Returns the new track, or null with [error] set.
  Future<Track?> save() async {
    final match = _match;
    final token = _token();
    if (match == null || !match.canSave || token == null || _saving) {
      return null;
    }
    _saving = true;
    _error = null;
    notifyListeners();
    try {
      final track = await _api.saveIdentifiedSong(token, match);
      _saved = true;
      await onSaved?.call();
      return track;
    } on ApiException catch (error) {
      _error = switch (error.code) {
        'quota_exceeded' => 'فضای کافی در حساب شما نیست.',
        'uploads_disabled' => 'افزودن آهنگ الان ممکن نیست.',
        _ => 'آهنگ به «موسیقی من» اضافه نشد. دوباره امتحان کنید.',
      };
      return null;
    } catch (_) {
      _error = 'آهنگ به «موسیقی من» اضافه نشد. دوباره امتحان کنید.';
      return null;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  void _set(int attempt, IdentifyPhase phase) {
    if (attempt != _attempt) return;
    _phase = phase;
    notifyListeners();
  }
}
