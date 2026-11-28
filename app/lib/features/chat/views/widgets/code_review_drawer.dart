import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/core/widgets/code_lines_view.dart';
import 'package:veraxi_app/core/widgets/language_file_icon.dart';
import 'package:veraxi_app/features/chat/view_models/code_file_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_review_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/selection_edge_auto_scroll.dart';

/// Kind of one rendered diff row.
enum _DiffRowKind { header, addition, deletion, context, meta }

/// One rendered diff row: its display line number (new-file number
/// for additions/context, old-file number for deletions) and text.
class _DiffRow {
  final _DiffRowKind kind;
  final int? lineNumber;
  final String text;

  const _DiffRow(this.kind, this.lineNumber, this.text);
}

/// Flattens one hunk's raw unified-diff lines into display rows,
/// tracking old/new line numbers from the hunk header starts.
List<_DiffRow> diffRowsForHunk(CodeReviewHunk hunk) {
  final rows = <_DiffRow>[];
  var oldLine = hunk.oldStart;
  var newLine = hunk.newStart;
  for (final line in hunk.lines) {
    if (line.startsWith('@@')) {
      rows.add(_DiffRow(_DiffRowKind.header, null, line));
    } else if (line.startsWith('+') && !line.startsWith('+++')) {
      rows.add(_DiffRow(_DiffRowKind.addition, newLine++, line));
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      rows.add(_DiffRow(_DiffRowKind.deletion, oldLine++, line));
    } else if (line.startsWith(r'\')) {
      rows.add(_DiffRow(_DiffRowKind.meta, null, line));
    } else {
      rows.add(_DiffRow(_DiffRowKind.context, newLine, line));
      newLine++;
      oldLine++;
    }
  }
  return rows;
}

/// Resolves a Markdown image [uri] against [markdownFilePath] and an
/// optional GitHub [repoKey] (`owner/repo`).
///
/// Absolute `http`/`https` URIs pass through unchanged. Relative paths
/// are normalized against [markdownFilePath]'s directory (rejecting
/// any `..` traversal above the repository root) and mapped to
/// `https://raw.githubusercontent.com/<repoKey>/HEAD/<path>` when
/// [repoKey] is an `owner/repo` slug.
Uri? resolveMarkdownImageUri(
  Uri uri, {
  required String markdownFilePath,
  String? repoKey,
}) {
  if (uri.hasScheme) {
    return (uri.scheme == 'http' || uri.scheme == 'https') ? uri : null;
  }
  final rawPath = uri.path;
  if (rawPath.isEmpty) return null;

  final baseSegments = <String>[];
  if (!rawPath.startsWith('/')) {
    final fileSegments = markdownFilePath.split('/');
    if (fileSegments.length > 1) {
      baseSegments.addAll(
        fileSegments
            .sublist(0, fileSegments.length - 1)
            .where((s) => s.isNotEmpty),
      );
    }
  }

  for (final seg in rawPath.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (baseSegments.isEmpty) return null;
      baseSegments.removeLast();
    } else {
      baseSegments.add(seg);
    }
  }

  if (baseSegments.isEmpty) return null;
  final slug = repoKey?.trim();
  if (slug == null ||
      !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(slug)) {
    return null;
  }
  return Uri.https(
    'raw.githubusercontent.com',
    '/$slug/HEAD/${baseSegments.join('/')}',
  );
}

/// Phase 5 Code review pane: the right split-pane (desktop) / modal
/// overlay (narrow) that reviews one turn's sandbox changes.
///
/// Live sandbox mode (review.sessionId non-empty): a "For Turn" bar
/// with a Commit action, stacked per-file diff cards with per-file
/// Revert/Accept, and a 180px Agent Edits rail that smooth-scrolls
/// the diff column. Read-only mode (no live sandbox session, e.g.
/// opened from a citation): the focused file is shown through
/// GET /api/v1/code/file and every git action is hidden — dead
/// buttons are never rendered (decision b).
///
/// Visual contract: docs/design/veraxi_code_review_pane.svg.
class CodeReviewDrawer extends ConsumerStatefulWidget {
  final CodeReviewState review;

  /// Total desktop split-pane container width when hosted side-by-side.
  /// When non-null, enables the draggable left-edge resize sash and
  /// header expand/restore button.
  final double? maxSplitWidth;

  const CodeReviewDrawer({
    super.key,
    required this.review,
    this.maxSplitWidth,
  });

  @override
  ConsumerState<CodeReviewDrawer> createState() => _CodeReviewDrawerState();
}

class _CodeReviewDrawerState extends ConsumerState<CodeReviewDrawer> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _fileKeys = {};
  bool _loadStarted = false;
  bool _focusedScrollDone = false;
  bool _sashHovered = false;
  bool _sashDragging = false;
  bool _isAuditing = false;
  late bool _showMarkdownPreview = _defaultMarkdownPreview();

  bool get _isLive => widget.review.hasLiveSandbox;

  bool get _isReadOnlyMarkdown {
    final path = _readOnlyPath;
    if (path == null) return false;
    final lower = path.toLowerCase();
    return lower.endsWith('.md') ||
        lower.endsWith('.markdown') ||
        lower.endsWith('.mdx');
  }

  /// Open Markdown files in rendered Preview by default, unless a
  /// specific line > 1 was cited so Raw mode can scroll to & highlight it.
  bool _defaultMarkdownPreview() {
    final startLine = widget.review.focusedStartLine;
    return startLine == null || startLine <= 1;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoad());
  }

  @override
  void didUpdateWidget(covariant CodeReviewDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.review.sessionId != widget.review.sessionId ||
        oldWidget.review.turnId != widget.review.turnId) {
      _loadStarted = false;
      _focusedScrollDone = false;
      _fileKeys.clear();
      _showMarkdownPreview = _defaultMarkdownPreview();
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoad());
    } else if (oldWidget.review.focusedPath != widget.review.focusedPath ||
        oldWidget.review.focusedStartLine != widget.review.focusedStartLine) {
      _focusedScrollDone = false;
      _showMarkdownPreview = _defaultMarkdownPreview();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocused());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _scrollController.dispose();
    super.dispose();
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        mounted) {
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return false;
      _close();
      return true;
    }
    return false;
  }

  void _close() {
    ref.read(activeReviewSessionProvider.notifier).state = null;
  }

  void _maybeLoad() {
    if (!mounted || !_isLive || _loadStarted) return;
    _loadStarted = true;
    ref.read(codeReviewProvider.notifier).load(
          widget.review.sessionId,
          turnId: widget.review.turnId,
        );
  }

  GlobalKey _keyFor(String path) =>
      _fileKeys.putIfAbsent(path, () => GlobalKey());

  void _scrollToFile(String path) {
    final targetContext = _keyFor(path).currentContext;
    if (targetContext == null) return;
    Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: 0.02,
    );
  }

  void _scrollToFocused() {
    if (_focusedScrollDone) return;
    final focused = widget.review.focusedPath;
    if (focused == null) return;
    _focusedScrollDone = true;
    _scrollToFile(focused);
  }

  @override
  Widget build(BuildContext context) {
    // Scroll to the focused (cited) file once its diff has loaded.
    ref.listen<CodeReviewLoadState>(codeReviewProvider, (prev, next) {
      if (prev?.diff == null && next.diff != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocused());
      }
    });

    // Esc dismissal is handled by the HardwareKeyboard handler
    // registered in initState (a focus-scoped listener would miss
    // Esc whenever the diff column, not the drawer chrome, has focus).
    return Container(
      key: const Key('code-review-drawer'),
      decoration: BoxDecoration(
        color: ObsidianTokens.shell,
        border: widget.maxSplitWidth == null
            ? const Border(
                left: BorderSide(color: ObsidianTokens.hairline),
              )
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.maxSplitWidth != null) _buildResizeSash(),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTabBar(),
                if (_isLive) _buildForTurnBar() else _buildReadOnlyBar(),
                const Divider(height: 1, color: ObsidianTokens.hairline),
                Expanded(
                    child: _isLive ? _buildLiveBody() : _buildReadOnlyBody()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResizeSash() {
    final active = _sashHovered || _sashDragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _sashHovered = true),
      onExit: (_) => setState(() => _sashHovered = false),
      child: GestureDetector(
        key: const Key('code-review-resize-sash'),
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _sashDragging = true),
        onHorizontalDragEnd: (_) => setState(() => _sashDragging = false),
        onHorizontalDragCancel: () => setState(() => _sashDragging = false),
        onHorizontalDragUpdate: _handleSashDrag,
        onDoubleTap: () {
          ref.read(reviewPaneWidthFractionProvider.notifier).state =
              kDefaultReviewPaneFraction;
        },
        child: SizedBox(
          width: 6,
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: active ? 2 : 1,
              color: active ? const Color(0xFF3B82F6) : ObsidianTokens.hairline,
            ),
          ),
        ),
      ),
    );
  }

  void _handleSashDrag(DragUpdateDetails details) {
    final totalWidth = widget.maxSplitWidth;
    if (totalWidth == null || totalWidth <= 0) return;
    final currentFraction = ref.read(reviewPaneWidthFractionProvider);
    final currentWidth = computeReviewPaneWidth(totalWidth, currentFraction);
    final nextWidth = currentWidth - details.delta.dx;
    final minFraction = (380.0 / totalWidth).clamp(0.2, 0.5);
    final maxFraction =
        ((totalWidth - 380.0) / totalWidth).clamp(minFraction, 0.85);
    ref.read(reviewPaneWidthFractionProvider.notifier).state =
        (nextWidth / totalWidth).clamp(minFraction, maxFraction);
  }

  Widget _buildTabBar() {
    return SizedBox(
      height: 50,
      child: Row(
        children: [
          const SizedBox(width: 14),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF16181D),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: const Color(0xFF252833)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Review',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFFF4F4F5),
                          ),
                        ),
                        SizedBox(width: 6),
                        Icon(Icons.add, size: 14, color: Color(0xFF71717A)),
                      ],
                    ),
                  ),
                  if (_isLive ||
                      (ref.watch(codeReviewProvider).diff?.files.isNotEmpty ??
                          false)) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      key: const Key('code-review-audit-diff-button'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF93C5FD),
                        side: const BorderSide(color: Color(0xFF252833)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                      onPressed: _isAuditing ? null : _triggerAuditDiff,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isAuditing) ...[
                            const SizedBox(
                              width: 11,
                              height: 11,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: Color(0xFF93C5FD),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            _isAuditing ? 'Auditing…' : 'Security Audit',
                            style: const TextStyle(
                                fontSize: 11.5, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_isLive) ...[
            _buildCommitSplitButton(),
            const SizedBox(width: 4),
          ],
          if (widget.maxSplitWidth != null) _buildExpandButton(),
          IconButton(
            key: const Key('code-review-close'),
            icon: const Icon(Icons.close, size: 18, color: Color(0xFF71717A)),
            tooltip: 'Close review',
            onPressed: _close,
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildExpandButton() {
    final fraction = ref.watch(reviewPaneWidthFractionProvider);
    final isExpanded = fraction >= 0.72;
    return IconButton(
      key: const Key('code-review-expand-button'),
      icon: Icon(
        isExpanded ? Icons.close_fullscreen : Icons.open_in_full,
        size: 16,
        color: const Color(0xFF71717A),
      ),
      tooltip: isExpanded ? 'Restore panel width' : 'Expand panel',
      onPressed: () {
        ref.read(reviewPaneWidthFractionProvider.notifier).state = isExpanded
            ? kDefaultReviewPaneFraction
            : kExpandedReviewPaneFraction;
      },
    );
  }

  Widget _buildCommitSplitButton() {
    final isCommitting = ref.watch(codeReviewProvider).isCommitting;
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: isCommitting ? const Color(0xFF1E3A8A) : const Color(0xFF2563EB),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: const Key('code-review-draft-pr-button'),
            onTap: isCommitting ? null : _openCommitDialog,
            borderRadius:
                const BorderRadius.horizontal(left: Radius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Text(
                isCommitting ? 'Committing…' : 'Commit',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Container(
            width: 1,
            height: 16,
            color: Colors.white.withValues(alpha: 0.22),
          ),
          PopupMenuButton<String>(
            tooltip: 'More review actions',
            color: const Color(0xFF1C1C1F),
            elevation: 10,
            offset: const Offset(0, 32),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: Color(0xFF34343A)),
            ),
            onSelected: (action) {
              switch (action) {
                case 'commit':
                  _openCommitDialog();
                case 'apply':
                  final files = ref.read(codeReviewProvider).diff?.files ??
                      const <CodeReviewDiffFile>[];
                  for (final f in files) {
                    ref.read(codeReviewProvider.notifier).acceptFile(f.path);
                  }
                case 'discard':
                  _close();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'commit',
                height: 36,
                child: Row(
                  children: [
                    Icon(Icons.commit, size: 15, color: Color(0xFFE4E4E7)),
                    SizedBox(width: 8),
                    Text('Commit / Open Draft PR',
                        style: TextStyle(
                            color: Color(0xFFE4E4E7), fontSize: 12.5)),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                key: Key('code-review-apply-locally-button'),
                value: 'apply',
                height: 36,
                child: Row(
                  children: [
                    Icon(Icons.download_done_outlined,
                        size: 15, color: Color(0xFFE4E4E7)),
                    SizedBox(width: 8),
                    Text('Apply Locally',
                        style: TextStyle(
                            color: Color(0xFFE4E4E7), fontSize: 12.5)),
                  ],
                ),
              ),
              PopupMenuDivider(height: 8),
              PopupMenuItem<String>(
                key: Key('code-review-discard-button'),
                value: 'discard',
                height: 36,
                child: Row(
                  children: [
                    Icon(Icons.delete_outline,
                        size: 15, color: Color(0xFFF87171)),
                    SizedBox(width: 8),
                    Text('Discard',
                        style: TextStyle(
                            color: Color(0xFFF87171), fontSize: 12.5)),
                  ],
                ),
              ),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Icon(
                Icons.keyboard_arrow_down,
                size: 15,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _triggerAuditDiff() async {
    if (_isAuditing) return;
    setState(() => _isAuditing = true);
    try {
      final files = ref
              .read(codeReviewProvider)
              .diff
              ?.files
              .map((f) => f.path)
              .toList() ??
          const <String>[];
      final repo = ref.read(selectedIndexedRepoProvider);
      final auditSummary = await ref
          .read(codeReviewProvider.notifier)
          .runSecurityDiffAudit(files: files, repo: repo);
      if (!mounted) return;
      ref.read(pendingSecurityThreadPromptProvider.notifier).state =
          auditSummary;
    } finally {
      if (mounted) {
        setState(() => _isAuditing = false);
      }
    }
  }

  Widget _buildForTurnBar() {
    final review = widget.review;
    final prompt = review.turnPrompt;
    final label = (prompt != null && prompt.trim().isNotEmpty)
        ? prompt.trim()
        : (review.turnId.isNotEmpty ? review.turnId : 'Current turn');
    final reviewState = ref.watch(codeReviewProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: ObsidianTokens.bubble,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: ObsidianTokens.borderStrong),
            ),
            child: const Text(
              'For Turn',
              style: TextStyle(fontSize: 11, color: Color(0xFFD4D4D8)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFA1A1AA)),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            key: const Key('code-review-commit-button'),
            onPressed: reviewState.isCommitting ? null : _openCommitDialog,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1D4ED8),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Commit',
                    style:
                        TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                SizedBox(width: 4),
                Icon(Icons.keyboard_arrow_down, size: 14),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadOnlyBar() {
    final path = _readOnlyPath;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Container(
            key: const Key('code-review-read-only-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: ObsidianTokens.bubble,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: ObsidianTokens.borderStrong),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 12, color: Color(0xFFA1A1AA)),
                SizedBox(width: 5),
                Text(
                  'Read-only',
                  style: TextStyle(fontSize: 11, color: Color(0xFFD4D4D8)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              path ?? 'No file selected',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: Color(0xFFA1A1AA),
              ),
            ),
          ),
          if (_isReadOnlyMarkdown) ...[
            const SizedBox(width: 10),
            _buildMarkdownModeToggle(),
          ],
        ],
      ),
    );
  }

  Widget _buildMarkdownModeToggle() {
    return Container(
      key: const Key('code-review-markdown-toggle'),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: ObsidianTokens.bubble,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: ObsidianTokens.borderStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildToggleOption(
            key: const Key('code-review-markdown-preview-toggle'),
            label: 'Preview',
            icon: Icons.article_outlined,
            selected: _showMarkdownPreview,
            onTap: () {
              if (!_showMarkdownPreview) {
                setState(() => _showMarkdownPreview = true);
              }
            },
          ),
          _buildToggleOption(
            key: const Key('code-review-markdown-raw-toggle'),
            label: 'Raw',
            icon: Icons.code,
            selected: !_showMarkdownPreview,
            onTap: () {
              if (_showMarkdownPreview) {
                setState(() => _showMarkdownPreview = false);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildToggleOption({
    required Key key,
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF27272A) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 12,
              color:
                  selected ? const Color(0xFFF4F4F5) : const Color(0xFF71717A),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? const Color(0xFFF4F4F5)
                    : const Color(0xFFA1A1AA),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? get _readOnlyPath =>
      widget.review.focusedPath ??
      (widget.review.files.isNotEmpty ? widget.review.files.first.path : null);

  // ---- Live sandbox body -------------------------------------------------

  Widget _buildLiveBody() {
    final state = ref.watch(codeReviewProvider);
    if (state.isLoading && state.diff == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.diff == null) {
      return _buildErrorState(state.error!);
    }
    final diff = state.diff;
    final files = diff?.files ?? const <CodeReviewDiffFile>[];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: files.isEmpty
              ? const Center(
                  child: Text(
                    'No changes in this session.',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFFA1A1AA)),
                  ),
                )
              : SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (state.error != null) _buildInlineError(state.error!),
                      for (final file in files) _buildFileCard(file, state),
                    ],
                  ),
                ),
        ),
        _buildAgentEditsRail(files),
      ],
    );
  }

  Widget _buildErrorState(String error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            error,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFFFCA5A5)),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              _loadStarted = false;
              _maybeLoad();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineError(String error) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1215),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        error,
        style: const TextStyle(fontSize: 11.5, color: Color(0xFFFCA5A5)),
      ),
    );
  }

  Widget _buildFileCard(CodeReviewDiffFile file, CodeReviewLoadState state) {
    final busy = state.busyPaths.contains(file.path);
    return Container(
      key: _keyFor(file.path),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: ObsidianTokens.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ObsidianTokens.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                LanguageFileIcon(fileName: file.fileName, size: 16),
                const SizedBox(width: 8),
                Text(
                  file.fileName,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'monospace',
                    color: Color(0xFFE4E4E7),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    file.path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Color(0xFF71717A),
                    ),
                  ),
                ),
                Text(
                  '+${file.additions}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF34D399),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '-${file.deletions}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFFF87171),
                  ),
                ),
                const SizedBox(width: 10),
                TextButton(
                  key: Key('code-review-revert-${file.path}'),
                  onPressed: busy
                      ? null
                      : () => ref
                          .read(codeReviewProvider.notifier)
                          .revertFile(file.path),
                  child: const Text(
                    'Revert',
                    style: TextStyle(fontSize: 11, color: Color(0xFFA1A1AA)),
                  ),
                ),
                TextButton(
                  key: Key('code-review-accept-${file.path}'),
                  onPressed: busy
                      ? null
                      : () => ref
                          .read(codeReviewProvider.notifier)
                          .acceptFile(file.path),
                  child: const Text(
                    'Accept',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF34D399),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: ObsidianTokens.hairline),
          for (final hunk in file.hunks) _buildHunk(file, hunk),
        ],
      ),
    );
  }

  Widget _buildHunk(CodeReviewDiffFile file, CodeReviewHunk hunk) {
    final rows = diffRowsForHunk(hunk);
    final hunkText = hunk.lines.join('\n');
    final attachment = DiffHunkAttachment(
      file: file.path,
      line: hunk.newStart,
      hunkText: hunkText,
    );
    final isAttached = ref.watch(attachedDiffHunkProvider) == attachment;
    final busy = ref.watch(codeReviewProvider).busyPaths.contains(file.path);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: const Color(0xFF0E1014),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            children: [
              Text(
                '@@ -${hunk.oldStart} +${hunk.newStart} @@',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  color: Color(0xFF71717A),
                ),
              ),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 24),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: busy
                    ? null
                    : () => ref
                        .read(codeReviewProvider.notifier)
                        .acceptHunk(file.path, hunk.lines),
                child: const Text(
                  '✓ Accept',
                  style: TextStyle(fontSize: 11, color: Color(0xFF34D399)),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 24),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: busy
                    ? null
                    : () => ref
                        .read(codeReviewProvider.notifier)
                        .rejectHunk(file.path, hunk.lines),
                child: const Text(
                  '✕ Reject',
                  style: TextStyle(fontSize: 11, color: Color(0xFFF87171)),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 24),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () {
                  ref.read(attachedDiffHunkProvider.notifier).state =
                      isAttached ? null : attachment;
                },
                child: Text(
                  isAttached ? '✎ Attached to chat' : '✎ Ask AI',
                  style: TextStyle(
                    fontSize: 11,
                    color: isAttached
                        ? const Color(0xFF60A5FA)
                        : const Color(0xFFD4D4D8),
                    fontWeight: isAttached ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final row in rows) _buildDiffRow(file, row),
      ],
    );
  }

  Widget _buildDiffRow(CodeReviewDiffFile file, _DiffRow row) {
    final focused = widget.review.focusedPath == file.path &&
        row.lineNumber != null &&
        widget.review.focusedStartLine != null &&
        row.lineNumber! >= widget.review.focusedStartLine! &&
        row.lineNumber! <=
            (widget.review.focusedEndLine ?? widget.review.focusedStartLine!);
    final Color? background = switch (row.kind) {
      _DiffRowKind.addition => ObsidianTokens.diffAddBg,
      _DiffRowKind.deletion => ObsidianTokens.diffRemoveBg,
      _DiffRowKind.header => const Color(0xFF13151A),
      _ => null,
    };
    final textColor = switch (row.kind) {
      _DiffRowKind.addition => const Color(0xFF86EFAC),
      _DiffRowKind.deletion => const Color(0xFFFCA5A5),
      _DiffRowKind.header => const Color(0xFF71717A),
      _ => const Color(0xFFA1A1AA),
    };
    return Container(
      decoration: BoxDecoration(
        color: background,
        border: focused
            ? const Border(left: BorderSide(color: Color(0xFF4F8EF7), width: 2))
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Text(
              row.lineNumber?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color:
                    focused ? const Color(0xFF4F8EF7) : const Color(0xFF52525B),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              row.text,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAgentEditsRail(List<CodeReviewDiffFile> diffFiles) {
    final items = diffFiles.isNotEmpty
        ? [
            for (final f in diffFiles)
              (path: f.path, additions: f.additions, deletions: f.deletions)
          ]
        : [
            for (final f in widget.review.files)
              (path: f.path, additions: f.additions, deletions: f.deletions)
          ];
    return Container(
      width: 180,
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: ObsidianTokens.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Text(
              'Agent Edits',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF71717A),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final item in items)
                  InkWell(
                    key: Key('code-review-rail-${item.path}'),
                    onTap: () => _scrollToFile(item.path),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: widget.review.focusedPath == item.path
                            ? ObsidianTokens.bubble
                            : null,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          LanguageFileIcon(
                            fileName: item.path.split('/').last,
                            size: 14,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              item.path.split('/').last,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                                color: Color(0xFFD4D4D8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Read-only body ------------------------------------------------------

  Widget _buildReadOnlyBody() {
    final path = _readOnlyPath;
    if (path == null) {
      return const Center(
        child: Text(
          'No file selected for review.',
          style: TextStyle(fontSize: 12.5, color: Color(0xFFA1A1AA)),
        ),
      );
    }
    final target = CodeCitationTarget(
      path: path,
      startLine: widget.review.focusedStartLine ?? 1,
      endLine: widget.review.focusedEndLine,
    );
    final asyncContent = ref.watch(codeFileProvider(target));
    return asyncContent.when(
      data: (content) {
        final showPreview = _isReadOnlyMarkdown && _showMarkdownPreview;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: showPreview
              ? _buildMarkdownPreview(
                  key: ValueKey('md-preview-$path'),
                  markdown: content.lines.join('\n'),
                  markdownFilePath: path,
                )
              : CodeLinesView(
                  key: ValueKey('code-raw-$path'),
                  lines: content.lines,
                  startLine: content.startLine,
                  highlightStartLine: widget.review.focusedStartLine,
                  highlightEndLine: widget.review.focusedEndLine,
                  autoScrollToHighlight: widget.review.focusedStartLine != null,
                ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "This file isn't available on the server.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xFFA1A1AA)),
          ),
        ),
      ),
    );
  }

  Widget _buildMarkdownPreview({
    required Key key,
    required String markdown,
    required String markdownFilePath,
  }) {
    final theme = Theme.of(context);
    return Container(
      key: key,
      color: ObsidianTokens.shell,
      child: SelectionEdgeAutoScroll(
        builder: (context, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          child: MarkdownBody(
            data: markdown,
            selectable: false,
            onTapLink: (_, href, __) => _openMarkdownLink(href),
            imageBuilder: (uri, _, alt) => _buildMarkdownImage(
              uri,
              alt: alt,
              markdownFilePath: markdownFilePath,
            ),
            styleSheet: MarkdownStyleSheet(
              p: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFE2E8F0),
                height: 1.6,
              ),
              h1: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
              h2: theme.textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
              h3: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              h4: theme.textTheme.titleSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              h5: theme.textTheme.bodyLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              h6: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFE2E8F0),
                fontWeight: FontWeight.w600,
              ),
              a: const TextStyle(
                color: Color(0xFF93C5FD),
                decoration: TextDecoration.underline,
              ),
              blockquote: const TextStyle(color: Color(0xFFA1A1AA)),
              img: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFE2E8F0),
              ),
              checkbox: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF93C5FD),
              ),
              blockquoteDecoration: BoxDecoration(
                color: ObsidianTokens.card,
                borderRadius: BorderRadius.circular(6),
                border: const Border(
                  left: BorderSide(color: Color(0xFF3B82F6), width: 3),
                ),
              ),
              code: GoogleFonts.firaCode(
                backgroundColor: ObsidianTokens.bubble,
                color: const Color(0xFFE2E8F0),
                fontSize: 12.5,
              ),
              codeblockDecoration: BoxDecoration(
                color: ObsidianTokens.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ObsidianTokens.hairline),
              ),
              horizontalRuleDecoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: ObsidianTokens.hairline),
                ),
              ),
              listBullet: const TextStyle(color: Color(0xFFE2E8F0)),
              tableHead: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              tableBody: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFE2E8F0),
                height: 1.4,
              ),
              tableBorder: TableBorder.all(
                color: ObsidianTokens.hairline,
                width: 1,
              ),
              tableCellsPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMarkdownImage(
    Uri uri, {
    required String markdownFilePath,
    String? alt,
  }) {
    final repoKey = _resolveActiveGitHubRepoSlug();
    final resolved = resolveMarkdownImageUri(
      uri,
      markdownFilePath: markdownFilePath,
      repoKey: repoKey,
    );
    if (resolved == null) {
      return _buildBrokenImagePlaceholder(alt);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          resolved.toString(),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _buildBrokenImagePlaceholder(alt),
        ),
      ),
    );
  }

  String? _resolveActiveGitHubRepoSlug() {
    final selected = ref.watch(selectedIndexedRepoProvider);
    if (selected != null && selected.isNotEmpty) return selected;
    final repos = ref.watch(indexedReposProvider);
    if (repos.length == 1) return repos.first.repoKey;
    return null;
  }

  Widget _buildBrokenImagePlaceholder(String? alt) {
    final label = (alt != null && alt.trim().isNotEmpty)
        ? alt.trim()
        : 'Image unavailable';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: ObsidianTokens.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ObsidianTokens.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.broken_image_outlined,
            size: 14,
            color: Color(0xFF71717A),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFA1A1AA)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMarkdownLink(String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
    }
  }

  // ---- Commit --------------------------------------------------------------

  Future<void> _openCommitDialog() async {
    // The dialog owns its TextEditingController (see
    // _CommitMessageDialog): disposing a locally created controller
    // as soon as `showDialog` resolves races the dialog's exit
    // animation, which rebuilds the TextField and throws
    // `A TextEditingController was used after being disposed`.
    final message = await showDialog<String>(
      context: context,
      builder: (_) => const _CommitMessageDialog(),
    );
    if (message == null || message.trim().isEmpty || !mounted) return;
    final ok = await ref.read(codeReviewProvider.notifier).commit(message);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Committed' : 'Commit failed'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// Commit-message dialog that owns its [TextEditingController]:
/// created in `initState`, disposed in `dispose`, so the controller
/// outlives the dialog's exit animation.
class _CommitMessageDialog extends StatefulWidget {
  const _CommitMessageDialog();

  @override
  State<_CommitMessageDialog> createState() => _CommitMessageDialogState();
}

class _CommitMessageDialogState extends State<_CommitMessageDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: ObsidianTokens.card,
      title: const Text(
        'Commit changes',
        style: TextStyle(fontSize: 15, color: Color(0xFFF4F4F5)),
      ),
      content: TextField(
        key: const Key('code-review-commit-message-field'),
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        style: const TextStyle(fontSize: 13, color: Color(0xFFE4E4E7)),
        decoration: const InputDecoration(
          hintText: 'Commit message',
          hintStyle: TextStyle(color: Color(0xFF71717A)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: const Key('code-review-commit-confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Commit'),
        ),
      ],
    );
  }
}
