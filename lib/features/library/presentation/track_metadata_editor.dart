import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:flutter/services.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/library/application/metadata_suggestions.dart';
import 'package:rhythmo/features/library/data/track.dart';
import 'package:rhythmo/features/library/data/track_metadata.dart';

/// Saves a draft based on a metadata version; see
/// `LibraryController.saveTrackMetadata`.
typedef SaveTrackMetadata = Future<MetadataSaveResult> Function(
    TrackMetadataDraft draft, int version);

/// Opens the editor for an owned cloud [track] and returns the saved track,
/// or null when nothing was saved.
Future<Track?> showTrackMetadataEditor(
  BuildContext context, {
  required Track track,
  required SaveTrackMetadata onSave,
  MetadataSuggestions suggestions = MetadataSuggestions.empty,
}) =>
    Navigator.of(context).push(MaterialPageRoute<Track>(
      builder: (_) => TrackMetadataEditor(
          track: track, onSave: onSave, suggestions: suggestions),
    ));

/// Limits the server enforces; checked here first so mistakes show at once.
const _maxText = 200;
const _maxComment = 1000;
const _maxNumber = 999;
const _unsafeFileNameCharacters = r'/\<>:"|?*';

/// A full-screen form for a cloud track's file name and embedded metadata.
class TrackMetadataEditor extends StatefulWidget {
  const TrackMetadataEditor({
    super.key,
    required this.track,
    required this.onSave,
    this.suggestions = MetadataSuggestions.empty,
  });

  final Track track;
  final SaveTrackMetadata onSave;

  /// Values used elsewhere in the library, offered as the user types.
  final MetadataSuggestions suggestions;

  @override
  State<TrackMetadataEditor> createState() => _TrackMetadataEditorState();
}

class _TrackMetadataEditorState extends State<TrackMetadataEditor> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  final _fileName = TextEditingController();
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final _album = TextEditingController();
  final _albumArtist = TextEditingController();
  final _composer = TextEditingController();
  final _genre = TextEditingController();
  final _year = TextEditingController();
  final _trackNumber = TextEditingController();
  final _discNumber = TextEditingController();
  final _comment = TextEditingController();

  /// The server copy the edit is based on; its version goes with the save.
  late Track _base;
  late TrackMetadataDraft _initial;
  late String _extension;
  bool _saving = false;
  bool _dirty = false;
  bool _done = false;
  Track? _conflict;
  String? _error;
  final Map<String, String> _serverErrors = {};

  List<TextEditingController> get _controllers => [
        _fileName,
        _title,
        _artist,
        _album,
        _albumArtist,
        _composer,
        _genre,
        _year,
        _trackNumber,
        _discNumber,
        _comment,
      ];

  @override
  void initState() {
    super.initState();
    _load(widget.track);
    for (final controller in _controllers) {
      controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _load(Track track) {
    _base = track;
    final name = track.fileName ?? '';
    final dot = name.lastIndexOf('.');
    _extension = dot > 0 ? name.substring(dot) : '';
    _fileName.text = dot > 0 ? name.substring(0, dot) : name;
    _title.text = track.title;
    _artist.text = track.artist ?? '';
    _album.text = track.album ?? '';
    _albumArtist.text = track.albumArtist ?? '';
    _composer.text = track.composer ?? '';
    _genre.text = track.genre ?? '';
    _year.text = track.year?.toString() ?? '';
    _trackNumber.text = track.trackNumber?.toString() ?? '';
    _discNumber.text = track.discNumber?.toString() ?? '';
    _comment.text = track.comment ?? '';
    _initial = TrackMetadataDraft.fromTrack(track);
    _dirty = false;
  }

  TrackMetadataDraft get _draft => TrackMetadataDraft(
        fileName: _fileName.text.trim().isEmpty
            ? ''
            : '${_fileName.text.trim()}$_extension',
        title: _title.text,
        artist: _artist.text,
        album: _album.text,
        albumArtist: _albumArtist.text,
        composer: _composer.text,
        genre: _genre.text,
        comment: _comment.text,
        year: int.tryParse(_year.text.trim()),
        trackNumber: int.tryParse(_trackNumber.text.trim()),
        discNumber: int.tryParse(_discNumber.text.trim()),
      );

  void _changed() {
    final dirty = !_draft.sameAs(_initial) ||
        // A typed number that does not parse is still a change.
        _year.text.trim() != (_initial.year?.toString() ?? '') ||
        _trackNumber.text.trim() != (_initial.trackNumber?.toString() ?? '') ||
        _discNumber.text.trim() != (_initial.discNumber?.toString() ?? '');
    if (dirty != _dirty || _serverErrors.isNotEmpty) {
      setState(() {
        _dirty = dirty;
        _serverErrors.clear();
      });
    }
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() => _error = null);
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final result = await widget.onSave(_draft, _base.version);
    if (!mounted) return;
    setState(() => _saving = false);
    switch (result) {
      case MetadataSaved(:final track):
        _done = true;
        Navigator.of(context).pop(track);
      case MetadataConflict(:final latest):
        setState(() => _conflict = latest);
        // The choice is at the top of the form.
        if (_scroll.hasClients) {
          unawaited(_scroll.animateTo(0,
              duration: RhythmoMotion.medium, curve: RhythmoMotion.standard));
        }
      case MetadataInvalid(:final field):
        setState(() {
          _serverErrors[field] = 'سرور این مقدار را نپذیرفت؛ آن را اصلاح کن.';
          _form.currentState?.validate();
        });
      case MetadataSaveFailed():
        setState(() => _error = _base.id.startsWith('device:')
            ? 'ذخیره در فایل انجام نشد. دسترسی ویرایش یا پشتیبانی قالب فایل را بررسی کن.'
            : 'ذخیره نشد. اتصال اینترنت را بررسی کن و دوباره تلاش کن.');
    }
  }

  void _useLatest() {
    final latest = _conflict;
    if (latest == null) return;
    setState(() {
      _conflict = null;
      _load(latest);
    });
  }

  void _keepMine() {
    final latest = _conflict;
    if (latest == null) return;
    setState(() {
      _conflict = null;
      // The next save replaces the newer copy with what is in the form.
      _base = latest;
      _initial = TrackMetadataDraft.fromTrack(latest);
    });
    _changed();
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(RhythmoIcons.warningCircle),
        title: const Text('تغییرات ذخیره نشده‌اند'),
        content: const Text('اگر بیرون بروی، تغییراتی که دادی از بین می‌رود.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ادامهٔ ویرایش'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('دور ریختن تغییرات'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      _done = true;
      Navigator.of(context).pop();
    }
  }

  String? _serverError(String field) => _serverErrors[field];

  String? _validateText(String field, String? value, {bool required = false}) {
    final text = value?.trim() ?? '';
    if (required && text.isEmpty) return 'این مورد نباید خالی باشد.';
    if (text.runes.length > _maxText) {
      return 'حداکثر $_maxText نویسه.';
    }
    if (text.runes.any((r) => r < 0x20 || r == 0x7F)) {
      return 'نویسه‌های نامعتبر را حذف کن.';
    }
    return _serverError(field);
  }

  String? _validateFileName(String? value) {
    final stem = value?.trim() ?? '';
    if (stem.isEmpty) return 'نام فایل نباید خالی باشد.';
    if (stem.startsWith('.') || stem.endsWith('.')) {
      return 'نام فایل نباید با نقطه شروع یا تمام شود.';
    }
    if (stem.runes.any((r) =>
        r < 0x20 ||
        _unsafeFileNameCharacters.contains(String.fromCharCode(r)) ||
        (r >= 0x202A && r <= 0x202E) ||
        (r >= 0x2066 && r <= 0x2069))) {
      return r'این نویسه‌ها مجاز نیستند: / \ < > : " | ? *';
    }
    if ((stem + _extension).runes.length > _maxText) {
      return 'نام فایل خیلی بلند است.';
    }
    return _serverError('fileName');
  }

  String? _validateNumber(String field, String? value, int min, int max) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return _serverError(field);
    final number = int.tryParse(text);
    if (number == null || number < min || number > max) {
      return 'عددی بین $min و $max وارد کن.';
    }
    return _serverError(field);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return PopScope(
      canPop: _done || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ویرایش اطلاعات آهنگ'),
          leading: IconButton(
            tooltip: 'بستن',
            icon: const Icon(RhythmoIcons.x),
            onPressed: _saving ? null : () => Navigator.maybePop(context),
          ),
        ),
        bottomNavigationBar: _SaveBar(
          error: _error,
          saving: _saving,
          enabled: _dirty && !_saving && _conflict == null,
          bottomInset: bottomInset,
          onSave: _save,
        ),
        body: RhythmoBackdrop(
            child: Form(
          key: _form,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              // Not a lazy list: every field must exist for the form to
              // validate all of them.
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_conflict != null)
                      _ConflictNotice(
                        onUseLatest: _useLatest,
                        onKeepMine: _keepMine,
                      ),
                    if (_base.id.startsWith('device:'))
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('تغییرات در خود فایل اصلی ذخیره می‌شوند. '
                            'در صورت نیاز، اندروید اجازهٔ ویرایش فایل را می‌پرسد.'),
                      )
                    else
                      _TagStatusNotice(track: _base),
                    _Section(
                      title: 'فایل',
                      children: [
                        _Field(
                          key: const ValueKey('fileName'),
                          controller: _fileName,
                          label: 'نام فایل',
                          helper: _base.id.startsWith('device:')
                              ? 'نام فایل اصلی روی دستگاه؛ قالب فایل تغییر نمی‌کند.'
                              : 'نام فایل هنگام دانلود؛ با عنوان آهنگ فرق دارد. '
                                  'قالب فایل ($_extension) تغییر نمی‌کند.',
                          suffix: _extension,
                          enabled: !_saving,
                          validator: _validateFileName,
                        ),
                      ],
                    ),
                    _Section(
                      title: 'اطلاعات آهنگ',
                      children: [
                        _Field(
                          key: const ValueKey('title'),
                          controller: _title,
                          label: 'عنوان',
                          enabled: !_saving,
                          validator: (v) =>
                              _validateText('title', v, required: true),
                        ),
                        _Field(
                          key: const ValueKey('artist'),
                          options: widget.suggestions.artists,
                          controller: _artist,
                          label: 'خواننده',
                          enabled: !_saving,
                          validator: (v) => _validateText('artist', v),
                        ),
                        _Field(
                          key: const ValueKey('album'),
                          options: widget.suggestions.albums,
                          controller: _album,
                          label: 'آلبوم',
                          enabled: !_saving,
                          validator: (v) => _validateText('album', v),
                        ),
                        _Field(
                          key: const ValueKey('albumArtist'),
                          options: widget.suggestions.artists,
                          controller: _albumArtist,
                          label: 'خوانندهٔ آلبوم',
                          enabled: !_saving,
                          validator: (v) => _validateText('albumArtist', v),
                        ),
                        _Field(
                          key: const ValueKey('composer'),
                          options: widget.suggestions.composers,
                          controller: _composer,
                          label: 'آهنگساز',
                          enabled: !_saving,
                          validator: (v) => _validateText('composer', v),
                        ),
                        _Field(
                          key: const ValueKey('genre'),
                          options: widget.suggestions.genres,
                          controller: _genre,
                          label: 'سبک',
                          enabled: !_saving,
                          validator: (v) => _validateText('genre', v),
                        ),
                      ],
                    ),
                    _Section(
                      title: 'سال و شماره',
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _NumberField(
                              key: const ValueKey('year'),
                              controller: _year,
                              label: 'سال',
                              maxDigits: 4,
                              enabled: !_saving,
                              validator: (v) =>
                                  _validateNumber('year', v, 0, 9999),
                            ),
                            _NumberField(
                              key: const ValueKey('trackNumber'),
                              controller: _trackNumber,
                              label: 'شمارهٔ آهنگ',
                              maxDigits: 3,
                              enabled: !_saving,
                              validator: (v) => _validateNumber(
                                  'trackNumber', v, 1, _maxNumber),
                            ),
                            _NumberField(
                              key: const ValueKey('discNumber'),
                              controller: _discNumber,
                              label: 'شمارهٔ دیسک',
                              maxDigits: 3,
                              enabled: !_saving,
                              validator: (v) => _validateNumber(
                                  'discNumber', v, 1, _maxNumber),
                            ),
                          ],
                        ),
                      ],
                    ),
                    _Section(
                      title: 'یادداشت',
                      children: [
                        _Field(
                          key: const ValueKey('comment'),
                          controller: _comment,
                          label: 'توضیح',
                          maxLines: 5,
                          maxLength: _maxComment,
                          enabled: !_saving,
                          validator: (v) {
                            if ((v ?? '').trim().runes.length > _maxComment) {
                              return 'حداکثر $_maxComment نویسه.';
                            }
                            return _serverError('comment');
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        )),
      ),
    );
  }
}

/// The text direction of a value: right-to-left unless it starts with a
/// left-to-right letter, so Latin titles read naturally in the RTL app.
TextDirection directionOf(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x0590 && rune <= 0x08FF) ||
        (rune >= 0xFB1D && rune <= 0xFDFF) ||
        (rune >= 0xFE70 && rune <= 0xFEFF)) {
      return TextDirection.rtl;
    }
    final char = String.fromCharCode(rune);
    if (char.toUpperCase() != char.toLowerCase()) return TextDirection.ltr;
  }
  return TextDirection.rtl;
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          const SizedBox(height: 10),
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const SizedBox(height: 12),
            child,
          ],
        ],
      ),
    );
  }
}

class _Field extends StatefulWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.label,
    required this.enabled,
    required this.validator,
    this.helper,
    this.suffix,
    this.maxLines = 1,
    this.maxLength,
    this.options = const [],
  });

  final TextEditingController controller;
  final String label;
  final String? helper;
  final String? suffix;
  final bool enabled;
  final int maxLines;
  final int? maxLength;
  final FormFieldValidator<String> validator;

  /// Library values to suggest while typing, most used first.
  final List<String> options;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) return _input(context);
    return RawAutocomplete<String>(
      textEditingController: widget.controller,
      focusNode: _focus,
      optionsBuilder: (value) => matchSuggestions(widget.options, value.text),
      fieldViewBuilder: (context, _, __, onSubmitted) =>
          _input(context, onSubmitted: onSubmitted),
      optionsViewBuilder: (context, onSelected, options) =>
          _SuggestionList(options: options, onSelected: onSelected),
    );
  }

  Widget _input(BuildContext context, {VoidCallback? onSubmitted}) {
    final controller = widget.controller;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextFormField(
        controller: controller,
        focusNode: widget.options.isEmpty ? null : _focus,
        onFieldSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
        enabled: widget.enabled,
        validator: widget.validator,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        textDirection: directionOf(value.text),
        minLines: 1,
        maxLines: widget.maxLines,
        maxLength: widget.maxLength,
        textInputAction: widget.maxLines > 1
            ? TextInputAction.newline
            : TextInputAction.next,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helper,
          helperMaxLines: 3,
          errorMaxLines: 3,
          suffixText: widget.suffix,
        ),
      ),
    );
  }
}

/// The dropdown under a field: one 48-pixel row per suggestion.
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.options, required this.onSelected});

  final Iterable<String> options;
  final AutocompleteOnSelected<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlighted = AutocompleteHighlightedOption.of(context);
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: Material(
        key: const ValueKey('suggestions'),
        elevation: 6,
        color: scheme.surfaceContainerHigh,
        borderRadius: RhythmoRadii.control,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240, maxWidth: 608),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            shrinkWrap: true,
            children: [
              for (final (index, option) in options.indexed)
                InkWell(
                  onTap: () => onSelected(option),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    color: index == highlighted
                        ? scheme.onSurface.withValues(alpha: 0.08)
                        : null,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      option,
                      textDirection: directionOf(option),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    super.key,
    required this.controller,
    required this.label,
    required this.maxDigits,
    required this.enabled,
    required this.validator,
  });

  final TextEditingController controller;
  final String label;
  final int maxDigits;
  final bool enabled;
  final FormFieldValidator<String> validator;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        validator: validator,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.next,
        textDirection: TextDirection.ltr,
        inputFormatters: [
          _PersianDigits(),
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(maxDigits),
        ],
        decoration: InputDecoration(labelText: label, errorMaxLines: 3),
      ),
    );
  }
}

/// Accepts Persian and Arabic-Indic digits from the keyboard as ASCII ones.
class _PersianDigits extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final text = String.fromCharCodes(newValue.text.runes.map((rune) {
      if (rune >= 0x06F0 && rune <= 0x06F9) return rune - 0x06F0 + 0x30;
      if (rune >= 0x0660 && rune <= 0x0669) return rune - 0x0660 + 0x30;
      return rune;
    }));
    return newValue.copyWith(text: text);
  }
}

class _ConflictNotice extends StatelessWidget {
  const _ConflictNotice({required this.onUseLatest, required this.onKeepMine});

  final VoidCallback onUseLatest;
  final VoidCallback onKeepMine;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: GlassSurface(
        key: const ValueKey('conflict'),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        radius: 16,
        tint: RhythmoColors.primary,
        borderColor: RhythmoColors.primary.withValues(alpha: 0.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(RhythmoIcons.warningCircle),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'این آهنگ هم‌زمان جای دیگری تغییر کرده است.',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'می‌توانی نسخهٔ تازه را ببینی، یا تغییرات خودت را نگه داری '
              'و با ذخیره، جایگزین آن کنی.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: onUseLatest,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  child: const Text('نمایش نسخهٔ تازه'),
                ),
                OutlinedButton(
                  onPressed: onKeepMine,
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  child: const Text('نگه‌داشتن تغییرات من'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Explains, when it matters, whether the file itself carries the metadata.
class _TagStatusNotice extends StatelessWidget {
  const _TagStatusNotice({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final tags = track.embeddedTags;
    final format = (track.fileName ?? '').split('.').last.toUpperCase();
    final (IconData icon, String message, bool busy)? notice =
        switch (tags.status) {
      EmbeddedTagStatus.pending => (
          RhythmoIcons.arrowsClockwise,
          'آخرین تغییرات در حال نوشتن در خود فایل است.',
          true,
        ),
      EmbeddedTagStatus.failed => (
          RhythmoIcons.warningCircle,
          'نوشتن اطلاعات در خود فایل ناموفق بود؛ با ذخیرهٔ دوباره، '
              'دوباره تلاش می‌شود. پخش و نام فایل درست کار می‌کنند.',
          false,
        ),
      _ when tags.unsupportedFields.isNotEmpty => (
          RhythmoIcons.warningCircle,
          'فایل‌های $format برچسب داخلی قابل ویرایش ندارند؛ تغییرات در '
              'ریتمو و نام فایل دانلودی ذخیره می‌شود، نه داخل خود فایل.',
          false,
        ),
      _ => null,
    };
    if (notice == null) return const SizedBox.shrink();
    final (icon, message, busy) = notice;
    return GlassSurface(
      key: const ValueKey('tagStatus'),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(14),
      radius: 16,
      blur: 0,
      shadow: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

/// The primary action, pinned above the system navigation area so it never
/// covers the last field.
class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.error,
    required this.saving,
    required this.enabled,
    required this.bottomInset,
    required this.onSave,
  });

  /// Why the last save failed, shown right above the button.
  final String? error;
  final bool saving;
  final bool enabled;
  final double bottomInset;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerLow
          .withValues(alpha: 0.96),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
              top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant)),
        ),
        padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomInset),
        // heightFactor keeps the bar as tall as the button, not the screen.
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ),
                FilledButton.icon(
                  key: const ValueKey('save'),
                  onPressed: enabled ? onSave : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  icon: saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(RhythmoIcons.check),
                  label: Text(saving ? 'در حال ذخیره…' : 'ذخیره'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
