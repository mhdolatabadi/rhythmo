// Renders the store and README screenshots from the real app with seeded
// demo data (no real users), so they can be refreshed after any UI change.
//
// Skipped in normal test runs. Regenerate with (see store/README.md):
//
//   flutter test test/screenshots/app_screenshots_test.dart \
//     --dart-define=SCREENSHOTS=true
//
// Phone shots go to store/tools/raw (framed by store/tools/frames.js),
// desktop shots to docs/screenshots. --dart-define=SIZE=phone|desktop
// limits the run to one of them.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/offline/response_cache.dart';
import 'package:rhythmo/app/app_preferences.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/presentation/mini_player.dart';
import 'package:rhythmo/main.dart';

import '../cache_controller_test.dart' show FakeAudioCache;
import '../player_controller_test.dart' show FakeAudioEngine;
import '../playlist_sharing_test.dart' show FakePlaylistsApi, listed;
import '../store_test.dart' show FakeStoreApi;
import '../upload_controller_test.dart' show FakeTracksApi, FakeUploader;
import '../widget_test.dart' show FakeAuthApi, FakePicker;

const _enabled = bool.fromEnvironment('SCREENSHOTS');
const _only = String.fromEnvironment('SIZE');

/// Wraps the whole app, so pushed routes (now playing) are captured too.
final _shotKey = GlobalKey();

/// Seeded demo library: made-up Persian and Latin titles, no real users.
const _demo = [
  ('باران پاییزی', 'گروه نسیم', 'شب‌های شهر'),
  ('کوچهٔ آشتی', 'سارا مهر', 'کوچه'),
  ('Night Drive', 'Lumen', 'Neon Roads'),
  ('ماه پشت ابر', 'گروه نسیم', 'شب‌های شهر'),
  ('دریا', 'آرش راد', null),
  ('Morning Light', 'Aster', 'Fields'),
  ('سه‌تار و باد', 'نوا', 'سکوت'),
  ('چراغ‌های دور', 'سارا مهر', 'کوچه'),
  ('Echoes', 'Lumen', 'Neon Roads'),
  ('خانهٔ قدیمی', 'آرش راد', null),
  ('نیمه‌شب', 'نوا', 'سکوت'),
  ('Slow Tide', 'Aster', 'Fields'),
];

List<Track> _tracks() => [
      for (final (i, (title, artist, album)) in _demo.indexed)
        Track(
          id: 'demo-$i',
          title: title,
          artist: artist,
          album: album,
          contentType: 'audio/mpeg',
          sizeBytes: (3 + i % 5) * 1024 * 1024,
          fileName: 'demo-$i.mp3',
          addedAt: DateTime.utc(2026, 11, 1 + i),
        ),
    ];

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = File('assets/fonts/$file').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  await load('Vazirmatn', [
    'Vazirmatn-Regular.ttf',
    'Vazirmatn-Medium.ttf',
    'Vazirmatn-Bold.ttf',
  ]);
  await load('Phosphor', ['Phosphor.ttf']);
  await load('PhosphorFill', ['Phosphor-Fill.ttf']);
  // A few Material icons are still used (checks, the edit pencil).
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final material = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (flutterRoot != null && material.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(material.readAsBytesSync())));
    await loader.load();
  }
}

Future<void> _pump(WidgetTester tester, Size logical, double ratio,
    {bool guest = false}) async {
  tester.view.physicalSize = logical * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  final playlists = FakePlaylistsApi()
    ..tracks = _tracks().take(5).toList()
    ..public = [
      listed('شب‌های شهر', likes: 42, shareToken: 'demo-a'),
      listed('جاده', likes: 17, shareToken: 'demo-b'),
      listed('Focus', likes: 9, shareToken: 'demo-c'),
    ];
  await tester.pumpWidget(RepaintBoundary(
      key: _shotKey,
      child: RhythmoApp(
        healthCheck: () async {},
        offlineCache: MemoryResponseCache(),
        appPreferencesStore: MemoryAppPreferencesStore(),
        authApi: FakeAuthApi(),
        tokenStore: MemoryTokenStore(guest ? null : 'valid-token'),
        tracksApi: FakeTracksApi(_tracks()),
        audioEngine: FakeAudioEngine(),
        audioCache: FakeAudioCache(),
        playlistsApi: playlists,
        storeApi: FakeStoreApi(songs: _tracks()),
        uploader: FakeUploader(),
        picker: FakePicker(null),
      )));
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String out, String name) async {
  // Spinners never settle; give loads a moment instead.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  final image = await tester.runAsync(() async {
    final raw =
        await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    final png = await raw.toByteData(format: ui.ImageByteFormat.png);
    raw.dispose();
    return png!;
  });
  final file = File('$out/$name.png')..createSync(recursive: true);
  file.writeAsBytesSync(image!.buffer.asUint8List());
}

/// Taps the control with [tooltip] and waits for the screen to settle.
Future<void> _go(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip).first);
  await tester.pumpAndSettle();
}

/// One screen: how to reach it from a fresh app.
typedef _Scene = (String name, bool guest, Future<void> Function(WidgetTester));

Future<void> _openNowPlaying(WidgetTester tester) async {
  await tester.tap(find.text('Slow Tide').first);
  await tester.pumpAndSettle();
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(
      of: find.byType(MiniPlayer), matching: find.text('Slow Tide')));
  await tester.pumpAndSettle();
}

final List<_Scene> _phoneScenes = [
  ('01-library', false, (_) async {}),
  ('02-now-playing', false, _openNowPlaying),
  ('03-playlists', false, (t) => t.tap(find.text('فهرست‌ها').first)),
  (
    '04-playlist',
    false,
    (t) async {
      await t.tap(find.text('فهرست‌ها').first);
      await t.pumpAndSettle();
      await t.tap(find.text('mix').first);
    }
  ),
  ('05-search', false, (t) => _go(t, 'جست‌وجو')),
  ('06-guest', true, (_) async {}),
  ('07-ganjineh', true, (t) => _go(t, 'گنجینه')),
];

final List<_Scene> _desktopScenes = [
  ('desktop-my-music', false, (_) async {}),
  (
    'desktop-playing',
    false,
    (t) async {
      await t.tap(find.text('Slow Tide').first);
    }
  ),
  ('desktop-search', false, (t) => _go(t, 'جست‌وجو')),
  ('desktop-home', false, (t) => _go(t, 'خانه')),
];

void main() {
  setUpAll(_loadFonts);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // A common Android phone (412×915 at 2.625×), framed to 1080×1920 for
  // Bazaar; README shots are a 1440×900 browser window.
  final runs = [
    if (_only.isEmpty || _only == 'phone')
      ('store/tools/raw', const Size(412, 915), 2.625, _phoneScenes),
    if (_only.isEmpty || _only == 'desktop')
      ('docs/screenshots', const Size(1440, 900), 1.0, _desktopScenes),
  ];

  for (final (out, logical, ratio, scenes) in runs) {
    for (final (name, guest, reach) in scenes) {
      testWidgets(name, (tester) async {
        await _pump(tester, logical, ratio, guest: guest);
        await reach(tester);
        await _capture(tester, out, name);
      }, skip: !_enabled);
    }
  }
}
