import 'package:flutter/material.dart';

class VeraxiLogo extends StatelessWidget {
  final double size;
  final Color color;

  const VeraxiLogo({
    super.key,
    this.size = 24.0,
    this.color = const Color(0xFFB4B4B4),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _VeraxiLogoPainter(color: color),
      ),
    );
  }
}

class _VeraxiLogoPainter extends CustomPainter {
  const _VeraxiLogoPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(size.width * 0.22, size.height * 0.28)
      ..lineTo(size.width * 0.5, size.height * 0.78)
      ..lineTo(size.width * 0.78, size.height * 0.28)
      ..moveTo(size.width * 0.32, size.height * 0.28)
      ..lineTo(size.width * 0.5, size.height * 0.62)
      ..lineTo(size.width * 0.68, size.height * 0.28);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _VeraxiLogoPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
