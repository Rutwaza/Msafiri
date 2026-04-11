import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/colors.dart';

class SpotlightLoader extends StatefulWidget {
  const SpotlightLoader({
    super.key,
    this.size = 32,
    this.color = AppColors.primary,
  });

  final double size;
  final Color color;

  @override
  State<SpotlightLoader> createState() => _SpotlightLoaderState();
}

class _SpotlightLoaderState extends State<SpotlightLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Color.lerp(widget.color, Colors.white, 0.38) ?? widget.color;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_controller.value);
          final pulse = 0.86 + (math.sin(_controller.value * math.pi * 2) * 0.12);
          return Transform.scale(
            scale: pulse,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Transform.rotate(
                  angle: _controller.value * math.pi * 2,
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    color: accent.withValues(alpha: 0.52 + (t * 0.30)),
                    size: widget.size * 0.82,
                  ),
                ),
                Icon(
                  Icons.star_rounded,
                  color: widget.color.withValues(alpha: 0.92),
                  size: widget.size * 0.44,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

