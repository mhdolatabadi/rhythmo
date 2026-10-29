import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/notifications/application/notifications_controller.dart';
import 'package:rhythmo/features/notifications/data/notifications.dart';
import 'package:rhythmo/features/notifications/presentation/notifications_screen.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/collab_sheet.dart';
import 'package:rhythmo/features/playlists/presentation/shared_playlist_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'playlist_sharing_test.dart' show FakePlaylistsApi, token;
import 'playlist_subscriptions_test.dart' show FakeNotificationsApi;
import 'upload_controller_test.dart' show FakeTracksApi;

void main() {
  test('reads a channel admin, its description and a muted subscription', () {
    final playlist = Playlist.fromJson({
      'id': 'p1',
      'name': 'golden',
      'description': 'best of the 70s',
      'trackCount': 1,
      'isOwner': false,
      'isAdmin': true,
      'members': [
        {'id': 'u2', 'name': 'a***@example.com', 'role': 'admin'},
        {'id': 'u3', 'name': 'm***@example.com', 'role': 'member'},
      ],
      'tracks': [
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
    expect(playlist.canManage, isTrue);
    expect(playlist.description, 'best of the 70s');
    expect(playlist.members.map((m) => m.isAdmin), [true, false]);
    // An admin may take out anyone's track.
    expect(playlist.canRemove(playlist.tracks.single), isTrue);

    final shared = SharedPlaylist.fromJson(token, {
      'name': 'golden',
      'description': 'best of the 70s',
      'owner': 'o',
      'subscribed': true,
      'subscriberCount': 3,
      'muted': true,
      'tracks': <dynamic>[],
    });
    expect(shared.description, 'best of the 70s');
    expect(
        shared.subscription,
        const PlaylistSubscription(
            subscribed: true, subscriberCount: 3, muted: true));
  });

  test('the API client speaks the channel endpoints', () async {
    final requests = <String>[];
    final client = ApiClient(Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
      requests.add('${request.method} ${request.url.path} ${request.body}');
      if (request.url.path.endsWith('/role')) return http.Response('', 204);
      final body = request.url.path.endsWith('/mute')
          ? {
              'subscribed': true,
              'subscriberCount': 2,
              'muted': request.method == 'PUT'
            }
          : {
              'id': 'p1',
              'name': 'golden',
              'description': 'bio',
              'trackCount': 0,
              'createdAt': '2026-01-01T00:00:00Z',
              'updatedAt': '2026-01-01T00:00:00Z',
            };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));

    expect((await client.setPlaylistMuted('tok', token, true)).muted, isTrue);
    expect((await client.setPlaylistMuted('tok', token, false)).muted, isFalse);
    await client.setPlaylistMemberAdmin('tok', 'p1', 'u2', true);
    expect(
        (await client.renamePlaylist('tok', 'p1', 'golden', description: 'bio'))
            .description,
        'bio');
    await client.renamePlaylist('tok', 'p1', 'golden');
    expect(requests, [
      'PUT /api/v1/shared-playlists/$token/subscription/mute ',
      'DELETE /api/v1/shared-playlists/$token/subscription/mute ',
      'PUT /api/v1/playlists/p1/members/u2/role {"role":"admin"}',
      'PUT /api/v1/playlists/p1 {"name":"golden","description":"bio"}',
      'PUT /api/v1/playlists/p1 {"name":"golden"}',
    ]);
  });

  testWidgets('a subscriber mutes and unmutes a channel', (tester) async {
    final subscriptions = FakeNotificationsApi()..subscribers[token] = {'me'};
    final api = FakePlaylistsApi()
      ..shared[token] = SharedPlaylist.fromJson(token, {
        'name': 'Channel mix',
        'description': 'Songs for the road',
        'owner': 'f***@example.com',
        'public': true,
        'subscribed': true,
        'subscriberCount': 1,
        'tracks': <dynamic>[],
      });
    await tester.pumpWidget(MaterialApp(
      home: SharedPlaylistScreen(
        shareToken: token,
        controller: PlaylistsController(
            api: api, subscriptions: subscriptions, token: () => 'tok'),
        player: PlayerController(
            api: FakeTracksApi(),
            engine: FakeAudioEngine(),
            token: () => 'tok'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Songs for the road'), findsOneWidget);

    await tester.tap(find.byTooltip('بی‌صدا کردن اعلان‌ها'));
    await tester.pumpAndSettle();
    expect(subscriptions.muted, {token});
    expect(find.byTooltip('صدادار کردن اعلان‌ها'), findsOneWidget);
    expect(find.textContaining('بی‌صدا شد'), findsOneWidget);

    await tester.tap(find.byTooltip('صدادار کردن اعلان‌ها'));
    await tester.pumpAndSettle();
    expect(subscriptions.muted, isEmpty);
    expect(find.byTooltip('بی‌صدا کردن اعلان‌ها'), findsOneWidget);
  });

  testWidgets('a channel nobody subscribed to has no mute button',
      (tester) async {
    final api = FakePlaylistsApi()
      ..shared[token] = SharedPlaylist.fromJson(token, {
        'name': 'Channel mix',
        'owner': 'f***@example.com',
        'public': true,
        'subscribed': false,
        'subscriberCount': 0,
        'tracks': <dynamic>[],
      });
    await tester.pumpWidget(MaterialApp(
      home: SharedPlaylistScreen(
        shareToken: token,
        controller: PlaylistsController(
            api: api,
            subscriptions: FakeNotificationsApi(),
            token: () => 'tok'),
        player: PlayerController(
            api: FakeTracksApi(),
            engine: FakeAudioEngine(),
            token: () => 'tok'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistMuteButton), findsNothing);
  });

  Future<void> openSheet(WidgetTester tester, FakePlaylistsApi api) async {
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
  }

  testWidgets('the owner makes a member an admin and takes it back',
      (tester) async {
    final api = FakePlaylistsApi()
      ..members = [const PlaylistMember(id: 'u2', name: 'm***@example.com')];
    await openSheet(tester, api);

    await tester.tap(find.byTooltip('ادمین کردن'));
    await tester.pumpAndSettle();
    expect(api.adminChanges, [('u2', true)]);
    expect(find.text('ادمین'), findsOneWidget);

    await tester.tap(find.byTooltip('برداشتن ادمین'));
    await tester.pumpAndSettle();
    expect(api.adminChanges, [('u2', true), ('u2', false)]);
    expect(find.text('ادمین'), findsNothing);
  });

  testWidgets('an admin removes plain members, not admins or the invite link',
      (tester) async {
    final api = FakePlaylistsApi()
      ..isOwner = false
      ..isAdmin = true
      ..members = [
        const PlaylistMember(id: 'u2', name: 'a***@example.com', isAdmin: true),
        const PlaylistMember(id: 'u3', name: 'm***@example.com'),
      ];
    await openSheet(tester, api);

    expect(find.text('ساخت لینک دعوت'), findsNothing);
    expect(find.byTooltip('ادمین کردن'), findsNothing);
    expect(find.byTooltip('حذف عضو'), findsOneWidget);
    await tester.tap(find.byTooltip('حذف عضو'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();
    expect(api.removedMembers, ['u3']);
  });

  test('reordering keeps the admin role', () {
    const track =
        Track(id: 't', title: 't', contentType: 'audio/mpeg', sizeBytes: 1);
    final playlist = Playlist(
      id: 'p',
      name: 'n',
      trackCount: 0,
      tracks: const [track],
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      isOwner: false,
      isAdmin: true,
    );
    expect(playlist.withTracks(const [track]).isAdmin, isTrue);
  });

  testWidgets('a muted channel says so in the channel list', (tester) async {
    final api = FakeNotificationsApi()
      ..channels = [
        const SubscribedPlaylist(
            shareToken: token,
            name: 'Quiet mix',
            owner: 'f***@example.com',
            trackCount: 3,
            unreadCount: 2,
            muted: true),
      ];
    await tester.pumpWidget(MaterialApp(
      home: NotificationsScreen(
        controller: NotificationsController(api: api, token: () => 'tok'),
        playlists:
            PlaylistsController(api: FakePlaylistsApi(), token: () => 'tok'),
        player: PlayerController(
            api: FakeTracksApi(),
            engine: FakeAudioEngine(),
            token: () => 'tok'),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('کانال‌های من'));
    await tester.pumpAndSettle();
    expect(find.text('۳ آهنگ · بی‌صدا'), findsOneWidget);
    expect(find.text('۲'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
