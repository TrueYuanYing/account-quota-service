import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'account_auth.dart';
import 'account_business.dart';

final accountIdentityProvider = ChangeNotifierProvider<AccountIdentity>((ref) {
  final identity = AccountIdentity(
      ref.read(accountAuthProvider), ref.read(accountBusinessProvider));
  return identity;
});

/// One small, memory-only profile. Switching accounts discards the old image.
class AccountIdentity extends ChangeNotifier {
  AccountIdentity(this.auth, this.business) {
    _owner = auth.userId;
    auth.addListener(_accountChanged);
  }
  final AccountAuth auth;
  final AccountBusiness business;
  String? _owner, _avatarSource;
  Uint8List? avatar;
  String nickname = '';
  int unread = 0, _revision = 0;
  bool loading = false, _disposed = false;
  String? error;

  void _accountChanged() {
    if (_owner == auth.userId && auth.hasSession) return;
    _revision++;
    _owner = auth.userId;
    avatar = null;
    _avatarSource = null;
    nickname = '';
    unread = 0;
    loading = false;
    error = null;
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (loading || !auth.hasSession) return;
    final owner = auth.userId, revision = ++_revision;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final data = await business.identity();
      if (_disposed || revision != _revision || owner != auth.userId) return;
      nickname = data['displayName'] is String ? data['displayName'] : '';
      unread =
          data['unread'] is int ? (data['unread'] as int).clamp(0, 1000000) : 0;
      final source = data['avatarBase64'] as String?;
      if (source != _avatarSource) {
        _avatarSource = source;
        avatar = null;
        if (source != null && source.length <= 43692) {
          try {
            final bytes = base64Decode(source);
            if (bytes.length <= 32768) avatar = bytes;
          } on FormatException {/* Invalid images use the placeholder. */}
        }
      }
    } catch (e) {
      if (!_disposed && revision == _revision) {
        error = e is StateError ? e.message.toString() : '资料暂时无法读取';
      }
    } finally {
      if (!_disposed && revision == _revision) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    auth.removeListener(_accountChanged);
    avatar = null;
    super.dispose();
  }
}
