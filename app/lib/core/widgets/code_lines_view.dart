import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// "Full file" (blue) or "Excerpt" (amber) provenance pill for code citations.
///
/// Design contract: docs/design/veraxi_code_citation_viewer.svg.
class CodeSourceBadge extends StatelessWidget {
  final bool isExcerpt;

  const CodeSourceBadge({
    super.key,
    required this.isExcerpt,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: isExcerpt ? const Color(0xFF2E2417) : const Color(0xFF233148),
        border: Border.all(
          color: isExcerpt ? const Color(0xFFD98A2B) : CodeLinesView.accentColor,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        isExcerpt ? 'Excerpt' : 'Full file',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: isExcerpt ? const Color(0xFFF3D3A7) : const Color(0xFFBFD7FB),
        ),
      ),
    );
  }
}

/// Pure presentational renderer for plain-text monospace code lines with
/// fixed-height rows, tabular right-aligned gutter numbers, horizontal scroll,
/// and an optional highlighted line range band.
class CodeLinesView extends StatelessWidget {
  final List<String> lines;
  final int startLine;
  final int? highlightStartLine;
  final int? highlightEndLine;
  final ScrollController? scrollController;
  final Color? codeTextColor;

  /// Accent used for the cited-range band and cited gutter numbers.
  static const Color accentColor = Color(0xFF4F8EF7);

  /// Background of the cited-range band.
  static const Color citedBandColor = Color(0xFF1D2A44);

  /// Fixed row height; scroll-to-cited-line math depends on it.
  static const double lineHeight = 21.0;

  static const double _charWidth = 7.55;

  const CodeLinesView({
    super.key,
    required this.lines,
    this.startLine = 1,
    this.highlightStartLine,
    this.highlightEndLine,
    this.scrollController,
    this.codeTextColor,
  });

  double _gutterWidthFor(int lastLine) {
    final digits = '$lastLine'.length;
    return math.max(36.0, digits * 8.0 + 12.0);
  }

  @override
  Widget build(BuildContext context) {
    final lastLine = lines.isEmpty ? startLine : startLine + lines.length - 1;
    final gutterWidth = _gutterWidthFor(lastLine);
    final longestLine =
        lines.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    final muted = Theme.of(context).textTheme.bodySmall?.color ??
        const Color(0xFF8C8C8C);

    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = gutterWidth + 14 + longestLine * _charWidth + 16;
        final width = math.max(constraints.maxWidth, textWidth);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: ListView.builder(
              controller: scrollController,
              itemExtent: lineHeight,
              itemCount: lines.length,
              itemBuilder: (context, index) => _buildLineRow(
                index: index,
                gutterWidth: gutterWidth,
                muted: muted,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLineRow({
    required int index,
    required double gutterWidth,
    required Color muted,
  }) {
    final lineNumber = startLine + index;
    final cited = highlightStartLine != null &&
        lineNumber >= highlightStartLine! &&
        lineNumber <= (highlightEndLine ?? highlightStartLine!);
    return Container(
      color: cited ? citedBandColor : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 2,
            color: cited ? accentColor : Colors.transparent,
          ),
          SizedBox(
            width: gutterWidth,
            child: Text(
              '$lineNumber',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: cited ? FontWeight.w600 : FontWeight.normal,
                color: cited ? accentColor : muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            lines[index],
            softWrap: false,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              color: codeTextColor,
            ),
          ),
        ],
      ),
    );
  }
}
