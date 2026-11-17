import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/sandbox_drawer_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/sandbox_toggle_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/sandbox_drawer.dart';
import 'package:veraxi_app/features/settings/data/sandbox_repository.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/code_sandboxes_tab.dart';

class FakeSandboxRepository extends SandboxRepository {
  FakeSandboxRepository()
      : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  SandboxConfig savedConfig = const SandboxConfig();
  Map<String, String>? savedSecrets;

  @override
  Future<SandboxConfig> getConfig() async {
    return const SandboxConfig(
      provider: 'modal',
      displayName: 'My Sandbox',
      hasSecrets: true,
    );
  }

  @override
  Future<SandboxConfig> saveConfig(
    SandboxConfig config, {
    Map<String, String>? secrets,
  }) async {
    savedConfig = config;
    savedSecrets = secrets;
    return config;
  }

  @override
  Future<SandboxTestResult> testSandbox() async {
    return const SandboxTestResult(
      ok: true,
      latencyMs: 42,
      output: 'Linux sandbox 6.8\n git version 2.43.0',
    );
  }

  @override
  Future<List<SandboxSessionInfo>> getSessions() async {
    return const [
      SandboxSessionInfo(
        id: 'session-1',
        status: 'running',
        provider: 'modal',
        gitBranch: 'sandbox/session-1',
        lastActiveAt: '2026-11-18T00:00:00Z',
      ),
    ];
  }

  @override
  Future<void> pauseSession(String id) async {}

  @override
  Future<void> destroySession(String id) async {}
}

ThemeData testTheme() {
  return ThemeData().copyWith(
    extensions: [
      AppThemeExtension(
        primaryGradientStart: Colors.blue,
        primaryGradientEnd: Colors.blueAccent,
        surfaceHighlight: Colors.grey.shade800,
        sidebarBackground: Colors.black,
        cardBackground: Colors.black54,
        dialogBackground: Colors.black87,
        borderColor: Colors.white24,
        borderColorStrong: Colors.white54,
        textTertiary: Colors.grey,
        iconColor: Colors.white,
      ),
    ],
  );
}

Widget wrapTab(FakeSandboxRepository repository) {
  return ProviderScope(
    overrides: [
      sandboxRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp(
      theme: testTheme(),
      home: const Scaffold(
        body: SingleChildScrollView(child: CodeSandboxesTab()),
      ),
    ),
  );
}

void main() {
  group('CodeSandboxesTab', () {
    late FakeSandboxRepository repository;

    setUp(() {
      repository = FakeSandboxRepository();
    });

    testWidgets('renders all five sections and the active session',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTab(repository));
      await tester.pumpAndSettle();

      expect(find.text('Code Sandboxes'), findsOneWidget);
      expect(find.text('Execution Backend'), findsOneWidget);
      expect(find.text('Runtime & Compute'), findsOneWidget);
      expect(find.text('Autonomy & Git Safety'), findsOneWidget);
      expect(find.text('Network & Secrets'), findsOneWidget);
      expect(find.text('Active Sandboxes'), findsOneWidget);

      // Provider options + the stored-secrets indicator.
      expect(find.text('Disabled'), findsOneWidget);
      expect(find.text('Modal (Cloud)'), findsOneWidget);
      expect(find.text('E2B (Cloud)'), findsOneWidget);
      expect(find.text('Remote MCP URL'), findsOneWidget);
      expect(find.text('Local Runner (veraxi-runner)'), findsOneWidget);
      expect(find.text('Secrets stored'), findsOneWidget);

      // Active session row with actions.
      expect(find.text('modal · running'), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Destroy'), findsOneWidget);
    });

    testWidgets('switching provider shows the provider-specific fields',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTab(repository));
      await tester.pumpAndSettle();

      // Modal is the fake's provider: its secret fields are shown.
      expect(find.text('Modal Token ID'), findsOneWidget);
      expect(find.text('Modal Token Secret'), findsOneWidget);
      expect(find.text('E2B API Key'), findsNothing);

      await tester.tap(find.text('E2B (Cloud)'));
      await tester.pumpAndSettle();

      expect(find.text('E2B API Key'), findsOneWidget);
      expect(find.text('Modal Token ID'), findsNothing);

      await tester.tap(find.text('Remote MCP URL'));
      await tester.pumpAndSettle();

      expect(find.text('Remote MCP URL'), findsWidgets);
      expect(find.text('Bearer Token'), findsOneWidget);
      expect(find.text('E2B API Key'), findsNothing);
    });

    testWidgets('autonomy selector updates the selected mode', (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTab(repository));
      await tester.pumpAndSettle();

      ChoiceChip chip(String label) =>
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

      expect(chip('Auto Read & Test').selected, isTrue);
      expect(chip('Ask All').selected, isFalse);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Ask All'));
      await tester.pumpAndSettle();

      expect(chip('Ask All').selected, isTrue);
      expect(
        find.text(
            'Every sandbox command and file write asks for approval first.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(ChoiceChip, 'Autonomous'));
      await tester.pumpAndSettle();
      expect(chip('Autonomous').selected, isTrue);
    });

    testWidgets('Test Sandbox button shows the latency badge', (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTab(repository));
      await tester.pumpAndSettle();

      expect(find.text('Sandbox ready · 42 ms'), findsNothing);

      await tester.tap(find.text('Test Sandbox'));
      await tester.pumpAndSettle();

      expect(find.text('Sandbox ready · 42 ms'), findsOneWidget);
      expect(find.textContaining('git version 2.43.0'), findsOneWidget);
    });

    testWidgets('domain chips can be removed in allowlist mode',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTab(repository));
      await tester.pumpAndSettle();

      expect(find.text('pypi.org'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.cancel).first);
      await tester.pumpAndSettle();
      // The first default domain chip is gone after tapping its delete icon.
      expect(
        find.widgetWithText(Chip, 'pypi.org'),
        findsNothing,
      );
    });
  });

  group('SandboxDrawer', () {
    testWidgets('renders terminal lines, approvals and diff coloring',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final vm = container.read(sandboxDrawerViewModelProvider.notifier);
      vm.appendStdout('\$ pytest -q\n10 passed');
      vm.appendStderr('warning: slow test');
      vm.handleSandboxEvent({
        'type': 'approval_required',
        'data': {
          'approval_id': 'a1',
          'session_id': 'session-1',
          'tool_name': 'sandbox_exec',
          'command': 'git push origin sandbox/session-1',
        },
      });
      vm.setDiff('+added line\n-removed line\n context line');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: testTheme(),
            home: const Scaffold(body: SandboxDrawer()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sandbox'), findsOneWidget);
      expect(find.text('\$ pytest -q'), findsOneWidget);
      expect(find.text('10 passed'), findsOneWidget);
      expect(find.text('warning: slow test'), findsOneWidget);
      expect(find.text('Approval needed'), findsOneWidget);
      expect(find.text('sandbox_exec'), findsOneWidget);
      expect(find.text('git push origin sandbox/session-1'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);

      // Reject resolves the prompt locally (and via the session API seam).
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      expect(find.text('Approval needed'), findsNothing);
      expect(find.text('Rejected: sandbox_exec'), findsOneWidget);

      // Diff tab shows +/- lines.
      await tester.tap(find.text('Diff'));
      await tester.pumpAndSettle();
      expect(find.text('+added line'), findsOneWidget);
      expect(find.text('-removed line'), findsOneWidget);
    });
  });

  group('SandboxToggleViewModel', () {
    test('persists sandbox_enabled into tool_settings', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final vm = container.read(sandboxToggleViewModelProvider.notifier);
      await vm.load();
      expect(container.read(sandboxToggleViewModelProvider).enabled, isFalse);

      await vm.setEnabled(true);
      expect(container.read(sandboxToggleViewModelProvider).enabled, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getString('tool_settings'), contains('"sandbox_enabled":true'));
    });
  });
}
