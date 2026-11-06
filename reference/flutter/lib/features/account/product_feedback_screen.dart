import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/account/account_auth.dart';
import '../../services/account/account_business.dart';
import '../../services/account/operation_id.dart';
import 'account_screen.dart';

class ProductFeedbackScreen extends ConsumerStatefulWidget {
  const ProductFeedbackScreen({super.key});
  @override
  ConsumerState<ProductFeedbackScreen> createState() =>
      _ProductFeedbackScreenState();
}

class _ProductFeedbackScreenState extends ConsumerState<ProductFeedbackScreen> {
  final _message = TextEditingController();
  List<dynamic> _orders = [], _history = [];
  String _category = 'product';
  String? _orderId, _error, _draftKey, _requestId;
  int _revision = 0;
  bool _loading = false, _sending = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(accountAuthProvider.select((auth) => auth.userId),
        (old, next) {
      _message.clear();
      _draftKey = null;
      _requestId = null;
      _orderId = null;
      _orders = [];
      _history = [];
      _load();
    });
    _load();
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  String _explain(Object error) =>
      error is StateError ? error.message.toString() : '读取失败，请稍后重试。';

  Future<void> _load() async {
    final revision = ++_revision;
    final auth = ref.read(accountAuthProvider);
    if (!auth.configured || !auth.hasSession) {
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(accountBusinessProvider);
      final results =
          await Future.wait([service.document(), service.feedback()]);
      if (mounted && revision == _revision) {
        setState(() {
          _orders = results[0]['orders'] as List? ?? [];
          _history = results[1]['rows'] as List? ?? [];
          if (!_orders.any((row) => row['id'] == _orderId)) _orderId = null;
        });
      }
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() => _error = _explain(error));
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final auth = ref.read(accountAuthProvider),
        owner = ref.read(accountAuthProvider).userId;
    if (_sending ||
        !auth.hasSession ||
        _message.text.trim().length < 3 ||
        (_category == 'order' && _orderId == null)) {
      return;
    }
    final message = _message.text.trim();
    final key = jsonEncode([owner, _category, _orderId, message]);
    if (_draftKey != key) {
      _draftKey = key;
      _requestId = newOperationId();
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(accountBusinessProvider).submitFeedback(
          requestId: _requestId!,
          category: _category,
          orderId: _category == 'order' ? _orderId : null,
          message: message);
      if (!mounted || ref.read(accountAuthProvider).userId != owner) return;
      _message.clear();
      _draftKey = null;
      _requestId = null;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('反馈已提交，可在下方查看处理状态')));
      await _load();
    } catch (error) {
      if (mounted && ref.read(accountAuthProvider).userId == owner) {
        setState(() => _error = _explain(error));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(accountAuthProvider);
    return Scaffold(
        appBar: AppBar(title: const Text('产品反馈'), actions: [
          IconButton(
              tooltip: '刷新处理状态',
              onPressed: _loading || _sending ? null : _load,
              icon: const Icon(Icons.refresh_rounded))
        ]),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(padding: const EdgeInsets.all(20), children: [
                  const Text('提交使用问题或订单问题。这里只发送你填写的内容及选择的订单，不会附带笔记、课堂或相册资料。'),
                  const SizedBox(height: 20),
                  if (!auth.configured)
                    const Card(
                        child: Padding(
                            padding: EdgeInsets.all(20),
                            child: Text('账号服务正在接通，完成后可在这里提交反馈。本机功能照常可用。')))
                  else if (!auth.hasSession)
                    FilledButton.icon(
                        onPressed: () async {
                          await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) => const AccountScreen()));
                          if (mounted) _load();
                        },
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('登录后提交反馈'))
                  else ...[
                    Wrap(spacing: 10, children: [
                      for (final entry
                          in const {'product': '产品问题', 'order': '订单问题'}.entries)
                        ChoiceChip(
                            label: Text(entry.value),
                            selected: _category == entry.key,
                            onSelected: _sending
                                ? null
                                : (_) => setState(() => _category = entry.key))
                    ]),
                    if (_category == 'order') ...[
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                          initialValue: _orderId,
                          isExpanded: true,
                          decoration:
                              const InputDecoration(labelText: '关联我的订单'),
                          items: [
                            for (final row in _orders)
                              DropdownMenuItem(
                                  value: row['id'] as String,
                                  child: Text(
                                      '¥${((row['priceCents'] as num) / 100).toStringAsFixed(2)} · ${row['id'].toString().substring(0, 8)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis))
                          ],
                          onChanged: _sending
                              ? null
                              : (id) => setState(() => _orderId = id)),
                      if (!_loading && _orders.isEmpty)
                        const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('此账号暂时没有订单，可选择产品问题提交。')),
                    ],
                    const SizedBox(height: 16),
                    TextField(
                        controller: _message,
                        enabled: !_sending,
                        minLines: 5,
                        maxLines: 10,
                        maxLength: 4000,
                        decoration: const InputDecoration(
                            labelText: '问题描述',
                            hintText: '发生了什么、在哪个页面、怎样重现……请勿填写密码或验证码。'),
                        onChanged: (_) => setState(() {})),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                        onPressed: _sending ||
                                _message.text.trim().length < 3 ||
                                (_category == 'order' && _orderId == null)
                            ? null
                            : _send,
                        icon: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send_rounded),
                        label: Text(_sending ? '正在提交…' : '提交反馈')),
                    const SizedBox(height: 28),
                    Text('我的反馈',
                        style: Theme.of(context).textTheme.titleMedium),
                    if (!_loading && _history.isEmpty && _error == null)
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: Text('还没有提交过反馈')),
                    for (final row in _history)
                      Card(
                          child: ListTile(
                              leading: Icon(row['state'] == 'resolved'
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.chat_bubble_outline_rounded),
                              title: Text(row['message'].toString()),
                              subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(row['state'] == 'resolved'
                                        ? '已处理'
                                        : row['state'] == 'processing'
                                            ? '处理中'
                                            : '待处理'),
                                    if ((row['reply']?.toString().trim() ?? '')
                                        .isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text('处理意见',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium),
                                      const SizedBox(height: 4),
                                      SelectableText(row['reply'].toString(),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium),
                                    ],
                                  ]))),
                  ],
                  if (_loading)
                    const Padding(
                        padding: EdgeInsets.all(16),
                        child: LinearProgressIndicator()),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(_error!)),
                ]))));
  }
}
