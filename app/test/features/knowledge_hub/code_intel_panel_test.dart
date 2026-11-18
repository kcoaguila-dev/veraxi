import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/data/code_intel_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/code_intel_section.dart';

class FakeCodeIntelRepository extends CodeIntelRepository {
  FakeCodeIntelRepository()
      : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  @override
  Future<Map<String, dynamic>> ingestRepo(String repoPath) async {
    return {'status': 'ok', 'nodes_written': 7, 'edges_written': 9};
  }

  @override
  Future<CodeOverview> fetchOverview() async {
    return CodeOverview.fromJson({
      'node_counts': {'Function': 4},
      'edge_counts': {'CALLS': 3},
      'total_nodes': 7,
      'total_edges': 9,
      'top_connected': [
        {
          'name': 'main',
          'qualified_name': 'app.main',
          'label': 'Function',
          'path': 'app.py',
          'connections': 5,
        },
      ],
    });
  }

  @override
  Future<List<CodeSymbolMatch>> lookupSymbol(String name) async {
    return [
      CodeSymbolMatch.fromJson({
        'name': 'main',
        'qualified_name': 'app.main',
        'label': 'Function',
        'path': 'app.py',
        'line': 3,
      }),
    ];
  }

  @override
  Future<List<ImpactedSymbol>> impactAnalysis(
    String symbol, {
    int maxDepth = 3,
  }) async {
    return [
      ImpactedSymbol.fromJson({
        'qualified_name': 'cli.run',
        'name': 'run',
        'label': 'Function',
        'path': 'cli.py',
        'depth': 1,
        'via_edge': 'CALLS',
      }),
      ImpactedSymbol.fromJson({
        'qualified_name': 'worker.boot',
        'name': 'boot',
        'label': 'Function',
        'path': 'worker.py',
        'depth': 2,
        'via_edge': 'IMPORTS',
      }),
    ];
  }

  @override
  Future<Map<String, dynamic>> syncVulnIntel() async {
    return {'status': 'ok', 'cves_written': 42};
  }

  @override
  Future<VulnReport> runVulnReport({String? repoPath}) async {
    return VulnReport.fromJson({
      'dependencies_checked': 3,
      'matched_count': 1,
      'unknown_count': 1,
      'kev_count': 1,
      'findings': [
        {
          'package': 'requests',
          'version': '2.31.0',
          'ecosystem': 'pypi',
          'source_file': 'pyproject.toml',
          'cve_id': 'CVE-2024-0001',
          'severity': 'HIGH',
          'cwe_ids': ['CWE-79'],
          'match_status': 'matched',
          'kev': true,
        },
        {
          'package': 'legacy-lib',
          'version': null,
          'ecosystem': 'pypi',
          'source_file': 'pyproject.toml',
          'cve_id': 'CVE-2023-9999',
          'severity': 'MEDIUM',
          'cwe_ids': [],
          'match_status': 'unknown',
          'kev': false,
        },
      ],
    });
  }
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
        iconColor: Colors.white70,
      ),
    ],
  );
}

void main() {
  testWidgets('Repo X-Ray and Vuln Intel panels render and filter',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fake = FakeCodeIntelRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        codeIntelRepositoryProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(
        theme: testTheme(),
        home: const Scaffold(
          body: SingleChildScrollView(child: CodeIntelSection()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Repo X-Ray'), findsOneWidget);
    expect(find.text('Vulnerability Intel'), findsOneWidget);

    // Index the repo (first text field is the shared repo path).
    await tester.enterText(find.byType(TextField).first, '/repos/demo');
    await tester.tap(find.text('Index Code Graph'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Indexed 7 nodes'), findsOneWidget);
    expect(find.text('7 nodes'), findsOneWidget);
    expect(find.text('9 edges'), findsOneWidget);
    expect(find.textContaining('app.main — 5 connections'), findsOneWidget);

    // Symbol search + impact tree with depth/edge badges.
    await tester.enterText(find.byType(TextField).at(1), 'main');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.textContaining('app.main · Function'), findsOneWidget);
    await tester.tap(find.text('Impact'));
    await tester.pumpAndSettle();
    expect(find.text('Impact of main'), findsOneWidget);
    expect(find.text('depth 1'), findsOneWidget);
    expect(find.text('CALLS'), findsOneWidget);
    expect(find.text('IMPORTS'), findsOneWidget);
    expect(find.text('cli.run'), findsOneWidget);

    // Vuln sync + scan.
    await tester.tap(find.text('Sync NVD & KEV'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Synced 42 CVEs'), findsOneWidget);
    await tester.tap(find.text('Run Vulnerability Scan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 dependencies checked'), findsOneWidget);
    // 'HIGH' is both the severity badge and the filter chip label.
    expect(find.text('HIGH'), findsWidgets);
    expect(find.text('KEV'), findsWidgets);
    expect(find.text('CWE-79'), findsOneWidget);
    expect(find.text('Matched'), findsOneWidget);
    // Unknown findings are clearly distinct from matched ones.
    expect(
      find.text('Unknown — version/range unparseable'),
      findsOneWidget,
    );

    // Severity filter narrows the list to HIGH only.
    await tester.tap(find.widgetWithText(ChoiceChip, 'HIGH'));
    await tester.pumpAndSettle();
    expect(find.textContaining('CVE-2024-0001'), findsOneWidget);
    expect(find.textContaining('CVE-2023-9999'), findsNothing);
  });

  test('severity filter logic in state', () {
    const state = CodeIntelState(
      severityFilter: 'CRITICAL',
      vulnReport: VulnReport(findings: [
        VulnFinding(
          package: 'a',
          cveId: 'CVE-1',
          severity: 'HIGH',
          matchStatus: 'matched',
        ),
        VulnFinding(
          package: 'b',
          cveId: 'CVE-2',
          severity: 'CRITICAL',
          matchStatus: 'unknown',
          kev: true,
        ),
      ]),
    );
    expect(state.filteredFindings.map((f) => f.cveId), ['CVE-2']);
  });
}
