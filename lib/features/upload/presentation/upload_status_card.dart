import 'package:rhythmo/core/persian_digits.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/design/design.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/features/upload/application/upload_controller.dart';

/// Shows the current upload's progress, result or failure.
class UploadStatusCard extends StatelessWidget {
  const UploadStatusCard({super.key, required this.controller});

  final UploadController controller;

  static String errorMessage(UploadError error) => switch (error) {
        UploadError.unsupportedFormat =>
          'این قالب پشتیبانی نمی‌شود. MP3، M4A، AAC، FLAC، OGG، OPUS، WAV یا WEBM انتخاب کن.',
        UploadError.tooLarge => 'حجم فایل بیشتر از ۲۰۰ مگابایت است.',
        UploadError.emptyFile => 'فایل خالی است.',
        UploadError.invalidAudio => 'این فایل، فایل صوتی معتبری نیست.',
        UploadError.quotaExceeded =>
          'فضای ذخیره‌سازی حسابت پر شده است. چند آهنگ را حذف کن و دوباره تلاش کن.',
        UploadError.tooManyPending =>
          'چند آپلود هنوز در حال تکمیل است. کمی بعد دوباره تلاش کن.',
        UploadError.uploadsDisabled =>
          'آپلود موقتاً غیرفعال است؛ پخش آهنگ‌های موجود همچنان در دسترس است.',
        UploadError.emailUnverified =>
          'برای آپلود، اول ایمیلت را تأیید کن. پخش آهنگ‌ها همین حالا هم کار می‌کند.',
        UploadError.network =>
          'ارسال فایل ناموفق بود. اتصال را بررسی کن و دوباره تلاش کن.',
        UploadError.unknown => 'آپلود ناموفق بود. دوباره تلاش کن.',
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final name = controller.fileName ?? '';
        final step = controller.batchTotal > 1
            ? 'فایل ${persianDigits(controller.batchIndex)} از ${persianDigits(controller.batchTotal)} — '
            : '';
        final (String label, double? progress, bool closable) =
            switch (controller.phase) {
          UploadPhase.idle => ('', null, false),
          UploadPhase.reading => ('در حال خواندن فایل…', null, false),
          UploadPhase.preparing => ('$stepآماده‌سازی «$name»…', null, false),
          UploadPhase.uploading => (
              '$stepدر حال آپلود «$name» — ${persianDigits((controller.progress * 100).round())}٪',
              controller.progress,
              false,
            ),
          UploadPhase.verifying => ('$stepدر حال بررسی «$name»…', null, false),
          UploadPhase.done => (
              controller.batchTotal > 1
                  ? '${persianDigits(controller.batchCompleted)} فایل به «موسیقی من» اضافه شد.'
                  : '«${controller.uploaded?.title ?? name}» به «موسیقی من» اضافه شد.',
              1.0,
              true,
            ),
          UploadPhase.failed => (
              controller.batchTotal > 1
                  ? '${persianDigits(controller.batchCompleted)} از ${persianDigits(controller.batchTotal)} فایل آپلود شد؛ '
                      '${persianDigits(controller.batchFailed)} فایل ناموفق بود. دوباره انتخاب و تلاش کن.'
                  : errorMessage(controller.error!),
              0.0,
              true,
            ),
        };
        if (controller.phase == UploadPhase.idle) {
          return const SizedBox.shrink();
        }
        final failed = controller.phase == UploadPhase.failed;
        return GlassSurface(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 16),
          radius: 18,
          blur: 16,
          tint: failed
              ? Theme.of(context).colorScheme.error
              : RhythmoColors.primary,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    failed
                        ? RhythmoIcons.warningCircle
                        : controller.phase == UploadPhase.done
                            ? RhythmoIcons.checkCircle
                            : RhythmoIcons.uploadSimple,
                    color: failed ? Theme.of(context).colorScheme.error : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(label)),
                  if (closable)
                    IconButton(
                      tooltip: 'بستن',
                      onPressed: controller.dismiss,
                      icon: const Icon(RhythmoIcons.x),
                    ),
                  if (controller.canCancel)
                    TextButton(
                      onPressed: controller.cancel,
                      child: const Text('لغو'),
                    ),
                ],
              ),
              if (!closable) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
              ],
            ],
          ),
        );
      },
    );
  }
}
