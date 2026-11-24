import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/data/acp_repository.dart';

enum AgentRuntimeType {
  veraxi('veraxi', 'Veraxi Engine'),
  antigravityAcp('antigravity_acp', 'Antigravity (Local ACP)');

  final String wireValue;
  final String displayName;
  const AgentRuntimeType(this.wireValue, this.displayName);
}

class AcpPermissionPrompt {
  final String sessionId;
  final String requestId;
  final String toolName;
  final String description;
  final Map<String, dynamic> args;

  const AcpPermissionPrompt({
    required this.sessionId,
    required this.requestId,
    required this.toolName,
    required this.description,
    this.args = const {},
  });

  factory AcpPermissionPrompt.fromEvent(Map<String, dynamic> event) {
    final rawArgs = event['args'];
    return AcpPermissionPrompt(
      sessionId: event['session_id'] as String? ?? '',
      requestId: event['request_id'] as String? ?? '',
      toolName: event['tool_name'] as String? ?? 'tool',
      description: event['description'] as String? ?? 'Permission requested',
      args: rawArgs is Map ? Map<String, dynamic>.from(rawArgs) : const {},
    );
  }
}

class AcpRuntimeState {
  final AgentRuntimeType selectedRuntime;
  final bool attachVeraxiMcp;
  final AcpStatus status;
  final bool isLoadingStatus;
  final AcpPermissionPrompt? pendingPermission;
  final String? quotaExhaustedMessage;

  const AcpRuntimeState({
    this.selectedRuntime = AgentRuntimeType.veraxi,
    this.attachVeraxiMcp = true,
    this.status = const AcpStatus(),
    this.isLoadingStatus = false,
    this.pendingPermission,
    this.quotaExhaustedMessage,
  });

  bool get isAcpActive => selectedRuntime == AgentRuntimeType.antigravityAcp;

  AcpRuntimeState copyWith({
    AgentRuntimeType? selectedRuntime,
    bool? attachVeraxiMcp,
    AcpStatus? status,
    bool? isLoadingStatus,
    AcpPermissionPrompt? pendingPermission,
    bool clearPendingPermission = false,
    String? quotaExhaustedMessage,
    bool clearQuotaExhausted = false,
  }) {
    return AcpRuntimeState(
      selectedRuntime: selectedRuntime ?? this.selectedRuntime,
      attachVeraxiMcp: attachVeraxiMcp ?? this.attachVeraxiMcp,
      status: status ?? this.status,
      isLoadingStatus: isLoadingStatus ?? this.isLoadingStatus,
      pendingPermission: clearPendingPermission
          ? null
          : (pendingPermission ?? this.pendingPermission),
      quotaExhaustedMessage: clearQuotaExhausted
          ? null
          : (quotaExhaustedMessage ?? this.quotaExhaustedMessage),
    );
  }
}

final acpRuntimeProvider =
    StateNotifierProvider<AcpRuntimeNotifier, AcpRuntimeState>((ref) {
  return AcpRuntimeNotifier(ref.watch(acpRepositoryProvider));
});

class AcpRuntimeNotifier extends StateNotifier<AcpRuntimeState> {
  final AcpRepository _repository;

  AcpRuntimeNotifier(this._repository) : super(const AcpRuntimeState());

  Future<void> refreshStatus() async {
    state = state.copyWith(isLoadingStatus: true);
    final status = await _repository.fetchStatus();
    if (!mounted) return;
    state = state.copyWith(status: status, isLoadingStatus: false);
  }

  void selectRuntime(AgentRuntimeType runtime) {
    state = state.copyWith(
      selectedRuntime: runtime,
      clearQuotaExhausted: true,
    );
    if (runtime == AgentRuntimeType.antigravityAcp) {
      refreshStatus();
    }
  }

  void setAttachVeraxiMcp(bool value) {
    state = state.copyWith(attachVeraxiMcp: value);
  }

  void setPendingPermission(AcpPermissionPrompt prompt) {
    state = state.copyWith(pendingPermission: prompt);
  }

  Future<void> resolvePermission(String outcome) async {
    final prompt = state.pendingPermission;
    if (prompt == null) return;
    state = state.copyWith(clearPendingPermission: true);
    await _repository.resolvePermission(
      sessionId: prompt.sessionId,
      requestId: prompt.requestId,
      outcome: outcome,
    );
  }

  void markQuotaExhausted(String message) {
    state = state.copyWith(quotaExhaustedMessage: message);
  }

  void switchToVeraxiByok() {
    state = state.copyWith(
      selectedRuntime: AgentRuntimeType.veraxi,
      clearQuotaExhausted: true,
      clearPendingPermission: true,
    );
  }
}
