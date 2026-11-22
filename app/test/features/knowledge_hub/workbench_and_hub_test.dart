import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/core/providers/model_selection_provider.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/repositories/memory_repository.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/core/widgets/code_lines_view.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/data/local_chat_migration_service.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/chat_screen.dart';
import 'package:veraxi_app/features/knowledge_hub/data/code_intel_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/data/knowledge_hub_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/views/knowledge_hub_screen.dart';

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
    this.streamedSourcePath = 'routes.py',
  }) : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  @override
  Future<List<Map<String, dynamic>>> fetchIndexedRepos() async => reposToReturn;

  @override
  Future<Map<String, dynamic>> fetchIndexedFile(String path) async => {
        'path': path,
        'source': 'file',
        'language': 'python',
        'start_line': 1,
        'line_count': 2,
        'content': 'def ingest_route(upload):\n    return parse_tar(upload)',
      };

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
    yield {'type': 'token', 'content': 'Streamed answer: '};
    yield {'type': 'token', 'content': 'parse_tar reads uploaded bytes.'};
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
      'ChatScreen switches [ Chat | Code ] via sidebar and Cmd/Ctrl+2, streams Ask Veraxi sidecar, and opens code citation',
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

    // Sidebar swaps to Code surfaces and loads live INDEXED REPOS.
    expect(find.text('INTEL & ANALYSIS'), findsOneWidget);
    expect(find.text('Vuln Intel'), findsOneWidget);
    expect(find.text('Repo X-Ray'), findsOneWidget);
    expect(find.text('Security Feed'), findsOneWidget);
    expect(find.text('Corpus Briefing'), findsOneWidget);
    expect(find.text('dbt Lineage'), findsOneWidget);
    expect(find.text('INDEXED REPOS'), findsOneWidget);
    expect(find.text('veraxi/custom-service'), findsNWidgets(2));
    expect(find.text('48 files · 310 symbols'), findsOneWidget);
    expect(find.text('Ask Veraxi'), findsOneWidget);
    expect(
      find.text('Static AST path inferred — verify runtime exposure'),
      findsOneWidget,
    );

    // Run Vuln Scan -> verifies Triage Funnel + aligned desktop table + Ask/Path actions.
    await tester.tap(find.text('Run Vulnerability Scan'));
    await tester.pumpAndSettle();
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
    expect(find.text('Ask'), findsNWidgets(2));
    expect(find.text('Path'), findsOneWidget);

    // Select a model and submit a scoped follow-up via quick chip -> verifies model forwarding, streaming, & line-numbered citation.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );
    await container
        .read(modelSelectionProvider.notifier)
        .selectModel('claude-3.5-sonnet');
    await tester.tap(find.text('What input reaches this symbol?'));
    await tester.pumpAndSettle();
    expect(codeRepo.lastSidecarModel, 'claude-3.5-sonnet');
    expect(find.text('Checked Code Graph · routes.py'), findsOneWidget);
    expect(
      find.text('Streamed answer: parse_tar reads uploaded bytes.'),
      findsOneWidget,
    );
    expect(find.text('routes.py'), findsWidgets);

    await tester.tap(find.text('routes.py').last);
    await tester.pumpAndSettle();
    expect(find.text('routes.py'), findsWidgets);
    expect(find.text('Full file'), findsOneWidget);
    expect(find.text('2 lines · python'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('def ingest_route(upload):'), findsOneWidget);
    expect(find.text('    return parse_tar(upload)'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();

    // Navigate to Repo X-Ray and Security Feed sub-views.
    await tester.tap(find.text('Repo X-Ray'));
    await tester.pumpAndSettle();
    expect(find.text('Repo X-Ray'), findsWidgets);

    await tester.tap(find.text('Security Feed'));
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
      'CodeWorkbenchView uses slide-over Ask Veraxi drawer below 1200px',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(ChatState(messages: []));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
          workspaceModeProvider.overrideWith((ref) => WorkspaceMode.code),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const ChatScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Below 1200px, sidecar is collapsed behind the header button until opened.
    expect(find.text('REACHABILITY PATH · SELECTED ROW'), findsNothing);
    await tester.tap(find.text('Ask Veraxi'));
    await tester.pumpAndSettle();
    expect(find.text('REACHABILITY PATH · SELECTED ROW'), findsOneWidget);
  });

  testWidgets(
      'KnowledgeHubScreen renders 3 tabs, live Indexed Sources, Re-index/Del, and sidebar INGESTION QUEUE',
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
          knowledgeHubRepositoryProvider.overrideWithValue(hubRepo),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const KnowledgeHubScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tab 1: Sources & Ingestion + left rail live queue.
    expect(find.text('Sources & Ingestion'), findsOneWidget);
    expect(find.text('Schema & Extraction'), findsOneWidget);
    expect(find.text('Infra & Monitors'), findsOneWidget);
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

    // Tab 2: Schema & Extraction.
    await tester.tap(find.text('Schema & Extraction'));
    await tester.pumpAndSettle();
    expect(find.text('Information Extraction Rules'), findsOneWidget);

    // Tab 3: Infra & Monitors.
    await tester.tap(find.text('Infra & Monitors'));
    await tester.pumpAndSettle();
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
      'Sidecar Q&A turns persist across 1440x900 -> 1000x800 -> 1440x900 resizes and citation highlights #L1-L2',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final chatVm = _StubChatViewModel(ChatState(messages: []));
    final codeRepo = _FakeCodeIntelRepository(
      streamedSourcePath: 'routes.py#L1-L2',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatViewModelProvider.overrideWith((ref) => chatVm),
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

    await tester.tap(find.text('Run Vulnerability Scan'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('What input reaches this symbol?'));
    await tester.pumpAndSettle();
    expect(
      find.text('Streamed answer: parse_tar reads uploaded bytes.'),
      findsOneWidget,
    );

    // Resize below 1200px: docked sidecar unmounts, narrow header button opens drawer.
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Ask Veraxi · CVE-2024-3094'));
    await tester.pumpAndSettle();
    expect(
      find.text('Streamed answer: parse_tar reads uploaded bytes.'),
      findsOneWidget,
    );

    // Resize back to >= 1200px: docked sidecar still has the turn.
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(
      find.text('Streamed answer: parse_tar reads uploaded bytes.'),
      findsOneWidget,
    );

    // Open #L1-L2 citation and verify Full file badge + highlighted lines.
    await tester.tap(find.text('routes.py#L1-L2'));
    await tester.pumpAndSettle();
    expect(find.text('Full file'), findsOneWidget);
    expect(find.text('Cited lines 1–2 · 2 lines · python'), findsOneWidget);
    final highlightedContainers = tester.widgetList<Container>(
      find.descendant(
        of: find.byType(CodeLinesView),
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.color == CodeLinesView.citedBandColor,
        ),
      ),
    );
    expect(highlightedContainers.length, 2);
  });
}
