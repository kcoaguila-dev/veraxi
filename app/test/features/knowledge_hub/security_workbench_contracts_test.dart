import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_chat_composer.dart';
import 'package:veraxi_app/features/chat/views/widgets/files_changed_card.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/security_feed_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/security_launchpad.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_inspector_pane.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_workbench_table.dart';

final _testThemeExtension = AppThemeExtension(
  primaryGradientStart: Colors.blue,
  primaryGradientEnd: Colors.blueAccent,
  surfaceHighlight: Colors.grey.shade800,
  sidebarBackground: Colors.black,
  cardBackground: Colors.black54,
  dialogBackground: Colors.black87,
  borderColor: Colors.white24,
  borderColorStrong: Colors.white54,
  textTertiary: Colors.grey,
  iconColor: Colors.white70,
);

Widget _wrapTestApp(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: [_testThemeExtension],
      ),
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    ),
  );
}

void main() {
  final directFinding = VulnFinding(
    package: 'requests',
    version: '2.28.0',
    ecosystem: 'pypi',
    sourceFile: 'pyproject.toml',
    cveId: 'CVE-2023-32681',
    severity: 'HIGH',
    matchStatus: 'matched',
    kev: true,
    epssScore: 0.873,
    dependencyScope: 'direct',
    introducedVia: 'pyproject.toml',
    fixedVersion: '2.31.0',
    compositeScore: 94,
    priorityReasons: const [
      'Reachable in 2 call sites',
      'Active in CISA KEV',
      'EPSS 87.3%',
    ],
    reachableFileCount: 2,
    callSites: const [
      VulnCallSite(
        file: 'app/client.py',
        line: 42,
        symbol: 'app.client.fetch',
        chain: ['app.api.handle'],
      ),
    ],
  );

  final transitiveFinding = VulnFinding(
    package: 'urllib3',
    version: '1.26.5',
    ecosystem: 'pypi',
    sourceFile: 'uv.lock',
    cveId: 'CVE-2023-43804',
    severity: 'MEDIUM',
    matchStatus: 'matched',
    dependencyScope: 'transitive',
    introducedVia: 'requests',
    compositeScore: 22,
  );

  test('filterFindingsByQuery supports is:direct token', () {
    final all = [directFinding, transitiveFinding];
    final directOnly = filterFindingsByQuery(all, 'is:direct');
    expect(directOnly.length, 1);
    expect(directOnly.first.package, 'requests');
  });

  testWidgets(
      'VulnWorkbenchTable groups by package, renders Direct/Transitive pills, and shows hidden footer',
      (tester) async {
    var showAllTapped = false;
    await tester.pumpWidget(
      _wrapTestApp(
        VulnWorkbenchTable(
          findings: [directFinding, transitiveFinding],
          selectedFindingId: directFinding.findingId,
          hiddenUnreachableCount: 38,
          totalFindingsCount: 40,
          onShowAll: () => showAllTapped = true,
        ),
      ),
    );

    expect(find.text('requests'), findsOneWidget);
    expect(find.text('urllib3'), findsOneWidget);
    expect(find.text('Direct'), findsWidgets);
    expect(find.text('Transitive'), findsWidgets);
    expect(
      find.text('38 unreachable transitive findings hidden'),
      findsOneWidget,
    );

    await tester.tap(find.text('Show all 40 →'));
    await tester.pump();
    expect(showAllTapped, isTrue);
  });

  testWidgets(
      'VulnInspectorPane handles call-site click, ignore menu, and Code Thread CTA',
      (tester) async {
    VulnCallSite? inspectedSite;
    String? ignoredReason;
    VulnFinding? askedFinding;

    await tester.pumpWidget(
      _wrapTestApp(
        VulnInspectorPane(
          finding: directFinding,
          onInspectCallSite: (_, site) => inspectedSite = site,
          onIgnoreFinding: (_, reason) => ignoredReason = reason,
          onAskFixInCodeThread: (f) => askedFinding = f,
        ),
      ),
    );

    expect(find.text('Score 94'), findsOneWidget);
    expect(find.text('Reachable in 2 call sites'), findsOneWidget);
    expect(find.text('Active in CISA KEV'), findsOneWidget);
    expect(find.text('→ Upgrade to requests >= 2.31.0'), findsOneWidget);

    await tester.tap(find.textContaining('app/client.py:42'));
    await tester.pump();
    expect(inspectedSite?.file, 'app/client.py');

    await tester.tap(find.text('Ignore / Snooze'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Snooze 30 days'));
    await tester.pumpAndSettle();
    expect(ignoredReason, 'snooze_30d');

    await tester.tap(find.text('Ask Veraxi to Fix in Code Thread →'));
    await tester.pump();
    expect(askedFinding?.cveId, 'CVE-2023-32681');
  });

  testWidgets(
      'SecurityFeedPanel renders instructive empty state with CLI snippet and supported tools',
      (tester) async {
    await tester.pumpWidget(
      _wrapTestApp(
        SecurityFeedPanel(
          embedded: true,
          initialTab: 0,
          onConnectRepo: () {},
        ),
      ),
    );

    expect(find.text('Upload SARIF 2.1.0 (.json)'), findsOneWidget);
    expect(find.text('+ Connect a repo'), findsOneWidget);
    expect(find.text('semgrep --sarif -o results.sarif .'), findsOneWidget);
    expect(
      find.text('Supports Semgrep · CodeQL · Bandit · Snyk · Trivy SARIF 2.1.0'),
      findsOneWidget,
    );
  });

  testWidgets(
      'CodeChatComposer renders and removes attachedDiffHunkProvider chip',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(attachedDiffHunkProvider.notifier).state =
        const DiffHunkAttachment(
      file: 'app/client.py',
      line: 42,
      hunkText: '+timeout=10',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: [_testThemeExtension],
          ),
          home: Scaffold(
            body: CodeChatComposer(
              isLoading: false,
              onSend: (_, {attachments}) {},
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('composer-attached-diff-hunk-chip')),
      findsOneWidget,
    );
    expect(find.text('app/client.py:42'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();
    expect(container.read(attachedDiffHunkProvider), isNull);
  });

  testWidgets('FilesChangedCard renders Audit Diff button next to Review',
      (tester) async {
    await tester.pumpWidget(
      _wrapTestApp(
        FilesChangedCard(
          summary: const FilesChangedSummary(
            sessionId: 's1',
            turnId: 't1',
            files: [
              FilesChangedFile(
                path: 'app/client.py',
                additions: 2,
                deletions: 1,
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('files-changed-audit-diff-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('files-changed-review-button')),
      findsOneWidget,
    );
  });
}
