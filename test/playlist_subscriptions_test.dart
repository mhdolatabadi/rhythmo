import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/notifications/application/notifications_controller.dart';
import 'package:rhythmo/features/notifications/data/notifications.dart';
import 'package:rhythmo/features/notifications/presentation/notifications_screen.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/playlist.dart';
import 'package:rhythmo/features/playlists/presentation/shared_playlist_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'playlist_sharing_test.dart' show FakePlaylistsApi, token;
import 'upload_controller_test.dart' show FakeTracksApi;

class FakeNotificationsApi implements NotificationsApi {
  final subscribers = <String, Set<String>>{};
  int? subscribeStatus;
  List<PlaylistNotification> notices = [];
  List<SubscribedPlaylist> channels = [];
  int unread = 0;
  final readCalls = <List<String>>[];

  @override
  Future<PlaylistSubscription> setPlaylistSubscription(
      String t, String shareToken, bool subscribed) async {
    if (subscribeStatus != null) {
      throw ApiException('$subscribeStatus', statusCode: subscribeStatus);
    }
    final who = subscribers.putIfAbsent(shareToken, () => {});
    subscribed ? who.add('me') : who.remove('me');
    return PlaylistSubscription(
        subscribed: subscribed, subscriberCount: who.length);
  }

  @override
  Future<List<SubscribedPlaylist>> listSubscriptions(String t) async =>
      channels;

  @override
  Future<({List<PlaylistNotification> notifications, int unread})>
      listNotifications(String t) async =>
          (notifications: notices, unread: unread);

  @override
  Future<int> unreadNotificationCount(String t) async => unread;

  @override
  Future<void> markNotificationsRead(String t,
      {List<String> ids = const []}) async {
    readCalls.add(ids);
    unread = 0;
  }
}

SharedPlaylist publicMix({bool subscribed = false, int count = 0}) =>
    SharedPlaylist.fromJson(token, {
      'name': 'Channel mix',
      'owner': 'f***@example.com',
      'isOwner': false,
      'public': true,
      'subscribed': subscribed,
      'subscriberCount': count,
      'tracks': [
        {
          'id': 's1',
          'title': 'Their song',
          'contentType': 'audio/mpeg',
          'sizeBytes': 1,
        },
      ],
    });

PlaylistNotification notice({bool read = false}) => PlaylistNotification(
      id: 'n1',
      shareToken: token,
      playlistName: 'Channel mix',
      trackTitle: 'New song',
      trackCount: 1,
      read: read,
      updatedAt: DateTime.now(),
    );

void main() {
  test('the API client speaks the subscription endpoints', () async {
    final requests = <String>[];
    final client = ApiClient(Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      final body = switch (request.url.path) {
        '/api/v1/notifications' => {
            'notifications': [
              {
                'id': 'n1',
                'kind': 'playlist_tracks_added',
                'shareToken': token,
                'playlistName': 'Channel mix',
                'trackCount': 3,
                'read': false,
                'updatedAt': '2026-10-25T12:00:00Z',
              },
            ],
            'unreadCount': 1,
          },
        '/api/v1/notifications/unread-count' => {'unreadCount': 4},
        '/api/v1/subscriptions' => {
            'playlists': [
              {
                'shareToken': token,
                'name': 'Channel mix',
                'owner': 'f***@example.com',
                'trackCount': 7,
                'unreadCount': 2,
              },
            ],
          },
        '/api/v1/notifications/read' => null,
        _ => {'subscribed': request.method == 'PUT', 'subscriberCount': 9},
      };
      return body == null
          ? http.Response('', 204)
          : http.Response(jsonEncode(body), 200,
              headers: {'content-type': 'application/json'});
    }));

    expect(await client.setPlaylistSubscription('tok', token, true),
        const PlaylistSubscription(subscribed: true, subscriberCount: 9));
    expect(
        (await client.setPlaylistSubscription('tok', token, false)).subscribed,
        isFalse);
    final inbox = await client.listNotifications('tok');
    expect(inbox.unread, 1);
    expect(inbox.notifications.single.trackCount, 3);
    expect(await client.unreadNotificationCount('tok'), 4);
    expect((await client.listSubscriptions('tok')).single.unreadCount, 2);
    await client.markNotificationsRead('tok');
    expect(requests, [
      'PUT /api/v1/shared-playlists/$token/subscription',
      'DELETE /api/v1/shared-playlists/$token/subscription',
      'GET /api/v1/notifications',
      'GET /api/v1/notifications/unread-count',
      'GET /api/v1/subscriptions',
      'POST /api/v1/notifications/read',
    ]);
  });

  test('a shared playlist without subscriptions has none', () {
    final playlist = SharedPlaylist.fromJson(
        token, {'name': 'x', 'owner': 'o', 'tracks': <dynamic>[]});
    expect(playlist.subscription, isNull);
  });

  Future<FakeNotificationsApi> pumpShared(WidgetTester tester,
      {SharedPlaylist? playlist, bool signedIn = true}) async {
    final subscriptions = FakeNotificationsApi();
    final api = FakePlaylistsApi()..shared[token] = playlist ?? publicMix();
    await tester.pumpWidget(MaterialApp(
      home: SharedPlaylistScreen(
        key: UniqueKey(),
        shareToken: token,
        controller: PlaylistsController(
            api: api,
            subscriptions: subscriptions,
            token: () => signedIn ? 'tok' : null),
        player: PlayerController(
            api: FakeTracksApi(),
            engine: FakeAudioEngine(),
            token: () => 'tok'),
      ),
    ));
    await tester.pumpAndSettle();
    return subscriptions;
  }

  testWidgets('subscribing to a public playlist like a channel',
      (tester) async {
    final api = await pumpShared(tester, playlist: publicMix(count: 2));

    expect(find.textContaining('۲ عضو'), findsOneWidget);
    await tester.tap(find.text('عضویت'));
    await tester.pumpAndSettle();
    expect(api.subscribers[token], {'me'});
    expect(find.text('عضو هستی'), findsOneWidget);
    expect(find.textContaining('خبرت می‌کنیم'), findsOneWidget);

    await tester.tap(find.text('عضو هستی'));
    await tester.pumpAndSettle();
    expect(api.subscribers[token], isEmpty);
    expect(find.text('عضویت'), findsOneWidget);
  });

  testWidgets('a refused subscription goes back', (tester) async {
    final subscriptions = FakeNotificationsApi()..subscribeStatus = 404;
    final api = FakePlaylistsApi()..shared[token] = publicMix();
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

    await tester.tap(find.text('عضویت'));
    await tester.pumpAndSettle();
    expect(find.text('عضویت'), findsOneWidget);
    expect(find.text('این فهرست پخش دیگر عمومی نیست.'), findsOneWidget);
  });

  testWidgets('link-only and own playlists offer no subscription',
      (tester) async {
    await pumpShared(tester,
        playlist: SharedPlaylist.fromJson(token, {
          'name': 'Link only',
          'owner': 'f***@example.com',
          'public': false,
          'subscribed': false,
          'subscriberCount': 0,
          'tracks': <dynamic>[],
        }));
    expect(find.text('عضویت'), findsNothing);

    await pumpShared(tester,
        playlist: SharedPlaylist.fromJson(token, {
          'name': 'Mine',
          'owner': 'm***@example.com',
          'isOwner': true,
          'public': true,
          'subscribed': false,
          'subscriberCount': 5,
          'tracks': <dynamic>[],
        }));
    expect(find.text('عضویت'), findsNothing);
    expect(find.textContaining('۵ عضو'), findsOneWidget);
  });

  testWidgets('the bell shows unread notices and the inbox opens them',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = FakeNotificationsApi()
      ..unread = 1
      ..notices = [notice()]
      ..channels = [
        const SubscribedPlaylist(
            shareToken: token,
            name: 'Channel mix',
            owner: 'f***@example.com',
            trackCount: 7,
            unreadCount: 1),
      ];
    final notifications = NotificationsController(api: api, token: () => 'tok');
    final playlists = PlaylistsController(
        api: FakePlaylistsApi()..shared[token] = publicMix(subscribed: true),
        subscriptions: api,
        token: () => 'tok');
    final player = PlayerController(
        api: FakeTracksApi(), engine: FakeAudioEngine(), token: () => 'tok');
    await notifications.refreshUnread();

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(actions: [
            NotificationsButton(
              controller: notifications,
              onOpen: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => NotificationsScreen(
                    controller: notifications,
                    playlists: playlists,
                    player: player),
              )),
            ),
          ]),
        ),
      ),
    ));
    expect(find.byTooltip('اعلان‌ها، ۱ خوانده‌نشده'), findsOneWidget);

    await tester.tap(find.byType(NotificationsButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Channel mix'), findsOneWidget);
    expect(find.text('«New song» اضافه شد'), findsOneWidget);

    await tester.tap(find.text('کانال‌های من'));
    await tester.pumpAndSettle();
    expect(find.text('۷ آهنگ'), findsOneWidget);
    await tester.tap(find.text('تازه‌ها'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('خواندن همه'));
    await tester.pumpAndSettle();
    expect(api.readCalls, [<String>[]]);
    expect(notifications.unreadCount, 0);
    expect(find.byTooltip('خواندن همه'), findsNothing);

    // Opening a notice opens its playlist.
    await tester.tap(find.text('Channel mix'));
    await tester.pumpAndSettle();
    expect(find.text('Their song'), findsOneWidget);
    expect(find.text('عضو هستی'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty inbox explains how to subscribe', (tester) async {
    final notifications = NotificationsController(
        api: FakeNotificationsApi(), token: () => 'tok');
    await tester.pumpWidget(MaterialApp(
      home: NotificationsScreen(
        controller: notifications,
        playlists:
            PlaylistsController(api: FakePlaylistsApi(), token: () => 'tok'),
        player: PlayerController(
            api: FakeTracksApi(),
            engine: FakeAudioEngine(),
            token: () => 'tok'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('اعلانی نداری'), findsOneWidget);
  });
}
