import 'package:dio/dio.dart';
import '../ai/hosted_ai_error.dart';
import '../license/license_service.dart';
import 'account_auth.dart';
import 'operation_id.dart';

/// The public build uses account quotas exclusively. Legacy install tokens are
/// neither read nor sent; only the administrator edition redeems activation codes.
class AccountQuotaService extends LicenseService {
  AccountQuotaService({required this.auth, Dio? dio}) : _client = dio ?? Dio() {
    _owner = auth.userId;
    auth.addListener(_accountChanged);
  }
  final AccountAuth auth;
  final Dio _client;
  String? _owner;
  DateTime? _loaded;
  Map<String, int> _remaining = {};
  /// Null means no successful quota snapshot; it must not be presented as zero.
  bool? get hasAvailableQuota => _loaded == null
      ? null
      : _remaining.values.any((value) => value > 0);
  final Set<CancelToken> _requests = {};
  @override
  bool get configured => auth.configured;

  void _accountChanged() {
    if (_owner == auth.userId && auth.hasSession) return;
    _owner = auth.userId;
    _loaded = null;
    _remaining = {};
    for (final request in _requests.toList()) {
      request.cancel('account changed');
    }
  }

  Map<String, String> _accountHeaders() {
    if (!auth.hasSession || auth.userId == null || auth.accessToken == null) {
      throw StateError('请先在设置中登录 IKO，再使用账户额度。');
    }
    return {'Authorization': 'Bearer ${auth.accessToken}'};
  }

  @override
  Future<(bool, String)> verifyOnline(String code) async =>
      (false, '公测版已改为账号额度，管理员激活码请在 IKO 管理版使用。');

  @override
  Future<bool> isActive({bool force = false}) async {
    if (!auth.hasSession) return false;
    if (!force &&
        _loaded != null &&
        DateTime.now().difference(_loaded!).inSeconds < 30) {
      return _remaining.values.any((value) => value > 0);
    }
    final owner = auth.userId;
    try {
      final response = await _client.get<Map<String, dynamic>>(
          'https://example.invalid/v1/me',
          options: Options(
              headers: _accountHeaders(),
              followRedirects: false,
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12)));
      if (owner != auth.userId || !auth.hasSession) return false;
      final rows = response.data?['quota'];
      if (rows is! List) throw StateError('账户额度数据暂不可用，请刷新重试。');
      final next = <String, int>{};
      for (final row in rows) {
        if (row is! Map ||
            !const ['answer', 'correct', 'translate', 'summary']
                .contains(row['kind']) ||
            row['remaining'] is! int ||
            row['remaining'] < 0 ||
            next.containsKey(row['kind'])) {
          throw StateError('账户额度数据暂不可用，请刷新重试。');
        }
        next[row['kind']] = row['remaining'];
      }
      if (next.length != 4) throw StateError('账户额度数据不完整，请刷新重试。');
      _remaining = next;
      _loaded = DateTime.now();
      statusMessage = null;
      return next.values.any((value) => value > 0);
    } catch (error) {
      if (owner == auth.userId) {
        _remaining = {};
        _loaded = null;
        statusMessage = _friendly(error);
      }
      return false;
    }
  }

  @override
  Future<void> requireActive(String feature) async {
    _accountHeaders();
    await isActive();
    if ((_remaining[feature] ?? 0) < 1) {
      throw StateError(
          statusMessage ?? '此类内置服务额度不足，请到设置 → 账户额度查看。其他类别和本机功能不受影响。');
    }
  }

  @override
  Future<String> complete(String feature, Map<String, dynamic> body,
      CancelToken token, void Function(String)? onProgress) async {
    final owner = auth.userId;
    _requests.add(token);
    try {
      final response = await _client.post<Map<String, dynamic>>(
          'https://example.invalid/v1/ai/complete',
          data: {
            'feature': feature,
            'messages': body['messages'],
            'requestId': newOperationId()
          },
          options: Options(
              headers: _accountHeaders(),
              followRedirects: false,
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 45)),
          cancelToken: token);
      if (owner != auth.userId || !auth.hasSession) {
        throw StateError('账号已切换，已停止显示原账号的请求结果。');
      }
      final text = response.data?['text'];
      if (text is! String || text.trim().isEmpty || text.length > 250000) {
        throw HostedAiError('内置服务没有返回有效内容，请重试。');
      }
      onProgress?.call(text.trim());
      return text.trim();
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw HostedAiError(_friendly(error));
    } finally {
      _requests.remove(token);
      _loaded = null;
    }
  }

  String _friendly(Object error) {
    if (error is StateError) return error.message.toString();
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['detail'] == 'upstream_unavailable_charged') {
        return '模型本次未返回有效回答；此请求已发送云端处理，已计入1次用量。可刷新账户额度；重新生成会另计一次。';
      }
      return switch (error.response?.statusCode) {
        401 || 403 => '登录状态已失效，请重新登录 IKO。',
        402 => '此类内置 API 额度已用完或正在处理中，请刷新账户额度。',
        409 => '此请求已处理或处理中，未重复扣量，请稍后刷新。',
        429 => '请求较多，请稍后再试。',
        503 => '内置服务繁忙或正在维护，本次未开始的请求不扣额度。请稍后重试或使用自己的 API。',
        _ => '内置服务暂未返回有效结果，请稍后重试并刷新额度。',
      };
    }
    return '账户额度暂不可用，请稍后刷新。';
  }

  @override
  Future<void> clear() async {
    _remaining = {};
    _loaded = null;
  }

  @override
  void dispose() {
    auth.removeListener(_accountChanged);
    for (final token in _requests.toList()) {
      token.cancel('service disposed');
    }
    _client.close(force: true);
    super.dispose();
  }
}
