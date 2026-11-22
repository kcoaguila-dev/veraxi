import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/widgets/code_lines_view.dart';
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
  static const Color accentColor = CodeLinesView.accentColor;

  /// Background of the cited-range band.
  static const Color citedBandColor = CodeLinesView.citedBandColor;

  /// Fixed row height; the scroll-to-cited-line math depends on it.
  static const double lineHeight = CodeLinesView.lineHeight;

  @override
  ConsumerState<CodeCitationViewer> createState() => _CodeCitationViewerState();
}

class _CodeCitationViewerState extends ConsumerState<CodeCitationViewer> {
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
                return CodeLinesView(
                  lines: content.lines,
                  startLine: content.startLine,
                  highlightStartLine: widget.target.startLine,
                  highlightEndLine: widget.target.effectiveEndLine,
                  scrollController: _scrollController,
                );
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
            CodeSourceBadge(isExcerpt: content.isExcerpt),
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
