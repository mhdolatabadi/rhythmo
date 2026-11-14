import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/core/quiet_after_dispose.dart';
import 'package:rhythmo/features/settings/data/storage_request.dart';

/// The account's request for more cloud storage (#208).
class StorageRequestController extends ChangeNotifier with QuietAfterDispose {
  StorageRequestController(
      {required StorageRequestApi api, required String? Function() token})
      : _api = api,
        _token = token;

  final StorageRequestApi _api;
  final String? Function() _token;

  StorageRequest? _latest;
  bool _loaded = false;
  bool _sending = false;
  String? _error;

  /// The latest request, or null when there is none (or not loaded yet).
  StorageRequest? get latest => _latest;
  bool get loaded => _loaded;
  bool get sending => _sending;

  /// Why the last request failed, for people.
  String? get error => _error;

  Future<void> load() async {
    final token = _token();
    if (token == null) return;
    try {
      _latest = await _api.myStorageRequest(token);
      _loaded = true;
    } catch (_) {
      // The card simply offers the request again.
    }
    notifyListeners();
  }

  /// Asks for [bytes] in all; true when it was sent.
  Future<bool> request(int bytes, {String reason = ''}) async {
    final token = _token();
    if (token == null || _sending) return false;
    _sending = true;
    _error = null;
    notifyListeners();
    try {
      _latest = await _api.requestStorage(token, bytes, reason: reason.trim());
      return true;
    } on ApiException catch (error) {
      _error = switch (error.code) {
        'request_open' => 'درخواست قبلی‌ات هنوز در حال بررسی است.',
        'email_unverified' =>
          'برای درخواست فضای بیشتر، اول ایمیلت را تأیید کن.',
        'rate_limited' => 'امروز چند بار درخواست داده‌ای. فردا دوباره تلاش کن.',
        'invalid_storage_request' => 'این مقدار از فضای فعلی‌ات بیشتر نیست.',
        _ => 'فرستادن درخواست ناموفق بود. دوباره تلاش کن.',
      };
      if (error.code == 'request_open') await load();
      return false;
    } catch (_) {
      _error = 'فرستادن درخواست ناموفق بود. دوباره تلاش کن.';
      return false;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  void clear() {
    _latest = null;
    _loaded = false;
    _error = null;
    notifyListeners();
  }
}
