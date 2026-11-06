import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gotrue/gotrue.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只包含可公开的认证地址与客户端key，不接受服务器管理员密钥。
class AccountConfig {
  const AccountConfig(this.url, this.publicKey);
  const AccountConfig.environment()
      : url = const String.fromEnvironment('IKO_AUTH_URL'),
        publicKey = const String.fromEnvironment('IKO_AUTH_PUBLIC_KEY');
  final String url, publicKey;

  bool get enabled {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    if (publicKey.startsWith('sb_publishable_')) return publicKey.length > 20;
    try {
      final parts = publicKey.split('.');
      if (parts.length != 3) return false;
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      return payload is Map && payload['role'] == 'anon';
    } catch (_) {
      return false;
    }
  }

  String get storageKey =>
      'iko.account.session.${sha256.convert(utf8.encode(url))}';
}

final accountAuthProvider = ChangeNotifierProvider<AccountAuth>((ref) {
  final auth = AccountAuth();
  unawaited(auth.initialize());
  return auth;
});

/// SDK负责验证码与会话刷新。本类只负责UI状态和加密持久化；不授予会员权益。
class AccountAuth extends ChangeNotifier {
  AccountAuth(
      {AccountConfig? config,
      GoTrueClient? client,
      FlutterSecureStorage? storage})
      : config = config ?? const AccountConfig.environment(),
        _client = client,
        _storage = storage ??
            const FlutterSecureStorage(
                aOptions: AndroidOptions(
                    encryptedSharedPreferences: true,
                    sharedPreferencesName: 'FlutterSecureIKOAccount'));

  final AccountConfig config;
  final FlutterSecureStorage _storage;
  GoTrueClient? _client;
  http.Client? _http;
  StreamSubscription<AuthState>? _subscription;
  Future<void>? _initializing;
  Future<void> _writes = Future.value();
  bool ready = false, busy = false, _disposed = false, _foreground = true;
  bool storageFailed = false;
  bool signOutPending = false;
  bool passwordSetupPending = false;
  DateTime? _emailVerifiedAt;
  String get _signOutMarker => '${config.storageKey}.signedOut';
  String? message;
  DateTime? _nextSend;
  bool get configured => config.enabled;
  String? get email => _client?.currentUser?.email;
  String? get userId => _client?.currentUser?.id;
  String? get accessToken => _client?.currentSession?.accessToken;
  bool get hasSession => _client?.currentSession != null;
  bool get needsRefresh => _client?.currentSession?.isExpired ?? false;
  int get resendSeconds => _nextSend == null
      ? 0
      : ((_nextSend!.difference(DateTime.now()).inMilliseconds / 1000).ceil())
          .clamp(0, 60);

  Future<void> initialize() => _initializing ??= _restore();

  Future<void> _restore() async {
    if (!configured) {
      ready = true;
      _notify();
      return;
    }
    final client = _client ??= GoTrueClient(
      url: config.url.replaceFirst(RegExp(r'/$'), ''),
      headers: {'apikey': config.publicKey},
      flowType: AuthFlowType.implicit,
      autoRefreshToken: true,
      httpClient: _http = _AccountHttpClient(),
    );
    client.stopAutoRefresh();
    _subscription = client.onAuthStateChange.listen((state) {
      if (_disposed) return;
      unawaited(_persist(state.session));
      _notify();
    }, onError: (Object error, StackTrace stack) {
      if (_disposed) return;
      message = accountErrorMessage(error);
      _notify();
    });
    try {
      if ((await SharedPreferences.getInstance()).getBool(_signOutMarker) ==
          true) {
        signOutPending = true;
        await _persist(null);
        return;
      }
      final saved = await _storage.read(key: config.storageKey);
      if (_disposed) return;
      if (saved != null) {
        try {
          await client.setInitialSession(saved);
        } on FormatException {
          await _persist(null);
        } on TypeError {
          await _persist(null);
        } on AuthException {
          await _persist(null);
        }
      }
    } catch (_) {
      storageFailed = true;
      message = '无法读取安全存储，请重试。你仍可使用本机功能。';
    } finally {
      if (!_disposed) {
        ready = true;
        if (_foreground) client.startAutoRefresh();
        _notify();
      }
    }
  }

  Future<void> _persist(Session? session) {
    // 刷新和退出可能连续到达，按事件顺序写入，防止旧token覆盖新会话。
    final value = session == null ? null : jsonEncode(session.toJson());
    return _writes = _writes.then((_) async {
      try {
        if (value == null) {
          await _storage.delete(key: config.storageKey);
          if (signOutPending) {
            final prefs = await SharedPreferences.getInstance();
            if (!await prefs.remove(_signOutMarker)) {
              throw StateError('Sign-out marker');
            }
            signOutPending = false;
          }
        } else {
          await _storage.write(key: config.storageKey, value: value);
        }
        storageFailed = false;
      } catch (_) {
        storageFailed = true;
        message = '账号状态未能安全保存，请重试；本机资料不受影响。';
        _notify();
      }
    });
  }

  Future<bool> sendCode(String email) async {
    await initialize();
    if (busy) return false;
    if (!configured) {
      message = '账号服务尚未开通';
      _notify();
      return false;
    }
    if (signOutPending) {
      message = '请先重试完成退出，再登录账号。';
      _notify();
      return false;
    }
    email = email.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email) ||
        email.length > 254) {
      message = '请输入有效邮箱';
      _notify();
      return false;
    }
    if (resendSeconds > 0) return false;
    return _run(() async {
      await _client!.signInWithOtp(email: email, shouldCreateUser: true);
      _nextSend = DateTime.now().add(const Duration(seconds: 60));
      message = '验证码已发送，请查看收件箱或垃圾邮件。';
    });
  }

  Future<bool> verifyCode(String email, String code,
      {bool setupPassword = false}) async {
    await initialize();
    if (busy) return false;
    if (signOutPending) {
      message = '请先重试完成退出，再登录账号。';
      _notify();
      return false;
    }
    if (!configured) {
      message = '账号服务尚未开通';
      _notify();
      return false;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code.trim())) {
      message = '请输入邮件中的6位验证码';
      _notify();
      return false;
    }
    passwordSetupPending = setupPassword;
    final success = await _run(() async {
      final result = await _client!.verifyOTP(
          email: email.trim(), token: code.trim(), type: OtpType.email);
      if (result.session == null) throw const AuthException('Missing session');
      await _persist(result.session);
      _emailVerifiedAt = DateTime.now();
      if (!storageFailed) message = null;
    });
    if (!success) passwordSetupPending = false;
    _notify();
    return success;
  }

  Future<bool> signInWithPassword(String email, String password) async {
    await initialize();
    if (busy) return false;
    if (!configured || signOutPending) {
      message = signOutPending ? '请先重试完成退出，再登录账号。' : '账号服务尚未开通';
      _notify();
      return false;
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.trim()) ||
        email.trim().length > 254 ||
        password.isEmpty ||
        password.length > 128) {
      message = '请输入邮箱账号和密码。';
      _notify();
      return false;
    }
    return _run(() async {
      final result = await _client!
          .signInWithPassword(email: email.trim(), password: password);
      if (result.session == null) throw const AuthException('Missing session');
      await _persist(result.session);
      _emailVerifiedAt = null;
      if (!storageFailed) message = null;
    });
  }

  Future<bool> savePassword(String password) async {
    await initialize();
    if (busy) return false;
    if (!hasSession ||
        _emailVerifiedAt == null ||
        DateTime.now().difference(_emailVerifiedAt!) >
            const Duration(minutes: 10)) {
      message = '请先重新验证邮箱，再设置密码。';
      _notify();
      return false;
    }
    if (password.length < 10 ||
        password.length > 128 ||
        !RegExp(r'[A-Za-z]').hasMatch(password) ||
        !RegExp(r'[0-9]').hasMatch(password)) {
      message = '密码需为10–128位，并包含字母和数字。';
      _notify();
      return false;
    }
    return _run(() async {
      await _client!.updateUser(
          UserAttributes(password: password, data: {'iko_password_set': true}));
      _emailVerifiedAt = null;
      passwordSetupPending = false;
      message = '登录密码已设置，下次可使用邮箱和密码登录。';
    });
  }

  void skipPasswordSetup() {
    passwordSetupPending = false;
    _emailVerifiedAt = null;
    _notify();
  }

  Future<void> signOut() async {
    await initialize();
    if (_client == null || busy) return;
    await _run(() async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(_signOutMarker, true)) {
        throw StateError('Cannot save sign-out intent');
      }
      signOutPending = true;
      passwordSetupPending = false;
      _emailVerifiedAt = null;
      try {
        await _client!.signOut(scope: SignOutScope.local);
      } finally {
        // SDK先移除本机会话，断网时同样清除本机凭据，不触碰用户库或旧激活。
        if (_client!.currentSession == null) await _persist(null);
      }
    });
  }

  Future<bool> _run(Future<void> Function() action) async {
    busy = true;
    message = null;
    _notify();
    try {
      await action();
      return true;
    } catch (error) {
      message = accountErrorMessage(error);
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  void setForeground(bool visible) {
    _foreground = visible;
    if (!ready || _disposed) return;
    if (visible) {
      _client?.startAutoRefresh();
    } else {
      _client?.stopAutoRefresh();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _client?.dispose();
    _http?.close();
    super.dispose();
  }
}

String accountErrorMessage(Object error) {
  if (error is AuthRetryableFetchException || error is TimeoutException) {
    return '暂时无法连接账号服务，请检查网络后重试。本机功能可以继续使用。';
  }
  if (error is AuthException) {
    if (error.code == 'invalid_credentials') return '邮箱或密码不正确；也可使用验证码登录或重设密码。';
    if (error.code == 'weak_password') return '密码需为10–128位，并包含字母和数字。';
    if (error.code == 'same_password') return '新密码与原密码相同，请换一个。';
    if (error.code == 'reauthentication_needed' ||
        error.code == 'reauthentication_not_valid') {
      return '请重新验证邮箱后设置密码。';
    }
    if (error.statusCode == '429' ||
        error.code == 'over_email_send_rate_limit' ||
        error.code == 'over_request_rate_limit') {
      return '操作太频繁，请稍后再试。';
    }
    if (error.code == 'otp_expired' || error.code == 'otp_disabled') {
      return '验证码无效或已过期，请重新获取。';
    }
    if (error.statusCode == '401' ||
        error.code == 'refresh_token_not_found' ||
        error.code == 'refresh_token_already_used') {
      return '登录已失效，请重新验证邮箱。';
    }
    if (error.code == 'email_address_invalid') return '请输入有效邮箱。';
    if (int.tryParse(error.statusCode ?? '') case final int code
        when code >= 500) {
      return '账号服务暂时不可用，请稍后重试。';
    }
  }
  // 不直接显示供应商原文，避免泄露请求、token或服务端详细信息。
  return '登录未完成，请确认邮箱和验证码后重试。';
}

/// 认证小型JSON请求设置总时限；超时取消底层请求，避免登录按钮持续等待。
class _AccountHttpClient extends http.BaseClient {
  final http.Client _inner =
      IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 10));
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abort = Completer<void>();
    final bounded = http.AbortableRequest(request.method, request.url,
        abortTrigger: abort.future)
      ..headers.addAll(request.headers)
      ..followRedirects = false
      ..bodyBytes = await request.finalize().toBytes();
    final response = await _inner
        .send(bounded)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 20), onTimeout: () {
      if (!abort.isCompleted) abort.complete();
      throw TimeoutException('Auth request deadline');
    });
    return http.StreamedResponse(
        Stream.value(response.bodyBytes), response.statusCode,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
        request: request);
  }

  @override
  void close() => _inner.close();
}
