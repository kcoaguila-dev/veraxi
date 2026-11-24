import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/acp_repository.dart';
import 'package:veraxi_app/features/chat/view_models/acp_runtime_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/acp_permission_banner.dart';

class _FakeAcpRepository extends AcpRepository {
  String? lastDecision;
  bool statusFetched = false;

  _FakeAcpRepository() : super(apiClient: ApiClient());

  @override
  Future<AcpStatus> fetchStatus() async {
    statusFetched = true;
    return const AcpStatus(
      available: true,
      acpEnabled: true,
      transport: 'local_stdio',
      binary: '/usr/local/bin/agy',
    );
  }

  @override
  Future<bool> resolvePermission({
    required String sessionId,
    required String requestId,
    required String outcome,
  }) async {
    lastDecision = '$sessionId:$requestId:$outcome';
    return true;
  }
}

void main() {
  test(
      'AcpRuntimeNotifier switches runtime, refreshes status, and resolves permissions',
      () async {
    final repo = _FakeAcpRepository();
    final notifier = AcpRuntimeNotifier(repo);

    expect(notifier.state.isAcpActive, isFalse);

    notifier.selectRuntime(AgentRuntimeType.antigravityAcp);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.isAcpActive, isTrue);
    expect(repo.statusFetched, isTrue);
    expect(notifier.state.status.transport, 'local_stdio');

    notifier.setPendingPermission(
      const AcpPermissionPrompt(
        sessionId: 's1',
        requestId: 'r1',
        toolName: 'edit_file',
        description: 'Update file',
      ),
    );
    expect(notifier.state.pendingPermission, isNotNull);

    await notifier.resolvePermission('allow_once');
    expect(notifier.state.pendingPermission, isNull);
    expect(repo.lastDecision, 's1:r1:allow_once');

    notifier.markQuotaExhausted('429 limit reached');
    expect(notifier.state.quotaExhaustedMessage, '429 limit reached');
    notifier.switchToVeraxiByok();
    expect(notifier.state.isAcpActive, isFalse);
    expect(notifier.state.quotaExhaustedMessage, isNull);
  });

  testWidgets('AcpPermissionBanner renders permission gate and quota fallback',
      (tester) async {
    final repo = _FakeAcpRepository();
    final notifier = AcpRuntimeNotifier(repo);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          acpRuntimeProvider.overrideWith((_) => notifier),
        ],
        child: const MaterialApp(
          home: Scaffold(body: AcpPermissionBanner()),
        ),
      ),
    );

    notifier.setPendingPermission(
      const AcpPermissionPrompt(
        sessionId: 's1',
        requestId: 'r1',
        toolName: 'run_command',
        description: 'Run pytest',
      ),
    );
    await tester.pumpAndSettle();

    expect(
        find.textContaining('Antigravity requests permission'), findsOneWidget);
    expect(find.text('Allow Once'), findsOneWidget);

    await tester.tap(find.text('Allow Once'));
    await tester.pumpAndSettle();
    expect(repo.lastDecision, 's1:r1:allow_once');

    notifier.markQuotaExhausted('Quota reached');
    await tester.pumpAndSettle();
    expect(find.text('Antigravity Quota Exhausted (HTTP 429)'), findsOneWidget);

    await tester.tap(find.text('Switch to BYOK'));
    await tester.pumpAndSettle();
    expect(notifier.state.isAcpActive, isFalse);
  });
}
