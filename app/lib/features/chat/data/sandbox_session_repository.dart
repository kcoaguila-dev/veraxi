import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// Chat-side access to the sandbox session approval endpoint.
///
/// The settings feature owns the full sandbox configuration repository;
/// chat only needs to answer an `approval_required` prompt for a live
/// session, so this deliberately tiny repository lives in the chat
/// feature (features never import another feature's data layer).
class SandboxSessionRepository {
  SandboxSessionRepository(this._apiClient);

  final ApiClient _apiClient;

  /// Records the user's decision for a gated sandbox action:
  /// POST /api/v1/sandboxes/sessions/{id}/approve.
  Future<void> approveSession(
    String sessionId, {
    required bool approved,
    String? approvalId,
    String? toolName,
  }) async {
    await _apiClient.post('/v1/sandboxes/sessions/$sessionId/approve', body: {
      'approved': approved,
      if (approvalId != null) 'approval_id': approvalId,
      if (toolName != null) 'tool_name': toolName,
    });
  }
}

final sandboxSessionRepositoryProvider =
    Provider<SandboxSessionRepository>((ref) {
  return SandboxSessionRepository(ref.watch(apiClientProvider));
});
