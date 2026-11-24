import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/core/widgets/code_lines_view.dart';
import 'package:veraxi_app/core/widgets/language_file_icon.dart';
import 'package:veraxi_app/features/chat/view_models/code_file_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_review_view_model.dart';

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

  const CodeReviewDrawer({super.key, required this.review});

  @override
  ConsumerState<CodeReviewDrawer> createState() => _CodeReviewDrawerState();
}

class _CodeReviewDrawerState extends ConsumerState<CodeReviewDrawer> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _fileKeys = {};
  bool _loadStarted = false;
  bool _focusedScrollDone = false;

  bool get _isLive => widget.review.hasLiveSandbox;

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
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoad());
    } else if (oldWidget.review.focusedPath != widget.review.focusedPath) {
      _focusedScrollDone = false;
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
      decoration: const BoxDecoration(
        color: ObsidianTokens.shell,
        border: Border(
          left: BorderSide(color: ObsidianTokens.hairline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTabBar(),
          if (_isLive) _buildForTurnBar() else _buildReadOnlyBar(),
          const Divider(height: 1, color: ObsidianTokens.hairline),
          Expanded(child: _isLive ? _buildLiveBody() : _buildReadOnlyBody()),
        ],
      ),
    );
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
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
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
                    onPressed: _triggerAuditDiff,
                    icon: const Icon(Icons.shield_outlined, size: 13),
                    label: const Text(
                      'Audit Diff',
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w500),
                    ),
                  ),
                  if (_isLive) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      key: const Key('code-review-discard-button'),
                      onPressed: _close,
                      child: const Text(
                        'Discard',
                        style: TextStyle(
                            fontSize: 11.5, color: Color(0xFFF87171)),
                      ),
                    ),
                    OutlinedButton(
                      key: const Key('code-review-apply-locally-button'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFE4E4E7),
                        side:
                            const BorderSide(color: ObsidianTokens.borderStrong),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () {
                        final files = ref.read(codeReviewProvider).diff?.files ??
                            const <CodeReviewDiffFile>[];
                        for (final f in files) {
                          ref
                              .read(codeReviewProvider.notifier)
                              .acceptFile(f.path);
                        }
                      },
                      child: const Text(
                        'Apply Locally',
                        style: TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton(
                      key: const Key('code-review-draft-pr-button'),
                      onPressed: ref.watch(codeReviewProvider).isCommitting
                          ? null
                          : _openCommitDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1D4ED8),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                      child: const Text(
                        'Open Draft PR',
                        style: TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
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

  Future<void> _triggerAuditDiff() async {
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
    ref.read(pendingSecurityThreadPromptProvider.notifier).state = auditSummary;
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
        ],
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
                    fontWeight:
                        isAttached ? FontWeight.w600 : FontWeight.w400,
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
      data: (content) => CodeLinesView(
        lines: content.lines,
        startLine: content.startLine,
        highlightStartLine: widget.review.focusedStartLine,
        highlightEndLine: widget.review.focusedEndLine,
        autoScrollToHighlight: widget.review.focusedStartLine != null,
      ),
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
