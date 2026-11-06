import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/app_widgets.dart';
import '../../services/account/account_auth.dart';
import '../../services/account/account_business.dart';
import 'login_brand.dart';

/// 只在初次进入时选择账号入口；后续token刷新不重建或卸载课堂工作区。
class AccountEntry extends ConsumerStatefulWidget {
  const AccountEntry({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<AccountEntry> createState() => _AccountEntryState();
}

class _AccountEntryState extends ConsumerState<AccountEntry>
    with WidgetsBindingObserver {
  bool _admitted = false;
  bool _passwordChecked = false;
  void _checkPasswordOnce() {
    if (_passwordChecked) return;
    _passwordChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final auth = ref.read(accountAuthProvider),
          owner = ref.read(accountAuthProvider).userId;
      if (!mounted || !auth.hasSession || owner == null) return;
      try {
        final profile = await ref
            .read(accountBusinessProvider)
            .identity()
            .timeout(const Duration(seconds: 4));
        if (!mounted || auth.userId != owner || profile['passwordSet'] != false) {
          return;
        }
        final setup = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('设置登录密码'),
                    content: const Text('设置后，下次可以直接使用邮箱和密码登录。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('稍后')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('去设置'))
                    ]));
        if (setup == true && mounted && auth.userId == owner) {
          await Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const AccountScreen(initialPasswordSetup: true)));
        }
      } catch (_) {/* Offline must never block the local workspace. */}
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref
        .read(accountAuthProvider)
        .setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(accountAuthProvider);
    if (_admitted) return widget.child;
    if (!auth.configured ||
        (auth.ready && auth.hasSession && !auth.passwordSetupPending)) {
      _admitted = true;
      if (auth.hasSession) _checkPasswordOnce();
      return widget.child;
    }
    return AccountScreen(onContinue: () => setState(() => _admitted = true));
  }
}

class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen(
      {super.key, this.onContinue, this.initialPasswordSetup = false});
  final bool initialPasswordSetup;
  final VoidCallback? onContinue;
  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _email = TextEditingController(), _code = TextEditingController();
  final _password = TextEditingController(),
      _confirmation = TextEditingController();
  bool _useCode = false, _resetPassword = false, _hidePassword = true;
  bool _checkingPassword = false;
  Timer? _cooldown;
  @override
  void initState() {
    super.initState();
    if (widget.initialPasswordSetup) {
      _email.text = ref.read(accountAuthProvider).email ?? '';
      _useCode = true;
      _resetPassword = true;
    }
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final auth = ref.read(accountAuthProvider);
    if (!await auth.sendCode(_email.text) || !mounted) return;
    _cooldown?.cancel();
    _cooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || auth.resendSeconds == 0) {
        timer.cancel();
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _verify() async {
    final auth = ref.read(accountAuthProvider);
    setState(() => _checkingPassword = true);
    try {
      if (await auth.verifyCode(_email.text, _code.text, setupPassword: true) &&
          mounted &&
          auth.hasSession) {
        FocusScope.of(context).unfocus();
        _code.clear();
        final owner = auth.userId;
        if (!_resetPassword) {
          try {
            final profile = await ref
                .read(accountBusinessProvider)
                .identity()
                .timeout(const Duration(seconds: 4));
            if (mounted &&
                auth.userId == owner &&
                profile['passwordSet'] == true) {
              auth.skipPasswordSetup();
              widget.onContinue?.call();
            }
          } catch (_) {
            /* Password setup remains available when status is unknown. */
          }
        }
      }
    } finally {
      if (mounted) setState(() => _checkingPassword = false);
    }
  }

  Future<void> _passwordLogin() async {
    final auth = ref.read(accountAuthProvider);
    if (await auth.signInWithPassword(_email.text, _password.text) && mounted) {
      _password.clear();
      FocusScope.of(context).unfocus();
      widget.onContinue?.call();
    }
  }

  Future<void> _savePassword() async {
    if (_password.text != _confirmation.text) {
      setState(() => _passwordMismatch = true);
      return;
    }
    if (await ref.read(accountAuthProvider).savePassword(_password.text) &&
        mounted) {
      _password.clear();
      _confirmation.clear();
      setState(() => _resetPassword = false);
      FocusScope.of(context).unfocus();
      widget.onContinue?.call();
    }
  }

  bool _passwordMismatch = false;

  Widget _passwordField({bool confirmation = false}) => TextField(
      key: Key(confirmation ? 'account-password-confirm' : 'account-password'),
      controller: confirmation ? _confirmation : _password,
      enabled: !ref.read(accountAuthProvider).busy,
      obscureText: _hidePassword,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: [
        confirmation
            ? AutofillHints.newPassword
            : ref.read(accountAuthProvider).passwordSetupPending
                ? AutofillHints.newPassword
                : AutofillHints.password
      ],
      textInputAction:
          confirmation || !ref.read(accountAuthProvider).passwordSetupPending
              ? TextInputAction.done
              : TextInputAction.next,
      onChanged: (_) {
        if (_passwordMismatch) setState(() => _passwordMismatch = false);
      },
      onSubmitted: (_) => ref.read(accountAuthProvider).passwordSetupPending
          ? _savePassword()
          : _passwordLogin(),
      decoration: InputDecoration(
          labelText: confirmation
              ? '确认新密码'
              : ref.read(accountAuthProvider).passwordSetupPending
                  ? '新密码'
                  : '登录密码',
          errorText: confirmation && _passwordMismatch ? '两次密码不一致' : null,
          suffixIcon: confirmation
              ? null
              : IconButton(
                  tooltip: _hidePassword ? '显示密码' : '隐藏密码',
                  onPressed: () =>
                      setState(() => _hidePassword = !_hidePassword),
                  icon: Icon(_hidePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined))));

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('退出账号？'),
              content: const Text('只退出此设备的账号。笔记、课堂、课表、录音和现有激活记录会保留在本机。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('退出')),
              ],
            ));
    if (confirmed == true && mounted) {
      await ref.read(accountAuthProvider).signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(accountAuthProvider), theme = Theme.of(context);
    final atStart = widget.onContinue != null;
    return Scaffold(
      appBar: atStart ? null : AppBar(title: const Text('账号')),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                  child: Semantics(
                      label: 'IKO', image: true, child: const LoginBrand())),
              const SizedBox(height: 20),
              Text(
                  auth.passwordSetupPending
                      ? '设置登录密码'
                      : auth.hasSession && !_resetPassword
                          ? '你的 IKO 账号'
                          : _resetPassword
                              ? '找回登录密码'
                              : '登录 IKO',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                  auth.passwordSetupPending
                      ? '邮箱已验证，下次可直接使用账号密码登录'
                      : auth.hasSession && !_resetPassword
                          ? '下次打开将自动恢复登录'
                          : _resetPassword
                              ? '验证邮箱后，设置新的登录密码'
                              : '邮箱就是账号，已有账号可直接使用密码登录',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 28),
              if (!auth.ready || _checkingPassword)
                const Center(child: CircularProgressIndicator())
              else if (!auth.configured)
                const GlassCard(child: Text('账号服务尚未开通。听写、笔记和课表可以照常在本机使用。'))
              else if (auth.passwordSetupPending) ...[
                Text(auth.email ?? '', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                _passwordField(),
                const SizedBox(height: 16),
                _passwordField(confirmation: true),
                const SizedBox(height: 8),
                const Text('10–128位，包含字母和数字。'),
                const SizedBox(height: 16),
                PillButton(
                    label: auth.busy ? '保存中…' : '保存密码并继续',
                    expanded: true,
                    onPressed: auth.busy ? null : _savePassword),
                TextButton(
                    onPressed: auth.busy
                        ? null
                        : () {
                            auth.skipPasswordSetup();
                            _password.clear();
                            _confirmation.clear();
                            setState(() => _resetPassword = false);
                            widget.onContinue?.call();
                          },
                    child: const Text('暂不设置，继续使用验证码登录')),
              ] else if (auth.hasSession && !_resetPassword) ...[
                GlassCard(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('已登录邮箱'),
                      const SizedBox(height: 8),
                      SelectableText(auth.email ?? '已验证账号',
                          style: theme.textTheme.titleMedium),
                      if (auth.needsRefresh) ...[
                        const SizedBox(height: 12),
                        const Text('待联网更新登录状态，本机功能可继续使用。')
                      ],
                    ])),
                const SizedBox(height: 16),
                OutlinedButton(
                    onPressed: auth.busy
                        ? null
                        : () => setState(() {
                              _email.text = auth.email ?? '';
                              _code.clear();
                              _password.clear();
                              _confirmation.clear();
                              _resetPassword = true;
                              _useCode = true;
                            }),
                    child: const Text('设置或重设登录密码')),
                OutlinedButton(
                    onPressed: auth.busy ? null : _signOut,
                    child: const Text('退出账号')),
              ] else ...[
                TextField(
                    key: const Key('account-email'),
                    controller: _email,
                    enabled: !auth.busy,
                    readOnly: _resetPassword && auth.hasSession,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                        labelText: '邮箱账号', hintText: 'name@example.com'),
                    onChanged: (_) {
                      if (_code.text.isNotEmpty) _code.clear();
                    }),
                const SizedBox(height: 16),
                if (!_useCode) ...[
                  _passwordField(),
                  PillButton(
                      label: auth.busy ? '请稍候…' : '账号密码登录',
                      expanded: true,
                      onPressed: auth.busy ? null : _passwordLogin),
                ] else ...[
                  TextField(
                      key: const Key('account-code'),
                      controller: _code,
                      enabled: !auth.busy,
                      keyboardType: TextInputType.number,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6)
                      ],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _verify(),
                      decoration: const InputDecoration(labelText: '6位验证码')),
                  const SizedBox(height: 12),
                  Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                          key: const Key('account-send'),
                          onPressed: auth.busy || auth.resendSeconds > 0
                              ? null
                              : _send,
                          child: Text(auth.resendSeconds > 0
                              ? '${auth.resendSeconds}秒后重新发送'
                              : '获取验证码'))),
                  const SizedBox(height: 12),
                  PillButton(
                      label: auth.busy
                          ? '请稍候…'
                          : _resetPassword
                              ? '验证邮箱并设置密码'
                              : '登录 / 注册',
                      expanded: true,
                      onPressed: auth.busy ? null : _verify),
                ],
                Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                        onPressed: auth.busy
                            ? null
                            : () => setState(() {
                                  _useCode = true;
                                  _resetPassword = true;
                                  _password.clear();
                                }),
                        child: const Text('忘记密码'))),
                TextButton(
                    onPressed: auth.busy
                        ? null
                        : () => setState(() {
                              _useCode = !_useCode;
                              _resetPassword = false;
                              _password.clear();
                              _code.clear();
                            }),
                    child: Text(_useCode ? '使用账号密码登录' : '验证码登录 / 注册')),
                if (_resetPassword && auth.hasSession)
                  TextButton(
                      onPressed: auth.busy
                          ? null
                          : () => setState(() => _resetPassword = false),
                      child: const Text('返回账号')),
              ],
              if (auth.message != null)
                Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Semantics(
                        liveRegion: true,
                        child:
                            Text(auth.message!, textAlign: TextAlign.center))),
              if (auth.signOutPending)
                TextButton(
                    onPressed: auth.busy ? null : () => auth.signOut(),
                    child: const Text('重试完成退出')),
              if (atStart) ...[
                const SizedBox(height: 16),
                TextButton(
                    onPressed: auth.busy
                        ? null
                        : () {
                            auth.skipPasswordSetup();
                            widget.onContinue?.call();
                          },
                    child: Text(auth.hasSession ? '继续使用 IKO' : '先使用本机功能')),
              ],
              const SizedBox(height: 20),
              Text('本机资料保留在此设备，登录不会自动上传笔记、课堂或相册。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall),
            ]),
      ))),
    );
  }
}
