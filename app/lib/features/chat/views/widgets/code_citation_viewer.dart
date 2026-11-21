import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/view_models/code_file_view_model.dart';

/// In-app viewer for a line-anchored code citation.
///
/// Opens when a citation chip carrying a `file://<path>#L<start>-L<end>`
/// URL is tapped (see [CodeCitationTarget.tryParse]). Shows the file
/// exactly as the server served it — plain text, real line numbers,
/// the cited range as an accent band — scrolled so the first cited
/// line sits near the top. Read-only by design: this is a citation
/// viewer, not an editor.
///
/// Visual contract: docs/design/veraxi_code_citation_viewer.svg.
class CodeCitationViewer extends ConsumerStatefulWidget {
  final CodeCitationTarget target;

  /// Optional external scroll controller (used by tests to assert
  /// the viewer scrolled to the cited line). When null the viewer
  /// owns and disposes its own controller.
  final ScrollController? scrollController;

  const CodeCitationViewer({
    super.key,
    required this.target,
    this.scrollController,
  });

  /// Accent used for the cited-range band and cited gutter numbers.
  static const Color accentColor = Color(0xFF4F8EF7);

  /// Background of the cited-range band.
  static const Color citedBandColor = Color(0xFF1D2A44);

  /// Fixed row height; the scroll-to-cited-line math depends on it.
  static const double lineHeight = 21.0;

  @override
  ConsumerState<CodeCitationViewer> createState() => _CodeCitationViewerState();
}

class _CodeCitationViewerState extends ConsumerState<CodeCitationViewer> {
  /// Approximate advance width of one monospace character at the
  /// body font size; used only to size the horizontal scroll area.
  static const double _charWidth = 7.55;

  late final ScrollController _scrollController;
  bool _ownsScrollController = false;
  bool _didScrollToCitedLine = false;

  @override
  void initState() {
    super.initState();
    final external = widget.scrollController;
    if (external != null) {
      _scrollController = external;
    } else {
      _scrollController = ScrollController();
      _ownsScrollController = true;
    }
  }

  @override
  void dispose() {
    if (_ownsScrollController) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  /// Scroll once, after the first frame with content, so the first
  /// cited line sits near the top with two context lines above it
  /// when they exist.
  void _scheduleScrollToCitedLine(CodeFileContent content) {
    if (_didScrollToCitedLine) return;
    _didScrollToCitedLine = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final citedIndex = widget.target.startLine - content.startLine;
      if (citedIndex <= 0) return;
      final desired = (citedIndex - 2) * CodeCitationViewer.lineHeight;
      final maxExtent = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(desired.clamp(0.0, maxExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    final asyncContent = ref.watch(codeFileProvider(widget.target));
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          widget.target.path,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSubHeader(asyncContent),
          const Divider(height: 1),
          Expanded(
            child: asyncContent.when(
              data: (content) {
                _scheduleScrollToCitedLine(content);
                return _buildLineList(content);
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => _buildUnavailable(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubHeader(AsyncValue<CodeFileContent> asyncContent) {
    final target = widget.target;
    final range = target.endLine != null
        ? 'Cited lines ${target.startLine}–${target.endLine}'
        : 'Cited line ${target.startLine}';
    final content = asyncContent.valueOrNull;
    final caption = content == null
        ? range
        : '$range · ${content.lineCount} lines'
            '${content.language != null ? ' · ${content.language}' : ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (content != null) ...[
            _buildSourceBadge(content),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              caption,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// "Full file" (blue) or "Excerpt" (amber) pill, mirroring the
  /// badge treatment in docs/design/sources_provenance.svg.
  Widget _buildSourceBadge(CodeFileContent content) {
    final excerpt = content.isExcerpt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: excerpt ? const Color(0xFF2E2417) : const Color(0xFF233148),
        border: Border.all(
          color: excerpt
              ? const Color(0xFFD98A2B)
              : CodeCitationViewer.accentColor,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        excerpt ? 'Excerpt' : 'Full file',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: excerpt ? const Color(0xFFF3D3A7) : const Color(0xFFBFD7FB),
        ),
      ),
    );
  }

  Widget _buildLineList(CodeFileContent content) {
    final lines = content.lines;
    final gutterWidth = _gutterWidthFor(content.endLine);
    final longestLine =
        lines.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = gutterWidth + 14 + longestLine * _charWidth + 16;
        final width = math.max(constraints.maxWidth, textWidth);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: ListView.builder(
              controller: _scrollController,
              itemExtent: CodeCitationViewer.lineHeight,
              itemCount: lines.length,
              itemBuilder: (context, index) =>
                  _buildLineRow(content, index, gutterWidth),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLineRow(
    CodeFileContent content,
    int index,
    double gutterWidth,
  ) {
    final lineNumber = content.startLine + index;
    final cited = lineNumber >= widget.target.startLine &&
        lineNumber <= widget.target.effectiveEndLine;
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    return Container(
      color: cited ? CodeCitationViewer.citedBandColor : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 2,
            color: cited ? CodeCitationViewer.accentColor : Colors.transparent,
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
                color: cited ? CodeCitationViewer.accentColor : muted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            content.lines[index],
            softWrap: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  double _gutterWidthFor(int lastLine) {
    final digits = '$lastLine'.length;
    return math.max(36.0, digits * 8.0 + 12.0);
  }

  Widget _buildUnavailable() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.code_off,
              size: 40,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
            const SizedBox(height: 16),
            const Text(
              "This file isn't available on the server.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              'It may have been indexed from another device, or '
              'removed since this answer was generated.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
