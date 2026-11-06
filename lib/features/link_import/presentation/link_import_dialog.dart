import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/tokens.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/format_size.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/link_import/application/link_import_controller.dart';
import 'package:rhythmo/features/link_import/data/link_import.dart';

/// Asks for a link to a song page, an audio file or a YouTube or Instagram
/// video and starts importing selected files; a Spotify link becomes a
/// playlist of the titles already in the library. Returns the message to show
/// once done, or null if closed.
Future<String?> showLinkImportDialog(
  BuildContext context, {
  required LinkImportController controller,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _LinkImportDialog(controller: controller),
    );

class _LinkImportDialog extends StatefulWidget {
  const _LinkImportDialog({required this.controller});

  final LinkImportController controller;

  @override
  State<_LinkImportDialog> createState() => _LinkImportDialogState();
}

class _LinkImportDialogState extends State<_LinkImportDialog> {
  final _field = TextEditingController();
  String? _error;
  List<LinkImportCandidate>? _candidates;
  final Set<int> _selected = {};
  SpotifyImportResult? _spotify;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _field.text = text;
      _error = null;
      _candidates = null;
      _selected.clear();
    });
  }

  Future<void> _scan() async {
    final url = _field.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'لینک صفحه‌ی آهنگ یا فایل را بچسبان.');
      return;
    }
    setState(() => _error = null);
    try {
      if (isSpotifyLink(url)) {
        final result = await widget.controller.importSpotify(url);
        if (!mounted) return;
        setState(() => _spotify = result);
        return;
      }
      final candidates = await widget.controller.preview(url);
      if (!mounted) return;
      setState(() {
        _candidates = candidates;
        _selected
          ..clear()
          ..addAll(List<int>.generate(candidates.length, (i) => i));
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = linkImportMessage(e.code));
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = linkImportMessage(null));
    }
  }

  Future<void> _submitSelected() async {
    final candidates = _candidates;
    if (candidates == null) {
      await _scan();
      return;
    }
    final selected = [
      for (final i in _selected)
        if (i >= 0 && i < candidates.length) candidates[i],
    ];
    final result = await widget.controller.submitCandidates(selected);
    if (!mounted) return;
    if (result.queued) {
      Navigator.pop(context, result.message);
    } else {
      setState(() => _error = result.message);
    }
  }

  String _spotifyMessage(SpotifyImportResult result) => result.playlistId ==
          null
      ? 'هیچ‌کدام از آهنگ‌های این لینک در «موسیقی من» نبود.'
      : 'فهرست پخش «${result.name}» با ${persianDigits(result.matched.length)} آهنگ ساخته شد.';

  void _toggle(int index, bool? value) {
    setState(() {
      if (value ?? false) {
        _selected.add(index);
      } else {
        _selected.remove(index);
      }
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final busy = widget.controller.submitting;
        if (_spotify case final result?) {
          return _SpotifyResultDialog(
            result: result,
            message: _spotifyMessage(result),
          );
        }
        final candidates = _candidates;
        final hasCandidates = candidates != null;
        return AlertDialog(
          title: const Text('افزودن از لینک'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(hasCandidates
                    ? 'فایل‌های صوتی پیدا شده را انتخاب کن.'
                    : 'لینک صفحه‌ی آهنگ، فایل صوتی، ویدیوی یوتیوب یا اینستاگرام را بچسبان. از لینک اسپاتیفای، آهنگ‌هایی که در «موسیقی من» داری در یک فهرست پخش جمع می‌شوند.'),
                const SizedBox(height: 16),
                TextField(
                  controller: _field,
                  autofocus: !hasCandidates,
                  enabled: !busy && !hasCandidates,
                  keyboardType: TextInputType.url,
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.go,
                  onChanged: (_) {
                    if (_candidates == null) return;
                    setState(() {
                      _candidates = null;
                      _selected.clear();
                    });
                  },
                  onSubmitted: (_) =>
                      hasCandidates ? _submitSelected() : _scan(),
                  decoration: InputDecoration(
                    labelText: 'لینک',
                    hintText: 'https://',
                    hintTextDirection: TextDirection.ltr,
                    errorText: _error,
                    errorMaxLines: 3,
                    suffixIcon: hasCandidates
                        ? IconButton(
                            tooltip: 'تغییر لینک',
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                      _candidates = null;
                                      _selected.clear();
                                      _error = null;
                                    }),
                            icon: const Icon(RhythmoIcons.pencilSimple),
                          )
                        : IconButton(
                            tooltip: 'چسباندن',
                            onPressed: busy ? null : _paste,
                            icon: const Icon(RhythmoIcons.copy),
                          ),
                  ),
                ),
                if (candidates != null) ...[
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: Scrollbar(
                      thumbVisibility: candidates.length > 4,
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: candidates.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final candidate = candidates[index];
                          final source = candidate.site.isEmpty
                              ? candidate.url
                              : candidate.site;
                          final details = [
                            if (candidate.durationSeconds > 0)
                              _formatDuration(candidate.durationSeconds),
                            if (candidate.sizeBytes > 0)
                              formatSize(candidate.sizeBytes),
                          ].join(' · ');
                          return CheckboxListTile(
                            value: _selected.contains(index),
                            onChanged: busy ? null : (v) => _toggle(index, v),
                            secondary: candidate.thumbnailUrl == null
                                ? null
                                : _Thumbnail(url: candidate.thumbnailUrl!),
                            title: Text(candidate.displayTitle,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            // The artist first; the site or size support it.
                            subtitle: candidate.artist == null
                                ? Text(
                                    details.isEmpty
                                        ? source
                                        : '$source · $details',
                                    textDirection: TextDirection.ltr,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis)
                                : Text(
                                    details.isEmpty
                                        ? candidate.artist!
                                        : '${candidate.artist!} · $details',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('انصراف'),
            ),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : hasCandidates
                      ? _submitSelected
                      : _scan,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      hasCandidates ? RhythmoIcons.check : RhythmoIcons.link),
              label: Text(busy
                  ? 'در حال بررسی…'
                  : hasCandidates
                      ? 'افزودن انتخاب‌شده‌ها'
                      : 'بررسی لینک'),
            ),
          ],
        );
      },
    );
  }
}

String _formatDuration(int seconds) {
  final minutes = seconds ~/ 60;
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return persianDigits('$minutes:$rest');
}

/// A video's preview image, or a note icon if it can't be loaded.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(RhythmoRadii.xs),
      child: SizedBox.square(
        dimension: 48,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          excludeFromSemantics: true,
          errorBuilder: (_, __, ___) => ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Icon(RhythmoIcons.musicNote, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// What a Spotify link turned into, with the titles that weren't found.
class _SpotifyResultDialog extends StatelessWidget {
  const _SpotifyResultDialog({required this.result, required this.message});

  final SpotifyImportResult result;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = result.missing;
    return AlertDialog(
      title: const Text('فهرست پخش از اسپاتیفای'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message),
            if (missing.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '${persianDigits(missing.length)} آهنگ در «موسیقی من» پیدا نشد:',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: Scrollbar(
                  thumbVisibility: missing.length > 5,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: missing.length,
                    itemBuilder: (context, index) {
                      final item = missing[index];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(RhythmoIcons.musicNote,
                            color: theme.colorScheme.onSurfaceVariant),
                        title: Text(item.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: item.artists.isEmpty
                            ? null
                            : Text(item.artists.join('، '),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                      );
                    },
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, message),
          icon: const Icon(RhythmoIcons.check),
          label: const Text('تمام'),
        ),
      ],
    );
  }
}

/// Says which of this session's link imports failed, and why.
class LinkImportFailures extends StatelessWidget {
  const LinkImportFailures({super.key, required this.controller});

  final LinkImportController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final failures = controller.failures;
        if (failures.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Card(
            color: scheme.errorContainer.withValues(alpha: 0.35),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(RhythmoIcons.warningCircle, color: scheme.error),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('افزودن از لینک ناموفق بود'),
                      ),
                      IconButton(
                        tooltip: 'بستن',
                        onPressed: controller.dismissFailures,
                        icon: const Icon(RhythmoIcons.x),
                      ),
                    ],
                  ),
                  for (final job in failures)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 12),
                      child: Text(
                        '«${job.fileName}»${job.site.isEmpty ? '' : ' از ${job.site}'}: ${linkImportMessage(job.error)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
