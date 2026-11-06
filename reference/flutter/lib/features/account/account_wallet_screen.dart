import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../core/widgets/app_widgets.dart';
import '../../services/account/account_auth.dart';
import '../../services/account/account_business.dart';
import '../../services/account/operation_id.dart';
import 'account_screen.dart';
import 'checkout_screen.dart';
import 'quota_product_card.dart';

class AccountWalletScreen extends ConsumerStatefulWidget {
  const AccountWalletScreen({super.key});
  @override
  ConsumerState<AccountWalletScreen> createState() =>
      _AccountWalletScreenState();
}

class _AccountWalletScreenState extends ConsumerState<AccountWalletScreen>
    with WidgetsBindingObserver {
  static const names = {
    'answer': '答题',
    'correct': '云端纠错',
    'translate': '翻译',
    'summary': '课堂摘要'
  };
  Map<String, dynamic>? _document, _catalog;
  String? _error, _pendingProduct, _requestId;
  bool _loading = false, _buying = false;
  int _revision = 0;
  String? _documentOwner;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading && !_buying) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _message(Object error) =>
      error is StateError ? error.message.toString() : '暂时无法读取，请稍后重试。';
  Future<void> _load() async {
    final revision = ++_revision;
    if (!ref.read(accountAuthProvider).hasSession) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final business = ref.read(accountBusinessProvider);
      final owner = ref.read(accountAuthProvider).userId;
      final values =
          await Future.wait([business.document(), business.products()]);
      if (mounted &&
          revision == _revision &&
          owner == ref.read(accountAuthProvider).userId) {
        setState(() {
          _document = values[0];
          _catalog = values[1];
          _documentOwner = owner;
        });
      }
      ref.invalidate(activationStatusProvider);
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _loading = false);
    }
  }

  Future<void> _buy(String product) async {
    if (_buying || _catalog?['checkoutEnabled'] != true) return;
    if (_pendingProduct != product) {
      _pendingProduct = product;
      _requestId = newOperationId();
    }
    setState(() => _buying = true);
    try {
      var result = await ref
          .read(accountBusinessProvider)
          .createOrder(product, _requestId!);
      if (result['state'] == 'expired') {
        _requestId = newOperationId();
        result = await ref
            .read(accountBusinessProvider)
            .createOrder(product, _requestId!);
      }
      final url = Uri.tryParse(result['checkoutUrl']?.toString() ?? '');
      if (url == null || !isIkoCheckout(url)) {
        throw StateError('支付链接无效，未打开付款页面。');
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => CheckoutScreen(url: url)));
      if (!mounted) return;
      // Reuse the pending order after cancellation; opening a page is not payment.
      final status = await ref
          .read(accountBusinessProvider)
          .checkOrder(result['id'].toString());
      if (status['state'] == 'paid' || status['state'] == 'expired') {
        _pendingProduct = null;
        _requestId = null;
      }
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  Future<void> _check(String id) async {
    setState(() => _buying = true);
    try {
      await ref.read(accountBusinessProvider).checkOrder(id);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(accountAuthProvider), theme = Theme.of(context);
    final document =
        auth.hasSession && _documentOwner == auth.userId ? _document : null;
    final rows = document?['quota'] as List? ?? [];
    return Scaffold(
        appBar: AppBar(title: const Text('账户额度'), actions: [
          IconButton(
              tooltip: '刷新',
              onPressed: _loading || _buying ? null : _load,
              icon: const Icon(Icons.refresh_rounded))
        ]),
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 740),
                    child:
                        ListView(padding: const EdgeInsets.all(20), children: [
                      Text('云端服务', style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      const Text(
                          '额度按账号保存，购买后累加，无日历到期。请求发送云端模型处理后计一次，超时、中断或未得到有效回答也计次。未通过登录、额度或繁忙校验不扣；手动重新生成另计一次。长课堂摘要的分段与合并各自计次。'),
                      const SizedBox(height: 16),
                      if (!auth.hasSession)
                        GlassCard(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              const Text('登录后查看额度和订单。离线听写、提醒、笔记、课表与专注可继续使用。'),
                              const SizedBox(height: 12),
                              FilledButton(
                                  onPressed: () async {
                                    await Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                            builder: (_) =>
                                                const AccountScreen()));
                                    if (mounted) await _load();
                                  },
                                  child: const Text('登录 IKO'))
                            ])),
                      if (_loading) const LinearProgressIndicator(),
                      if (_error != null)
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(_error!,
                                style:
                                    TextStyle(color: theme.colorScheme.error))),
                      for (final raw in rows)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: GlassCard(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Row(children: [
                                    Expanded(
                                        child: Text(names[raw['kind']] ?? '额度',
                                            style:
                                                theme.textTheme.titleMedium)),
                                    Text('${raw['remaining']} 次',
                                        style: theme.textTheme.titleLarge)
                                  ]),
                                  const SizedBox(height: 12),
                                  LinearProgressIndicator(
                                      value: (raw['total'] as num) > 0
                                          ? ((raw['remaining'] as num) /
                                                  (raw['total'] as num))
                                              .clamp(0, 1)
                                          : 0),
                                  const SizedBox(height: 8),
                                  Text(
                                      '已用 ${raw['used']} · 处理中 ${raw['reserved']} · 今日成功 ${(document?['todayUsage'] as Map?)?[raw['kind']] ?? 0}'),
                                ]))),
                      if (auth.hasSession) ...[
                        const SizedBox(height: 12),
                        Text('添加额度', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 8),
                        for (final raw in _catalog?['products'] as List? ?? [])
                          Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: QuotaProductCard(
                                product: Map<String, dynamic>.from(raw),
                                onBuy: _buying ||
                                        raw['purchasable'] != true ||
                                        _catalog?['checkoutEnabled'] != true
                                    ? null
                                    : () => _buy(raw['id']),
                              )),
                        const SizedBox(height: 12),
                        Text('最近订单', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 8),
                        for (final row in document?['orders'] as List? ?? [])
                          Card(
                              child: ListTile(
                                  leading:
                                      const Icon(Icons.receipt_long_outlined),
                                  title: Text(
                                      '¥${((row['priceCents'] as num) / 100).toStringAsFixed(2)} · ${row['state'] == 'paid' ? '已入账' : row['state'] == 'pending' ? '待付款' : row['state'] == 'expired' ? '超时关闭' : '已撤销'}'),
                                  subtitle: Text(row['id'].toString()),
                                  trailing: row['state'] == 'pending' &&
                                          _catalog?['checkoutEnabled'] == true
                                      ? TextButton(
                                          onPressed: _buying
                                              ? null
                                              : () => _check(row['id']),
                                          child: const Text('核对到账'))
                                      : null)),
                      ],
                      const SizedBox(height: 12),
                      const Text('自备 API 费用由对应供应商收取。管理员激活码仅在 IKO 管理版使用。'),
                    ])))));
  }
}
