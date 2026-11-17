import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/chat/data/sandbox_session_repository.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';

/// One streamed terminal line in the sandbox drawer.
class SandboxTerminalLine {
  final String text;
  final bool isStderr;

  const SandboxTerminalLine(this.text, {this.isStderr = false});
}

/// A pending sandbox approval prompt (autonomy gate).
class SandboxApproval {
  final String id;
  final String? sessionId;
  final String toolName;
  final String description;

  const SandboxApproval({
    required this.id,
    this.sessionId,
    required this.toolName,
    required this.description,
  });
}

/// State for the collapsible Terminal & Diff drawer.
class SandboxDrawerState {
  final bool expanded;
  final bool showDiff;
  final List<SandboxTerminalLine> lines;
  final List<SandboxApproval> approvals;
  final String diff;
  final String? sessionStatus;
  final String? activeSessionId;

  const SandboxDrawerState({
    this.expanded = true,
    this.showDiff = false,
    this.lines = const [],
    this.approvals = const [],
    this.diff = '',
    this.sessionStatus,
    this.activeSessionId,
  });

  SandboxDrawerState copyWith({
    bool? expanded,
    bool? showDiff,
    List<SandboxTerminalLine>? lines,
    List<SandboxApproval>? approvals,
    String? diff,
    String? sessionStatus,
    String? activeSessionId,
  }) {
    return SandboxDrawerState(
      expanded: expanded ?? this.expanded,
      showDiff: showDiff ?? this.showDiff,
      lines: lines ?? this.lines,
      approvals: approvals ?? this.approvals,
      diff: diff ?? this.diff,
      sessionStatus: sessionStatus ?? this.sessionStatus,
      activeSessionId: activeSessionId ?? this.activeSessionId,
    );
  }
}

final sandboxDrawerViewModelProvider =
    StateNotifierProvider<SandboxDrawerViewModel, SandboxDrawerState>((ref) {
  final repository = ref.watch(sandboxSessionRepositoryProvider);
  return SandboxDrawerViewModel(repository);
});

/// Holds the drawer's terminal output, pending approvals and diff.
///
/// Events enter two ways:
///  * [handleSandboxEvent] — the raw SSE event shape the backend emits
///    for a sandbox-enabled chat (`sandbox_stdout`, `sandbox_stderr`,
///    `approval_required`, `sandbox_diff`). This is the public seam a
///    future chat-stream bridge calls directly.
///  * [ingestToolEvents] — what is wired today: `chat_screen` listens
///    to the chat state and forwards the last message's `sandbox_*`
///    [ToolEvent]s, because `ChatViewModel._handleStreamEvent` is
///    private and message-bound, so raw SSE events never reach the
///    view layer. Tool events are de-duplicated by id + completion.
class SandboxDrawerViewModel extends StateNotifier<SandboxDrawerState> {
  final SandboxSessionRepository _repository;
  final Set<String> _seenToolEventKeys = {};

  SandboxDrawerViewModel(this._repository) : super(const SandboxDrawerState());

  void setExpanded(bool expanded) => state = state.copyWith(expanded: expanded);

  void toggleExpanded() => state = state.copyWith(expanded: !state.expanded);

  void setShowDiff(bool showDiff) => state = state.copyWith(showDiff: showDiff);

  void appendStdout(String text) => _append(text, isStderr: false);

  void appendStderr(String text) => _append(text, isStderr: true);

  void _append(String text, {required bool isStderr}) {
    final chunks = text.split('\n').where((line) => line.isNotEmpty);
    if (chunks.isEmpty) return;
    state = state.copyWith(
      expanded: true,
      lines: [
        ...state.lines,
        ...chunks.map((line) => SandboxTerminalLine(line, isStderr: isStderr)),
      ],
    );
  }

  void setDiff(String diff) =>
      state = state.copyWith(diff: diff, expanded: true);

  void clear() {
    _seenToolEventKeys.clear();
    state = const SandboxDrawerState();
  }

  /// Handles one raw sandbox SSE event. Accepts both the `event` key
  /// (astream-style) and a plain `type` key, with payloads either at
  /// the top level or nested under `data`.
  void handleSandboxEvent(Map<String, dynamic> event) {
    final type = (event['event'] ?? event['type']) as String?;
    if (type == null) return;
    final data = event['data'] is Map
        ? Map<String, dynamic>.from(event['data'] as Map)
        : event;
    switch (type) {
      case 'sandbox_stdout':
        final text =
            (data['text'] ?? data['chunk'] ?? data['output']) as String?;
        if (text != null) appendStdout(text);
      case 'sandbox_stderr':
        final text =
            (data['text'] ?? data['chunk'] ?? data['output']) as String?;
        if (text != null) appendStderr(text);
      case 'sandbox_diff':
        final diff = (data['diff'] ?? data['output']) as String?;
        if (diff != null) setDiff(diff);
      case 'approval_required':
        _addApproval(data);
      default:
        break;
    }
    final sessionId = data['session_id'] as String?;
    if (sessionId != null && sessionId != state.activeSessionId) {
      state = state.copyWith(activeSessionId: sessionId);
    }
  }

  void _addApproval(Map<String, dynamic> data) {
    final toolName =
        (data['tool_name'] ?? data['tool'] ?? data['name']) as String? ??
            'sandbox_exec';
    final args = data['args'];
    var description = (data['description'] ?? data['command']) as String? ?? '';
    if (description.isEmpty && args is Map) {
      description = args.entries.map((e) => '${e.key}: ${e.value}').join(' · ');
    }
    if (description.isEmpty) {
      description = 'The agent wants to run a sandbox action.';
    }
    final approval = SandboxApproval(
      id: (data['approval_id'] ?? data['id']) as String? ??
          'approval-${state.approvals.length}-${DateTime.now().millisecondsSinceEpoch}',
      sessionId: data['session_id'] as String? ?? state.activeSessionId,
      toolName: toolName,
      description: description,
    );
    state = state.copyWith(
      expanded: true,
      approvals: [...state.approvals, approval],
    );
  }

  /// Forwards completed/running `sandbox_*` tool events from chat state
  /// into terminal lines, approvals and the diff view.
  void ingestToolEvents(Iterable<ToolEvent> toolEvents) {
    for (final toolEvent in toolEvents) {
      if (!toolEvent.name.startsWith('sandbox')) continue;
      final key = '${toolEvent.id}:${toolEvent.isComplete}';
      if (!_seenToolEventKeys.add(key)) continue;
      if (toolEvent.name == 'sandbox_diff' && toolEvent.result != null) {
        setDiff(toolEvent.result.toString());
        continue;
      }
      final command = toolEvent.args['command'] as String?;
      if (command != null && command.isNotEmpty) {
        appendStdout('\$ $command');
      }
      if (toolEvent.isComplete && toolEvent.result != null) {
        appendStdout(toolEvent.result.toString());
      }
      if (state.sessionStatus != 'running') {
        state = state.copyWith(sessionStatus: 'running');
      }
    }
  }

  /// Answers a pending approval. When the approval carries a session
  /// id the decision is posted to the backend session endpoint; purely
  /// local prompts (no session yet) are resolved in-state only.
  Future<void> decide(SandboxApproval approval, {required bool approve}) async {
    state = state.copyWith(
      approvals: state.approvals.where((a) => a.id != approval.id).toList(),
    );
    appendStdout(approve
        ? 'Approved: ${approval.toolName}'
        : 'Rejected: ${approval.toolName}');
    final sessionId = approval.sessionId ?? state.activeSessionId;
    if (sessionId == null) return;
    try {
      await _repository.approveSession(
        sessionId,
        approved: approve,
        approvalId: approval.id,
        toolName: approval.toolName,
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      debugPrint('[SandboxDrawer] approve call failed: $e');
    }
  }
}
