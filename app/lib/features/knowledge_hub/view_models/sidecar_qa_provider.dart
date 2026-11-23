import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/model_selection_provider.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';

/// A single scoped Q&A turn in the Ask Veraxi sidecar.
class SidecarQaTurn {
  final String question;
  final String answer;
  final String? citation;
  final String? activityLabel;
  final bool isStreaming;
  final bool isFallback;

  const SidecarQaTurn({
    required this.question,
    required this.answer,
    this.citation,
    this.activityLabel,
    this.isStreaming = false,
    this.isFallback = false,
  });

  SidecarQaTurn copyWith({
    String? answer,
    String? citation,
    String? activityLabel,
    bool? isStreaming,
    bool? isFallback,
  }) {
    return SidecarQaTurn(
      question: question,
      answer: answer ?? this.answer,
      citation: citation ?? this.citation,
      activityLabel: activityLabel ?? this.activityLabel,
      isStreaming: isStreaming ?? this.isStreaming,
      isFallback: isFallback ?? this.isFallback,
    );
  }
}

/// Persistent conversation state for the Ask Veraxi sidecar across
/// responsive layout transitions (docked row vs. narrow slide-over drawer).
class SidecarQaState {
  final Map<String, List<SidecarQaTurn>> turnsByKey;
  final Map<String, String> threadIdsByKey;
  final bool isStreaming;

  const SidecarQaState({
    this.turnsByKey = const {},
    this.threadIdsByKey = const {},
    this.isStreaming = false,
  });

  List<SidecarQaTurn> turnsForKey(String key) => turnsByKey[key] ?? const [];

  SidecarQaState copyWith({
    Map<String, List<SidecarQaTurn>>? turnsByKey,
    Map<String, String>? threadIdsByKey,
    bool? isStreaming,
  }) {
    return SidecarQaState(
      turnsByKey: turnsByKey ?? this.turnsByKey,
      threadIdsByKey: threadIdsByKey ?? this.threadIdsByKey,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }
}

/// Manages Ask Veraxi sidecar turns, thread IDs, and active SSE streams.
class SidecarQaNotifier extends StateNotifier<SidecarQaState> {
  final Ref _ref;
  StreamSubscription<Map<String, dynamic>>? _activeSubscription;

  SidecarQaNotifier(this._ref) : super(const SidecarQaState());

  @override
  void dispose() {
    _activeSubscription?.cancel();
    _activeSubscription = null;
    super.dispose();
  }

  /// Stops any active sidecar stream and marks in-flight turns as finished.
  void stopStreaming() {
    _activeSubscription?.cancel();
    _activeSubscription = null;
    if (!mounted) return;

    final updatedTurns = <String, List<SidecarQaTurn>>{};
    state.turnsByKey.forEach((key, list) {
      updatedTurns[key] = [
        for (final turn in list)
          turn.isStreaming ? turn.copyWith(isStreaming: false) : turn,
      ];
    });
    state = state.copyWith(
      turnsByKey: updatedTurns,
      isStreaming: false,
    );
  }

  /// Submits a question scoped to [finding] (or the workspace when null).
  void submitQuestion({
    required String question,
    VulnFinding? finding,
  }) {
    if (state.isStreaming) return;
    final q = question.trim();
    if (q.isEmpty) return;

    final key = finding?.cveId ?? '_workspace';
    final defaultCitation = finding == null
        ? null
        : (finding.reachableInCode.isNotEmpty
            ? (finding.reachableInCode.first.path ??
                finding.reachableInCode.first.qualifiedName)
            : (finding.sourceFile ?? finding.package));

    final existingTurns = List<SidecarQaTurn>.from(state.turnsForKey(key));
    final turnIndex = existingTurns.length;
    existingTurns.add(
      SidecarQaTurn(
        question: q,
        answer: '',
        citation: defaultCitation,
        isStreaming: true,
      ),
    );

    final nextTurnsByKey = Map<String, List<SidecarQaTurn>>.from(
      state.turnsByKey,
    )..[key] = existingTurns;

    final nextThreadIds = Map<String, String>.from(state.threadIdsByKey);
    final threadId = nextThreadIds.putIfAbsent(
      key,
      () => 'sidecar-$key-${DateTime.now().millisecondsSinceEpoch}',
    );

    state = state.copyWith(
      turnsByKey: nextTurnsByKey,
      threadIdsByKey: nextThreadIds,
      isStreaming: true,
    );

    final repoKey = _ref.read(selectedIndexedRepoProvider);
    final selectedModel = _ref.read(modelSelectionProvider).selectedModel;
    final buffer = StringBuffer();
    String? streamedCitation = defaultCitation;
    String? activityLabel;

    final stream =
        _ref.read(codeIntelViewModelProvider.notifier).streamSidecarAsk(
              question: q,
              finding: finding,
              repoKey: repoKey,
              threadId: threadId,
              model: selectedModel,
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
        _updateTurn(
          key: key,
          turnIndex: turnIndex,
          transform: (t) => t.copyWith(
            answer: buffer.toString(),
            citation: streamedCitation,
            activityLabel: activityLabel,
          ),
        );
      },
      onError: (_) {
        _finishWithFallbackOrBuffer(
          key: key,
          turnIndex: turnIndex,
          question: q,
          finding: finding,
          buffer: buffer,
          streamedCitation: streamedCitation,
        );
      },
      onDone: () {
        _finishWithFallbackOrBuffer(
          key: key,
          turnIndex: turnIndex,
          question: q,
          finding: finding,
          buffer: buffer,
          streamedCitation: streamedCitation,
        );
      },
      cancelOnError: true,
    );
  }

  void _finishWithFallbackOrBuffer({
    required String key,
    required int turnIndex,
    required String question,
    required VulnFinding? finding,
    required StringBuffer buffer,
    required String? streamedCitation,
  }) {
    _activeSubscription = null;
    if (!mounted) return;
    final useFallback = buffer.isEmpty;
    final finalAnswer =
        useFallback ? buildScopedAnswer(question, finding) : buffer.toString();
    _updateTurn(
      key: key,
      turnIndex: turnIndex,
      isStreaming: false,
      transform: (t) => t.copyWith(
        answer: finalAnswer,
        citation: streamedCitation,
        isStreaming: false,
        isFallback: useFallback,
      ),
    );
  }

  void _updateTurn({
    required String key,
    required int turnIndex,
    bool? isStreaming,
    required SidecarQaTurn Function(SidecarQaTurn) transform,
  }) {
    final currentList = state.turnsByKey[key];
    if (currentList == null || turnIndex >= currentList.length) return;
    final nextList = List<SidecarQaTurn>.from(currentList);
    nextList[turnIndex] = transform(nextList[turnIndex]);
    final nextTurns = Map<String, List<SidecarQaTurn>>.from(state.turnsByKey)
      ..[key] = nextList;
    state = state.copyWith(
      turnsByKey: nextTurns,
      isStreaming: isStreaming ?? state.isStreaming,
    );
  }

  /// Deterministic AST-scoped fallback summary when no live LLM stream
  /// produces tokens.
  static String buildScopedAnswer(String question, VulnFinding? finding) {
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
}

/// Persistent provider for Ask Veraxi sidecar Q&A state.
final sidecarQaProvider =
    StateNotifierProvider<SidecarQaNotifier, SidecarQaState>(
  (ref) => SidecarQaNotifier(ref),
);
