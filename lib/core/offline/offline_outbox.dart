import 'dart:async';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/offline/response_cache.dart';

/// Whether [error] means the server could not be reached, rather than that
/// it refused: no connection, a timeout, or a proxy answering for it.
bool isUnreachable(Object error) =>
    error is http.ClientException ||
    error is TimeoutException ||
    (error is ApiException && const {502, 503, 504}.contains(error.statusCode));

/// Changes the listener made while offline, kept on the device until the
/// server can take them: likes, and songs added to or arranged in their
/// playlists. Each is a small JSON map with a `kind`; a newer change to the
/// same thing replaces the older one, so only the last state is sent.
class OfflineOutbox extends ChangeNotifier {
  OfflineOutbox(
      {required ResponseCache store, required String? Function() account})
      : _store = store,
        _account = account;

  final ResponseCache _store;
  final String? Function() _account;

  final Map<String, List<Map<String, Object?>>> _pending = {};
  bool _flushing = false;

  String _key(String account) => 'outbox|$account';

  /// The changes waiting for the signed-in account, oldest first.
  Future<List<Map<String, Object?>>> pending() async {
    final account = _account();
    if (account == null) return const [];
    return List.unmodifiable(await _load(account));
  }

  Future<List<Map<String, Object?>>> _load(String account) async {
    final known = _pending[account];
    if (known != null) return known;
    final list = <Map<String, Object?>>[];
    try {
      final raw = await _store.read(_key(account));
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map && item['kind'] is String) {
            list.add(item.cast<String, Object?>());
          }
        }
      }
    } catch (error) {
      debugPrint('Offline changes unreadable: $error');
    }
    return _pending[account] = list;
  }

  /// Keeps [action] to send later. An earlier change with the same `key`
  /// is dropped: the newer one says where it should end up.
  Future<void> add(Map<String, Object?> action) async {
    final account = _account();
    if (account == null) return;
    final list = await _load(account);
    final key = action['key'];
    if (key != null) list.removeWhere((item) => item['key'] == key);
    list.add(action);
    await _save(account);
    notifyListeners();
  }

  Future<void> _save(String account) =>
      _store.write(_key(account), jsonEncode(_pending[account] ?? const []));

  /// Sends the waiting changes in order through [run]. One the server
  /// can't take (gone, forbidden) is dropped; when the server can't be
  /// reached the rest wait for the next try.
  Future<void> flush(
      Future<void> Function(Map<String, Object?> action) run) async {
    final account = _account();
    if (account == null || _flushing) return;
    _flushing = true;
    try {
      final list = await _load(account);
      while (list.isNotEmpty && _account() == account) {
        final action = list.first;
        try {
          await run(action);
        } catch (error) {
          if (isUnreachable(error)) break;
          debugPrint('Dropped an offline change: $error');
        }
        list.remove(action);
        await _save(account);
      }
    } finally {
      _flushing = false;
      notifyListeners();
    }
  }
}
