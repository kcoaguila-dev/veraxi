import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/widgets/code_lines_view.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/sidecar_qa_provider.dart';

/// Docked (380px on >= 1200px) or slide-over (< 1200px) Ask Veraxi sidecar
/// anchored to the selected CVE/symbol row in Code mode.
///
/// Design contract: docs/design/veraxi_code_workbench.svg.
class AskVeraxiSidecar extends ConsumerStatefulWidget {
  final VulnFinding? finding;
  final VoidCallback? onClose;
  final FocusNode? composerFocusNode;
  final String? citationToOpen;
  final int citationOpenNonce;
  final int pathHighlightNonce;

  const AskVeraxiSidecar({
    super.key,
    required this.finding,
    this.onClose,
    this.composerFocusNode,
    this.citationToOpen,
    this.citationOpenNonce = 0,
    this.pathHighlightNonce = 0,
  });

  @override
  ConsumerState<AskVeraxiSidecar> createState() => _AskVeraxiSidecarState();
}

class _AskVeraxiSidecarState extends ConsumerState<AskVeraxiSidecar> {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _listScrollController = ScrollController();
  bool _pathHighlighted = false;

  @override
  void initState() {
    super.initState();
    if (widget.citationOpenNonce > 0 && widget.citationToOpen != null) {
      final path = widget.citationToOpen!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openCodeCitation(path);
      });
    } else if (widget.pathHighlightNonce > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _triggerPathHighlight();
      });
    }
  }

  @override
  void didUpdateWidget(covariant AskVeraxiSidecar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.citationOpenNonce != oldWidget.citationOpenNonce &&
        widget.citationToOpen != null) {
      final path = widget.citationToOpen!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openCodeCitation(path);
      });
    } else if (widget.pathHighlightNonce != oldWidget.pathHighlightNonce) {
      _triggerPathHighlight();
    }
  }

  void _triggerPathHighlight() {
    if (_listScrollController.hasClients) {
      _listScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
    setState(() => _pathHighlighted = true);
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() => _pathHighlighted = false);
      }
    });
  }

  @override
  void dispose() {
    _promptController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  void _stopStreaming() {
    ref.read(sidecarQaProvider.notifier).stopStreaming();
  }

  void _submitQuestion([String? overridePrompt]) {
    final q = (overridePrompt ?? _promptController.text).trim();
    if (q.isEmpty) return;
    if (overridePrompt == null) {
      _promptController.clear();
    }
    ref.read(sidecarQaProvider.notifier).submitQuestion(
          question: q,
          finding: widget.finding,
        );
  }

  ({String path, int? startLine, int? endLine}) _parseCitationTarget(
    String raw,
  ) {
    final hashMatch = RegExp(r'^(.+?)#L(\d+)(?:-L?(\d+))?$').firstMatch(raw);
    if (hashMatch != null) {
      final start = int.tryParse(hashMatch.group(2)!);
      final end = hashMatch.group(3) != null
          ? int.tryParse(hashMatch.group(3)!)
          : start;
      return (path: hashMatch.group(1)!, startLine: start, endLine: end);
    }

    final colonMatch = RegExp(r'^(.+?):(\d+)(?:-(\d+))?$').firstMatch(raw);
    if (colonMatch != null) {
      final start = int.tryParse(colonMatch.group(2)!);
      final end = colonMatch.group(3) != null
          ? int.tryParse(colonMatch.group(3)!)
          : start;
      return (path: colonMatch.group(1)!, startLine: start, endLine: end);
    }

    return (path: raw, startLine: null, endLine: null);
  }

  Future<void> _openCodeCitation(String citationRaw) async {
    final parsed = _parseCitationTarget(citationRaw);
    final viewModel = ref.read(codeIntelViewModelProvider.notifier);
    final fileData = await viewModel.fetchIndexedFile(parsed.path);
    if (!mounted) return;

    final content = fileData?['content'] as String?;
    final language = fileData?['language'] as String? ?? 'source';
    final startLine = (fileData?['start_line'] as num?)?.toInt() ?? 1;
    final source = fileData?['source'] as String? ?? 'file';
    final isExcerpt = source == 'excerpt';
    final lines = content?.split('\n') ?? const <String>[];
    final lineCount =
        (fileData?['line_count'] as num?)?.toInt() ?? lines.length;
    final rangeCaption = parsed.startLine != null
        ? (parsed.endLine != null && parsed.endLine != parsed.startLine
            ? 'Cited lines ${parsed.startLine}–${parsed.endLine} · '
            : 'Cited line ${parsed.startLine} · ')
        : '';

    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF131315),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF2E2E34)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 540),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Color(0xFF2E2E34)),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.code, size: 16, color: Color(0xFF4F8EF7)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        parsed.path,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFECECEC),
                          fontFamily: 'monospace',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          size: 18, color: Color(0xFFB4B4B4)),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              if (content != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFF232328)),
                    ),
                  ),
                  child: Row(
                    children: [
                      CodeSourceBadge(isExcerpt: isExcerpt),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '$rangeCaption$lineCount lines · $language',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFA1A1AA),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: content != null
                    ? Container(
                        color: const Color(0xFF171719),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: CodeLinesView(
                          lines: lines,
                          startLine: startLine,
                          highlightStartLine: parsed.startLine,
                          highlightEndLine: parsed.endLine ?? parsed.startLine,
                          codeTextColor: const Color(0xFFD4D4D8),
                          autoScrollToHighlight: true,
                        ),
                      )
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'File preview unavailable for ${parsed.path} on this server.',
                            style: const TextStyle(
                                color: Color(0xFFA1A1AA), fontSize: 12.5),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final finding = widget.finding;
    final qaState = ref.watch(sidecarQaProvider);
    final turns = qaState.turnsForKey(finding?.cveId ?? '_workspace');

    return Container(
      width: 380,
      decoration: const BoxDecoration(
        color: Color(0xFF171717),
        border: Border(
          left: BorderSide(color: Color(0xFF2B2B2E), width: 1),
        ),
      ),
      child: Column(
        children: [
          _buildHeader(finding),
          Expanded(
            child: ListView(
              controller: _listScrollController,
              padding: const EdgeInsets.all(16),
              children: [
                _buildPathCard(finding),
                const SizedBox(height: 16),
                if (turns.isEmpty && finding != null) ...[
                  Text(
                    'Ask a scoped follow-up about ${finding.cveId} or its AST reachability.',
                    style: const TextStyle(
                      color: Color(0xFF71717A),
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final prompt in const [
                        'What input reaches this symbol?',
                        'Suggest minimal safe patch',
                        'Verify runtime exposure',
                      ])
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _submitQuestion(prompt),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1F1F23),
                              borderRadius: BorderRadius.circular(12),
                              border:
                                  Border.all(color: const Color(0xFF2E2E34)),
                            ),
                            child: Text(
                              prompt,
                              style: const TextStyle(
                                color: Color(0xFFD4D4D8),
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                for (final turn in turns) _buildTurn(turn),
              ],
            ),
          ),
          _buildComposer(finding, isStreaming: qaState.isStreaming),
        ],
      ),
    );
  }

  Widget _buildHeader(VulnFinding? finding) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: Color(0xFF171717),
        border: Border(
          bottom: BorderSide(color: Color(0xFF2B2B2E), width: 1),
        ),
      ),
      child: Row(
        children: [
          const Text(
            'Ask Veraxi',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF1F2D29),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: const Color(0xFF10B981), width: 0.8),
              ),
              child: Text(
                finding?.cveId ?? 'No CVE selected',
                style: const TextStyle(
                  color: Color(0xFF34D399),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (widget.onClose != null) ...[
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.close, color: Color(0xFF9CA3AF), size: 18),
              onPressed: widget.onClose,
              tooltip: 'Close sidecar',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReachableHopRow(ImpactedSymbol hit, int depth) {
    final hasPath = hit.path != null && hit.path!.isNotEmpty;
    final row = Padding(
      padding: EdgeInsets.only(left: (depth + 1) * 10.0, top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Color(0xFF71717A),
                ),
                children: [
                  TextSpan(text: '—[${hit.viaEdge ?? 'CALLS'}]→ '),
                  TextSpan(
                    text: hit.qualifiedName,
                    style: TextStyle(
                      color: hasPath
                          ? const Color(0xFFBFD7FB)
                          : const Color(0xFFE4E4E7),
                      decoration: hasPath
                          ? TextDecoration.underline
                          : TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (hasPath) ...[
            const SizedBox(width: 6),
            const Icon(
              Icons.code,
              size: 12,
              color: Color(0xFF4F8EF7),
            ),
          ],
        ],
      ),
    );
    if (!hasPath) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => _openCodeCitation(hit.path!),
      child: row,
    );
  }

  Widget _buildPathCard(VulnFinding? finding) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F23),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _pathHighlighted
              ? const Color(0xFF34D399)
              : const Color(0xFF2E2E34),
          width: _pathHighlighted ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'REACHABILITY PATH · SELECTED ROW',
            style: TextStyle(
              color: Color(0xFF8E8E93),
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          if (finding == null)
            const Text(
              'Run a scan or select a finding row to view its static AST path.',
              style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12),
            )
          else if (finding.reachableInCode.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  finding.package,
                  style: const TextStyle(
                    color: Color(0xFFE4E4E7),
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                ),
                for (int i = 0;
                    i < finding.reachableInCode.length && i < 3;
                    i++)
                  _buildReachableHopRow(finding.reachableInCode[i], i),
                Padding(
                  padding: const EdgeInsets.only(left: 24, top: 4),
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFF71717A),
                      ),
                      children: [
                        const TextSpan(text: '—[AFFECTS]→ '),
                        TextSpan(
                          text: finding.cveId,
                          style: const TextStyle(color: Color(0xFFFCA5A5)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${finding.package}${finding.version != null ? ' ${finding.version}' : ''}',
                  style: const TextStyle(
                    color: Color(0xFFE4E4E7),
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'No static AST route found for ${finding.cveId}',
                  style: const TextStyle(
                    color: Color(0xFFA1A1AA),
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF272017),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'Static AST path inferred — verify runtime exposure',
              style: TextStyle(
                color: Color(0xFFFBBF24),
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTurn(SidecarQaTurn turn) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF2B2B2F),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                turn.question,
                style:
                    const TextStyle(color: Color(0xFFF4F4F5), fontSize: 12.5),
              ),
            ),
          ),
          if (turn.activityLabel != null) ...[
            const SizedBox(height: 8),
            Text(
              turn.activityLabel!,
              style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
            ),
          ],
          const SizedBox(height: 10),
          if (turn.answer.isEmpty && turn.isStreaming)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(
              turn.answer,
              style: const TextStyle(
                color: Color(0xFFE4E4E7),
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          if (turn.isFallback && !turn.isStreaming) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF272017),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF78350F), width: 0.7),
              ),
              child: const Text(
                'Offline AST summary — configure an LLM key for live answers',
                style: TextStyle(
                  color: Color(0xFFFBBF24),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          if (turn.citation != null && !turn.isStreaming) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(11),
              onTap: () => _openCodeCitation(turn.citation!),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF27272B),
                  borderRadius: BorderRadius.circular(11),
                  border:
                      Border.all(color: const Color(0xFF3F3F46), width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.code, size: 12, color: Color(0xFF34D399)),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        turn.citation!,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF34D399),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildComposer(VulnFinding? finding, {required bool isStreaming}) {
    final anchorLabel = finding?.sourceFile ?? finding?.package ?? 'workspace';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 10),
        decoration: BoxDecoration(
          color: const Color(0xFF2B2B2F),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF3A3A40)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _promptController,
              focusNode: widget.composerFocusNode,
              style: const TextStyle(color: Color(0xFFF4F4F5), fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText:
                    'Ask about ${finding?.cveId ?? 'selected finding'}...',
                hintStyle:
                    const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
              ),
              onSubmitted: (_) => _submitQuestion(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Flexible(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2D29),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: const Color(0xFF10B981), width: 0.8),
                    ),
                    child: Text(
                      'Anchored: $anchorLabel',
                      style: const TextStyle(
                        color: Color(0xFF34D399),
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap:
                      isStreaming ? _stopStreaming : () => _submitQuestion(),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: isStreaming
                          ? const Color(0xFF3B1D1E)
                          : const Color(0xFFECECEC),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isStreaming ? Icons.stop : Icons.arrow_upward,
                      size: 16,
                      color: isStreaming
                          ? const Color(0xFFFCA5A5)
                          : const Color(0xFF171717),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
