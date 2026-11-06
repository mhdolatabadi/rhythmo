/// Music being added from a link: a song page on a music site, or an audio
/// file itself.
class LinkImport {
  const LinkImport({
    required this.id,
    required this.fileName,
    required this.site,
    required this.state,
    this.error,
    this.trackId,
  });

  factory LinkImport.fromJson(Map<String, dynamic> json) => LinkImport(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        site: json['site'] as String? ?? '',
        state: switch (json['state']) {
          'done' => LinkImportState.done,
          'failed' => LinkImportState.failed,
          'downloading' => LinkImportState.downloading,
          _ => LinkImportState.queued,
        },
        error: json['error'] as String?,
        trackId: json['trackId'] as String?,
      );

  final String id;
  final String fileName;

  /// The site the file comes from, for example `music.example.ir`.
  final String site;
  final LinkImportState state;

  /// Why a failed import was refused, as the server names it.
  final String? error;
  final String? trackId;

  bool get finished =>
      state == LinkImportState.done || state == LinkImportState.failed;
}

enum LinkImportState { queued, downloading, done, failed }

class LinkImportCandidate {
  const LinkImportCandidate({
    required this.url,
    required this.fileName,
    required this.site,
    this.sizeBytes = 0,
    this.title,
    this.artist,
    this.thumbnailUrl,
    this.durationSeconds = 0,
  });

  factory LinkImportCandidate.fromJson(Map<String, dynamic> json) =>
      LinkImportCandidate(
        url: json['url'] as String,
        fileName: json['fileName'] as String,
        site: json['site'] as String? ?? '',
        sizeBytes: json['sizeBytes'] as int? ?? 0,
        title: _nonEmpty(json['title']),
        artist: _nonEmpty(json['artist']),
        thumbnailUrl: _nonEmpty(json['thumbnailUrl']),
        durationSeconds: json['durationSeconds'] as int? ?? 0,
      );

  final String url;
  final String fileName;
  final String site;
  final int sizeBytes;

  /// A video's title, artist (or channel) and preview image, when the link
  /// is a YouTube or Instagram one.
  final String? title;
  final String? artist;
  final String? thumbnailUrl;
  final int durationSeconds;

  String get displayTitle => title ?? fileName;
}

String? _nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

/// A title on a Spotify track, album or playlist.
class SpotifyTitle {
  const SpotifyTitle({required this.title, this.artists = const []});

  factory SpotifyTitle.fromJson(Map<String, dynamic> json) => SpotifyTitle(
        title: json['title'] as String,
        artists: [
          for (final artist in json['artists'] as List<dynamic>? ?? const [])
            artist as String,
        ],
      );

  final String title;
  final List<String> artists;
}

/// What a Spotify link turned into: a playlist of the titles already in the
/// library (none if nothing matched), and the titles that weren't found.
class SpotifyImportResult {
  const SpotifyImportResult({
    required this.name,
    required this.matched,
    required this.missing,
    this.playlistId,
  });

  factory SpotifyImportResult.fromJson(Map<String, dynamic> json) =>
      SpotifyImportResult(
        name: json['name'] as String? ?? '',
        playlistId: json['playlistId'] as String?,
        matched: [
          for (final item in json['matched'] as List<dynamic>? ?? const [])
            SpotifyTitle.fromJson(item as Map<String, dynamic>),
        ],
        missing: [
          for (final item in json['missing'] as List<dynamic>? ?? const [])
            SpotifyTitle.fromJson(item as Map<String, dynamic>),
        ],
      );

  final String name;
  final String? playlistId;
  final List<SpotifyTitle> matched;
  final List<SpotifyTitle> missing;
}

/// Spotify links are matched against the library instead of downloaded.
bool isSpotifyLink(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.toLowerCase() == 'open.spotify.com';
}

abstract interface class LinkImportsApi {
  /// Lists the audio files a link leads to, without starting imports.
  Future<List<LinkImportCandidate>> previewLink(String token, String url);

  /// Starts importing the audio a link leads to.
  Future<LinkImport> importFromLink(String token, String url);

  /// The user's latest link imports, newest first.
  Future<List<LinkImport>> listLinkImports(String token);

  /// Makes a playlist of a Spotify link's titles found in the library.
  Future<SpotifyImportResult> importSpotify(String token, String url);
}

/// What a refused link or a failed import means, in Persian.
String linkImportMessage(String? code) => switch (code) {
      'invalid_url' => 'این لینک معتبر نیست. یک لینک http یا https بچسبان.',
      'blocked_url' => 'ریتمو اجازه ندارد به نشانی این لینک وصل شود.',
      'import_timeout' => 'بررسی لینک طول کشید؛ کمی بعد دوباره امتحان کن.',
      'unreachable' =>
        'صفحه باز نشد. لینک را بررسی کن یا کمی بعد دوباره امتحان کن.',
      'no_audio' =>
        'در این صفحه فایل صوتی پیدا نشد. لینک صفحه‌ی خود آهنگ یا لینک مستقیم فایل را بچسبان.',
      'unsupported_format' => 'این لینک به فایل صوتی پشتیبانی‌شده نمی‌رسد.',
      'too_large' => 'این فایل از حد مجاز بزرگ‌تر است.',
      'too_long' => 'این ویدیو از حداکثر مدت مجاز طولانی‌تر است.',
      'metadata_only' =>
        'از اسپاتیفای فقط فهرست آهنگ‌ها خوانده می‌شود؛ آهنگ‌هایی که در «موسیقی من» داری در یک فهرست پخش جمع می‌شوند.',
      'no_tracks' => 'در این لینک اسپاتیفای آهنگی پیدا نشد.',
      'duplicate_import' => 'این آهنگ همین حالا در حال اضافه شدن است.',
      'too_many_imports' ||
      'too_many_pending_uploads' ||
      'rate_limited' =>
        'چند فایل در حال اضافه شدن است؛ کمی صبر کن و دوباره امتحان کن.',
      'quota_exceeded' =>
        'فضای کافی در حسابت نیست. چند آهنگ را حذف کن و دوباره امتحان کن.',
      'uploads_disabled' => 'افزودن آهنگ فعلاً غیرفعال است.',
      'email_unverified' =>
        'اول ایمیلت را تأیید کن؛ بعد می‌توانی از لینک آهنگ اضافه کنی.',
      'invalid_audio' => 'فایل دریافت‌شده صوتی معتبر نبود.',
      _ => 'افزودن از لینک ناموفق بود. دوباره تلاش کن.',
    };
