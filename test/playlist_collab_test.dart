import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/collab_sheet.dart';
import 'package:rhythmo/features/playlists/presentation/playlists_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'playlist_sharing_test.dart' show FakePlaylistsApi;
import 'upload_controller_test.dart' show FakeTracksApi;

const mine = Track(
    id: 'mine', title: 'My song', contentType: 'audio/mpeg', sizeBytes: 1);
const theirs = Track(
  id: 'theirs',
  title: 'Their song',
  contentType: 'audio/mpeg',
  sizeBytes: 1,
  addedBy: 'f***@example.com',
  viaPlaylist: 'p1',
);
const extra = Track(
    id: 'extra',
    title: 'Another of mine',
    artist: 'Example Artist · علی کوچه می خواهم ۱۲',
    contentType: 'audio/mpeg',
    sizeBytes: 1);

void main() {
  group('collaborative playlist model', () {
    test('reads members, who added each track and how to play it', () {
      final playlist = Playlist.fromJson({
        'id': 'p1',
        'name': 'together',
        'trackCount': 2,
        'isOwner': false,
        'owner': 'o***@example.com',
        'members': [
          {
            'id': 'u2',
            'name': 'm***@example.com',
            'joinedAt': '2026-01-01T00:00:00Z'
          },
        ],
        'tracks': [
          {
            'id': 'a',
            'title': 'mine',
            'contentType': 'audio/mpeg',
            'sizeBytes': 1
          },
          {
            'id': 'b',
            'title': 'theirs',
            'contentType': 'audio/mpeg',
            'sizeBytes': 1,
            'addedBy': 'o***@example.com',
          },
        ],
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-01T00:00:00Z',
      });

      expect(playlist.isOwner, isFalse);
      expect(playlist.isCollaborative, isTrue);
      expect(playlist.members.single.name, 'm***@example.com');
      expect(playlist.tracks[0].viaPlaylist, isNull);
      expect(playlist.tracks[1].viaPlaylist, 'p1');
      expect(playlist.canRemove(playlist.tracks[0]), isTrue);
      expect(playlist.canRemove(playlist.tracks[1]), isFalse);
    });

    test('uses loaded tracks when the server count is stale', () {
      final playlist = Playlist.fromJson({
        'id': 'p1',
        'name': 'mix',
        'trackCount': 0,
        'tracks': [
          {
            'id': 'a',
            'title': 'first',
            'contentType': 'audio/mpeg',
            'sizeBytes': 1
          },
          {
            'id': 'b',
            'title': 'second',
            'contentType': 'audio/mpeg',
            'sizeBytes': 1
          },
        ],
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-01T00:00:00Z',
      });

      expect(playlist.displayTrackCount, 2);
    });

    test('an older server response means the user owns it', () {
      final playlist = Playlist.fromJson({
        'id': 'p1',
        'name': 'mine',
        'trackCount': 0,
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-01T00:00:00Z',
      });
      expect(playlist.isOwner, isTrue);
      expect(playlist.isCollaborative, isFalse);
    });

    test('invite links are told apart from share links', () {
      final token = 'C' * 22;
      final link =
          collabPlaylistLink(Uri.parse('https://rhythmo.example.com'), token);
      expect(link.toString(), 'https://rhythmo.example.com/app/?collab=$token');
      expect(collabTokenFrom(link.toString()), token);
      expect(collabTokenFrom('https://rhythmo.example.com/app/?shared=$token'),
          isNull);
      expect(collabTokenFrom('https://rhythmo.example.com/app/?collab=short'),
          isNull);
    });
  });

  test('another member\'s track plays through the playlist', () async {
    final tracks = FakeTracksApi();
    final player = PlayerController(
        api: tracks, engine: FakeAudioEngine(), token: () => 'tok');
    await player.playFrom([mine, theirs], 1);
    expect(tracks.calls, contains('playlist:p1:theirs'));
  });

  group('playlists controller', () {
    test('an edited track shows its new metadata in loaded playlists', () {
      final controller =
          PlaylistsController(api: FakePlaylistsApi(), token: () => 'tok');
      const song = Track(
          id: 's1', title: 'Old', contentType: 'audio/mpeg', sizeBytes: 1);
      controller.playlists = [
        Playlist(
          id: 'p1',
          name: 'With it',
          trackCount: 1,
          tracks: const [song],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        Playlist(
          id: 'p2',
          name: 'Not loaded',
          trackCount: 7,
          tracks: const [],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];
      var notified = 0;
      controller.addListener(() => notified++);

      controller.updateTrack(const Track(
          id: 's1', title: 'New', contentType: 'audio/mpeg', sizeBytes: 1));

      expect(controller.playlists.first.tracks.single.title, 'New');
      // A playlist whose tracks are not loaded keeps its count.
      expect(controller.playlists.last.trackCount, 7);
      expect(notified, 1);
    });

    test('joining a wrong link says it is unavailable; leaving drops it',
        () async {
      final api = FakePlaylistsApi()..collabToken = 'C' * 22;
      final controller = PlaylistsController(api: api, token: () => 'tok');

      expect(() => controller.join('D' * 22),
          throwsA(isA<SharedPlaylistUnavailable>()));
      final joined = await controller.join('C' * 22);
      expect(joined.isOwner, isFalse);
      expect(api.joined, ['C' * 22]);

      await controller.load();
      expect(controller.playlists, hasLength(1));
      expect(await controller.leave('p1'), isTrue);
      expect(api.left, isTrue);
      expect(controller.playlists, isEmpty);
    });
  });

  Future<FakePlaylistsApi> pumpDetail(WidgetTester tester, FakePlaylistsApi api,
      {List<Track> library = const [mine, extra]}) async {
    await tester.pumpWidget(MaterialApp(
      home: PlaylistDetailScreen(
        playlistId: 'p1',
        controller: PlaylistsController(api: api, token: () => 'tok'),
        libraryTracks: library,
        player: PlayerController(
            api: FakeTracksApi(),
            engine: FakeAudioEngine(),
            token: () => 'tok'),
      ),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('a member adds and removes only their own tracks',
      (tester) async {
    final api = await pumpDetail(
        tester,
        FakePlaylistsApi()
          ..isOwner = false
          ..tracks = [theirs, mine]);

    // The owner's controls are gone; leaving is offered instead.
    expect(find.byTooltip('دعوت دوستان و مدیریت اعضا'), findsNothing);
    expect(find.byTooltip('اشتراک‌گذاری'), findsNothing);
    await tester.tap(find.byTooltip('گزینه‌های فهرست پخش'));
    await tester.pumpAndSettle();
    expect(find.text('تغییر نام'), findsNothing);
    expect(find.text('حذف فهرست پخش'), findsNothing);
    expect(find.text('ترک فهرست پخش'), findsOneWidget);
    await tester.tapAt(const Offset(4, 300));
    await tester.pumpAndSettle();
    expect(find.textContaining('از o***@example.com'), findsOneWidget);
    expect(find.text('خواننده نامشخص · افزوده‌ی f***@example.com'),
        findsOneWidget);
    // Only their own track can be taken out.
    expect(find.byTooltip('حذف از فهرست پخش'), findsOneWidget);

    // Picking tracks keeps the ones others added.
    await tester.tap(find.text('مدیریت آهنگ‌ها'));
    await tester.pumpAndSettle();
    final picker = find.byType(AlertDialog);
    Finder pickerText(String text) =>
        find.descendant(of: picker, matching: find.text(text));
    expect(pickerText('۱ آهنگ انتخاب شده'), findsOneWidget);
    final search = find.widgetWithText(TextField, 'جست‌وجوی عنوان یا هنرمند');
    await tester.enterText(search, 'example artist');
    await tester.pump();
    expect(pickerText('Another of mine'), findsOneWidget);
    await tester.enterText(search, 'علي كُوچه میخواهم ١٢');
    await tester.pump();
    expect(pickerText('Another of mine'), findsOneWidget);
    expect(pickerText('My song'), findsNothing);
    await tester.enterText(search, 'ANOTHER');
    await tester.pump();
    expect(pickerText('My song'), findsNothing);
    await tester.tap(pickerText('Another of mine'));
    await tester.pump();
    expect(pickerText('۲ آهنگ انتخاب شده'), findsOneWidget);
    await tester.enterText(search, 'no matching song');
    await tester.pump();
    expect(pickerText('آهنگی با این جست‌وجو پیدا نشد.'), findsOneWidget);
    await tester.enterText(search, '');
    await tester.pump();
    expect(pickerText('My song'), findsOneWidget);
    expect(pickerText('۲ آهنگ انتخاب شده'), findsOneWidget);
    await tester.tap(find.text('ذخیره'));
    await tester.pumpAndSettle();
    expect(api.replacedWith, ['theirs', 'mine', 'extra']);

    expect(find.byTooltip('حذف از فهرست پخش'), findsNWidgets(2));
    await tester.tap(find.byTooltip('حذف از فهرست پخش').first);
    await tester.pumpAndSettle();
    expect(api.replacedWith, ['theirs', 'extra']);

    await tester.tap(find.byTooltip('گزینه‌های فهرست پخش'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ترک فهرست پخش'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'ترک'));
    await tester.pumpAndSettle();
    expect(api.left, isTrue);
  });

  testWidgets('the owner invites people and removes a member', (tester) async {
    final api = FakePlaylistsApi()
      ..members = [const PlaylistMember(id: 'u2', name: 'm***@example.com')]
      ..tracks = [mine, theirs];
    final controller = PlaylistsController(api: api, token: () => 'tok');
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showCollabSheet(context,
                playlist: api.playlist, controller: controller),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('اعضا (۱)'), findsOneWidget);
    await tester.tap(find.text('ساخت لینک دعوت'));
    await tester.pumpAndSettle();
    expect(find.text('${'C' * 21}1'), findsOneWidget);

    // A new link replaces the old one.
    await tester.tap(find.text('لینک تازه'));
    await tester.pumpAndSettle();
    expect(find.text('${'C' * 21}2'), findsOneWidget);

    await tester.tap(find.byTooltip('حذف عضو'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();
    expect(api.removedMembers, ['u2']);
    expect(find.text('هنوز کسی عضو نشده.'), findsOneWidget);

    await tester.tap(find.text('باطل کردن لینک'));
    await tester.pumpAndSettle();
    expect(api.collabToken, isNull);
    expect(find.text('ساخت لینک دعوت'), findsOneWidget);
  });

  testWidgets('collaboration fits a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final long = 'someone.with.a.very.long.address' * 2;
    await pumpDetail(
        tester,
        FakePlaylistsApi()
          ..collabToken = 'C' * 22
          ..members = [PlaylistMember(id: 'u2', name: '$long@example.com')]
          ..tracks = [
            mine,
            Track(
              id: 'long',
              title: 'یک آهنگ با اسمی بسیار طولانی که نباید بیرون بزند ' * 2,
              contentType: 'audio/mpeg',
              sizeBytes: 1,
              addedBy: '$long@example.com',
              viaPlaylist: 'p1',
            ),
          ]);
    expect(tester.takeException(), isNull);
    for (final tooltip in [
      'گزینه‌های فهرست پخش',
      'پخش تصادفی',
      'دعوت دوستان و مدیریت اعضا',
      'اشتراک‌گذاری',
      'حذف از فهرست پخش',
      'برای جابه‌جایی بکش',
    ]) {
      final button = find.ancestor(
          of: find.byTooltip(tooltip), matching: find.byType(IconButton));
      final rect = tester.getRect(button.evaluate().isEmpty
          ? find.byTooltip(tooltip).first
          : button.first);
      expect(rect.width, greaterThanOrEqualTo(48), reason: tooltip);
      expect(rect.height, greaterThanOrEqualTo(48), reason: tooltip);
      expect(rect.left, greaterThanOrEqualTo(0), reason: tooltip);
      expect(rect.right, lessThanOrEqualTo(360), reason: tooltip);
    }
    // The add action sits in the list's heading, clear of the screen edge,
    // and nothing floats over the tracks.
    final add = tester.getRect(find.ancestor(
        of: find.text('مدیریت آهنگ‌ها'), matching: find.byType(FilledButton)));
    expect(add.left, greaterThanOrEqualTo(16));
    expect(add.right, lessThanOrEqualTo(360 - 16));
    expect(find.byType(FloatingActionButton), findsNothing);

    await tester.tap(find.text('مدیریت آهنگ‌ها'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final dialog = tester.getRect(find.byType(AlertDialog));
    expect(dialog.left, greaterThanOrEqualTo(0));
    expect(dialog.right, lessThanOrEqualTo(360));
    await tester.tap(find.text('انصراف'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('دعوت دوستان و مدیریت اعضا'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final remove = tester.getRect(find
        .ancestor(
            of: find.byTooltip('حذف عضو'), matching: find.byType(IconButton))
        .first);
    expect(remove.width, greaterThanOrEqualTo(48));
    expect(remove.left, greaterThanOrEqualTo(0));
    expect(remove.right, lessThanOrEqualTo(360));
  });

  testWidgets('the owner\'s page is centred on desktop and reorders in place',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api =
        await pumpDetail(tester, FakePlaylistsApi()..tracks = [mine, extra]);
    expect(tester.takeException(), isNull);

    // One centred column: equal room on both sides, never past 960 px.
    final add = tester.getRect(find.ancestor(
        of: find.text('مدیریت آهنگ‌ها'), matching: find.byType(FilledButton)));
    final row = tester.getRect(find.ancestor(
        of: find.text('My song'), matching: find.byType(InkWell)));
    expect(row.width, lessThanOrEqualTo(960));
    expect((row.left - (1600 - row.right)).abs(), lessThan(1));
    expect(add.left, greaterThanOrEqualTo(row.left));

    // Rename and delete live in the page's menu.
    await tester.tap(find.byTooltip('گزینه‌های فهرست پخش'));
    await tester.pumpAndSettle();
    expect(find.text('تغییر نام'), findsOneWidget);
    expect(find.text('حذف فهرست پخش'), findsOneWidget);
    expect(find.text('ترک فهرست پخش'), findsNothing);
    await tester.tapAt(const Offset(4, 500));
    await tester.pumpAndSettle();

    // Dragging the handle moves a track and keeps the page on screen.
    final handle = find.byTooltip('برای جابه‌جایی بکش');
    final gesture = await tester.startGesture(tester.getCenter(handle.first));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(api.replacedWith, ['extra', 'mine']);
    expect(find.text('My song'), findsOneWidget);
  });
}
