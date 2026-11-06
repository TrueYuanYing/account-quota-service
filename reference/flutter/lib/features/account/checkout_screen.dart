import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

bool isIkoCheckout(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'example.invalid' &&
    (!uri.hasPort || uri.port == 443) &&
    uri.userInfo.isEmpty &&
    uri.path == '/v1/payments/checkout';

Uri alipayCheckoutUri(Uri checkout) {
  if (!isIkoCheckout(checkout)) throw ArgumentError('Invalid checkout');
  return Uri(
      scheme: 'alipays',
      host: 'platformapi',
      path: '/startapp',
      queryParameters: {'appId': '20000067', 'url': checkout.toString()});
}

enum CheckoutNavigation { web, alipay, block }

CheckoutNavigation checkoutNavigation(Uri uri) {
  if (uri.toString() == 'about:blank') return CheckoutNavigation.web;
  if (uri.userInfo.isNotEmpty || uri.toString().length > 16384) {
    return CheckoutNavigation.block;
  }
  if ((uri.scheme == 'alipays' || uri.scheme == 'alipay') &&
      !uri.hasPort &&
      uri.host == 'platformapi' &&
      uri.path.toLowerCase() == '/startapp') {
    return CheckoutNavigation.alipay;
  }
  final host = uri.host.toLowerCase();
  final trusted = host == 'example.invalid' ||
      host == 'zpayz.cn' ||
      host.endsWith('.zpayz.cn') ||
      host == 'z-pay.cn' ||
      host.endsWith('.z-pay.cn') ||
      host == 'alipay.com' ||
      host.endsWith('.alipay.com');
  return uri.scheme == 'https' && (!uri.hasPort || uri.port == 443) && trusted
      ? CheckoutNavigation.web
      : CheckoutNavigation.block;
}

/// No account token or native JS bridge is given to the payment website.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key, required this.url});
  final Uri url;
  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  WebViewController? _web;
  bool _qr = false, _opening = false;
  bool _ready = false;
  bool _mainFrameFailed = false;
  int _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!isIkoCheckout(widget.url)) {
      _error = '支付链接无效，请返回账户重新打开。';
      return;
    }
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value.clamp(0, 99));
        },
        onPageStarted: (_) {
          if (mounted) {
            setState(() {
              _ready = false;
              _mainFrameFailed = false;
              _progress = 0;
            });
          }
        },
        onPageFinished: _finishPage,
        onNavigationRequest: (request) async {
          final uri = Uri.tryParse(request.url);
          final action =
              uri == null ? CheckoutNavigation.block : checkoutNavigation(uri);
          if (action == CheckoutNavigation.alipay && request.isMainFrame) {
            await _openAlipay(uri!);
          }
          if (action == CheckoutNavigation.block &&
              request.isMainFrame &&
              mounted) {
            setState(() => _error = '支付平台跳转到了未支持的页面，请改用支付宝或扫码打开此订单。');
          }
          return action == CheckoutNavigation.web
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && mounted) {
            setState(() {
              _mainFrameFailed = true;
              _error = '收银台暂未加载，请重试；也可使用支付宝或扫码打开同一订单。';
            });
          }
        },
      ));
    _load();
  }

  Future<void> _finishPage(String url) async {
    if (!mounted) return;
    if (isIkoCheckout(Uri.parse(url))) {
      final colors = Theme.of(context).colorScheme;
      String hex(Color c) => '#${c.toARGB32().toRadixString(16).substring(2)}';
      final css =
          'body{background:${hex(colors.surface)}!important;color:${hex(colors.onSurface)}!important}'
          '.panel{background:${hex(colors.surfaceContainerLow)};border-color:${hex(colors.outlineVariant)}}'
          '.note,header span,footer,.order,.quotas dt{color:${hex(colors.onSurfaceVariant)}}'
          'button{background:${hex(colors.primary)};color:${hex(colors.onPrimary)}}'
          '.channel{color:${hex(colors.secondary)}}';
      try {
        await _web?.runJavaScript('''(() => {
          if(location.hostname !== 'example.invalid' || location.pathname !== '/v1/payments/checkout') return;
          let s = document.getElementById('iko-host-theme');
          if (!s) { s = document.createElement('style'); s.id = 'iko-host-theme'; document.head.appendChild(s); }
          s.textContent = ${jsonEncode(css)};
        })()''');
      } catch (_) {
        // Optional host styling must not erase or replace a payment-load error.
      }
    }
    if (mounted) {
      setState(() {
        if (!_mainFrameFailed) _error = null;
        _ready = !_mainFrameFailed;
        _progress = 100;
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _mainFrameFailed = false;
      _progress = 0;
      _ready = false;
    });
    try {
      await _web?.loadRequest(widget.url);
    } catch (_) {
      if (mounted) setState(() => _error = '无法加载收银台，请重试或改用扫码。');
    }
  }

  Future<void> _openAlipay(Uri uri) async {
    if (!mounted || _opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await const MethodChannel('com.iko.study/web_question')
          .invokeMethod<void>(
              'openAlipay', {'url': uri.replace(path: '/startapp').toString()});
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _error = error.code == 'alipay_unavailable'
            ? '此设备未安装支付宝，可在下方收银台继续，或选择扫码支付。'
            : '暂时无法打开支付宝，可在下方继续或改用扫码支付。');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法打开支付宝，请使用下方收银台或扫码。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final valid = isIkoCheckout(widget.url);
    return Scaffold(
      appBar: AppBar(title: const Text('确认付款'), actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回核对到账')),
      ]),
      body: SafeArea(
          child: Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(children: [
              SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                        value: false,
                        icon: Icon(Icons.account_balance_wallet_outlined),
                        label: Text('支付宝付款')),
                    ButtonSegment(
                        value: true,
                        icon: Icon(Icons.qr_code_rounded),
                        label: Text('扫码支付')),
                  ],
                  selected: {
                    _qr
                  },
                  onSelectionChanged: (value) =>
                      setState(() => _qr = value.single)),
              const SizedBox(height: 8),
              if (!_qr)
                SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: !valid || _opening
                          ? null
                          : () => _openAlipay(alipayCheckoutUri(widget.url)),
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: Text(_opening ? '正在打开支付宝…' : '直接打开支付宝'),
                    )),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(children: [
                      Expanded(
                          child: Text(_error!,
                              style: TextStyle(color: colors.error))),
                      if (!_qr && valid)
                        TextButton(onPressed: _load, child: const Text('重试')),
                    ])),
            ])),
        Expanded(
            child: _qr && valid
                ? LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Center(
                            child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Column(children: [
                            const Text('扫码打开此订单'),
                            const SizedBox(height: 12),
                            DecoratedBox(
                                decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(18)),
                                child: QrImageView(
                                    data: widget.url.toString(),
                                    size: (constraints.maxWidth - 56)
                                        .clamp(160.0, 280.0),
                                    padding: const EdgeInsets.all(18),
                                    semanticsLabel: 'IKO 当前订单入口二维码')),
                            const SizedBox(height: 16),
                            const Text(
                                '使用另一台设备的支付宝扫一扫，打开同一订单，再核对金额和额度并确认付款。二维码为订单入口，不会自动扣款。'),
                            const SizedBox(height: 8),
                            const Text(
                                '链接自生成起15分钟有效。过期后返回账户重新打开；不要将二维码发给无关的人。'),
                          ]),
                        ))))
                : _web == null
                    ? const SizedBox.shrink()
                    : Stack(children: [
                        IgnorePointer(
                            ignoring: !_ready && _error == null,
                            child: Opacity(
                                opacity: _ready || _error != null ? 1 : 0,
                                child: WebViewWidget(controller: _web!))),
                        if (!_ready && _error == null)
                          LinearProgressIndicator(
                              value: _progress == 0 ? null : _progress / 100),
                      ])),
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text('完成付款后返回核对到账；额度以服务器核验结果为准。',
                style: Theme.of(context).textTheme.bodySmall)),
      ])),
    );
  }
}
