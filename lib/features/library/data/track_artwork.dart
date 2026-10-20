import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/features/library/data/track.dart';

typedef ArtworkLoader = Future<Uint8List?> Function(Track track);

/// One bounded cache shared by rows, player and system media controls.
class TrackArtworkController extends ChangeNotifier {
  TrackArtworkController(this.loader);

  final ArtworkLoader loader;
  final _pending = <String, Future<Uint8List?>>{};
  final _active = <Future<void>>[];
  int generation = 0;
  bool _disposed = false;

  String keyFor(Track track) =>
      '${track.id}:${track.version}:${track.sourceUri}:${track.fromStore}:${track.sharedVia}:${track.viaPlaylist}';

  Future<Uint8List?> load(Track track) {
    final key = keyFor(track);
    return _pending.putIfAbsent(key, () {
      while (_pending.length >= 96) {
        _pending.remove(_pending.keys.first);
      }
      return _load(track);
    });
  }

  Future<Uint8List?> _load(Track track) async {
    while (_active.length >= 4) {
      await Future.any(_active);
    }
    final done = Completer<void>();
    _active.add(done.future);
    try {
      final bytes = await loader(track);
      return bytes != null && bytes.length <= 512 * 1024 ? bytes : null;
    } catch (_) {
      // Missing, unreadable and temporarily unavailable covers keep the
      // existing placeholder; they never interrupt audio playback.
      return null;
    } finally {
      _active.remove(done.future);
      done.complete();
    }
  }

  void clear() {
    _pending.clear();
    generation++;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static Future<Uint8List?> local(Track track) async {
    if (track.sourceUri == null) return null;
    const channel = MethodChannel('ir.mhdolatabadi.nafir/local_audio');
    return channel.invokeMethod<Uint8List>(
      'readArtwork',
      {'uri': track.sourceUri.toString()},
    );
  }
}

class TrackArtworkScope extends InheritedNotifier<TrackArtworkController> {
  const TrackArtworkScope({
    super.key,
    required TrackArtworkController controller,
    required super.child,
  }) : super(notifier: controller);

  static TrackArtworkController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TrackArtworkScope>()?.notifier;
}

/// Preserves the existing dimensions, decoration and accessibility fallback.
class TrackCover extends StatelessWidget {
  const TrackCover({
    super.key,
    required this.track,
    required this.child,
    this.radius = 12,
  });

  final Track track;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final controller = TrackArtworkScope.maybeOf(context);
    if (controller == null) return child;
    return FutureBuilder<Uint8List?>(
      key: ValueKey((controller.keyFor(track), controller.generation)),
      future: controller.load(track),
      builder: (context, snapshot) {
        final bytes = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        if (bytes == null) return child;
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox.expand(
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, __, ___) => child,
            ),
          ),
        );
      },
    );
  }
}
