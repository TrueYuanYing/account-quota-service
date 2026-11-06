import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'account_auth.dart';

final accountBusinessProvider = Provider<AccountBusiness>((ref) {
  final service = AccountBusiness(auth: ref.read(accountAuthProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// Explicit account operations only, separate from local notes and classrooms.
class AccountBusiness {
  AccountBusiness({required this.auth, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 15)));
  final AccountAuth auth;
  final Dio _dio;
  Future<Map<String, dynamic>> document() => _request('me');
  Future<Map<String, dynamic>> identity() => _request('me/profile');
  Future<Map<String, dynamic>> notifications() => _request('notifications');
  Future<Map<String, dynamic>> readNotifications(List<String> ids) =>
      _request('notifications/read', body: {'ids': ids});
  Future<Map<String, dynamic>> readAllNotifications() =>
      _request('notifications/read', body: {'all': true});
  Future<Map<String, dynamic>> saveNickname(String name) =>
      _request('me/profile', method: 'PATCH', body: {'displayName': name});
  Future<Map<String, dynamic>> saveAvatar(String? jpegBase64) =>
      _request('me/avatar', method: 'PUT', body: {'jpegBase64': jpegBase64});
  Future<Map<String, dynamic>> products() => _request('products');
  Future<Map<String, dynamic>> createOrder(String product, String request) =>
      _request('orders', body: {'productId': product, 'requestId': request});
  Future<Map<String, dynamic>> checkOrder(String id) => _request('orders/$id');
  Future<Map<String, dynamic>> feedback() => _request('feedback');
  Future<Map<String, dynamic>> submitFeedback(
          {required String requestId,
          required String category,
          required String message,
          String? orderId}) =>
      _request('feedback', body: {
        'requestId': requestId,
        'category': category,
        'orderId': orderId,
        'message': message
      });

  Future<Map<String, dynamic>> _request(String path,
      {Map<String, dynamic>? body, String? method}) async {
    if (!auth.configured) throw StateError('账号服务尚未开通，请稍后再试；本机资料不受影响。');
    final owner = auth.userId, token = auth.accessToken;
    if (!auth.hasSession || owner == null || token == null) {
      throw StateError('请先登录 IKO，再提交或查看反馈。');
    }
    final endpoint =
        Uri.https('example.invalid', '/v1/$path').toString();
    try {
      final options = Options(
          headers: {'Authorization': 'Bearer $token'}, followRedirects: false);
      final response = await _dio.request<Map<String, dynamic>>(endpoint,
          data: body,
          options: options.copyWith(
              method: method ?? (body == null ? 'GET' : 'POST')));
      if (!auth.hasSession || auth.userId != owner) {
        throw StateError('账号已切换，请重新打开此页面。');
      }
      if (response.data == null) throw StateError('账号服务没有返回有效内容，请重试。');
      return response.data!;
    } on DioException catch (error) {
      throw StateError(switch (error.response?.statusCode) {
        401 || 403 => '登录状态已失效，请重新登录。',
        400 => '提交内容或关联订单有误，请检查后重新提交。',
        503 => '服务暂未开放或正在维护，请稍后再试；未扣除本机或账户资料。',
        429 => '今天提交次数较多，请稍后再试。',
        _ => '账号服务暂不可用，请稍后重试。未提交本机笔记或课堂资料。',
      });
    }
  }

  void dispose() => _dio.close(force: true);
}
