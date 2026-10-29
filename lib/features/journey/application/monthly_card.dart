import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/features/library/data/track.dart';

String listeningMonthLabel(String key) {
  const names = [
    'ژانویه',
    'فوریه',
    'مارس',
    'آوریل',
    'مه',
    'ژوئن',
    'ژوئیه',
    'اوت',
    'سپتامبر',
    'اکتبر',
    'نوامبر',
    'دسامبر'
  ];
  final parts = key.split('-');
  final month = parts.length == 2 ? int.tryParse(parts[1]) : null;
  if (month == null || month < 1 || month > 12) return persianDigits(key);
  return '${names[month - 1]} ${persianDigits(parts[0])} (میلادی)';
}

/// An immutable snapshot with only the information explicitly exported.
class MonthlyListeningCard {
  MonthlyListeningCard(
      {required this.month,
      required Map<String, int> plays,
      required List<Track> library})
      : plays = Map.unmodifiable(plays),
        topTracks = _topTracks(plays, library);

  final String month;
  final Map<String, int> plays;
  final List<Track> topTracks;
  int get total => plays.values.fold<int>(0, (a, b) => a + b);

  static List<Track> _topTracks(Map<String, int> plays, List<Track> library) {
    final unique = {for (final track in library) track.id: track};
    final tracks = unique.values.where((t) => plays.containsKey(t.id)).toList()
      ..sort((a, b) {
        final count = plays[b.id]!.compareTo(plays[a.id]!);
        return count != 0 ? count : a.id.compareTo(b.id);
      });
    return List.unmodifiable(tracks.take(3));
  }

  /// Fixed export dimensions with RTL text layout and the app's bundled font.
  Future<Uint8List> renderPng() async {
    const width = 1080.0;
    const height = 1350.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, width, height),
        Paint()..color = RhythmoColors.background);
    canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(64, 64, 952, 1222),
            const Radius.circular(RhythmoRadii.sheet)),
        Paint()..color = RhythmoColors.surface);
    void text(String value, double top,
        {double size = 36,
        Color color = RhythmoColors.onSurface,
        int lines = 2,
        FontWeight weight = FontWeight.normal}) {
      final painter = TextPainter(
        text: TextSpan(
            text: persianDigits(value),
            style: TextStyle(
                fontFamily: 'Vazirmatn',
                fontSize: size,
                height: 1.5,
                color: color,
                fontWeight: weight)),
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.right,
        maxLines: lines,
        ellipsis: '…',
      )..layout(maxWidth: 824);
      painter.paint(canvas, Offset(128 + 824 - painter.width, top));
      painter.dispose();
    }

    text('خاطرهٔ شنیدن من', 132, size: 58, weight: FontWeight.w700);
    text(listeningMonthLabel(month), 230,
        size: 30, color: RhythmoColors.onSurfaceVariant);
    canvas.drawLine(
        const Offset(128, 320),
        const Offset(952, 320),
        Paint()
          ..color = RhythmoColors.outlineVariant
          ..strokeWidth = 2);
    text('$total بار شنیدن معنادار', 366, size: 44);
    text('${plays.length} آهنگ متفاوت', 448,
        size: 36, color: RhythmoColors.onSurfaceVariant);
    text('همراه‌های محبوب این ماه', 578,
        size: 34, color: RhythmoColors.primary);
    if (topTracks.isEmpty) {
      text('نام آهنگ‌ها در «موسیقی من» در دسترس نیست.', 660,
          size: 30, color: RhythmoColors.onSurfaceVariant);
    }
    for (var i = 0; i < topTracks.length; i++) {
      final track = topTracks[i];
      text(track.title, 660 + i * 140,
          size: 38, lines: 1, weight: FontWeight.w600);
      text(
          '${track.artist == null ? '' : '${track.artist} · '}'
          '${plays[track.id]} بار',
          720 + i * 140,
          size: 26,
          lines: 1,
          color: RhythmoColors.onSurfaceVariant);
    }
    text('ریتمو', 1166, size: 38, weight: FontWeight.w700);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG encoding failed');
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
}
