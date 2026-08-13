import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Desktop hover feedback: lifts the child 2px and exposes the hovered
/// state so callers can brighten the card border.  No-op on touch devices.
class HoverLift extends StatefulWidget {
  const HoverLift({super.key, required this.builder});
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.easeOut,
      transform: Matrix4.translationValues(0, _hovered ? -2 : 0, 0),
      child: widget.builder(context, _hovered),
    ),
  );
}

/// Border color for a hoverable card: accent-tinted while hovered.
Color hoverBorder(bool hovered) =>
    hovered ? AppColors.accent.withValues(alpha: 0.45) : AppColors.border;
