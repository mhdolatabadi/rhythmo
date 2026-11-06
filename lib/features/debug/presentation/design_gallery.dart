import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';

/// Opens the design gallery. It exists only in debug builds; release
/// builds never reach it.
void openDesignGallery(BuildContext context) {
  if (!kDebugMode) return;
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => const DesignGallery(),
  ));
}

/// Every token and shared component on one page, for checking the system by
/// eye and for screenshot tests at phone and desktop widths.
class DesignGallery extends StatelessWidget {
  const DesignGallery({super.key});

  static const colors = <(String, Color)>[
    ('background', RhythmoColors.background),
    ('surface', RhythmoColors.surface),
    ('surfaceStrong', RhythmoColors.surfaceStrong),
    ('surfaceRaised', RhythmoColors.surfaceRaised),
    ('primary', RhythmoColors.primary),
    ('primaryContainer', RhythmoColors.primaryContainer),
    ('secondary', RhythmoColors.secondary),
    ('secondaryContainer', RhythmoColors.secondaryContainer),
    ('onSurface', RhythmoColors.onSurface),
    ('onSurfaceVariant', RhythmoColors.onSurfaceVariant),
    ('outline', RhythmoColors.outline),
    ('outlineVariant', RhythmoColors.outlineVariant),
  ];

  static const spacing = <(String, double)>[
    ('xs', RhythmoSpace.xs),
    ('sm', RhythmoSpace.sm),
    ('md', RhythmoSpace.md),
    ('lg', RhythmoSpace.lg),
    ('xl', RhythmoSpace.xl),
    ('xxl', RhythmoSpace.xxl),
    ('xxxl', RhythmoSpace.xxxl),
    ('huge', RhythmoSpace.huge),
  ];

  static const radii = <(String, double)>[
    ('xs', RhythmoRadii.xs),
    ('sm', RhythmoRadii.sm),
    ('md', RhythmoRadii.md),
    ('lg', RhythmoRadii.lg),
    ('xl', RhythmoRadii.xl),
    ('sheet', RhythmoRadii.sheet),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final types = <(String, TextStyle?)>[
      ('displaySmall', text.displaySmall),
      ('headlineSmall', text.headlineSmall),
      ('titleLarge', text.titleLarge),
      ('titleMedium', text.titleMedium),
      ('bodyLarge', text.bodyLarge),
      ('bodyMedium', text.bodyMedium),
      ('labelLarge', text.labelLarge),
      ('labelMedium', text.labelMedium),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('سامانهٔ طراحی')),
      body: RhythmoBackdrop(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: RhythmoSpace.pageWidth),
            child: ListView(
              padding:
                  rhythmoListBottomPadding(context, extra: RhythmoSpace.xxxl),
              children: [
                const RhythmoSectionHeader(title: 'رنگ‌ها'),
                _Wrap(children: [
                  for (final (name, color) in colors)
                    _Swatch(name: name, color: color),
                ]),
                const RhythmoSectionHeader(title: 'حروف'),
                for (final (name, style) in types)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: RhythmoSpace.xxl,
                        vertical: RhythmoSpace.xs),
                    child: Text('$name · ریتمو، موسیقی تو', style: style),
                  ),
                const RhythmoSectionHeader(title: 'فاصله‌ها و گوشه‌ها'),
                _Wrap(children: [
                  for (final (name, value) in spacing)
                    _Measure(label: name, value: value, width: value),
                ]),
                _Wrap(children: [
                  for (final (name, value) in radii)
                    _Measure(label: name, value: value, radius: value),
                ]),
                const RhythmoSectionHeader(title: 'لایه‌های شیشه'),
                _Wrap(children: [
                  for (final (name, level) in const [
                    ('chrome', RhythmoGlassLevel.chrome),
                    ('panel', RhythmoGlassLevel.panel),
                    ('card', RhythmoGlassLevel.card),
                  ])
                    SizedBox(
                      width: 140,
                      height: 88,
                      child: GlassSurface.level(
                        level,
                        child: Center(child: Text(name)),
                      ),
                    ),
                ]),
                const RhythmoSectionHeader(
                  title: 'دکمه‌ها',
                  subtitle: 'با تب یا کلیدهای جهت، حلقهٔ تمرکز دیده می‌شود.',
                ),
                _Wrap(children: [
                  FilledButton(onPressed: () {}, child: const Text('اصلی')),
                  FilledButton.tonal(
                      onPressed: () {}, child: const Text('ثانویه')),
                  OutlinedButton(onPressed: () {}, child: const Text('دورخط')),
                  TextButton(onPressed: () {}, child: const Text('متنی')),
                  const FilledButton(onPressed: null, child: Text('غیرفعال')),
                  IconButton(
                    tooltip: 'نمونه',
                    onPressed: () {},
                    icon: const Icon(RhythmoIcons.heart),
                  ),
                  IconButton.filled(
                    tooltip: 'پخش',
                    onPressed: () {},
                    icon: const Icon(RhythmoIcons.playFill),
                  ),
                ]),
                const RhythmoSectionHeader(title: 'برچسب‌ها و لغزنده'),
                _Wrap(children: [
                  FilterChip(
                      label: const Text('انتخاب‌شده'),
                      selected: true,
                      onSelected: (_) {}),
                  FilterChip(label: const Text('معمولی'), onSelected: (_) {}),
                  const Chip(label: Text('فقط نمایش')),
                ]),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: RhythmoSpace.lg),
                  child: Slider(value: 0.4, onChanged: (_) {}),
                ),
                RhythmoSectionHeader(
                  title: 'ردیف آهنگ',
                  trailing: TextButton(
                    onPressed: () {},
                    child: const Text('همه'),
                  ),
                ),
                RhythmoTrackRow(
                  seed: 'gallery-1',
                  title:
                      'آهنگی با عنوانی بسیار بلند که هرگز در یک خط جا نمی‌شود',
                  subtitle: 'هنرمند',
                  detail: persianDigits('۳٫۲ مگابایت'),
                  onTap: () {},
                  trailing: IconButton(
                    tooltip: 'اقدامات آهنگ',
                    onPressed: () {},
                    icon: const Icon(RhythmoIcons.dotsThreeVertical),
                  ),
                ),
                RhythmoTrackRow(
                  seed: 'gallery-2',
                  title: 'Now playing',
                  subtitle: 'Artist',
                  active: true,
                  onTap: () {},
                ),
                const RhythmoSectionHeader(title: 'حالت‌ها'),
                const SizedBox(
                  height: 280,
                  child: RhythmoStateView(
                    icon: RhythmoIcons.musicNotes,
                    title: '«موسیقی من» خالی است',
                    message: 'با «افزودن موسیقی» اولین آهنگ را اضافه کنید.',
                  ),
                ),
                SizedBox(
                  height: 300,
                  child: RhythmoStateView.error(
                    icon: RhythmoIcons.cloudSlash,
                    title: '«موسیقی من» دریافت نشد',
                    message: 'اتصال اینترنت را بررسی کنید.',
                    action: FilledButton.icon(
                      onPressed: () {},
                      icon: const Icon(RhythmoIcons.arrowsClockwise),
                      label: const Text('تلاش دوباره'),
                    ),
                  ),
                ),
                const SizedBox(
                  height: 200,
                  child: RhythmoStateView.loading(title: 'در حال بارگذاری…'),
                ),
                const RhythmoSectionHeader(title: 'برگه و گفت‌وگو'),
                _Wrap(children: [
                  OutlinedButton(
                    onPressed: () => showRhythmoSheet<void>(
                      context,
                      builder: (_) => RhythmoSheetFrame(
                        title: 'برگهٔ نمونه',
                        child: ListView(
                          padding: rhythmoListBottomPadding(context),
                          children: [
                            for (var i = 1; i <= 12; i++)
                              RhythmoTrackRow(
                                seed: 'sheet-$i',
                                title: 'آهنگ ${persianDigits(i)}',
                                subtitle: 'هنرمند',
                              ),
                          ],
                        ),
                      ),
                    ),
                    child: const Text('باز کردن برگه'),
                  ),
                  OutlinedButton(
                    onPressed: () => showRhythmoConfirm(
                      context,
                      title: 'حذف فهرست پخش؟',
                      message: 'آهنگ‌های «موسیقی من» حذف نمی‌شوند.',
                      confirmLabel: 'حذف',
                      destructive: true,
                    ),
                    child: const Text('گفت‌وگوی تأیید'),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Wrap extends StatelessWidget {
  const _Wrap({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: RhythmoSpace.xxl, vertical: RhythmoSpace.sm),
        child: Wrap(
          spacing: RhythmoSpace.md,
          runSpacing: RhythmoSpace.md,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        ),
      );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 56,
            decoration: BoxDecoration(
              color: color,
              borderRadius: RhythmoRadii.control,
              border: Border.all(color: RhythmoColors.softBorder),
            ),
          ),
          const SizedBox(height: RhythmoSpace.xs),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.ltr,
              style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _Measure extends StatelessWidget {
  const _Measure({
    required this.label,
    required this.value,
    this.width,
    this.radius,
  });

  final String label;
  final double value;
  final double? width;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: width ?? 56,
          height: radius == null ? 16 : 56,
          decoration: BoxDecoration(
            color: radius == null ? colors.primary : colors.secondaryContainer,
            borderRadius: BorderRadius.circular(radius ?? RhythmoRadii.bar),
          ),
        ),
        const SizedBox(height: RhythmoSpace.xs),
        Text('$label ${persianDigits(value.round())}',
            style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}
