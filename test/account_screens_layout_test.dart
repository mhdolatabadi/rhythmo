import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/main.dart';

import 'cache_controller_test.dart' show FakeAudioCache;
import 'player_controller_test.dart' show FakeAudioEngine;
import 'upload_controller_test.dart' show FakeTracksApi, FakeUploader;
import 'widget_test.dart' show FakeAuthApi, FakePicker;

void main() {
  for (final size in const [Size(360, 740), Size(1280, 900)]) {
    final label = '${size.width.toInt()} px';

    testWidgets('settings is a centred, capped list at $label', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RhythmoApp(
        healthCheck: () async {},
        authApi: FakeAuthApi(),
        tokenStore: MemoryTokenStore('valid-token'),
        tracksApi: FakeTracksApi(),
        audioEngine: FakeAudioEngine(),
        audioCache: FakeAudioCache(),
        uploader: FakeUploader(),
        picker: FakePicker(null),
      ));
      await tester.pumpAndSettle();

      // «حساب» in the dock is the one way to settings.
      await tester.tap(find.byTooltip('حساب'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final list = tester.getRect(find.byType(ListView).last);
      expect(list.width, lessThanOrEqualTo(RhythmoSpace.listWidth));
      expect((list.left - (size.width - list.right)).abs(), lessThan(2),
          reason: 'centred');
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
        if (tile.onTap == null) continue;
        final rect = tester.getRect(find.byWidget(tile));
        expect(rect.height, greaterThanOrEqualTo(RhythmoSpace.target));
      }
    });
  }
}
