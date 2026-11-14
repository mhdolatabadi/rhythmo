import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/data/track_metadata.dart';
import 'package:rhythmo/features/library/presentation/track_metadata_editor.dart';

const _track = Track(
  id: 't1',
  title: 'آهنگ',
  contentType: 'audio/mpeg',
  sizeBytes: 1000,
  fileName: 'song.mp3',
  version: 3,
);

Future<void> _open(
  WidgetTester tester, {
  required ChangeTrackCover onChangeCover,
  required PickCoverImage pickCover,
  required List<int> savedVersions,
  Track track = _track,
}) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('fa'),
    supportedLocales: const [Locale('fa')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: RhythmoTheme.dark(),
    home: TrackMetadataEditor(
      track: track,
      onSave: (draft, version) async {
        savedVersions.add(version);
        return MetadataSaved(track);
      },
      onChangeCover: onChangeCover,
      pickCover: pickCover,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  final image = Uint8List.fromList([1, 2, 3]);

  testWidgets('choosing a cover sends it and the next save builds on it',
      (tester) async {
    final sent = <(Uint8List, int)>[];
    final saved = <int>[];
    await _open(
      tester,
      pickCover: () async => image,
      onChangeCover: (bytes, version) async {
        sent.add((bytes, version));
        return MetadataSaved(Track(
          id: 't1',
          title: 'آهنگ',
          contentType: 'audio/mpeg',
          sizeBytes: 1000,
          fileName: 'song.mp3',
          version: version + 1,
        ));
      },
      savedVersions: saved,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('کاور'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('changeCover')));
    await tester.pumpAndSettle();
    expect(sent.single.$1, image);
    expect(sent.single.$2, 3);
    expect(find.text('کاور ذخیره شد.'), findsOneWidget);

    // A later field edit is based on the version the cover produced.
    await tester.enterText(
        find.descendant(
            of: find.byKey(const ValueKey('title')),
            matching: find.byType(EditableText)),
        'تازه');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save')));
    await tester.pumpAndSettle();
    expect(saved, [4]);
  });

  testWidgets('a cancelled pick sends nothing; a bad image says why',
      (tester) async {
    var picks = 0;
    final sent = <int>[];
    await _open(
      tester,
      pickCover: () async => picks++ == 0 ? null : image,
      onChangeCover: (bytes, version) async {
        sent.add(version);
        return const MetadataInvalid('invalid_image');
      },
      savedVersions: [],
    );
    await tester.tap(find.byKey(const ValueKey('changeCover')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    await tester.tap(find.byKey(const ValueKey('changeCover')));
    await tester.pumpAndSettle();
    expect(sent, [3]);
    expect(find.textContaining('قابل استفاده نیست'), findsOneWidget);
  });

  testWidgets('files on the device have no cover row', (tester) async {
    await _open(
      tester,
      track: const Track(
        id: 'device:1',
        title: 'آهنگ',
        contentType: 'audio/mpeg',
        sizeBytes: 1000,
        fileName: 'song.mp3',
        version: 1,
      ),
      pickCover: () async => image,
      onChangeCover: (_, __) async => const MetadataSaveFailed(),
      savedVersions: [],
    );
    expect(find.byKey(const ValueKey('changeCover')), findsNothing);
  });
}
