import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/repositories/memory_repository.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/data/local_chat_migration_service.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/chat_screen.dart';
import 'package:veraxi_app/features/knowledge_hub/data/code_intel_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/data/knowledge_hub_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/views/knowledge_hub_screen.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_chat_pane.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_review_drawer.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/corpus_briefing_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/repo_xray_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/security_launchpad.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_intel_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_workbench_table.dart';

class _MockChatRepository extends Mock implements IChatRepository {
  @override
  Stream<Map<String, dynamic>> streamSyncEvents() => const Stream.empty();
}

class _MockTtsRepository extends Mock implements TTSRepository {}

class _MockMemoryRepository extends Mock implements MemoryRepository {}

class _MockMigrationService extends Mock implements LocalChatMigrationService {}

class _StubChatViewModel extends ChatViewModel {
  _StubChatViewModel(ChatState initialState)
      : super(
          _MockChatRepository(),
          _MockTtsRepository(),
          _MockMemoryRepository(),
          _MockMigrationService(),
        ) {
    state = initialState;
  }

  @override
  Future<void> loadThreads() async {}
}

class _FakeKnowledgeHubRepository extends KnowledgeHubRepository {
  final List<String> deletedIds = [];
  final List<String> reindexedIds = [];
  final List<IndexedSourceItem> sourcesToReturn;

  _FakeKnowledgeHubRepository({
    this.sourcesToReturn = const [
      IndexedSourceItem(
        id: 'veraxi/backend',
        name: 'veraxi/backend',
        subtitle: '/repo/backend',
        type: 'Code AST',
        category: 'repo',
        counts: '142 files · 812 nodes',
        lastSynced: '12m ago',
        isStale: false,
      ),
      IndexedSourceItem(
        id: 'architecture_v2_draft.pdf',
        name: 'architecture_v2_draft.pdf',
        subtitle: 'Uploaded · 4.2 MB',
        type: 'PDF',
        category: 'doc',
        counts: '64 chunks · 91 nodes',
        lastSynced: '18d ago',
        isStale: true,
      ),
    ],
  }) : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  @override
  Future<BackendStats> fetchStats() async =>
      BackendStats(nodeCount: 3210, vectorCount: 1840, sourceCount: 3);

  @override
  Future<Map<String, dynamic>?> getSchema() async => {
        'entities': ['Service', 'Vulnerability'],
        'relationships': ['CALLS', 'AFFECTS'],
      };

  @override
  Future<SourcesSnapshot> fetchSources() async => SourcesSnapshot(
        sources: sourcesToReturn,
        queue: const [
          IngestionJobItem(
            jobId: 'job-1',
            source: 'architecture_v3.pdf',
            stage: 'Chunking + Dual-Write',
            progress: 0.78,
          ),
        ],
      );

  @override
  Future<Map<String, dynamic>> reindexSource({
    required String sourceId,
    required String category,
  }) async {
    reindexedIds.add(sourceId);
    return {'status': 'ok', 'source_id': sourceId};
  }

  @override
  Future<Map<String, dynamic>> deleteSource({
    required String sourceId,
    required String category,
  }) async {
    deletedIds.add(sourceId);
    return {'status': 'deleted', 'deleted_nodes': 91, 'deleted_vectors': 64};
  }
}

class _FakeCodeIntelRepository extends CodeIntelRepository {
  final List<Map<String, dynamic>> reposToReturn;
  final String streamedSourcePath;
  final String? streamedToken;
  final Map<String, dynamic> Function(String path)? fileResponseBuilder;
  String? lastSidecarModel;
  String? lastScanRepoPath;

  _FakeCodeIntelRepository({
    this.reposToReturn = const [
      {
        'repo_key': 'veraxi/custom-service',
        'display_name': 'veraxi/custom-service',
        'root_path': '/repos/custom',
        'file_count': 48,
        'symbol_count': 310,
        'is_stale': false,
      },
    ],
  })  : streamedSourcePath = 'routes.py',
        streamedToken = null,
        fileResponseBuilder = null,
        super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  @override
  Future<List<Map<String, dynamic>>> fetchIndexedRepos() async => reposToReturn;

  @override
  Future<Map<String, dynamic>> fetchIndexedFile(String path) async {
    if (fileResponseBuilder != null) {
      return fileResponseBuilder!(path);
    }
    return {
      'path': path,
      'source': 'file',
      'language': 'python',
      'start_line': 1,
      'line_count': 2,
      'content': 'def ingest_route(upload):\n    return parse_tar(upload)',
    };
  }

  @override
  Stream<Map<String, dynamic>> streamSidecarAsk({
    required String question,
    VulnFinding? finding,
    String? repoKey,
    String? threadId,
    String? model,
  }) async* {
    lastSidecarModel = model;
    yield {'type': 'activity', 'label': 'Checked Code Graph · routes.py'};
    if (streamedToken != null) {
      yield {'type': 'token', 'content': streamedToken!};
    } else {
      yield {'type': 'token', 'content': 'Streamed answer: '};
      yield {'type': 'token', 'content': 'parse_tar reads uploaded bytes.'};
    }
    yield {
      'type': 'sources',
      'sources': [
        {'path': streamedSourcePath}
      ],
    };
  }

  @override
  Future<VulnReport> runVulnReport({
    String? repoPath,
    bool includeReachability = false,
    Map<String, dynamic>? sbomJson,
  }) async {
    lastScanRepoPath = repoPath;
    return VulnReport.fromJson({
      'dependencies_checked': 42,
      'matched_count': 2,
      'unknown_count': 0,
      'kev_count': 1,
      'findings': [
        {
          'package': 'archive-utils',
          'version': '5.6.1',
          'ecosystem': 'pypi',
          'source_file': 'routes.py',
          'cve_id': 'CVE-2024-3094',
          'severity': 'CRITICAL',
          'cwe_ids': ['CWE-502'],
          'match_status': 'matched',
          'kev': true,
          'epss_score': 0.94,
          'reachable_file_count': 1,
          'reachable_in_code': [
            {
              'qualified_name': 'fastapi_app.ingest_route',
              'name': 'ingest_route',
              'label': 'Function',
              'path': 'routes.py',
              'depth': 1,
              'via_edge': 'CALLS',
            },
          ],
        },
        {
          'package': 'black',
          'version': '23.12.1',
          'ecosystem': 'pypi',
          'source_file': 'pyproject.toml',
          'cve_id': 'CVE-2024-21503',
          'severity': 'LOW',
          'cwe_ids': ['CWE-1333'],
          'match_status': 'matched',
          'kev': false,
          'epss_score': 0.12,
          'reachable_file_count': 0,
          'reachable_in_code': [],
        },
      ],
    });
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'ChatScreen switches [ Chat | Code ] to the 2-column Code Chat default, unified Security workspace, and returns to Code Chat',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(ChatState(messages: []));
    final codeRepo = _FakeCodeIntelRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
          codeChatViewModelProvider.overrideWith(
              (ref) => _StubChatViewModel(ChatState(messages: []))),
          codeIntelRepositoryProvider.overrideWithValue(codeRepo),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Initially in Chat mode: segmented switcher shows Chat & Code.
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);
    expect(find.text('INTEL & ANALYSIS'), findsNothing);

    // Switch to Code mode via sidebar tap.
    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();

    // Phase 6 sidebar: repo-grouped Projects with Knowledge Hub +
    // Security rows only — no INTEL & ANALYSIS section, no per-panel
    // nav rows.
    expect(find.text('INTEL & ANALYSIS'), findsNothing);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Knowledge Hub'), findsOneWidget);
    expect(find.text('Security'), findsOneWidget);
    expect(find.text('Vuln Intel'), findsNothing);
    expect(find.text('INDEXED REPOS'), findsNothing);
    expect(find.text('veraxi/custom-service'), findsNWidgets(2));
    expect(find.text('48 files · 310 symbols'), findsNothing);

    // Default Code sub-view is Code Chat (2-column: rail + center
    // stage), and the Review split-pane is closed by default.
    final container0 = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );
    expect(container0.read(codeSubViewProvider), CodeSubView.codeChat);
    expect(container0.read(activeReviewSessionProvider), isNull);
    expect(find.byType(CodeChatPane), findsOneWidget);
    expect(find.byType(CodeReviewDrawer), findsNothing);
    expect(find.text('veraxi/custom-service / New chat'), findsOneWidget);
    expect(
        find.text('Ask anything about veraxi/custom-service.'), findsOneWidget);
    expect(find.text('Run Vulnerability Scan'), findsNothing);

    // Open the unified Security workspace via the Security row.
    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();
    expect(container0.read(codeSubViewProvider), CodeSubView.vulnIntel);
    expect(find.text('Vulnerability Intel'), findsOneWidget);

    // Unified Security section tabs; non-CVE labels also appear on
    // the launchpad quick-start cards before any scan has run.
    expect(find.text('CVEs & Reachability'), findsOneWidget);
    expect(find.text('SAST · SARIF'), findsWidgets);
    expect(find.text('Recon · Nuclei'), findsWidgets);
    expect(find.text('ATT&CK · STIX'), findsWidgets);
    expect(find.text('SOC Alerts'), findsWidgets);
    expect(find.byType(SecuritySectionTabs), findsOneWidget);
    expect(find.text('Security Launchpad'), findsOneWidget);
    expect(find.text('Index & Scan'), findsOneWidget);
    expect(find.text('Ask Veraxi'), findsNothing);

    // Embedded Security Feed section: SAST tab shows its real ingest
    // action inside the unified workspace, then return to CVEs.
    await tester.tap(find.text('SAST · SARIF').first);
    await tester.pumpAndSettle();
    expect(find.text('Upload SARIF 2.1.0'), findsOneWidget);
    expect(find.text('Security Launchpad'), findsNothing);
    await tester.tap(find.text('CVEs & Reachability'));
    await tester.pumpAndSettle();
    expect(find.text('Security Launchpad'), findsOneWidget);

    // Run Vuln Scan -> verifies Triage Funnel + aligned desktop table + Ask/Path actions.
    await tester.tap(find.text('Run Vulnerability Scan'));
    await tester.pumpAndSettle();
    expect(find.text('Security Launchpad'), findsNothing);
    expect(find.text('SAST · SARIF'), findsOneWidget);
    expect(codeRepo.lastScanRepoPath, '/repos/custom');
    expect(find.text('TRIAGE FUNNEL'), findsOneWidget);
    expect(find.text('CVE / PACKAGE'), findsOneWidget);
    expect(find.text('CVE-2024-3094'), findsWidgets);
    expect(find.text('Static Path (1 hop)'), findsOneWidget);
    expect(find.text('Include reachability'), findsOneWidget);
    expect(find.text('CWE-502'), findsOneWidget);
    expect(find.text('All Findings (2)'), findsOneWidget);
    expect(find.text('CISA KEV (1)'), findsOneWidget);
    expect(find.text('Reachable (1)'), findsOneWidget);
    expect(find.text('EPSS ≥ 0.7 (1)'), findsOneWidget);

    // SecurityQueryBar: is:kev narrows the table to the KEV finding,
    // and clearing the query restores every finding.
    expect(find.byType(SecurityQueryBar), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(SecurityQueryBar),
        matching: find.byType(TextField),
      ),
      'is:kev',
    );
    await tester.pumpAndSettle();
    expect(find.text('CVE-2024-3094'), findsWidgets);
    expect(find.text('CVE-2024-21503'), findsNothing);
    expect(find.text('1 matching'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(SecurityQueryBar),
        matching: find.byType(TextField),
      ),
      '',
    );
    await tester.pumpAndSettle();
    expect(find.text('CVE-2024-21503'), findsWidgets);
    expect(find.text('2 matching'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );

    // Repo X-Ray and the standalone Security Feed sub-view remain
    // reachable as Code sub-views (driven here via the provider,
    // since Phase 6 removed their sidebar rows).
    container.read(codeSubViewProvider.notifier).state = CodeSubView.repoXray;
    await tester.pumpAndSettle();
    expect(find.text('Repo X-Ray'), findsWidgets);

    // Back button in the workbench header returns to Code Chat.
    await tester.tap(find.byTooltip('Back to Code Chat'));
    await tester.pumpAndSettle();
    expect(container.read(codeSubViewProvider), CodeSubView.codeChat);
    expect(find.byType(CodeChatPane), findsOneWidget);

    container.read(codeSubViewProvider.notifier).state =
        CodeSubView.securityFeed;
    await tester.pumpAndSettle();
    expect(find.text('Security Feed'), findsWidgets);

    // Switch back to Chat mode via Ctrl+1 shortcut.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('INTEL & ANALYSIS'), findsNothing);
    expect(find.text('Chats'), findsOneWidget);
  });

  testWidgets(
      'CodeWorkbenchView does not mount Ask Veraxi sidecar below 1200px and selecting a repo returns to Code Chat',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(ChatState(messages: []));
    final codeRepo = _FakeCodeIntelRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
          codeChatViewModelProvider.overrideWith(
              (ref) => _StubChatViewModel(ChatState(messages: []))),
          codeIntelRepositoryProvider.overrideWithValue(codeRepo),
          workspaceModeProvider.overrideWith((ref) => WorkspaceMode.code),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New chat'), findsNothing);

    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();

    expect(find.text('Ask Veraxi'), findsNothing);
    expect(find.text('REACHABILITY PATH · SELECTED ROW'), findsNothing);

    // Tapping a repo in Projects returns to Code Chat.
    await tester.tap(find.text('veraxi/custom-service').first);
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );
    expect(container.read(codeSubViewProvider), CodeSubView.codeChat);
    expect(find.byType(CodeChatPane), findsOneWidget);
  });

  testWidgets(
      'KnowledgeHubScreen renders 5 tabs, live Indexed Sources, Re-index/Del, and sidebar INGESTION QUEUE',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(ChatState(messages: []));
    final hubRepo = _FakeKnowledgeHubRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
          codeChatViewModelProvider.overrideWith(
              (ref) => _StubChatViewModel(ChatState(messages: []))),
          knowledgeHubRepositoryProvider.overrideWithValue(hubRepo),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const KnowledgeHubScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // All 5 tabs are present in the header.
    expect(find.text('Sources & Ingestion'), findsOneWidget);
    expect(find.text('Repo X-Ray'), findsOneWidget);
    expect(find.text('Corpus & Lineage'), findsOneWidget);
    expect(find.text('Schema & Extraction'), findsOneWidget);
    expect(find.text('Infra & Monitors'), findsOneWidget);

    // Tab 1: Sources & Ingestion + left rail live queue.
    expect(find.text('Indexed Sources'), findsOneWidget);
    expect(find.text('architecture_v2_draft.pdf'), findsOneWidget);
    expect(find.text('architecture_v3.pdf'), findsWidgets);
    expect(find.text('INGESTION QUEUE'), findsWidgets);
    expect(find.text('Stale'), findsOneWidget);

    // Re-index and Delete (with confirmation dialog) call repository methods.
    await tester.tap(find.text('Re-index').last);
    await tester.pumpAndSettle();
    expect(hubRepo.reindexedIds, ['architecture_v2_draft.pdf']);

    await tester.tap(find.text('Del').last);
    await tester.pumpAndSettle();
    expect(find.text('Delete Indexed Source?'), findsOneWidget);
    expect(hubRepo.deletedIds, isEmpty);

    await tester.tap(find.text('Delete Source'));
    await tester.pumpAndSettle();
    expect(hubRepo.deletedIds, ['architecture_v2_draft.pdf']);
    expect(find.text('architecture_v2_draft.pdf'), findsNothing);

    // Tab 2: Repo X-Ray embeds the RepoXrayPanel.
    await tester.tap(find.text('Repo X-Ray'));
    await tester.pumpAndSettle();
    expect(find.text('Index Code Graph'), findsOneWidget);
    expect(find.byType(RepoXrayPanel), findsOneWidget);

    // Tab 3: Corpus & Lineage embeds the CorpusBriefingPanel
    // (briefing + dbt lineage in one tab).
    await tester.tap(find.text('Corpus & Lineage'));
    await tester.pumpAndSettle();
    expect(find.text('Corpus Briefing'), findsOneWidget);
    expect(find.text('dbt Lineage'), findsOneWidget);
    expect(find.text('Upload manifest.json'), findsOneWidget);
    expect(find.byType(CorpusBriefingPanel), findsOneWidget);

    // Tab 4: Schema & Extraction.
    await tester.tap(find.text('Schema & Extraction'));
    await tester.pumpAndSettle();
    expect(find.text('Information Extraction Rules'), findsOneWidget);
    expect(find.text('Auto-Generate from Sample'), findsOneWidget);

    // Tab 5: Infra & Monitors.
    await tester.tap(find.text('Infra & Monitors'));
    await tester.pumpAndSettle();
    expect(find.text('Database Monitors'), findsOneWidget);
    expect(find.text('Qdrant'), findsOneWidget);
    expect(find.text('Neo4j'), findsOneWidget);
  });

  testWidgets(
      'VulnIntelPanel falls back to stacked cards below 640px in workbench mode',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(580, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(ChatState(messages: []));
    final codeRepo = _FakeCodeIntelRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
          codeChatViewModelProvider.overrideWith(
              (ref) => _StubChatViewModel(ChatState(messages: []))),
          codeIntelRepositoryProvider.overrideWithValue(codeRepo),
          workspaceModeProvider.overrideWith((ref) => WorkspaceMode.code),
          codeSubViewProvider.overrideWith((ref) => CodeSubView.vulnIntel),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run Vulnerability Scan'));
    await tester.pumpAndSettle();

    expect(find.text('CVE / PACKAGE'), findsNothing);
    expect(
      find.text('archive-utils 5.6.1 — CVE-2024-3094'),
      findsOneWidget,
    );
  });

  testWidgets(
      'Empty-tenant states render honest empty messages when APIs return []',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(ChatState(messages: []));
    final emptyCodeRepo = _FakeCodeIntelRepository(reposToReturn: const []);
    final emptyHubRepo = _FakeKnowledgeHubRepository(sourcesToReturn: const []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
          codeChatViewModelProvider.overrideWith(
              (ref) => _StubChatViewModel(ChatState(messages: []))),
          codeIntelRepositoryProvider.overrideWithValue(emptyCodeRepo),
          workspaceModeProvider.overrideWith((ref) => WorkspaceMode.code),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No repos indexed yet'), findsOneWidget);
    expect(find.text('veraxi/backend'), findsNothing);

    final hubChatVm = _StubChatViewModel(ChatState(messages: []));
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          chatViewModelProvider.overrideWith((ref) => hubChatVm),
          knowledgeHubRepositoryProvider.overrideWithValue(emptyHubRepo),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const KnowledgeHubScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
          'No indexed sources yet. Upload a document or ingest a URL above.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'Code Mode sidebar stays in Code mode on Knowledge Hub and matches Chat Mode row thickness',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(ChatState(messages: []));
    final hubRepo = _FakeKnowledgeHubRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
          codeChatViewModelProvider.overrideWith(
              (ref) => _StubChatViewModel(ChatState(messages: []))),
          knowledgeHubRepositoryProvider.overrideWithValue(hubRepo),
          workspaceModeProvider.overrideWith((ref) => WorkspaceMode.code),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const KnowledgeHubScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Stays in Code mode sidebar (Security & Knowledge Hub visible, New chat & Chats list hidden).
    expect(find.text('New chat'), findsNothing);
    expect(find.text('Knowledge Hub'), findsNWidgets(2)); // sidebar + header
    expect(find.text('Security'), findsOneWidget);
    expect(find.text('Chats'), findsNothing);

    // Sidebar Knowledge Hub & Security rows use 8px vertical padding & 14px font size.
    final securityText = tester.widget<Text>(find.text('Security'));
    expect(securityText.style?.fontSize, 14);
    final securityContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('Security'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      securityContainer.padding,
      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    );
  });

  testWidgets(
      'Code Mode shows single Vulnerability Intel heading, aligned VulnWorkbenchTable without dead header margin, and empty-tenant scan guard',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(ChatState(messages: []));
    final emptyCodeRepo = _FakeCodeIntelRepository(reposToReturn: const []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
          codeChatViewModelProvider.overrideWith(
              (ref) => _StubChatViewModel(ChatState(messages: []))),
          codeIntelRepositoryProvider.overrideWithValue(emptyCodeRepo),
          workspaceModeProvider.overrideWith((ref) => WorkspaceMode.code),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();

    // Single heading in Code Mode (header bar only, not duplicated in VulnIntelPanel).
    expect(find.text('Vulnerability Intel'), findsOneWidget);

    // Empty-tenant scan guard: guidance hint renders and Run Vulnerability Scan is disabled.
    expect(
      find.text('Select an indexed repo or upload an SBOM to scan'),
      findsOneWidget,
    );
    // Phase 6: the empty state is the Security Launchpad, and its
    // Index & Scan button is likewise disabled with no repo path.
    expect(find.text('Security Launchpad'), findsOneWidget);
    expect(find.byType(SecurityLaunchpad), findsOneWidget);
    final launchpadButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Index & Scan'),
    );
    expect(launchpadButton.onPressed, isNull);
    final scanFinder = find.widgetWithText(
      ElevatedButton,
      'Run Vulnerability Scan',
    );
    final scanButton = tester.widget<ElevatedButton>(scanFinder);
    expect(scanButton.onPressed, isNull);
    await tester.tap(scanFinder);
    await tester.pumpAndSettle();
    expect(emptyCodeRepo.lastScanRepoPath, isNull);

    // Now test with an indexed repo: scan enabled + table column header alignment.
    final codeRepo = _FakeCodeIntelRepository();
    final chatVm2 = _StubChatViewModel(ChatState(messages: []));
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm2),
          codeChatViewModelProvider.overrideWith(
              (ref) => _StubChatViewModel(ChatState(messages: []))),
          codeIntelRepositoryProvider.overrideWithValue(codeRepo),
          workspaceModeProvider.overrideWith((ref) => WorkspaceMode.code),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run Vulnerability Scan'));
    await tester.pumpAndSettle();

    expect(find.byType(VulnWorkbenchTable), findsOneWidget);
    expect(find.byType(SecurityQueryBar), findsOneWidget);
    expect(find.text('Security Launchpad'), findsNothing);
    final headerTextFinder = find.text('CVE / PACKAGE');
    expect(headerTextFinder, findsOneWidget);
    final headerContainer = tester.widget<Container>(
      find
          .ancestor(
            of: headerTextFinder,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).border != null,
            ),
          )
          .first,
    );
    expect(headerContainer.margin, isNull);

    final headerRow = tester.widget<Row>(
      find.ancestor(of: headerTextFinder, matching: find.byType(Row)).first,
    );
    final spacerCount = headerRow.children
        .whereType<SizedBox>()
        .where((b) => b.width == 8)
        .length;
    expect(spacerCount, 3);
  });

  group('filterFindingsByQuery', () {
    VulnFinding make({
      required String cveId,
      required String package,
      String? severity,
      bool kev = false,
      double? epss,
      int reachable = 0,
      List<String> cwes = const [],
      String? sourceFile,
    }) {
      return VulnFinding(
        package: package,
        version: '1.0.0',
        ecosystem: 'pypi',
        sourceFile: sourceFile,
        cveId: cveId,
        severity: severity,
        cweIds: cwes,
        matchStatus: 'matched',
        kev: kev,
        epssScore: epss,
        reachableFileCount: reachable,
      );
    }

    final findings = <VulnFinding>[
      make(
        cveId: 'CVE-2024-3094',
        package: 'archive-utils',
        severity: 'CRITICAL',
        kev: true,
        epss: 0.94,
        reachable: 1,
        cwes: const ['CWE-502'],
        sourceFile: 'routes.py',
      ),
      make(
        cveId: 'CVE-2024-21503',
        package: 'black',
        severity: 'LOW',
        epss: 0.12,
      ),
      make(
        cveId: 'CVE-2023-32681',
        package: 'requests',
        severity: 'MEDIUM',
        epss: 0.45,
        reachable: 2,
        cwes: const ['CWE-601'],
        sourceFile: 'client.py',
      ),
    ];

    List<String> ids(List<VulnFinding> result) =>
        result.map((f) => f.cveId).toList();

    test('empty and blank queries return every finding in order', () {
      expect(ids(filterFindingsByQuery(findings, '')),
          ['CVE-2024-3094', 'CVE-2024-21503', 'CVE-2023-32681']);
      expect(ids(filterFindingsByQuery(findings, '   ')),
          ['CVE-2024-3094', 'CVE-2024-21503', 'CVE-2023-32681']);
      expect(findings.length, 3);
    });

    test('is:reachable and is:kev tokens filter structurally', () {
      expect(ids(filterFindingsByQuery(findings, 'is:reachable')),
          ['CVE-2024-3094', 'CVE-2023-32681']);
      expect(ids(filterFindingsByQuery(findings, 'is:kev')), ['CVE-2024-3094']);
      expect(ids(filterFindingsByQuery(findings, 'IS:KEV')), ['CVE-2024-3094']);
    });

    test('severity: token is case-insensitive and exact', () {
      expect(ids(filterFindingsByQuery(findings, 'severity:critical')),
          ['CVE-2024-3094']);
      expect(ids(filterFindingsByQuery(findings, 'Severity:MEDIUM')),
          ['CVE-2023-32681']);
      expect(ids(filterFindingsByQuery(findings, 'severity:high')), isEmpty);
      expect(ids(filterFindingsByQuery(findings, 'severity:low')),
          ['CVE-2024-21503']);
    });

    test('epss: comparisons support >, >=, <, <=, = and bare values', () {
      expect(
          ids(filterFindingsByQuery(findings, 'epss:>0.7')), ['CVE-2024-3094']);
      expect(ids(filterFindingsByQuery(findings, 'epss:>=0.94')),
          ['CVE-2024-3094']);
      expect(ids(filterFindingsByQuery(findings, 'epss:<0.3')),
          ['CVE-2024-21503']);
      expect(ids(filterFindingsByQuery(findings, 'epss:<=0.12')),
          ['CVE-2024-21503']);
      expect(ids(filterFindingsByQuery(findings, 'epss:=0.45')),
          ['CVE-2023-32681']);
      expect(ids(filterFindingsByQuery(findings, 'epss:0.4')),
          ['CVE-2024-3094', 'CVE-2023-32681']);
    });

    test('free text matches CVE, package, CWE, and source file', () {
      expect(
          ids(filterFindingsByQuery(findings, 'archive')), ['CVE-2024-3094']);
      expect(ids(filterFindingsByQuery(findings, 'cve-2024-21503')),
          ['CVE-2024-21503']);
      expect(
          ids(filterFindingsByQuery(findings, 'CWE-601')), ['CVE-2023-32681']);
      expect(
          ids(filterFindingsByQuery(findings, 'routes.py')), ['CVE-2024-3094']);
      expect(ids(filterFindingsByQuery(findings, 'nonexistent')), isEmpty);
    });

    test('combined tokens are ANDed together', () {
      expect(
          ids(filterFindingsByQuery(findings, 'is:reachable severity:medium')),
          ['CVE-2023-32681']);
      expect(ids(filterFindingsByQuery(findings, 'is:kev epss:>0.9 archive')),
          ['CVE-2024-3094']);
      expect(
          ids(filterFindingsByQuery(findings, 'is:kev severity:low')), isEmpty);
      expect(
          ids(filterFindingsByQuery(
              findings, 'is:reachable epss:<0.5 requests')),
          ['CVE-2023-32681']);
    });

    test('malformed epss token falls back to free text and matches nothing',
        () {
      expect(ids(filterFindingsByQuery(findings, 'epss:>abc')), isEmpty);
      expect(ids(filterFindingsByQuery(findings, 'epss:')), isEmpty);
    });
  });

  test('epssBadgeColors differentiates high, moderate, and low EPSS risk tiers',
      () {
    final high = epssBadgeColors(0.94);
    final moderate = epssBadgeColors(0.45);
    final low = epssBadgeColors(0.12);

    expect(high.bg, isNot(equals(moderate.bg)));
    expect(high.bg, isNot(equals(low.bg)));
    expect(moderate.bg, isNot(equals(low.bg)));
    expect(high.text, isNot(equals(low.text)));
  });

  testWidgets(
      'ChatSidebar clears CupertinoActivityIndicator and shows empty state when getThreads resolves empty or throws',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final mockRepo = _MockChatRepository();
    when(() => mockRepo.getThreads()).thenAnswer((_) async => []);

    final realVm = ChatViewModel(
      mockRepo,
      _MockTtsRepository(),
      _MockMemoryRepository(),
      _MockMigrationService(),
    );
    final codeRepo = _FakeCodeIntelRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => realVm),
          codeChatViewModelProvider.overrideWith(
              (ref) => _StubChatViewModel(ChatState(messages: []))),
          codeIntelRepositoryProvider.overrideWithValue(codeRepo),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('No conversations yet'), findsOneWidget);

    when(() => mockRepo.getThreads()).thenThrow(Exception('CORS failure'));
    await realVm.loadThreads();
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('No conversations yet'), findsOneWidget);
  });

  testWidgets(
      'Code Mode isolates its thread from Chat Mode and renders Antigravity-style empty state',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(
      ChatState(
        threadId: 'chat-thread-1',
        messages: [
          ChatMessage(
            id: 'm1',
            role: 'user',
            content: 'whos the ceo of nvidia now?',
          ),
        ],
      ),
    );
    final codeVm = _StubChatViewModel(ChatState(messages: []));
    final codeRepo = _FakeCodeIntelRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
          codeChatViewModelProvider.overrideWith((ref) => codeVm),
          codeIntelRepositoryProvider.overrideWithValue(codeRepo),
          workspaceModeProvider.overrideWith((ref) => WorkspaceMode.code),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Code Mode must NOT show Chat Mode's active conversation.
    expect(
      find.descendant(
        of: find.byType(CodeChatPane),
        matching: find.text('whos the ceo of nvidia now?'),
      ),
      findsNothing,
    );
    // Code Mode shows its Antigravity-inspired empty state.
    expect(find.textContaining('What\'s next?'), findsOneWidget);
    expect(
        find.text('Ask anything about veraxi/custom-service.'), findsOneWidget);
  });
}
