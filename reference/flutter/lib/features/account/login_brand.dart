import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/widgets/app_widgets.dart';

/// 保留品牌字形，仅重绘O的眼眶与瞳孔。后台、离页和减少动态效果时停止。
class LoginBrand extends StatefulWidget {
  const LoginBrand({super.key});
  @override
  State<LoginBrand> createState() => _LoginBrandState();
}

class _LoginBrandState extends State<LoginBrand>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _motion =
      AnimationController(vsync: this, duration: const Duration(seconds: 6));
  bool _foreground = true, _enabled = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _sync();
  }

  void _sync() {
    if (_enabled && _foreground) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
      _motion.value = 0;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
      child: SizedBox(
          width: 80,
          height: 80,
          child: CustomPaint(
              foregroundPainter: _EyePainter(_motion),
              child: const BrandIconPreview(mode: 'light', size: 80))));
}

class _EyePainter extends CustomPainter {
  _EyePainter(this.motion) : super(repaint: motion);
  final Animation<double> motion;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1024, size.height / 1024);
    // 固定品牌眼眶内部边界，避免原瞳孔在闭眼时漏出。
    const eye = Rect.fromLTRB(666, 388, 804, 636);
    const paper = Color(0xfff3f2ee);
    const ink = Color(0xff17191c);
    final t = motion.value;
    final blink = (1 - ((t - .72).abs() / .025)).clamp(0.0, 1.0);
    canvas.drawOval(eye, Paint()..color = ink);
    canvas.save();
    canvas.clipPath(Path()..addOval(eye));
    canvas.translate(735, 512);
    canvas.scale(1, 1 - blink * .97);
    canvas.translate(-735, -512);
    canvas.drawOval(eye, Paint()..color = paper);
    final shift =
        Offset(math.sin(t * math.pi * 2) * 8, math.sin(t * math.pi * 4) * 3);
    canvas.drawOval(
        Rect.fromCenter(
            center: const Offset(748, 511) + shift, width: 90, height: 108),
        Paint()..color = const Color(0xff487bff));
    canvas.drawCircle(
        const Offset(736, 485) + shift, 15, Paint()..color = paper);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EyePainter oldDelegate) => oldDelegate.motion != motion;
}
