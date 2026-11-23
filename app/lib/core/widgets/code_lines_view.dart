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
          color:
              isExcerpt ? const Color(0xFFD98A2B) : CodeLinesView.accentColor,
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
class CodeLinesView extends StatefulWidget {
  final List<String> lines;
  final int startLine;
  final int? highlightStartLine;
  final int? highlightEndLine;
  final ScrollController? scrollController;
  final Color? codeTextColor;
  final bool autoScrollToHighlight;

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
    this.autoScrollToHighlight = false,
  });

  @override
  State<CodeLinesView> createState() => _CodeLinesViewState();
}

class _CodeLinesViewState extends State<CodeLinesView> {
  ScrollController? _ownedController;
  String? _lastScrolledKey;

  ScrollController get _effectiveController =>
      widget.scrollController ?? (_ownedController ??= ScrollController());

  @override
  void initState() {
    super.initState();
    _scheduleScrollToHighlight();
  }

  @override
  void didUpdateWidget(covariant CodeLinesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController == null && widget.scrollController != null) {
      _ownedController?.dispose();
      _ownedController = null;
    }
    if (oldWidget.autoScrollToHighlight != widget.autoScrollToHighlight ||
        oldWidget.highlightStartLine != widget.highlightStartLine ||
        oldWidget.startLine != widget.startLine ||
        oldWidget.lines.length != widget.lines.length) {
      _scheduleScrollToHighlight();
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  void _scheduleScrollToHighlight() {
    if (!widget.autoScrollToHighlight || widget.highlightStartLine == null) {
      return;
    }
    final key =
        '${widget.startLine}:${widget.highlightStartLine}:${widget.lines.length}';
    if (_lastScrolledKey == key) return;
    _lastScrolledKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_effectiveController.hasClients) return;
      final citedIndex = widget.highlightStartLine! - widget.startLine;
      if (citedIndex > 0) {
        final desired = math.max(0, citedIndex - 2) * CodeLinesView.lineHeight;
        _effectiveController.jumpTo(
          desired.clamp(0.0, _effectiveController.position.maxScrollExtent),
        );
      }
    });
  }

  double _gutterWidthFor(int lastLine) {
    final digits = '$lastLine'.length;
    return math.max(36.0, digits * 8.0 + 12.0);
  }

  @override
  Widget build(BuildContext context) {
    final lastLine = widget.lines.isEmpty
        ? widget.startLine
        : widget.startLine + widget.lines.length - 1;
    final gutterWidth = _gutterWidthFor(lastLine);
    final longestLine =
        widget.lines.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    final muted =
        Theme.of(context).textTheme.bodySmall?.color ?? const Color(0xFF8C8C8C);

    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth =
            gutterWidth + 14 + longestLine * CodeLinesView._charWidth + 16;
        final width = math.max(constraints.maxWidth, textWidth);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: ListView.builder(
              controller: _effectiveController,
              itemExtent: CodeLinesView.lineHeight,
              itemCount: widget.lines.length,
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
    final lineNumber = widget.startLine + index;
    final cited = widget.highlightStartLine != null &&
        lineNumber >= widget.highlightStartLine! &&
        lineNumber <= (widget.highlightEndLine ?? widget.highlightStartLine!);
    return Container(
      color: cited ? CodeLinesView.citedBandColor : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 2,
            color: cited ? CodeLinesView.accentColor : Colors.transparent,
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
                color: cited ? CodeLinesView.accentColor : muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            widget.lines[index],
            softWrap: false,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              color: widget.codeTextColor,
            ),
          ),
        ],
      ),
    );
  }
}
