import 'package:flutter/foundation.dart';
import 'package:rhythmo/core/api/api_client.dart';
import 'package:rhythmo/features/auth/data/auth_models.dart';
import 'package:rhythmo/features/auth/data/token_store.dart';

enum AuthStatus { restoring, restoreFailed, signedOut, signedIn }

class AuthController extends ChangeNotifier {
  AuthController({required AuthApi api, required TokenStore tokenStore})
      : _api = api,
        _tokenStore = tokenStore;

  final AuthApi _api;
  final TokenStore _tokenStore;

  AuthStatus _status = AuthStatus.restoring;
  AuthUser? _user;
  String? _token;

  AuthStatus get status => _status;
  AuthUser? get user => _user;

  /// The access token while signed in.
  String? get token => _status == AuthStatus.signedIn ? _token : null;

  /// Restores a saved session. A rejected token is discarded; a network
  /// failure keeps it so the user can retry without signing in again.
  Future<void> restore() async {
    _set(AuthStatus.restoring);
    final token = await _tokenStore.read();
    if (token == null) return _set(AuthStatus.signedOut);
    try {
      final user = await _api.me(token);
      _token = token;
      _set(AuthStatus.signedIn, user);
    } on ApiException catch (error) {
      if (!error.isUnauthorized) return _set(AuthStatus.restoreFailed);
      await _tokenStore.clear();
      _set(AuthStatus.signedOut);
    } catch (_) {
      _set(AuthStatus.restoreFailed);
    }
  }

  Future<void> login(String email, String password) =>
      _start(_api.login(email.trim(), password));

  Future<void> register(String email, String password) =>
      _start(_api.register(email.trim(), password));

  /// Deletes the account for good, then signs out. Throws, still signed in,
  /// when the server refuses, for example for a wrong password.
  Future<void> deleteAccount(String password) async {
    final token = this.token;
    if (token == null) throw StateError('Not signed in.');
    await _api.deleteAccount(token, password);
    await logout();
  }

  /// Signs the account out on every other device. This device swaps to the
  /// new session the server returns and stays signed in.
  Future<void> signOutEverywhere() async {
    final token = this.token;
    if (token == null) throw StateError('Not signed in.');
    await _start(_api.revokeSessions(token));
  }

  /// Mails a new verification code and returns when it expires.
  Future<DateTime> sendEmailCode() => _api.sendEmailCode(_requireToken());

  /// Confirms the email address; throws, still unverified, on a wrong code.
  Future<void> verifyEmail(String code) async {
    final token = _requireToken();
    final user = await _api.verifyEmail(token, code);
    if (this.token == token) _set(AuthStatus.signedIn, user);
  }

  /// Corrects an unverified address. Returns whether a code was mailed to
  /// the new one.
  Future<bool> changeEmail(String email) async {
    final token = _requireToken();
    final result = await _api.changeEmail(token, email.trim());
    if (this.token == token) _set(AuthStatus.signedIn, result.user);
    return result.codeSent;
  }

  String _requireToken() {
    final token = this.token;
    if (token == null) throw StateError('Not signed in.');
    return token;
  }

  Future<void> refreshUser() async {
    final currentToken = token;
    if (currentToken == null) return;
    final user = await _api.me(currentToken);
    if (token == currentToken) _set(AuthStatus.signedIn, user);
  }

  /// Checks the session again once the server can be reached after the app
  /// ran offline: a session ended elsewhere in the meantime signs out here
  /// too, and a restore that failed for lack of a connection is retried.
  Future<void> revalidate() async {
    if (_status == AuthStatus.restoreFailed) return restore();
    if (_status != AuthStatus.signedIn) return;
    try {
      await refreshUser();
    } on ApiException catch (error) {
      if (error.isUnauthorized && _status == AuthStatus.signedIn) {
        await logout();
      }
    } catch (_) {
      // Still unreachable; the next reconnect checks again.
    }
  }

  Future<void> logout() async {
    _token = null;
    await _tokenStore.clear();
    _set(AuthStatus.signedOut);
  }

  Future<void> _start(Future<AuthSession> request) async {
    final session = await request;
    await _tokenStore.write(session.token);
    _token = session.token;
    _set(AuthStatus.signedIn, session.user);
  }

  void _set(AuthStatus status, [AuthUser? user]) {
    _status = status;
    _user = user;
    notifyListeners();
  }
}
