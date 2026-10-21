import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device metadata belongs to the local media URI, independently of accounts.
abstract interface class LocalTrackMetadataStore {
  Future<Map<String, Map<String, dynamic>>> read();
  Future<void> write(Map<String, Map<String, dynamic>> metadata);
}

class SecureLocalTrackMetadataStore implements LocalTrackMetadataStore {
  SecureLocalTrackMetadataStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'rhythmo.local_track_metadata';

  @override
  Future<Map<String, Map<String, dynamic>>> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return {};
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return data.map(
        (key, value) => MapEntry(key, Map<String, dynamic>.from(value as Map)));
  }

  @override
  Future<void> write(Map<String, Map<String, dynamic>> metadata) =>
      _storage.write(key: _key, value: jsonEncode(metadata));
}

class MemoryLocalTrackMetadataStore implements LocalTrackMetadataStore {
  Map<String, Map<String, dynamic>> metadata = {};

  @override
  Future<Map<String, Map<String, dynamic>>> read() async => Map.from(metadata);

  @override
  Future<void> write(Map<String, Map<String, dynamic>> metadata) async {
    this.metadata = Map.from(metadata);
  }
}
