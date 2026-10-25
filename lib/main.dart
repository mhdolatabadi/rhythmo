import 'package:rhythmo/features/library/data/track_artwork.dart';
import 'package:rhythmo/features/player/data/track_notification_artwork.dart';
import 'package:rhythmo/features/journey/application/listening_journey.dart';
import 'package:flutter/foundation.dart';
import 'package:rhythmo/app/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/features/link_import/application/link_import_controller.dart';
import 'package:rhythmo/features/link_import/data/link_import.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rhythmo/app/app_configuration.dart';
import 'package:rhythmo/app/app_theme.dart';
import 'package:rhythmo/app/backend_gate.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/auth/application/auth_controller.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';
import 'package:rhythmo/features/auth/presentation/auth_gate.dart';
import 'package:rhythmo/features/bots/application/bot_link_controller.dart';
import 'package:rhythmo/features/identify/application/identify_controller.dart';
import 'package:rhythmo/features/identify/data/snippet_recorder.dart';
import 'package:rhythmo/features/history/application/recently_played_controller.dart';
import 'package:rhythmo/features/library/application/library_controller.dart';
import 'package:rhythmo/features/library/application/library_sync_controller.dart';
import 'package:rhythmo/features/library/application/local_audio_controller.dart';
import 'package:rhythmo/features/library/data/local_audio_library.dart';
import 'package:rhythmo/features/library/data/local_audio_upload.dart';
import 'package:rhythmo/features/library/data/track_download.dart';
import 'package:rhythmo/features/lyrics/application/lyrics_controller.dart';
import 'package:rhythmo/features/player/application/favorite_tracks.dart';
import 'package:rhythmo/features/player/application/media_session.dart';
import 'package:rhythmo/features/player/application/playback_settings.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';
import 'package:rhythmo/features/player/data/audio_cache.dart';
import 'package:rhythmo/features/player/data/audio_engine.dart';
import 'package:rhythmo/features/playlists/application/playlists_controller.dart';
import 'package:rhythmo/features/playlists/data/device_playlist_store.dart';
import 'package:rhythmo/features/settings/application/cache_controller.dart';
import 'package:rhythmo/features/upload/application/upload_controller.dart';
import 'package:rhythmo/features/upload/data/audio_picker.dart';
import 'package:rhythmo/features/upload/data/storage_uploader.dart';
import 'package:rhythmo/features/store/application/store_controller.dart';
import 'package:rhythmo/features/store/data/store_catalog.dart';
import 'package:rhythmo/features/likes/data/likes.dart';
import 'package:rhythmo/features/notifications/application/notifications_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) await BrowserContextMenu.disableContextMenu();
  final mediaSession = await startMediaSession();
  await AppConfiguration.loadLaunchLink();
  runApp(ProviderScope(child: RhythmoApp(mediaSession: mediaSession)));
}

class RhythmoApp extends StatefulWidget {
  final AppPreferencesStore? appPreferencesStore;
  const RhythmoApp({
    super.key,
    this.healthCheck,
    this.authApi,
    this.tokenStore,
    this.tracksApi,
    this.playlistsApi,
    this.botsApi,
    this.linkImportsApi,
    this.identifyApi,
    this.storeApi,
    this.notificationsApi,
    this.likesApi,
    this.snippetRecorder,
    this.historyApi,
    this.lyricsApi,
    this.uploader,
    this.picker,
    this.audioEngine,
    this.audioCache,
    this.localAudioLibrary,
    this.localAudioUpload,
    this.trackDownloader,
    this.favoritesStore,
    this.playbackSettingsStore,
    this.mediaSession,
    this.appPreferencesStore,
  });

  /// Test overrides; by default these talk to [AppConfiguration.apiBaseUri]
  /// and the real device.
  final Future<void> Function()? healthCheck;
  final AuthApi? authApi;
  final TokenStore? tokenStore;
  final TracksApi? tracksApi;
  final PlaylistsApi? playlistsApi;
  final BotsApi? botsApi;
  final LinkImportsApi? linkImportsApi;
  final IdentifyApi? identifyApi;
  final StoreApi? storeApi;
  final NotificationsApi? notificationsApi;
  final LikesApi? likesApi;
  final SnippetRecorder? snippetRecorder;
  final HistoryApi? historyApi;
  final LyricsApi? lyricsApi;
  final StorageUploader? uploader;
  final AudioPicker? picker;
  final AudioEngine? audioEngine;
  final AudioCache? audioCache;
  final LocalAudioLibrary? localAudioLibrary;
  final LocalAudioUploadSource? localAudioUpload;
  final TrackDownloader? trackDownloader;
  final FavoritesStore? favoritesStore;
  final PlaybackSettingsStore? playbackSettingsStore;

  /// System media controls; null in tests and where they are unavailable.
  final RhythmoAudioHandler? mediaSession;

  @override
  State<RhythmoApp> createState() => _RhythmoAppState();
}

class _RhythmoAppState extends State<RhythmoApp> {
  late final ApiClient? _apiClient = AppConfiguration.apiBaseUri == null
      ? null
      : ApiClient(AppConfiguration.apiBaseUri!);
  late final AuthApi? _authApi = widget.authApi ?? _apiClient;
  late final AuthController? _auth = _authApi == null
      ? null
      : AuthController(
          api: _authApi,
          tokenStore: widget.tokenStore ?? SecureTokenStore(),
        );

  late final TracksApi? _tracksApi = widget.tracksApi ?? _apiClient;
  late final PlaylistsApi? _playlistsApi = widget.playlistsApi ??
      _apiClient ??
      (_tracksApi is PlaylistsApi ? _tracksApi as PlaylistsApi : null);
  late final PlaylistsController? _playlists = _playlistsApi == null
      ? null
      : PlaylistsController(
          api: _playlistsApi,
          accountId: () => _auth?.user?.id,
          deviceStore: SecureDevicePlaylistStore(),
          subscriptions: _notificationsApi,
          token: () => _auth?.token,
          isAdmin: () => _auth?.user?.isAdmin ?? false);

  late final NotificationsApi? _notificationsApi = widget.notificationsApi ??
      _apiClient ??
      (_playlistsApi is NotificationsApi
          ? _playlistsApi as NotificationsApi
          : null);
  late final NotificationsController? _notifications = _notificationsApi == null
      ? null
      : NotificationsController(
          api: _notificationsApi, token: () => _auth?.token);

  late final BotsApi? _botsApi = widget.botsApi ?? _apiClient;
  late final BotLinkController? _botLinks = _botsApi == null
      ? null
      : BotLinkController(api: _botsApi, token: () => _auth?.token);

  late final LinkImportsApi? _linkImportsApi =
      widget.linkImportsApi ?? _apiClient;
  late final LinkImportController? _linkImports = _linkImportsApi == null
      ? null
      : LinkImportController(api: _linkImportsApi, token: () => _auth?.token);

  late final IdentifyApi? _identifyApi = widget.identifyApi ?? _apiClient;
  late final IdentifyController? _identify = _identifyApi == null
      ? null
      : IdentifyController(
          api: _identifyApi,
          recorder: widget.snippetRecorder ?? MicSnippetRecorder(),
          token: () => _auth?.token,
          // A song added from a playlist shows up in the library.
          onSaved: () async => _library?.load(),
        );

  late final StoreApi? _storeApi = widget.storeApi ?? _apiClient;
  late final StoreController? _store = _storeApi == null
      ? null
      : StoreController(
          api: _storeApi,
          token: () => _auth?.token,
          // A song added from the store shows up in the library.
          onSaved: () async => _library?.load(),
        );

  late final HistoryApi? _historyApi = widget.historyApi ??
      _apiClient ??
      (_tracksApi is HistoryApi ? _tracksApi as HistoryApi : null);
  late final RecentlyPlayedController? _recent = _historyApi == null
      ? null
      : RecentlyPlayedController(api: _historyApi, token: () => _auth?.token);

  late final LyricsApi? _lyricsApi = widget.lyricsApi ??
      _apiClient ??
      (_tracksApi is LyricsApi ? _tracksApi as LyricsApi : null);
  late final LyricsController? _lyrics = _lyricsApi == null
      ? null
      : LyricsController(api: _lyricsApi, token: () => _auth?.token);

  late final UploadController? _uploads = _tracksApi == null
      ? null
      : UploadController(
          api: _tracksApi,
          uploader: widget.uploader ?? DioStorageUploader(),
          token: () => _auth?.token,
        );

  late final LibraryController? _library = _tracksApi == null
      ? null
      : LibraryController(
          api: _tracksApi,
          token: () => _auth?.token,
          likes: widget.likesApi ?? _apiClient,
        );

  late final _artwork = TrackArtworkController((track) {
    if (track.isLocal) return TrackArtworkController.local(track);
    return _apiClient?.trackArtwork(_auth?.token, track) ?? Future.value(null);
  });

  final ListeningJourney _journey = ListeningJourney();

  String? _artworkToken;

  void _selectJourneyAccount() {
    _journey.selectAccount(_auth?.user?.id);
    final token = _auth?.token;
    if (_artworkToken != token) {
      _artworkToken = token;
      _artwork.clear();
    }
  }

  // One cache shared by playback and the Settings screen.
  late final AudioCache _audioCache = widget.audioCache ?? createAudioCache();

  late final PlayerController? _player = _tracksApi == null
      ? null
      : (PlayerController(
          api: _tracksApi,
          engine: widget.audioEngine ?? JustAudioEngine(cache: _audioCache),
          token: () => _auth?.token,
          favorites: FavoriteTracks(
            store: widget.favoritesStore ?? SecureFavoritesStore(),
            // Likes live on the server once signed in (#284).
            api: widget.likesApi ?? _apiClient,
            token: () => _auth?.token,
          )..load(),
          settingsStore:
              widget.playbackSettingsStore ?? SecurePlaybackSettingsStore(),
          // A real listen goes into the recently played history.
          journey: _journey,
          onListened: (track) => _recent?.record(track),
          lyrics: _lyrics,
        )..loadSettings());

  late final LocalAudioController _localAudio = LocalAudioController(
    widget.localAudioLibrary ?? createLocalAudioLibrary(),
  );

  late final LibrarySyncController? _sync = _uploads == null
      ? null
      : LibrarySyncController(
          uploads: _uploads,
          uploadSource:
              widget.localAudioUpload ?? createLocalAudioUploadSource(),
          onUploaded: () async {
            await _library?.load();
          },
          api: _tracksApi!,
          token: () => _auth?.token,
          downloader: widget.trackDownloader ?? createTrackDownloader(),
          // A saved download appears among the device's music.
          onDownloaded: _localAudio.load,
        );

  late final CacheController _cache = CacheController(
    cache: _audioCache,
    playing: () => _player?.track?.id,
  );

  late final _preferences =
      AppPreferencesController(store: widget.appPreferencesStore);

  @override
  void initState() {
    super.initState();
    _auth?.addListener(_selectJourneyAccount);
    _selectJourneyAccount();
    _preferences.load();
    final player = _player;
    if (player != null) {
      widget.mediaSession?.attach(
        player,
        artworkFor: (track) async {
          final bytes = await _artwork.load(track);
          return bytes == null ? null : trackNotificationArtwork(bytes);
        },
      );
    }
  }

  @override
  void dispose() {
    _auth?.removeListener(_selectJourneyAccount);
    _artwork.dispose();
    _journey.dispose();
    _preferences.dispose();
    _player?.dispose();
    _auth?.dispose();
    _sync?.dispose();
    _uploads?.dispose();
    _library?.dispose();
    _playlists?.dispose();
    _recent?.dispose();
    _lyrics?.dispose();
    _botLinks?.dispose();
    _linkImports?.dispose();
    _identify?.dispose();
    _store?.dispose();
    _localAudio.dispose();
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppPreferencesScope(
      controller: _preferences,
      child: ListenableBuilder(
        listenable: _preferences,
        builder: (context, _) => MaterialApp(
          title: 'rhythmo',
          builder: (context, child) => TrackArtworkScope(
            controller: _artwork,
            child: child ?? const SizedBox.shrink(),
          ),
          debugShowCheckedModeBanner: false,
          // The UI is Persian only: right-to-left layout and Persian Material
          // strings (tooltips, dialogs), whatever the device language is.
          locale: const Locale('fa'),
          supportedLocales: const [Locale('fa')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: RhythmoTheme.light(),
          darkTheme: RhythmoTheme.dark(),
          themeMode: _preferences.value.themeMode,
          home: _WebEdgeInsets(
            child: BackendGate(
              healthCheck: widget.healthCheck ?? _apiClient?.checkHealth,
              child: _auth == null ||
                      _uploads == null ||
                      _sync == null ||
                      _library == null ||
                      _player == null
                  ? const SizedBox.shrink()
                  : AuthGate(
                      controller: _auth,
                      adminApi: _apiClient,
                      player: _player,
                      library: _library,
                      playlists: _playlists,
                      recent: _recent,
                      localAudio: _localAudio,
                      uploads: _uploads,
                      sync: _sync,
                      cache: _cache,
                      botLinks: _botLinks,
                      linkImports: _linkImports,
                      identify: _identify,
                      store: _store,
                      notifications: _notifications,
                      picker: widget.picker ?? FilePickerAudioPicker(),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WebEdgeInsets extends StatelessWidget {
  const _WebEdgeInsets({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final horizontal = switch (width) {
          >= 1200 => 32.0,
          >= 720 => 24.0,
          _ => 0.0,
        };
        if (horizontal == 0) return child;
        return ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontal),
            child: child,
          ),
        );
      },
    );
  }
}
