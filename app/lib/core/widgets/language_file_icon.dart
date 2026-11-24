import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// File kinds [LanguageFileIcon] knows how to draw.
enum FileIconKind {
  python,
  dart,
  typescript,
  javascript,
  toml,
  yaml,
  json,
  markdown,
  generic,
}

/// Resolves the icon kind for [fileName] (a bare name or a path) from
/// its extension. Unknown or missing extensions fall back to
/// [FileIconKind.generic].
FileIconKind fileIconKindFor(String fileName) {
  final lower = fileName.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return FileIconKind.generic;
  switch (lower.substring(dot + 1)) {
    case 'py':
      return FileIconKind.python;
    case 'dart':
      return FileIconKind.dart;
    case 'ts':
    case 'tsx':
    case 'mts':
    case 'cts':
      return FileIconKind.typescript;
    case 'js':
    case 'jsx':
    case 'mjs':
    case 'cjs':
      return FileIconKind.javascript;
    case 'toml':
      return FileIconKind.toml;
    case 'yaml':
    case 'yml':
      return FileIconKind.yaml;
    case 'json':
    case 'jsonc':
      return FileIconKind.json;
    case 'md':
    case 'markdown':
      return FileIconKind.markdown;
    default:
      return FileIconKind.generic;
  }
}

/// Vector file icon for a source file, drawn with [CustomPaint] (plus
/// text chips for TypeScript/JavaScript) so it stays clean at any DPI.
///
/// Python renders as the two-tone blue/yellow mark; Dart as a stylised
/// teal diamond; TOML as a gear; YAML/JSON as labelled glyph chips;
/// Markdown as an outlined `M` + down-arrow badge; anything else as a
/// generic folded-page outline.
class LanguageFileIcon extends StatelessWidget {
  final String fileName;
  final double size;

  const LanguageFileIcon({
    super.key,
    required this.fileName,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: _buildForKind(fileIconKindFor(fileName)),
    );
  }

  Widget _buildForKind(FileIconKind kind) {
    switch (kind) {
      case FileIconKind.python:
        return const CustomPaint(painter: _PythonPainter());
      case FileIconKind.dart:
        return const CustomPaint(painter: _DartPainter());
      case FileIconKind.typescript:
        return _buildLabelChip('TS', const Color(0xFF3178C6), Colors.white);
      case FileIconKind.javascript:
        return _buildLabelChip('JS', const Color(0xFFF7DF1E), Colors.black);
      case FileIconKind.toml:
        return const CustomPaint(
          painter: _GearPainter(color: Color(0xFF9C4221)),
        );
      case FileIconKind.yaml:
        return _buildLabelChip('Y', const Color(0xFFCB171E), Colors.white);
      case FileIconKind.json:
        return const CustomPaint(painter: _BracesPainter());
      case FileIconKind.markdown:
        return const CustomPaint(painter: _MarkdownPainter());
      case FileIconKind.generic:
        return const CustomPaint(painter: _GenericFilePainter());
    }
  }

  Widget _buildLabelChip(String label, Color background, Color foreground) {
    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.18),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
    );
  }
}

void _paintCenteredText(
  Canvas canvas,
  Size size,
  String text,
  Color color,
  double fontSize,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        fontFamily: 'monospace',
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(
    canvas,
    Offset(
      (size.width - painter.width) / 2,
      (size.height - painter.height) / 2,
    ),
  );
}

/// Two-tone Python mark: blue upper snake head, yellow lower snake
/// head, each with a white eye.
class _PythonPainter extends CustomPainter {
  const _PythonPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final blue = Paint()..color = const Color(0xFF3776AB);
    final yellow = Paint()..color = const Color(0xFFFFD43B);
    final eye = Paint()..color = Colors.white;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.05, h * 0.03, w * 0.58, h * 0.58),
        Radius.circular(w * 0.17),
      ),
      blue,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.37, h * 0.39, w * 0.58, h * 0.58),
        Radius.circular(w * 0.17),
      ),
      yellow,
    );
    canvas.drawCircle(Offset(w * 0.25, h * 0.22), w * 0.055, eye);
    canvas.drawCircle(Offset(w * 0.75, h * 0.78), w * 0.055, eye);
  }

  @override
  bool shouldRepaint(covariant _PythonPainter oldDelegate) => false;
}

/// Stylised Dart mark: a teal diamond split by a lighter facet.
class _DartPainter extends CustomPainter {
  const _DartPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final base = Path()
      ..moveTo(w * 0.50, h * 0.04)
      ..lineTo(w * 0.96, h * 0.50)
      ..lineTo(w * 0.50, h * 0.96)
      ..lineTo(w * 0.04, h * 0.50)
      ..close();
    canvas.drawPath(base, Paint()..color = const Color(0xFF0175C2));
    final facet = Path()
      ..moveTo(w * 0.50, h * 0.04)
      ..lineTo(w * 0.96, h * 0.50)
      ..lineTo(w * 0.50, h * 0.50)
      ..close();
    canvas.drawPath(facet, Paint()..color = const Color(0xFF13B9FD));
  }

  @override
  bool shouldRepaint(covariant _DartPainter oldDelegate) => false;
}

/// Simple gear: eight teeth around a ring with a punched-out hub.
class _GearPainter extends CustomPainter {
  final Color color;

  const _GearPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()..color = color;
    for (var i = 0; i < 8; i++) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(i * math.pi / 4);
      canvas.drawRect(
        Rect.fromLTWH(
          -size.width * 0.07,
          -size.height * 0.50,
          size.width * 0.14,
          size.height * 0.20,
        ),
        paint,
      );
      canvas.restore();
    }
    canvas.drawCircle(center, size.width * 0.34, paint);
    canvas.drawCircle(
      center,
      size.width * 0.15,
      Paint()..blendMode = BlendMode.clear,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GearPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// JSON braces glyph in the conventional yellow.
class _BracesPainter extends CustomPainter {
  const _BracesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    _paintCenteredText(
      canvas,
      size,
      '{}',
      const Color(0xFFEAB308),
      size.height * 0.72,
    );
  }

  @override
  bool shouldRepaint(covariant _BracesPainter oldDelegate) => false;
}

/// Markdown badge: outlined rounded rect with an `M` and a down arrow.
class _MarkdownPainter extends CustomPainter {
  const _MarkdownPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = Paint()
      ..color = const Color(0xFF8A8A8E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, w * 0.07)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.05, h * 0.14, w * 0.90, h * 0.72),
        Radius.circular(w * 0.12),
      ),
      stroke,
    );
    final glyph = Paint()
      ..color = const Color(0xFFE4E4E7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, w * 0.08)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final mPath = Path()
      ..moveTo(w * 0.16, h * 0.68)
      ..lineTo(w * 0.16, h * 0.34)
      ..lineTo(w * 0.27, h * 0.55)
      ..lineTo(w * 0.38, h * 0.34)
      ..lineTo(w * 0.38, h * 0.68);
    canvas.drawPath(mPath, glyph);
    final arrowPath = Path()
      ..moveTo(w * 0.68, h * 0.32)
      ..lineTo(w * 0.68, h * 0.66)
      ..moveTo(w * 0.56, h * 0.54)
      ..lineTo(w * 0.68, h * 0.68)
      ..lineTo(w * 0.80, h * 0.54);
    canvas.drawPath(arrowPath, glyph);
  }

  @override
  bool shouldRepaint(covariant _MarkdownPainter oldDelegate) => false;
}

/// Generic file: folded-page outline.
class _GenericFilePainter extends CustomPainter {
  const _GenericFilePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = Paint()
      ..color = const Color(0xFFA1A1AA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, w * 0.07)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final page = Path()
      ..moveTo(w * 0.24, h * 0.06)
      ..lineTo(w * 0.62, h * 0.06)
      ..lineTo(w * 0.80, h * 0.24)
      ..lineTo(w * 0.80, h * 0.94)
      ..lineTo(w * 0.24, h * 0.94)
      ..close();
    canvas.drawPath(page, stroke);
    final fold = Path()
      ..moveTo(w * 0.62, h * 0.06)
      ..lineTo(w * 0.62, h * 0.24)
      ..lineTo(w * 0.80, h * 0.24);
    canvas.drawPath(fold, stroke);
  }

  @override
  bool shouldRepaint(covariant _GenericFilePainter oldDelegate) => false;
}
