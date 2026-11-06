import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/bots/data/messenger_bot.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/presentation/channel_sync_sheet.dart';
import 'package:rhythmo/features/playlists/presentation/playlists_screen.dart';

import 'player_controller_test.dart' show FakeAudioEngine;
import 'playlist_sharing_test.dart' show FakePlaylistsApi;
import 'upload_controller_test.dart' show FakeTracksApi;

class FakeBotChannelsApi implements BotChannelsApi {
  List<SyncedChannel> channels = [
    const SyncedChannel(provider: 'telegram', chatId: '-1001', title: 'Golden'),
  ];
  final codes = <String>[];
  bool fail = false;

  @override
  Future<BotLinkCode> createChannelCode(String token, String playlistId) async {
    if (fail) throw ApiException('nope', statusCode: 500);
    codes.add(playlistId);
    return BotLinkCode(
      code: '87654321',
      expiresAt: DateTime.utc(2026, 10, 29, 12, 10),
      bots: const [
        MessengerBot(
            provider: 'telegram', name: 'تلگرام', username: 'RhythmoBot'),
      ],
    );
  }

  @override
  Future<List<SyncedChannel>> listSyncedChannels(
          String token, String playlistId) async =>
      channels;

  @override
  Future<void> removeSyncedChannel(
      String token, String playlistId, SyncedChannel channel) async {
    channels = [
      for (final c in channels)
        if (c.chatId != channel.chatId) c
    ];
  }
}

void main() {
  test('the API client speaks the channel sync endpoints', () async {
    final requests = <String>[];
    final client = ApiClient(Uri.parse('https://api.example.com'),
        httpClient: MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (request.method == 'DELETE') return http.Response('', 204);
      final body = request.method == 'POST'
          ? {
              'code': '87654321',
              'expiresAt': '2026-10-29T12:10:00Z',
              'bots': [
                {'provider': 'bale', 'name': 'بله', 'username': 'NafirBot'},
              ],
            }
          : {
              'channels': [
                {
                  'provider': 'bale',
                  'chatId': '-1001',
                  'title': 'Golden',
                  'linkedAt': '2026-10-29T12:00:00Z',
                },
              ],
            };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }));

    expect((await client.createChannelCode('tok', 'p1')).code, '87654321');
    final channels = await client.listSyncedChannels('tok', 'p1');
    expect(channels.single.title, 'Golden');
    await client.removeSyncedChannel('tok', 'p1', channels.single);
    expect(requests, [
      'POST /api/v1/playlists/p1/bot-channels/code',
      'GET /api/v1/playlists/p1/bot-channels',
      'DELETE /api/v1/playlists/p1/bot-channels/bale/-1001',
    ]);
  });

  Future<FakeBotChannelsApi> openSheet(WidgetTester tester,
      {FakeBotChannelsApi? channels}) async {
    final api = FakePlaylistsApi();
    final sync = channels ?? FakeBotChannelsApi();
    final controller =
        PlaylistsController(api: api, channels: sync, token: () => 'tok');
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showChannelSyncSheet(context,
                playlist: api.playlist, controller: controller),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return sync;
  }

  testWidgets('an admin gets a code to post in their channel', (tester) async {
    final sync = await openSheet(tester);
    expect(find.text('Golden'), findsOneWidget);
    expect(find.text('تلگرام'), findsOneWidget);

    await tester.tap(find.text('گرفتن کد اتصال'));
    await tester.pumpAndSettle();
    expect(sync.codes, ['p1']);
    expect(find.text('8765 4321'), findsOneWidget);
    expect(find.textContaining('@RhythmoBot'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing a synced channel asks first', (tester) async {
    final sync = await openSheet(tester);
    await tester.tap(find.byTooltip('قطع همگام‌سازی'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'قطع'));
    await tester.pumpAndSettle();
    expect(sync.channels, isEmpty);
    expect(find.text('هنوز کانالی وصل نیست.'), findsOneWidget);
  });

  testWidgets('a failed code says so', (tester) async {
    await openSheet(tester, channels: FakeBotChannelsApi()..fail = true);
    await tester.tap(find.text('گرفتن کد اتصال'));
    await tester.pumpAndSettle();
    expect(find.text('گرفتن کد ناموفق بود. دوباره تلاش کن.'), findsOneWidget);
  });

  testWidgets('only people who run a playlist see channel sync',
      (tester) async {
    Future<void> menuFor(FakePlaylistsApi api) async {
      await tester.pumpWidget(MaterialApp(
        home: PlaylistDetailScreen(
          key: UniqueKey(),
          playlistId: 'p1',
          controller: PlaylistsController(
              api: api, channels: FakeBotChannelsApi(), token: () => 'tok'),
          libraryTracks: const [],
          player: PlayerController(
              api: FakeTracksApi(),
              engine: FakeAudioEngine(),
              token: () => 'tok'),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('گزینه‌های فهرست پخش'));
      await tester.pumpAndSettle();
    }

    await menuFor(FakePlaylistsApi()
      ..isOwner = false
      ..isAdmin = true);
    expect(find.text('اتصال کانال تلگرام یا بله'), findsOneWidget);
    await tester.tapAt(const Offset(4, 500));
    await tester.pumpAndSettle();

    await menuFor(FakePlaylistsApi()..isOwner = false);
    expect(find.text('اتصال کانال تلگرام یا بله'), findsNothing);
  });
}
