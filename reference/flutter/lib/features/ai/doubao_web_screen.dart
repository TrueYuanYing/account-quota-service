import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../data/models/app_settings.dart';
import '../../services/ai/doubao_web_session.dart';
import '../../services/alert/question_context.dart';
import '../live/live_capture_screen.dart';

ModalRoute<dynamic>? _captureRoute;

void registerDoubaoCaptureRoute(ModalRoute<dynamic> route) {
  _captureRoute = route;
}

void unregisterDoubaoCaptureRoute(ModalRoute<dynamic>? route) {
  if (_captureRoute == route) _captureRoute = null;
}

bool openDoubaoInApp(WidgetRef ref,
    {String? prompt, String? questionId, BuildContext? context}) {
  if (ref.read(settingsProvider).valueOrNull?.answerMode !=
      QuestionAnswerMode.web) {
    return false;
  }
  final navigator = appNavigatorKey.currentState ??
      (context == null ? null : Navigator.maybeOf(context));
  if (navigator == null) return false;
  final session = ref.read(doubaoWebSessionProvider);
  if (prompt != null &&
      questionId != null &&
      !session.offerQuestion(questionId, prompt)) {
    return false;
  }
  final existing = _captureRoute;
  if (existing != null && existing.navigator == navigator) {
    if (!existing.isActive) return false;
    navigator.popUntil((route) => route == existing);
    return true;
  }
  if (session.routeOpen) return true;
  session.routeOpen = true;
  final route =
      MaterialPageRoute<void>(builder: (_) => const LiveCaptureScreen());
  unawaited(navigator.push<void>(route));
  unawaited(route.completed.whenComplete(() {
    session.routeOpen = false;
  }));
  return true;
}

/// Both panes belong to the capture page; neither overlays the other.
class DoubaoCaptureSplit extends StatefulWidget {
  const DoubaoCaptureSplit(
      {super.key,
      required this.transcript,
      this.keyboardVisible = false,
      this.keyboardControls});
  final Widget transcript;
  final bool keyboardVisible;
  final Widget? keyboardControls;

  @override
  State<DoubaoCaptureSplit> createState() => _DoubaoCaptureSplitState();
}

class _DoubaoCaptureSplitState extends State<DoubaoCaptureSplit> {
  // Preserve the platform view and pending question across layout reparenting.
  final _webKey = GlobalKey(debugLabel: 'doubao-web-pane');
  final _transcriptKey = GlobalKey(debugLabel: 'capture-transcript-pane');

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (_, constraints) {
        final wide = constraints.maxWidth >= 720;
        final keyboard = widget.keyboardVisible;
        final primary =
            KeyedSubtree(key: _transcriptKey, child: widget.transcript);
        final web = DoubaoWebScreen(key: _webKey, compact: keyboard);
        final color = Theme.of(context).colorScheme.outlineVariant;
        if (wide) {
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                flex: 55,
                child: SizedBox(
                    key: const ValueKey('capture-transcript-pane'),
                    child: primary)),
            VerticalDivider(width: 1, thickness: 1, color: color),
            Expanded(
                flex: 45,
                child: SizedBox(
                    key: const ValueKey('doubao-web-pane'), child: web)),
          ]);
        }
        return Column(children: [
          // Keep the composer usable when the keyboard takes most of a phone.
          if (!keyboard)
            Expanded(
                flex: 45,
                child: SizedBox(
                    key: const ValueKey('capture-transcript-pane'),
                    child: primary)),
          if (keyboard && widget.keyboardControls != null)
            SizedBox(height: 56, child: widget.keyboardControls),
          Divider(height: 1, thickness: 1, color: color),
          Expanded(
              flex: 55,
              child:
                  SizedBox(key: const ValueKey('doubao-web-pane'), child: web)),
        ]);
      });
}

void openLatestDoubaoQuestion(BuildContext context, WidgetRef ref,
    {String question = ''}) {
  final live = ref.read(liveSessionProvider).current;
  final prompt = QuestionContext.webPrompt(
      transcript: live.transcript,
      partial: live.livePartial,
      question: question,
      subjectContext:
          ref.read(keywordManagerProvider).valueOrNull?.contextLine() ?? '');
  openDoubaoInApp(ref,
      context: context,
      prompt: prompt.isEmpty ? null : prompt,
      questionId: 'manual:${DateTime.now().microsecondsSinceEpoch}');
}

/// The official page renders its own login and answers; IKO never imports login data.
class DoubaoWebScreen extends ConsumerStatefulWidget {
  const DoubaoWebScreen({super.key, this.compact = false});
  final bool compact;
  @override
  ConsumerState<DoubaoWebScreen> createState() => _DoubaoWebScreenState();
}

class _DoubaoWebScreenState extends ConsumerState<DoubaoWebScreen>
    with WidgetsBindingObserver, RouteAware {
  late final DoubaoWebSession _session;
  String? _error;
  bool _covered = false;
  bool _background = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = ref.read(doubaoWebSessionProvider);
    ref.listenManual(settingsProvider, (_, next) {
      if (next.valueOrNull?.answerMode != QuestionAnswerMode.web) {
        unawaited(_session.suspend(discard: true));
      } else if (!_covered && !_background) {
        unawaited(_activate());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _activate());
  }

  Future<void> _activate() async {
    if (!mounted ||
        _covered ||
        _background ||
        ref.read(settingsProvider).valueOrNull?.answerMode !=
            QuestionAnswerMode.web) {
      return;
    }
    try {
      await _session.activate();
      if (mounted && _error != null) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = '内置网页启动失败，可用外部浏览器打开豆包。');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPop() {
    _covered = true;
    unawaited(_session.suspend(discard: true));
  }

  @override
  void didPushNext() {
    _covered = true;
    unawaited(_session.suspend());
  }

  @override
  void didPopNext() {
    _covered = false;
    unawaited(_activate());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _background = false;
      if (ref.read(settingsProvider).valueOrNull?.answerMode ==
          QuestionAnswerMode.web) {
        _activate();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _background = true;
      unawaited(_session.suspend());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    unawaited(_session.suspend(discard: true));
    super.dispose();
  }

  Future<void> _copy() async {
    if (_session.pendingPrompt.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: _session.pendingPrompt));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('待发问题已复制，可在网页长按粘贴。')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('复制失败，可在问题预览中长按复制。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(doubaoWebSessionProvider);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
          automaticallyImplyLeading: false,
          toolbarHeight: 44,
          titleTextStyle: Theme.of(context).textTheme.titleSmall,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          title: const Text('豆包 · 网页问答'),
          actions: [
            IconButton(
                tooltip: '重新加载豆包',
                onPressed: session.initialized && _error == null
                    ? () => session.controller.reload()
                    : _activate,
                icon: const Icon(Icons.refresh_rounded)),
            IconButton(
                tooltip: '外部浏览器',
                onPressed: () async {
                  try {
                    await const MethodChannel('com.iko.study/web_question')
                        .invokeMethod<void>('openDoubao');
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('无法打开浏览器，可自行访问 www.doubao.com。')));
                    }
                  }
                },
                icon: const Icon(Icons.open_in_new_rounded)),
          ]),
      body: SafeArea(
          child: Column(children: [
        if (!widget.compact)
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(_error ?? session.message,
                        style: Theme.of(context).textTheme.bodySmall),
                    if (session.pendingPrompt.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(spacing: 8, children: [
                        TextButton.icon(
                            onPressed: () => showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                builder: (_) => SafeArea(
                                    child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: SizedBox(
                                            height: MediaQuery.sizeOf(context)
                                                    .height *
                                                .6,
                                            child: SingleChildScrollView(
                                                child: SelectableText(
                                                    session.pendingPrompt)))))),
                            icon: const Icon(Icons.notes_rounded),
                            label: Text(
                                '问题预览 · ${session.pendingPrompt.length} 字')),
                        TextButton(onPressed: _copy, child: const Text('复制问题')),
                        TextButton(
                            onPressed: session.retry,
                            child: const Text('重试发送')),
                      ]),
                    ],
                  ])),
        if (session.progress < 100)
          LinearProgressIndicator(value: session.progress / 100),
        Expanded(
            child: session.initialized && _error == null
                ? WebViewWidget(controller: session.controller)
                : const Center(child: Text('正在准备豆包官方网页…'))),
      ])),
    );
  }
}
