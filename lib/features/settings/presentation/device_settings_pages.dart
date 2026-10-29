import 'package:rhythmo/core/design/design.dart';
import 'package:flutter/material.dart';
import 'package:rhythmo/core/widgets/rhythmo_icons.dart';
import 'package:rhythmo/core/persian_digits.dart';
import 'package:rhythmo/features/settings/data/device_settings.dart';

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen(
      {super.key, this.device = const PlatformDeviceSettings()});
  final DeviceSettings device;
  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  late Future<Map<String, bool>> _status;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _status = widget.device.permissions();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
  }

  void _refresh() {
    if (mounted) {
      setState(() => _status = widget.device.permissions());
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    var opened = false;
    try {
      opened = await widget.device.openSettings();
    } catch (_) {/* Show recovery below. */}
    if (!mounted || opened) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'تنظیمات دستگاه باز نشد. از تنظیمات گوشی وارد بخش برنامه‌ها شو.')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('دسترسی‌ها')),
        body: RhythmoBackdrop(
            child: widget.device.supportsNative
                ? FutureBuilder<Map<String, bool>>(
                    future: _status,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError ||
                          snapshot.data?.isEmpty != false) {
                        return Center(
                            child: FilledButton(
                                onPressed: _refresh,
                                child: const Text(
                                    'دریافت دوبارهٔ وضعیت دسترسی‌ها')));
                      }
                      return ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            for (final item in const {
                              'audio': 'آهنگ‌های دستگاه',
                              'microphone': 'میکروفن برای شناسایی آهنگ',
                              'notifications': 'اعلان‌ها'
                            }.entries)
                              ListTile(
                                  title: Text(item.value),
                                  subtitle: Text(
                                      snapshot.data![item.key] == true
                                          ? 'مجاز'
                                          : 'غیرفعال')),
                            const ListTile(
                                title: Text('دسترسی‌ها را خودت مدیریت می‌کنی'),
                                subtitle: Text(
                                    'بازکردن این صفحه هیچ دسترسی تازه‌ای درخواست نمی‌کند.')),
                            FilledButton(
                                onPressed: _open,
                                child: const Text('بازکردن تنظیمات دستگاه')),
                          ]);
                    })
                : const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'در وب، دسترسی میکروفن و فایل‌ها را از تنظیمات همین سایت در مرورگر مدیریت کن. دسترسی فقط هنگام استفاده از قابلیت مربوط درخواست می‌شود.'))),
      );
}

class AboutScreen extends StatefulWidget {
  const AboutScreen(
      {super.key,
      this.device = const PlatformDeviceSettings(),
      required this.openPage});
  final DeviceSettings device;
  final Future<void> Function(String path) openPage;
  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  late Future<String?> _version = widget.device.appVersion();
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('دربارهٔ ریتمو')),
        body: RhythmoBackdrop(
            child: ListView(padding: const EdgeInsets.all(16), children: [
          const ListTile(
              title: Text('ریتمو'),
              subtitle: Text('موسیقی شخصی تو، روی وب و اندروید')),
          FutureBuilder<String?>(
              future: _version,
              builder: (context, snapshot) => ListTile(
                  title: const Text('نسخهٔ برنامه'),
                  subtitle:
                      Text(snapshot.connectionState != ConnectionState.done
                          ? 'در حال دریافت…'
                          : snapshot.data == null
                              ? 'نسخه دریافت نشد'
                              : persianDigits(snapshot.data!)),
                  trailing: snapshot.connectionState == ConnectionState.done &&
                          snapshot.data == null
                      ? IconButton(
                          tooltip: 'تلاش دوباره',
                          onPressed: () => setState(
                              () => _version = widget.device.appVersion()),
                          icon: const Icon(RhythmoIcons.arrowsClockwise))
                      : null)),
          ListTile(
              title: const Text('وب‌سایت ریتمو'),
              onTap: () => widget.openPage('/')),
          ListTile(
              title: const Text('حریم خصوصی'),
              onTap: () => widget.openPage('/privacy')),
          ListTile(
              title: const Text('مجوزهای نرم‌افزار'),
              onTap: () =>
                  showLicensePage(context: context, applicationName: 'ریتمو')),
        ])),
      );
}
