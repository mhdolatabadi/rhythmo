import 'dart:async';

import 'package:flutter/foundation.dart';

/// How long to wait between checks while the server can't be reached:
/// soon at first, then every half minute.
const networkProbeDelays = [
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 30),
];

/// Whether the rhythmo server can be reached right now, as the app's own
/// requests find it. While it can't, the app keeps working from what it
/// saved on this device, checks again now and then, and tells listeners
/// once the server answers again so they can catch up.
class NetworkStatus extends ChangeNotifier {
  NetworkStatus({
    Future<void> Function()? probe,
    void Function() Function(Duration delay, void Function() callback)?
        schedule,
  })  : _probe = probe,
        _schedule = schedule ?? _timer;

  static void Function() _timer(Duration delay, void Function() callback) =>
      Timer(delay, callback).cancel;

  final Future<void> Function()? _probe;
  final void Function() Function(Duration, void Function()) _schedule;

  bool _online = true;
  int _step = 0;
  void Function()? _cancelProbe;
  bool _disposed = false;

  /// False while requests to the server fail for lack of a connection.
  bool get online => _online;

  /// A request reached the server.
  void reportSuccess() {
    _cancelProbe?.call();
    _cancelProbe = null;
    _step = 0;
    if (_online || _disposed) return;
    _online = true;
    notifyListeners();
  }

  /// A request could not reach the server: no connection, a timeout, or
  /// the server is down.
  void reportFailure() {
    if (_disposed) return;
    final changed = _online;
    _online = false;
    _planProbe();
    if (changed) notifyListeners();
  }

  /// Checks the server now, for example when the listener asks to retry.
  Future<bool> check() async {
    final probe = _probe;
    if (probe == null) return _online;
    try {
      await probe();
      reportSuccess();
    } catch (_) {
      reportFailure();
    }
    return _online;
  }

  void _planProbe() {
    if (_probe == null || _cancelProbe != null) return;
    final delay =
        networkProbeDelays[_step.clamp(0, networkProbeDelays.length - 1)];
    _step++;
    _cancelProbe = _schedule(delay, () {
      _cancelProbe = null;
      if (_disposed || _online) return;
      unawaited(check());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelProbe?.call();
    _cancelProbe = null;
    super.dispose();
  }
}
