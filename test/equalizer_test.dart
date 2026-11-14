import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/player/application/equalizer_controller.dart';
import 'package:rhythmo/features/player/data/equalizer.dart';
import 'package:rhythmo/features/player/presentation/equalizer_sheet.dart';

class _FakeEqualizerEngine implements EqualizerEngine {
  _FakeEqualizerEngine({this.supportsEqualizer = true});

  @override
  final bool supportsEqualizer;
  final applied = <EqualizerSettings>[];

  @override
  Future<void> setEqualizer(EqualizerSettings settings) async =>
      applied.add(settings);
}

void main() {
  group('EqualizerSettings', () {
    test('is off and flat by default', () {
      const settings = EqualizerSettings();
      expect(settings.active, isFalse);
      expect(settings.headroomDb, 0);
      expect(settings.gainAt(1000), 0);
    });

    test('presets give their gains and headroom', () {
      const bass =
          EqualizerSettings(enabled: true, preset: EqualizerPreset.bass);
      expect(bass.gainsDb, EqualizerPreset.bass.gainsDb);
      expect(bass.active, isTrue);
      expect(bass.headroomDb, 6);
      expect(bass.gainAt(30), 6);
      expect(bass.gainAt(20000), 0);
      // Between 60 Hz (6 dB) and 230 Hz (4 dB) on a log scale.
      final mid = bass.gainAt(117.5);
      expect(mid, greaterThan(4));
      expect(mid, lessThan(6));
    });

    test('a disabled preset changes nothing', () {
      const off = EqualizerSettings(preset: EqualizerPreset.rock);
      expect(off.active, isFalse);
      expect(off.headroomDb, 0);
    });

    test('round-trips through json and drops bad values', () {
      const custom = EqualizerSettings(
        enabled: true,
        preset: EqualizerPreset.custom,
        customGainsDb: [1, 2, 3, -4, 5],
      );
      final restored = EqualizerSettings.fromJson(custom.toJson());
      expect(restored.enabled, isTrue);
      expect(restored.preset, EqualizerPreset.custom);
      expect(restored.gainsDb, [1, 2, 3, -4, 5]);

      final bad = EqualizerSettings.fromJson({
        'enabled': true,
        'preset': 'gone',
        'custom': [99, 'x', 0, 0, 0],
      });
      expect(bad.preset, EqualizerPreset.flat);
      expect(bad.customGainsDb, [maxBandGainDb, 0, 0, 0, 0]);
      expect(EqualizerSettings.fromJson('nope').enabled, isFalse);
    });
  });

  group('EqualizerController', () {
    test('restores the saved settings and applies them', () async {
      final engine = _FakeEqualizerEngine();
      final store = MemoryEqualizerStore();
      await store.write(const EqualizerSettings(
          enabled: true, preset: EqualizerPreset.vocal));
      final controller = EqualizerController(engine, store);
      await controller.load();
      expect(controller.settings.preset, EqualizerPreset.vocal);
      expect(engine.applied.single.preset, EqualizerPreset.vocal);
    });

    test('turning on from flat starts with a heard preset', () async {
      final engine = _FakeEqualizerEngine();
      final store = MemoryEqualizerStore();
      final controller = EqualizerController(engine, store);
      await controller.setEnabled(true);
      expect(controller.settings.enabled, isTrue);
      expect(controller.settings.preset, EqualizerPreset.bass);
      expect((await store.read()).preset, EqualizerPreset.bass);
    });

    test('moving a band makes a custom preset from what was heard', () async {
      final engine = _FakeEqualizerEngine();
      final controller = EqualizerController(engine, MemoryEqualizerStore());
      await controller.setPreset(EqualizerPreset.rock);
      await controller.setBand(2, 20);
      expect(controller.settings.preset, EqualizerPreset.custom);
      expect(controller.settings.gainsDb, [5, 3, maxBandGainDb, 3, 5]);
      expect(engine.applied.last.gainsDb[2], maxBandGainDb);
    });

    test('flat turns it off', () async {
      final controller =
          EqualizerController(_FakeEqualizerEngine(), MemoryEqualizerStore());
      await controller.setPreset(EqualizerPreset.pop);
      await controller.setPreset(EqualizerPreset.flat);
      expect(controller.settings.enabled, isFalse);
      expect(controller.settings.active, isFalse);
    });

    test('does nothing to load where unsupported', () async {
      final engine = _FakeEqualizerEngine(supportsEqualizer: false);
      final controller = EqualizerController(engine, MemoryEqualizerStore());
      expect(controller.supported, isFalse);
      await controller.load();
      expect(engine.applied, isEmpty);
    });
  });

  test('labels bands and gains in Persian', () {
    expect(formatBand(60), '۶۰ هرتز');
    expect(formatBand(3600), '۳٫۶ کیلوهرتز');
    expect(formatBand(14000), '۱۴ کیلوهرتز');
    expect(formatGain(4), '+۴');
    expect(formatGain(-2.2), '−۲');
    expect(formatGain(0), '۰');
  });

  testWidgets('the sheet fits a 360 px phone and changes the sound',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = _FakeEqualizerEngine();
    final controller = EqualizerController(engine, MemoryEqualizerStore());
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(body: EqualizerSheet(equalizer: controller)),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('اکولایزر'), findsOneWidget);
    expect(find.text('۶۰'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(equalizerBands.length));

    await tester.tap(find.text('سنتی'));
    await tester.pump();
    expect(controller.settings.enabled, isTrue);
    expect(controller.settings.preset, EqualizerPreset.traditional);
    expect(engine.applied.last.preset, EqualizerPreset.traditional);
    expect(find.text('بازنشانی'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('equalizer-switch')));
    await tester.pump();
    expect(controller.settings.enabled, isFalse);
    expect(tester.takeException(), isNull);

    // Every chip and slider keeps a 48 px target.
    for (final chip in tester.widgetList(find.byType(ChoiceChip))) {
      expect(
          tester.getSize(find.byWidget(chip)).height, greaterThanOrEqualTo(48));
    }
  });
}
