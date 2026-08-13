import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Plays a one-shot fade + slide-up (6% of its own height) when the widget
/// first appears.  State is kept across rebuilds, so scrolling back and
/// forth does not replay the entrance.
class AppearIn extends StatefulWidget {
  const AppearIn({super.key, this.delay = Duration.zero, required this.child});
  final Duration delay;
  final Widget child;

  @override
  State<AppearIn> createState() => _AppearInState();
}

class _AppearInState extends State<AppearIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppMotion.normal);
    _fade = CurvedAnimation(parent: _controller, curve: AppMotion.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(_fade);
    if (widget.delay > Duration.zero) {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: SlideTransition(position: _slide, child: widget.child),
  );
}
