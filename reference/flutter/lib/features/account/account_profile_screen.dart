import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../../core/widgets/app_widgets.dart';
import '../../services/account/account_auth.dart';
import '../../services/account/account_business.dart';
import '../../services/account/account_identity.dart';
import 'account_screen.dart';

/// Re-encoding a fresh canvas drops EXIF and original album metadata.
Uint8List compressAccountAvatar(Uint8List input) {
  if (input.length > 12 * 1024 * 1024) throw StateError('图片较大，请选择另一张图片。');
  final decoder = img.findDecoderForData(input);
  final info = decoder?.startDecode(input);
  if (decoder == null || info == null || info.width * info.height > 16000000) {
    throw StateError('图片尺寸过大或格式不支持。');
  }
  final decoded = decoder.decodeFrame(0);
  if (decoded == null) throw StateError('无法读取这张图片。');
  final resized = img.bakeOrientation(img.copyResize(decoded,
      width: decoded.width >= decoded.height ? 128 : null,
      height: decoded.height > decoded.width ? 128 : null));
  final clean =
      img.Image(width: resized.width, height: resized.height, numChannels: 3);
  img.fill(clean, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(clean, resized);
  final bytes = img.encodeJpg(clean, quality: 78);
  if (bytes.length > 24 * 1024) throw StateError('图片压缩后仍较大，请换一张图片。');
  return bytes;
}

class AccountCorner extends ConsumerStatefulWidget {
  const AccountCorner({super.key});
  @override
  ConsumerState<AccountCorner> createState() => _AccountCornerState();
}

class _AccountCornerState extends ConsumerState<AccountCorner>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted &&
          _foreground &&
          TickerMode.valuesOf(context).enabled &&
          ModalRoute.of(context)?.isCurrent == true) {
        _load();
      }
    });
  }

  void _load() => unawaited(ref.read(accountIdentityProvider).load());
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _open(bool notifications) async {
    final auth = ref.read(accountAuthProvider);
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => !auth.hasSession
            ? const AccountScreen()
            : notifications
                ? const AccountNotificationsScreen()
                : const AccountProfileScreen()));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(accountIdentityProvider);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
          tooltip: '通知',
          onPressed: () => _open(true),
          icon: Badge(
              isLabelVisible: identity.unread > 0,
              smallSize: 7,
              child: const Icon(Icons.notifications_none_rounded))),
      IconButton(
          tooltip: '账号资料',
          onPressed: () => _open(false),
          icon: CircleAvatar(
              radius: 16,
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              foregroundImage: identity.avatar == null
                  ? null
                  : MemoryImage(identity.avatar!),
              child: const Icon(Icons.person_outline_rounded, size: 21))),
    ]);
  }
}

class AccountProfileScreen extends ConsumerStatefulWidget {
  const AccountProfileScreen({super.key});
  @override
  ConsumerState<AccountProfileScreen> createState() =>
      _AccountProfileScreenState();
}

class _AccountProfileScreenState extends ConsumerState<AccountProfileScreen> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error, _owner;
  @override
  void initState() {
    super.initState();
    _owner = ref.read(accountAuthProvider).userId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(accountIdentityProvider).load();
      if (mounted && _owner == ref.read(accountAuthProvider).userId) {
        _name.text = ref.read(accountIdentityProvider).nickname;
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _change({bool avatar = false, bool remove = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final business = ref.read(accountBusinessProvider);
      if (_owner != ref.read(accountAuthProvider).userId) {
        throw StateError('账号已切换，请重新打开资料。');
      }
      if (avatar) {
        String? encoded;
        if (!remove) {
          final file = await ImagePicker().pickImage(
              source: ImageSource.gallery,
              requestFullMetadata: false,
              maxWidth: 1024,
              maxHeight: 1024);
          if (file == null) return;
          if (await file.length() > 12 * 1024 * 1024) {
            throw StateError('图片较大，请换一张图片。');
          }
          encoded = base64Encode(
              await compute(compressAccountAvatar, await file.readAsBytes()));
        }
        if (_owner != ref.read(accountAuthProvider).userId) {
          throw StateError('账号已切换，请重新打开资料。');
        }
        await business.saveAvatar(encoded);
      } else {
        final name = _name.text.trim();
        if (name.isEmpty) throw StateError('先写一个昵称吧。');
        await business.saveNickname(name);
      }
      await ref.read(accountIdentityProvider).load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('资料已保存')));
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            _error = e is StateError ? e.message.toString() : '资料未保存，请重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(accountAuthProvider),
        identity = ref.watch(accountIdentityProvider);
    if (!auth.hasSession || auth.userId != _owner) return const AccountScreen();
    return Scaffold(
        appBar: AppBar(title: const Text('账号资料')),
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child:
                        ListView(padding: const EdgeInsets.all(24), children: [
                      Center(
                          child: CircleAvatar(
                              radius: 48,
                              foregroundImage: identity.avatar == null
                                  ? null
                                  : MemoryImage(identity.avatar!),
                              child: const Icon(Icons.person_outline_rounded,
                                  size: 44))),
                      const SizedBox(height: 12),
                      Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          children: [
                            TextButton.icon(
                                onPressed:
                                    _busy ? null : () => _change(avatar: true),
                                icon: const Icon(Icons.photo_outlined),
                                label: const Text('选择头像')),
                            if (identity.avatar != null)
                              TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () =>
                                          _change(avatar: true, remove: true),
                                  child: const Text('移除头像'))
                          ]),
                      const SizedBox(height: 24),
                      GlassCard(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            TextField(
                                controller: _name,
                                maxLength: 40,
                                enabled: !_busy,
                                decoration:
                                    const InputDecoration(labelText: '昵称')),
                            const SizedBox(height: 12),
                            SelectableText(auth.email ?? ''),
                            const SizedBox(height: 20),
                            FilledButton(
                                onPressed: _busy ? null : () => _change(),
                                child: const Text('保存昵称'))
                          ])),
                      if (_busy)
                        const Padding(
                            padding: EdgeInsets.only(top: 16),
                            child: LinearProgressIndicator()),
                      if (_error != null || identity.error != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(_error ?? identity.error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                    ])))));
  }
}

class AccountNotificationsScreen extends ConsumerStatefulWidget {
  const AccountNotificationsScreen({super.key});
  @override
  ConsumerState<AccountNotificationsScreen> createState() =>
      _AccountNotificationsScreenState();
}

class _AccountNotificationsScreenState
    extends ConsumerState<AccountNotificationsScreen>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _rows = [];
  bool _busy = false;
  String? _error, _owner;
  Timer? _refresh;
  bool _foreground = true;
  static const names = {
    'answer': '答题',
    'correct': '云端纠错',
    'translate': '翻译',
    'summary': '课堂摘要'
  };
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _owner = ref.read(accountAuthProvider).userId;
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && _foreground && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(_load());
        unawaited(ref.read(accountIdentityProvider).load());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(_load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final data = await ref.read(accountBusinessProvider).notifications();
      if (mounted && _owner == ref.read(accountAuthProvider).userId) {
        setState(() {
          _error = null;
          _rows = [
            for (final row in data['rows'] as List? ?? [])
              Map<String, dynamic>.from(row)
          ];
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
            () => _error = e is StateError ? e.message.toString() : '暂时无法读取消息');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read(List<String> ids, {bool all = false}) async {
    if (_busy || !all && ids.isEmpty) return;
    setState(() => _busy = true);
    try {
      if (all) {
        await ref.read(accountBusinessProvider).readAllNotifications();
      } else {
        await ref.read(accountBusinessProvider).readNotifications(ids);
      }
      await ref.read(accountIdentityProvider).load();
    } catch (e) {
      if (mounted) {
        setState(() =>
            _error = e is StateError ? e.message.toString() : '标记未完成，请重试');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(accountAuthProvider);
    if (!auth.hasSession || auth.userId != _owner) return const AccountScreen();
    return Scaffold(
        appBar: AppBar(title: const Text('通知'), actions: [
          TextButton(
              onPressed: _busy ? null : () => _read([], all: true),
              child: const Text('全部已读'))
        ]),
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(20),
                            children: [
                              if (_busy) const LinearProgressIndicator(),
                              if (_error != null)
                                Text(_error!,
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error)),
                              if (!_busy && _rows.isEmpty && _error == null)
                                const Padding(
                                    padding: EdgeInsets.all(32),
                                    child: Center(child: Text('暂时没有新消息'))),
                              for (final row in _rows)
                                GlassCard(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    onTap: _busy
                                        ? null
                                        : () => _read([row['id'].toString()]),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(children: [
                                            Badge(
                                                isLabelVisible:
                                                    row['readAt'] == null,
                                                smallSize: 6,
                                                child: Icon(
                                                    Icons
                                                        .mark_email_unread_outlined,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .secondary)),
                                            const SizedBox(width: 12),
                                            Expanded(
                                                child: Text(
                                                    row['title'].toString(),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium))
                                          ]),
                                          const SizedBox(height: 12),
                                          Text(row['body'].toString()),
                                          const SizedBox(height: 10),
                                          Wrap(
                                              spacing: 16,
                                              runSpacing: 6,
                                              children: [
                                                for (final key in names.keys)
                                                  if (((row['quotas']
                                                                  as Map?)?[key]
                                                              as num? ??
                                                          0) >
                                                      0)
                                                    Text(
                                                        '${names[key]} +${row['quotas'][key]}')
                                              ]),
                                        ])),
                            ]))))));
  }
}
