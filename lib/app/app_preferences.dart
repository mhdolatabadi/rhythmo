import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum LibraryTab {
  tracks('آهنگ‌ها'),

  /// Music added to this device lately, newest first; Android only.
  newOnDevice('تازه‌های دستگاه'),
  playlists('فهرست‌های پخش'),
  albums('آلبوم‌ها'),
  artists('هنرمندان'),
  favorites('پسندیده‌ها');

  const LibraryTab(this.label);
  final String label;
}

class AppPreferences {
  const AppPreferences(
      {this.themeMode = ThemeMode.dark,
      this.order = LibraryTab.values,
      this.hidden = const {LibraryTab.favorites}});
  final ThemeMode themeMode;
  final List<LibraryTab> order;
  final Set<LibraryTab> hidden;
  factory AppPreferences.fromJson(Object? value) {
    if (value is! Map) {
      return const AppPreferences();
    }
    final order = <LibraryTab>[];
    if (value['tabs'] case final List tabs) {
      for (final name in tabs) {
        for (final tab in LibraryTab.values) {
          if (tab.name == name && !order.contains(tab)) {
            order.add(tab);
          }
        }
      }
    }
    for (final tab in LibraryTab.values) {
      if (!order.contains(tab)) {
        order.add(tab);
      }
    }
    final hidden = value['hidden'] is List
        ? {
            for (final tab in LibraryTab.values)
              if ((value['hidden'] as List).contains(tab.name) &&
                  tab != LibraryTab.tracks)
                tab
          }
        : const {LibraryTab.favorites};
    return AppPreferences(
        themeMode: ThemeMode.values.firstWhere(
            (mode) => mode.name == value['theme'],
            orElse: () => ThemeMode.dark),
        order: List.unmodifiable(order),
        hidden: Set.unmodifiable(hidden));
  }
  Map<String, Object> toJson() => {
        'theme': themeMode.name,
        'tabs': order.map((tab) => tab.name).toList(),
        'hidden': hidden.map((tab) => tab.name).toList()
      };
}

abstract interface class AppPreferencesStore {
  Future<AppPreferences> read();
  Future<void> write(AppPreferences value);
}

class SecureAppPreferencesStore implements AppPreferencesStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'nafir.app_preferences';
  @override
  Future<AppPreferences> read() async {
    final raw = await _storage.read(key: _key);
    return raw == null
        ? const AppPreferences()
        : AppPreferences.fromJson(jsonDecode(raw));
  }

  @override
  Future<void> write(AppPreferences value) =>
      _storage.write(key: _key, value: jsonEncode(value.toJson()));
}

class MemoryAppPreferencesStore implements AppPreferencesStore {
  AppPreferences value = const AppPreferences();
  @override
  Future<AppPreferences> read() async => value;
  @override
  Future<void> write(AppPreferences value) async => this.value = value;
}

class AppPreferencesController extends ChangeNotifier {
  AppPreferencesController({AppPreferencesStore? store})
      : _store = store ?? SecureAppPreferencesStore();
  final AppPreferencesStore _store;
  AppPreferences value = const AppPreferences();
  int _revision = 0;
  Future<void> _writes = Future.value();
  bool _disposed = false;
  Future<void> load() async {
    final revision = _revision;
    try {
      final saved = await _store.read();
      if (!_disposed && revision == _revision) {
        value = saved;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('App preferences unavailable: $error');
    }
  }

  Future<void> update(
      {ThemeMode? themeMode,
      List<LibraryTab>? order,
      Set<LibraryTab>? hidden}) {
    _revision++;
    final safe = AppPreferences.fromJson(AppPreferences(
            themeMode: themeMode ?? value.themeMode,
            order: order ?? value.order,
            hidden: hidden ?? value.hidden)
        .toJson());
    value = safe;
    notifyListeners();
    _writes =
        _writes.then((_) => _store.write(safe)).catchError((Object error) {
      debugPrint('Could not save app preferences: $error');
    });
    return _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class AppPreferencesScope extends InheritedNotifier<AppPreferencesController> {
  const AppPreferencesScope(
      {super.key,
      required AppPreferencesController controller,
      required super.child})
      : super(notifier: controller);
  static AppPreferencesController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppPreferencesScope>()
      ?.notifier;
}
