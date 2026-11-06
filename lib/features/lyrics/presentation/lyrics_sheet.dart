import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:flutter/rendering.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/lyrics/application/lyrics_controller.dart';
import 'package:rhythmo/features/lyrics/data/lyrics.dart';
import 'package:rhythmo/features/player/application/player_controller.dart';

/// Opens the «متن آهنگ» sheet for whatever [player] is playing. It follows
/// along when the track changes.
Future<void> openLyrics(
  BuildContext context,
  PlayerController player,
  LyricsController lyrics,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: LyricsView(player: player, lyrics: lyrics),
    ),
  );
}

/// How long a manual scroll pauses following the music.
const lyricsFollowPause = Duration(seconds: 4);

/// Whether [text] reads right to left: it has a Persian, Arabic or Hebrew
/// letter before any Latin one.
TextDirection lyricDirection(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x0590 && rune <= 0x08FF) ||
        (rune >= 0xFB1D && rune <= 0xFEFC)) {
      return TextDirection.rtl;
    }
    if ((rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        (rune >= 0xC0 && rune <= 0x24F)) {
      return TextDirection.ltr;
    }
  }
  return TextDirection.rtl;
}

/// The lyrics of the playing track: synced lines that light up and scroll
/// with the music (tap one to jump there), or plain text to read.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.player, required this.lyrics});

  final PlayerController player;
  final LyricsController lyrics;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  Track? _track;
  TrackLyrics? _result;
  Object? _error;
  bool _loading = false;
  int _request = 0;
  Timer? _extractionPoll;
  String? _extractionState;
  bool _startingExtraction = false;
  bool _generated = false;
  String? _extractionError;

  PlayerController get _player => widget.player;

  @override
  void initState() {
    super.initState();
    _player.addListener(_onPlayer);
    _onPlayer();
  }

  @override
  void dispose() {
    _extractionPoll?.cancel();
    _player.removeListener(_onPlayer);
    super.dispose();
  }

  void _onPlayer() {
    final track = _player.track;
    if (track == null || identical(track, _track) || track.id == _track?.id) {
      return;
    }
    _extractionPoll?.cancel();
    _extractionState = null;
    _extractionError = null;
    _generated = false;
    _track = track;
    _load();
  }

  Future<void> _load() async {
    final track = _track;
    if (track == null) return;
    final request = ++_request;
    final cached = widget.lyrics.cached(track);
    setState(() {
      _result = cached;
      _error = null;
      _loading = cached == null && widget.lyrics.unavailable(track) == null;
    });
    try {
      final extraction = await widget.lyrics.extraction(track);
      if (!mounted || request != _request) return;
      setState(() => _extractionState = extraction?['state'] as String?);
      if (_extractionState == 'queued' || _extractionState == 'processing') {
        setState(() => _loading = false);
        _extractionPoll?.cancel();
        _extractionPoll = Timer(const Duration(seconds: 15), _load);
        return;
      }
      if (_extractionState == 'done') {
        setState(() {
          _result = TrackLyrics.fromJson({...extraction!, 'status': 'found'});
          _generated = true;
          _loading = false;
        });
        return;
      }
    } catch (_) {
      // A transient status failure must not prevent existing lyrics from loading.
      if (!mounted || request != _request) return;
      if (_extractionState == 'queued' || _extractionState == 'processing') {
        _extractionPoll?.cancel();
        _extractionPoll = Timer(const Duration(seconds: 15), _load);
        return;
      }
    }
    if (!_loading) return;
    try {
      final result =
          await widget.lyrics.load(track, duration: _player.duration);
      if (!mounted || request != _request) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _extract() async {
    final track = _track;
    if (track == null || _startingExtraction) return;
    setState(() {
      _startingExtraction = true;
      _extractionError = null;
    });
    try {
      await widget.lyrics.extraction(track, start: true);
      if (!mounted || _track?.id != track.id) return;
      await _load();
    } catch (error) {
      if (!mounted || _track?.id != track.id) return;
      setState(() => _extractionError = error is ApiException &&
              error.code == 'transcription_busy'
          ? 'صف پردازش پر است؛ پس از پایان فایل‌های قبلی دوباره امتحان کنید.'
          : 'استخراج شروع نشد؛ دوباره امتحان کنید.');
    } finally {
      if (mounted) setState(() => _startingExtraction = false);
    }
  }

  Widget get _source => _generated
      ? const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
              'متن استخراج‌شده از صدا؛ ممکن است نیاز به اصلاح داشته باشد.'))
      : LyricsSource(match: _result?.match);

  Future<void> _choose() async {
    final track = _track;
    if (track == null) return;
    final chosen = await showModalBottomSheet<TrackLyrics>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: LyricsChooser(track: track, lyrics: widget.lyrics),
      ),
    );
    if (chosen != null && mounted && identical(track, _track)) {
      setState(() => _result = chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = _track;
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'متن آهنگ',
                      style: theme.textTheme.titleLarge,
                    ),
                    if (track != null)
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (result != null && result.canChoose)
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _choose,
                  icon: const Icon(RhythmoIcons.magnifyingGlass),
                  label: const Text('متن دیگر'),
                ),
            ],
          ),
        ),
        if (_extractionState != null &&
            _extractionState != 'done' &&
            _extractionState != 'queued' &&
            _extractionState != 'processing')
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _startingExtraction ? null : _extract,
              icon: const Icon(RhythmoIcons.quotes),
              label: Text(_startingExtraction
                  ? 'در حال ثبت درخواست'
                  : _extractionState == 'failed'
                      ? 'تلاش دوباره برای استخراج از صدا'
                      : 'استخراج متن از صدا'),
            ),
          ),
        if (_extractionError != null)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_extractionError!, semanticsLabel: _extractionError)),
        Expanded(child: _body(context, track, result)),
      ],
    );
  }

  Widget _body(BuildContext context, Track? track, TrackLyrics? result) {
    if (track == null) return const SizedBox.shrink();
    if (_extractionState == 'queued' || _extractionState == 'processing') {
      return LyricsMessage(
        icon: RhythmoIcons.quotes,
        title: _extractionState == 'queued'
            ? 'در صف استخراج متن'
            : 'در حال تبدیل صدا به متن',
        detail: 'می‌توانید این صفحه را ببندید؛ پردازش روی سرور ادامه دارد.',
      );
    }
    switch (widget.lyrics.unavailable(track)) {
      case LyricsUnavailable.deviceOnly:
        return const LyricsMessage(
          icon: RhythmoIcons.deviceMobile,
          title: 'متن این آهنگ در دسترس نیست',
          detail: 'متن آهنگ فقط برای آهنگ‌های روی سرور پیدا می‌شود.',
        );
      case LyricsUnavailable.signedOut:
        return const LyricsMessage(
          icon: RhythmoIcons.userCircle,
          title: 'برای دیدن متن آهنگ وارد شوید',
        );
      case LyricsUnavailable.store:
        return const LyricsMessage(
          icon: RhythmoIcons.vinylRecord,
          title: 'متن آهنگ‌های گنجینه هنوز نمایش داده نمی‌شود',
          detail: 'آهنگ را به «موسیقی من» اضافه کن تا متنش را ببینی.',
        );
      case null:
    }
    if (_loading) {
      return Center(
        child: Semantics(
          label: 'در حال پیدا کردن متن آهنگ',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null || result == null) {
      final busy = _error is ApiException &&
          (_error as ApiException).code == 'lyrics_unavailable';
      return LyricsMessage(
        icon: RhythmoIcons.warningCircle,
        title:
            busy ? 'سرویس متن آهنگ الان پاسخ نمی‌دهد' : 'متن آهنگ دریافت نشد',
        detail: 'کمی بعد دوباره امتحان کنید.',
        action: FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _load,
          icon: const Icon(RhythmoIcons.arrowsClockwise),
          label: const Text('تلاش دوباره'),
        ),
      );
    }
    switch (result.status) {
      case LyricsStatus.notFound:
        return LyricsMessage(
          icon: RhythmoIcons.quotes,
          title: 'متنی پیدا نشد',
          detail: result.canChoose
              ? 'می‌توانید متن را با جستجو پیدا کنید.'
              : 'متن این آهنگ در LRCLIB نیست.',
          action: result.canChoose
              ? FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _choose,
                  icon: const Icon(RhythmoIcons.magnifyingGlass),
                  label: const Text('جستجوی متن'),
                )
              : null,
        );
      case LyricsStatus.instrumental:
        return const LyricsMessage(
          icon: RhythmoIcons.musicNotes,
          title: 'این آهنگ بی‌کلام است',
        );
      case LyricsStatus.found:
        if (result.isSynced) {
          return SyncedLyrics(
            key: ValueKey(track.id),
            lines: result.lines,
            player: _player,
            footer: _source,
          );
        }
        return PlainLyrics(
          text: result.text,
          footer: _source,
        );
    }
  }
}

/// A state with no lyrics to show, drawn as the shared [RhythmoStateView];
/// a warning icon makes it an error.
class LyricsMessage extends StatelessWidget {
  const LyricsMessage({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) => icon == RhythmoIcons.warningCircle
      ? RhythmoStateView.error(
          icon: icon, title: title, message: detail, action: action)
      : RhythmoStateView(
          icon: icon, title: title, message: detail, action: action);
}

/// Plain lyrics: text to scroll through, each line in its own direction.
class PlainLyrics extends StatelessWidget {
  const PlainLyrics({super.key, required this.text, this.footer});

  final String text;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
          height: 1.7,
          fontWeight: FontWeight.w500,
        );
    return SingleChildScrollView(
      key: const ValueKey('plain-lyrics'),
      padding: EdgeInsets.fromLTRB(
          24, 8, 24, MediaQuery.viewPaddingOf(context).bottom + 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in text.split('\n'))
            Text(
              line,
              textAlign: TextAlign.center,
              textDirection: lyricDirection(line),
              style: style,
            ),
          if (footer != null) footer!,
        ],
      ),
    );
  }
}

/// Synced lyrics: the playing line is lit and kept in view; tapping a line
/// seeks there. Scrolling by hand pauses the following for a moment.
class SyncedLyrics extends StatefulWidget {
  const SyncedLyrics({
    super.key,
    required this.lines,
    required this.player,
    this.footer,
  });

  final List<LyricLine> lines;
  final PlayerController player;
  final Widget? footer;

  @override
  State<SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends State<SyncedLyrics> {
  final _scroll = ScrollController();
  late final _keys = List.generate(widget.lines.length, (_) => GlobalKey());
  int _active = -2;
  DateTime? _pausedUntil;
  Timer? _resume;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPosition());
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPosition);
    _resume?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onPosition() {
    if (!mounted) return;
    final active = activeLyricLine(widget.lines, widget.player.position);
    if (active == _active) return;
    setState(() => _active = active);
    _follow();
  }

  void _follow() {
    final paused = _pausedUntil;
    if (paused != null && DateTime.now().isBefore(paused)) return;
    final index = _active < 0 ? 0 : _active;
    final target = _keys[index].currentContext;
    if (target == null) return;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    Scrollable.ensureVisible(
      target,
      alignment: 0.35,
      duration: reduceMotion ? Duration.zero : RhythmoMotion.long,
      curve: RhythmoMotion.standard,
    );
  }

  bool _onScroll(UserScrollNotification notification) {
    if (notification.direction != ScrollDirection.idle) {
      _pausedUntil = DateTime.now().add(lyricsFollowPause);
      _resume?.cancel();
      _resume = Timer(lyricsFollowPause, () {
        _pausedUntil = null;
        _follow();
      });
    }
    return false;
  }

  void _seek(LyricLine line) {
    _pausedUntil = null;
    widget.player.seek(line.time);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final base = theme.textTheme.titleLarge?.copyWith(height: 1.45);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final height = MediaQuery.sizeOf(context).height;
    return NotificationListener<UserScrollNotification>(
      onNotification: _onScroll,
      child: SingleChildScrollView(
        key: const ValueKey('synced-lyrics'),
        controller: _scroll,
        // Room below the last line so it, too, can scroll up to where the
        // playing line sits, clear of the system bar.
        padding: EdgeInsets.fromLTRB(16, height * 0.12, 16,
            MediaQuery.viewPaddingOf(context).bottom + height * 0.4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.lines.length; i++)
              _LyricLineTile(
                key: _keys[i],
                line: widget.lines[i],
                active: i == _active,
                past: i < _active,
                style: base,
                colors: colors,
                animate: !reduceMotion,
                onTap: () => _seek(widget.lines[i]),
              ),
            if (widget.footer != null) widget.footer!,
          ],
        ),
      ),
    );
  }
}

class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    super.key,
    required this.line,
    required this.active,
    required this.past,
    required this.style,
    required this.colors,
    required this.animate,
    required this.onTap,
  });

  final LyricLine line;
  final bool active;
  final bool past;
  final TextStyle? style;
  final ColorScheme colors;
  final bool animate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = line.text;
    final color = active
        ? colors.onSurface
        : colors.onSurfaceVariant.withValues(alpha: past ? 0.55 : 0.75);
    return Semantics(
      selected: active,
      button: true,
      hint: 'پخش از این خط',
      child: InkWell(
        borderRadius: BorderRadius.circular(RhythmoRadii.lg),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Center(
              child: AnimatedDefaultTextStyle(
                duration: animate ? RhythmoMotion.medium : Duration.zero,
                curve: RhythmoMotion.standard,
                style: (style ?? const TextStyle()).copyWith(
                  color: color,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
                // An empty timed line is an instrumental break.
                child: text.isEmpty
                    ? Icon(RhythmoIcons.musicNotes, size: 22, color: color)
                    : Text(
                        text,
                        textAlign: TextAlign.center,
                        textDirection: lyricDirection(text),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the lyrics come from, so a wrong match is easy to notice.
class LyricsSource extends StatelessWidget {
  const LyricsSource({super.key, required this.match});

  final LyricsMatch? match;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final match = this.match;
    final name = match == null
        ? null
        : [match.trackName, match.artistName]
            .where((part) => part.isNotEmpty)
            .join(' — ');
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Text(
        name == null || name.isEmpty
            ? 'متن از LRCLIB'
            : 'متن از LRCLIB · $name',
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The owner picks another LRCLIB entry when the match is wrong: the
/// entries for the track itself, or a search of their own.
class LyricsChooser extends StatefulWidget {
  const LyricsChooser({super.key, required this.track, required this.lyrics});

  final Track track;
  final LyricsController lyrics;

  @override
  State<LyricsChooser> createState() => _LyricsChooserState();
}

class _LyricsChooserState extends State<LyricsChooser> {
  final _query = TextEditingController();
  List<LyricsMatch>? _matches;
  bool _failed = false;
  bool _saving = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final request = ++_request;
    setState(() {
      _matches = null;
      _failed = false;
    });
    try {
      final found =
          await widget.lyrics.candidates(widget.track, query: _query.text);
      if (mounted && request == _request) setState(() => _matches = found);
    } catch (_) {
      if (mounted && request == _request) setState(() => _failed = true);
    }
  }

  Future<void> _pick(LyricsMatch match) async {
    setState(() => _saving = true);
    try {
      final lyrics = await widget.lyrics.choose(widget.track, match);
      if (mounted) Navigator.of(context).pop(lyrics);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('این متن ذخیره نشد. دوباره امتحان کنید.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _matches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 12),
          child: Text(
            'انتخاب متن آهنگ',
            style: theme.textTheme.titleLarge,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'جستجوی عنوان یا هنرمند',
              prefixIcon: const Icon(RhythmoIcons.magnifyingGlass),
              suffixIcon: IconButton(
                tooltip: 'جستجو',
                onPressed: _search,
                icon: const Icon(RhythmoIcons.check),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_saving) const LinearProgressIndicator(),
        Expanded(
          child: _failed
              ? LyricsMessage(
                  icon: RhythmoIcons.warningCircle,
                  title: 'جستجو انجام نشد',
                  action: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: _search,
                    child: const Text('تلاش دوباره'),
                  ),
                )
              : matches == null
                  ? const Center(child: CircularProgressIndicator())
                  : matches.isEmpty
                      ? const LyricsMessage(
                          icon: RhythmoIcons.quotes,
                          title: 'متنی پیدا نشد',
                          detail: 'عنوان یا نام هنرمند را جستجو کنید.',
                        )
                      : ListView.builder(
                          padding: EdgeInsets.only(
                            bottom:
                                MediaQuery.viewPaddingOf(context).bottom + 16,
                          ),
                          itemCount: matches.length,
                          itemBuilder: (context, index) => _MatchTile(
                            match: matches[index],
                            onTap: _saving ? null : () => _pick(matches[index]),
                          ),
                        ),
        ),
      ],
    );
  }
}

class _MatchTile extends StatelessWidget {
  const _MatchTile({required this.match, required this.onTap});

  final LyricsMatch match;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final duration = match.duration;
    final details = [
      if (match.artistName.isNotEmpty) match.artistName,
      if (match.albumName.isNotEmpty) match.albumName,
      if (duration != null)
        persianDigits(
            '${duration.inMinutes}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}'),
    ].join(' · ');
    return ListTile(
      minTileHeight: 64,
      contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 24),
      onTap: onTap,
      title: Text(
        match.trackName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: match.synced
          ? Tooltip(
              message: 'متن همگام با آهنگ',
              child: Icon(
                RhythmoIcons.waveform,
                color: Theme.of(context).colorScheme.primary,
              ),
            )
          : null,
    );
  }
}
