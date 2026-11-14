import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/tokens.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/features/player/application/equalizer_controller.dart';
import 'package:rhythmo/features/player/data/equalizer.dart';

/// «۶۰ هرتز», «۳٫۶ کیلوهرتز»: a band's centre as listeners read it.
String formatBand(int hz) =>
    '${persianDigits(_bandNumber(hz))} ${hz < 1000 ? 'هرتز' : 'کیلوهرتز'}';

String _bandNumber(int hz) {
  if (hz < 1000) return '$hz';
  final khz = hz / 1000;
  return (khz == khz.roundToDouble()
          ? khz.toInt().toString()
          : khz.toStringAsFixed(1))
      .replaceAll('.', '٫');
}

/// «+۴» / «−۲» / «۰»: a band's gain in decibels.
String formatGain(double db) {
  final rounded = db.round();
  final digits = persianDigits(rounded.abs());
  if (rounded > 0) return '+$digits';
  if (rounded < 0) return '−$digits';
  return digits;
}

/// Opens the equalizer as a bottom sheet.
Future<void> showEqualizerSheet(
        BuildContext context, EqualizerController equalizer) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => EqualizerSheet(equalizer: equalizer),
    );

/// The equalizer (#224): on/off, a few presets and five bands. It changes
/// only how this device plays; files are never touched.
class EqualizerSheet extends StatelessWidget {
  const EqualizerSheet({super.key, required this.equalizer});

  final EqualizerController equalizer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: equalizer,
      builder: (context, _) {
        final settings = equalizer.settings;
        final gains = settings.gainsDb;
        return SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewPaddingOf(context).bottom + 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                key: const ValueKey('equalizer-switch'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                title: Text('اکولایزر',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w500)),
                subtitle: const Text('فقط پخش روی همین دستگاه تغییر می‌کند.'),
                value: settings.enabled,
                onChanged: equalizer.setEnabled,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final preset in EqualizerPreset.values)
                      if (preset != EqualizerPreset.flat)
                        ChoiceChip(
                          label: Text(preset.label),
                          selected:
                              settings.enabled && settings.preset == preset,
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                          onSelected: (_) => equalizer.setPreset(preset),
                        ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AnimatedOpacity(
                opacity: settings.enabled ? 1 : 0.5,
                duration: RhythmoMotion.quick,
                child: SizedBox(
                  height: 220,
                  child: Row(
                    textDirection: TextDirection.ltr,
                    children: [
                      for (var band = 0; band < equalizerBands.length; band++)
                        Expanded(
                          child: _BandSlider(
                            key: ValueKey('equalizer-band-$band'),
                            hz: equalizerBands[band].round(),
                            gainDb: gains[band],
                            onChanged: (value) =>
                                equalizer.setBand(band, value),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (settings.enabled && settings.preset != EqualizerPreset.flat)
                Center(
                  child: TextButton(
                    onPressed: () => equalizer.setPreset(EqualizerPreset.flat),
                    child: const Text('بازنشانی'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _BandSlider extends StatelessWidget {
  const _BandSlider({
    super.key,
    required this.hz,
    required this.gainDb,
    required this.onChanged,
  });

  final int hz;
  final double gainDb;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      children: [
        Text(formatGain(gainDb), style: muted),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              value: gainDb.clamp(-maxBandGainDb, maxBandGainDb).toDouble(),
              min: -maxBandGainDb,
              max: maxBandGainDb,
              divisions: (maxBandGainDb * 2).round(),
              semanticFormatterCallback: (value) =>
                  '${formatBand(hz)}: ${formatGain(value)} دسی‌بل',
              onChanged: onChanged,
            ),
          ),
        ),
        // Number and unit on two lines so five bands fit a narrow phone.
        Text(persianDigits(_bandNumber(hz)), style: muted),
        Text(hz < 1000 ? 'هرتز' : 'کیلوهرتز', style: muted),
      ],
    );
  }
}
