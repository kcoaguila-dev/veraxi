import 'package:veraxi_app/features/chat/data/acp_repository.dart';

/// Web/non-IO stub: Antigravity ACP is restricted to Veraxi Desktop.
class DesktopAcpClient {
  DesktopAcpClient._();
  static final DesktopAcpClient instance = DesktopAcpClient._();

  static bool get isSupported => false;

  Future<AcpStatus> checkStatus() async => const AcpStatus();

  Stream<Map<String, dynamic>> streamPrompt({
    required String threadId,
    required String prompt,
    String? model,
    String? cwd,
  }) async* {
    yield {
      'error': 'Antigravity (Local ACP) is only available on Veraxi Desktop.',
      'code': 'unsupported_platform',
    };
  }

  Future<bool> resolvePermission({
    required String sessionId,
    required String requestId,
    required String outcome,
  }) async =>
      false;

  Future<bool> cancelSession(String sessionId) async => false;
}
