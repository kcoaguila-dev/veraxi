import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';

/// A single scoped Q&A turn in the Ask Veraxi sidecar.
class SidecarQaTurn {
  final String question;
  final String answer;
  final String? citation;
  final String? activityLabel;
  final bool isStreaming;

  const SidecarQaTurn({
    required this.question,
    required this.answer,
    this.citation,
    this.activityLabel,
    this.isStreaming = false,
  });

  SidecarQaTurn copyWith({
    String? answer,
    String? citation,
    String? activityLabel,
    bool? isStreaming,
  }) {
    return SidecarQaTurn(
      question: question,
      answer: answer ?? this.answer,
      citation: citation ?? this.citation,
      activityLabel: activityLabel ?? this.activityLabel,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }
}

/// Docked (380px on >= 1200px) or slide-over (< 1200px) Ask Veraxi sidecar
/// anchored to the selected CVE/symbol row in Code mode.
///
/// Design contract: docs/design/veraxi_code_workbench.svg.
class AskVeraxiSidecar extends ConsumerStatefulWidget {
  final VulnFinding? finding;
  final VoidCallback? onClose;

  const AskVeraxiSidecar({
    super.key,
    required this.finding,
    this.onClose,
  });

  @override
  ConsumerState<AskVeraxiSidecar> createState() => _AskVeraxiSidecarState();
}

class _AskVeraxiSidecarState extends ConsumerState<AskVeraxiSidecar> {
  final TextEditingController _promptController = TextEditingController();
  final Map<String, List<SidecarQaTurn>> _turnsByCve = {};
  final Map<String, String> _threadIdsByCve = {};
  StreamSubscription<Map<String, dynamic>>? _activeSubscription;
  bool _isStreaming = false;

  @override
  void dispose() {
    _activeSubscription?.cancel();
    _promptController.dispose();
    super.dispose();
  }

  void _stopStreaming() {
    _activeSubscription?.cancel();
    _activeSubscription = null;
    if (!mounted) return;
    setState(() {
      _isStreaming = false;
      for (final list in _turnsByCve.values) {
        for (int i = 0; i < list.length; i++) {
          if (list[i].isStreaming) {
            list[i] = list[i].copyWith(isStreaming: false);
          }
        }
      }
    });
  }

  void _submitQuestion([String? overridePrompt]) {
    if (_isStreaming) return;
    final q = (overridePrompt ?? _promptController.text).trim();
    if (q.isEmpty) return;

    final finding = widget.finding;
    final key = finding?.cveId ?? '_workspace';
    final defaultCitation = finding == null
        ? null
        : (finding.reachableInCode.isNotEmpty
            ? (finding.reachableInCode.first.path ??
                finding.reachableInCode.first.qualifiedName)
            : (finding.sourceFile ?? finding.package));

    final turns = _turnsByCve.putIfAbsent(key, () => []);
    final turnIndex = turns.length;
    setState(() {
      turns.add(
        SidecarQaTurn(
          question: q,
          answer: '',
          citation: defaultCitation,
          isStreaming: true,
        ),
      );
      _isStreaming = true;
    });
    if (overridePrompt == null) {
      _promptController.clear();
    }

    final repoKey = ref.read(selectedIndexedRepoProvider);
    final threadId = _threadIdsByCve.putIfAbsent(
      key,
      () => 'sidecar-$key-${DateTime.now().millisecondsSinceEpoch}',
    );
    final buffer = StringBuffer();
    String? streamedCitation = defaultCitation;
    String? activityLabel;

    final stream =
        ref.read(codeIntelViewModelProvider.notifier).streamSidecarAsk(
              question: q,
              finding: finding,
              repoKey: repoKey,
              threadId: threadId,
            );

    _activeSubscription = stream.listen(
      (event) {
        if (!mounted) return;
        final type = event['type'] as String? ?? '';
        if (type == 'token' && event['content'] != null) {
          buffer.write(event['content'].toString());
        } else if (type == 'answer' && event['answer'] != null) {
          buffer
            ..clear()
            ..write(event['answer'].toString());
        } else if (event['token'] != null) {
          buffer.write(event['token'].toString());
        } else if (event['delta'] != null) {
          buffer.write(event['delta'].toString());
        } else if (type == 'activity' && event['label'] != null) {
          activityLabel = event['label'].toString();
        } else if (type == 'sources' && event['sources'] is List) {
          final sources = event['sources'] as List;
          if (sources.isNotEmpty && sources.first is Map) {
            final first = sources.first as Map;
            final path =
                first['path']?.toString() ?? first['source']?.toString();
            if (path != null && path.isNotEmpty) {
              streamedCitation = path;
            }
          }
        }
        setState(() {
          turns[turnIndex] = turns[turnIndex].copyWith(
            answer: buffer.toString(),
            citation: streamedCitation,
            activityLabel: activityLabel,
          );
        });
      },
      onError: (_) {
        if (!mounted) return;
        final fallback = _buildScopedAnswer(q, finding);
        setState(() {
          turns[turnIndex] = turns[turnIndex].copyWith(
            answer: buffer.isNotEmpty ? buffer.toString() : fallback,
            citation: streamedCitation,
            isStreaming: false,
          );
          _isStreaming = false;
        });
      },
      onDone: () {
        if (!mounted) return;
        final finalAnswer = buffer.isNotEmpty
            ? buffer.toString()
            : _buildScopedAnswer(q, finding);
        setState(() {
          turns[turnIndex] = turns[turnIndex].copyWith(
            answer: finalAnswer,
            citation: streamedCitation,
            isStreaming: false,
          );
          _isStreaming = false;
        });
      },
      cancelOnError: true,
    );
  }

  String _buildScopedAnswer(String question, VulnFinding? finding) {
    if (finding == null) {
      return 'Run a vulnerability scan or select a finding row to scope answers to a specific dependency and AST path.';
    }
    final kevNote = finding.kev
        ? 'This CVE is on the CISA KEV catalog (active exploitation).'
        : 'Not currently listed on CISA KEV.';
    final epssNote = finding.epssScore != null
        ? ' EPSS ${(finding.epssScore! * 100).toStringAsFixed(1)}%.'
        : '';
    if (finding.reachableInCode.isNotEmpty) {
      final top = finding.reachableInCode.first;
      return '${finding.cveId} affects ${finding.package} (${finding.matchStatus}). '
          '$kevNote$epssNote Static AST analysis links ${top.qualifiedName} '
          '(${top.path ?? 'repo'}) via ${top.viaEdge ?? 'CALLS'}. Verify runtime exposure before patching.';
    }
    return '${finding.cveId} affects ${finding.package} (${finding.matchStatus}). '
        '$kevNote$epssNote No static AST call path was found in the current code graph; verify runtime usage.';
  }

  Future<void> _openCodeCitation(String citationPath) async {
    final viewModel = ref.read(codeIntelViewModelProvider.notifier);
    final fileData = await viewModel.fetchIndexedFile(citationPath);
    if (!mounted) return;

    final content = fileData?['content'] as String?;
    final language = fileData?['language'] as String? ?? 'source';
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF171717),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF2B2B2E)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680, maxHeight: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Color(0xFF2B2B2E)),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.code, size: 16, color: Color(0xFF34D399)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$citationPath ($language)',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          size: 18, color: Color(0xFF9CA3AF)),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: content != null
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          content,
                          style: const TextStyle(
                            color: Color(0xFFE4E4E7),
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      )
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'File preview unavailable for $citationPath on this server.',
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
    final turns = _turnsByCve[finding?.cveId ?? '_workspace'] ?? const [];

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
          _buildComposer(finding),
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

  Widget _buildPathCard(VulnFinding? finding) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F23),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2E2E34)),
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
                  Padding(
                    padding: EdgeInsets.only(left: (i + 1) * 10.0, top: 4),
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Color(0xFF71717A),
                        ),
                        children: [
                          TextSpan(
                            text:
                                '—[${finding.reachableInCode[i].viaEdge ?? 'CALLS'}]→ ',
                          ),
                          TextSpan(
                            text: finding.reachableInCode[i].qualifiedName,
                            style: const TextStyle(color: Color(0xFFE4E4E7)),
                          ),
                        ],
                      ),
                    ),
                  ),
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

  Widget _buildComposer(VulnFinding? finding) {
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
                      _isStreaming ? _stopStreaming : () => _submitQuestion(),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _isStreaming
                          ? const Color(0xFF3B1D1E)
                          : const Color(0xFFECECEC),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isStreaming ? Icons.stop : Icons.arrow_upward,
                      size: 16,
                      color: _isStreaming
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
