import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/data/code_intel_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/code_intel_section.dart';

class FakeCodeIntelRepository extends CodeIntelRepository {
  Map<String, dynamic>? freshnessJson;
  int ingestCallCount = 0;

  FakeCodeIntelRepository({this.freshnessJson})
      : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  @override
  Future<Map<String, dynamic>> ingestRepo(String repoPath) async {
    ingestCallCount++;
    return {'status': 'ok', 'nodes_written': 7, 'edges_written': 9};
  }

  @override
  Future<CodeOverview> fetchOverview() async {
    return CodeOverview.fromJson({
      'node_counts': {'Function': 4},
      'edge_counts': {'CALLS': 3},
      'total_nodes': 7,
      'total_edges': 9,
      if (freshnessJson != null) 'freshness': freshnessJson,
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
  Future<VulnReport> runVulnReport({
    String? repoPath,
    bool includeReachability = false,
    Map<String, dynamic>? sbomJson,
  }) async {
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
          'epss_score': 0.873,
          'epss_percentile': 0.97,
          'reachable_file_count': 2,
          'reachable_in_code': [
            {
              'qualified_name': 'app.main',
              'name': 'main',
              'label': 'Function',
              'path': 'app.py',
              'depth': 1,
              'via_edge': 'CALLS',
            },
          ],
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

  @override
  Future<SarifIngestResult> ingestSarif(Map<String, dynamic> sarif) async {
    return const SarifIngestResult(
      findingsWritten: 5,
      fileLinks: 5,
      cweLinks: 2,
    );
  }

  @override
  Future<ReconIngestResult> ingestRecon(dynamic nucleiPayload) async {
    return const ReconIngestResult(
      findingsWritten: 3,
      hostLinks: 2,
      cveLinks: 1,
    );
  }

  @override
  Future<AttackSyncResult> syncAttackIntel({
    Map<String, dynamic>? stixJson,
  }) async {
    return const AttackSyncResult(
      techniquesWritten: 10,
      tacticsWritten: 3,
      mitigationsWritten: 4,
    );
  }

  @override
  Future<AlertIngestResult> ingestAlerts(dynamic alerts) async {
    return const AlertIngestResult(
      alertsWritten: 7,
      iocLinks: 2,
      techniqueLinks: 1,
    );
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
    tester.view.physicalSize = const Size(1200, 4400);
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
    expect(find.text('Security Feed'), findsOneWidget);
    expect(find.text('Upload SBOM (CycloneDX/SPDX)'), findsOneWidget);
    expect(find.text('Include reachability'), findsOneWidget);

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

    // EPSS badge and code-reachability pill render for the enriched
    // finding; the legacy finding has neither.
    expect(find.text('EPSS 87.3%'), findsOneWidget);
    expect(find.text('Reachable in Code · 2 files'), findsOneWidget);

    // Reachability expansion lists the reachable locations.
    await tester.tap(find.text('Reachable from'));
    await tester.pumpAndSettle();
    expect(find.text('app.main'), findsWidgets);

    // Quick filter: High EPSS keeps only the EPSS >= 0.5 finding.
    await tester.tap(find.widgetWithText(ChoiceChip, 'High EPSS ≥ 0.5'));
    await tester.pumpAndSettle();
    expect(find.textContaining('CVE-2024-0001'), findsOneWidget);
    expect(find.textContaining('CVE-2023-9999'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    expect(find.textContaining('CVE-2023-9999'), findsOneWidget);

    // Severity filter narrows the list to HIGH only.
    await tester.tap(find.widgetWithText(ChoiceChip, 'HIGH'));
    await tester.pumpAndSettle();
    expect(find.textContaining('CVE-2024-0001'), findsOneWidget);
    expect(find.textContaining('CVE-2023-9999'), findsNothing);

    // Security Feed tabs switch between the four ingest sources.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Recon'));
    await tester.pumpAndSettle();
    expect(find.text('Upload Nuclei JSON/JSONL'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'ATT&CK'));
    await tester.pumpAndSettle();
    expect(find.text('Sync MITRE ATT&CK'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'SOC'));
    await tester.pumpAndSettle();
    expect(find.text('Upload Alerts / IOCs (.json)'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'SAST'));
    await tester.pumpAndSettle();
    expect(find.text('Upload SARIF 2.1.0 (.json)'), findsOneWidget);
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

  test('quick filter logic in state (KEV / EPSS / reachability)', () {
    const report = VulnReport(findings: [
      VulnFinding(
        package: 'a',
        cveId: 'CVE-KEV',
        matchStatus: 'matched',
        kev: true,
        epssScore: 0.2,
      ),
      VulnFinding(
        package: 'b',
        cveId: 'CVE-EPSS',
        matchStatus: 'matched',
        epssScore: 0.9,
      ),
      VulnFinding(
        package: 'c',
        cveId: 'CVE-REACH',
        matchStatus: 'matched',
        reachableFileCount: 3,
      ),
      VulnFinding(
        package: 'd',
        cveId: 'CVE-PLAIN',
        matchStatus: 'matched',
      ),
    ]);
    List<String> ids(String filter) => CodeIntelState(
          vulnReport: report,
          vulnQuickFilter: filter,
        ).filteredFindings.map((f) => f.cveId).toList();
    expect(ids(VulnQuickFilter.all),
        ['CVE-KEV', 'CVE-EPSS', 'CVE-REACH', 'CVE-PLAIN']);
    expect(ids(VulnQuickFilter.kevOnly), ['CVE-KEV']);
    expect(ids(VulnQuickFilter.highEpss), ['CVE-EPSS']);
    expect(ids(VulnQuickFilter.reachable), ['CVE-REACH']);
  });

  test('CodeOverview.fromJson parses freshness stamp', () {
    final overview = CodeOverview.fromJson({
      'total_nodes': 12,
      'total_edges': 24,
      'freshness': {
        'indexed_commit': '7a8b9c0123456789',
        'indexed_at': '2026-11-22T08:00:00Z',
        'repo_key': 'veraxi',
        'current_commit': 'f4e5d6c987654321',
        'stale': true,
      },
    });
    expect(overview.freshness, isNotNull);
    expect(overview.freshness!.shortIndexedCommit, '7a8b9c0');
    expect(overview.freshness!.shortCurrentCommit, 'f4e5d6c');
    expect(overview.freshness!.isStale, isTrue);
  });

  testWidgets(
      'RepoXrayPanel renders fresh and stale commit stamps with Re-index action',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 4400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fake = FakeCodeIntelRepository(
      freshnessJson: {
        'indexed_commit': '7a8b9c0abcdef',
        'stale': false,
      },
    );
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

    await tester.enterText(find.byType(TextField).first, '/repos/demo');
    await tester.tap(find.text('Index Code Graph'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('code-index-freshness-fresh')), findsOneWidget);
    expect(find.text('Index fresh · commit 7a8b9c0'), findsOneWidget);
    expect(find.byKey(const Key('code-index-freshness-stale')), findsNothing);

    // Switch overview to stale and refresh.
    fake.freshnessJson = {
      'indexed_commit': '7a8b9c0abcdef',
      'current_commit': 'f4e5d6c123456',
      'stale': true,
    };
    await tester.tap(find.byTooltip('Refresh overview'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('code-index-freshness-stale')), findsOneWidget);
    expect(find.text('Index stale · 7a8b9c0 → f4e5d6c'), findsOneWidget);
    final callsBeforeReindex = fake.ingestCallCount;
    await tester.tap(find.byKey(const Key('code-index-reindex-action')));
    await tester.pumpAndSettle();
    expect(fake.ingestCallCount, callsBeforeReindex + 1);
  });
}
