import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/chat/data/connect_repo_repository.dart';
import 'package:veraxi_app/features/chat/view_models/connect_repo_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/connect_repo_dialog.dart';

class _FakeConnectRepoRepository extends ConnectRepoRepository {
  final List<String> ingestedPaths = [];
  final List<String> indexedGitHubRepos = [];
  final List<bool> indexedAutoSyncFlags = [];
  final List<(String, String)> disconnectedGitHubRepos = [];
  Map<String, dynamic>? stubIndexResponse;
  Map<String, dynamic>? stubPollResponse;
  GitHubAppStatus stubGitHubAppStatus;
  List<GitHubAppRepoItem> stubGitHubAppRepos;

  _FakeConnectRepoRepository({
    this.stubGitHubAppStatus = const GitHubAppStatus(
      configured: true,
      appSlug: 'veraxi-app',
      manageUrl: 'https://github.com/apps/veraxi-app/installations/new',
      installations: [],
    ),
    this.stubGitHubAppRepos = const [],
    this.stubIndexResponse,
    this.stubPollResponse,
  }) : super(apiClient: ApiClient());

  @override
  Future<GitHubAppStatus> fetchGitHubAppStatus() async => stubGitHubAppStatus;

  @override
  Future<List<GitHubAppRepoItem>> fetchGitHubAppRepos({String? query}) async =>
      stubGitHubAppRepos;

  @override
  Future<Map<String, dynamic>> indexGitHubAppRepo({
    required int installationId,
    required String repoFullName,
    String? branch,
    bool autoSyncOnPush = true,
  }) async {
    indexedGitHubRepos.add(repoFullName);
    indexedAutoSyncFlags.add(autoSyncOnPush);
    return stubIndexResponse ??
        {'status': 'ok', 'nodes_written': 25, 'edges_written': 10};
  }

  @override
  Future<Map<String, dynamic>> pollGitHubAppJob(String jobId) async {
    return stubPollResponse ?? {'status': 'complete', 'result': {}};
  }

  @override
  Stream<Map<String, dynamic>> streamGitHubAppJob(String jobId) async* {
    yield await pollGitHubAppJob(jobId);
  }

  @override
  Future<void> disconnectGitHubAppRepo(String owner, String repo) async {
    disconnectedGitHubRepos.add((owner, repo));
  }

  @override
  Future<Map<String, dynamic>> ingestRepo(String repoPath) async {
    ingestedPaths.add(repoPath);
    return {'status': 'ok', 'nodes_written': 42, 'edges_written': 18};
  }

  @override
  Future<List<IndexedRepoItem>> fetchIndexedRepos() async {
    return const [
      IndexedRepoItem(
        repoKey: 'veraxi',
        displayName: 'veraxi',
        rootPath: '/home/ubuntu/src/ai/veraxi',
        fileCount: 120,
        symbolCount: 450,
      ),
    ];
  }
}

Widget _wrapWithHost(
  _FakeConnectRepoRepository repo, {
  List<IndexedRepoItem> initialRepos = const [],
}) {
  return ProviderScope(
    overrides: [
      connectRepoRepositoryProvider.overrideWithValue(repo),
      indexedReposProvider.overrideWith((ref) => initialRepos),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showConnectRepoDialog(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('switches source tabs and validates empty local path',
      (tester) async {
    final repo = _FakeConnectRepoRepository();
    await tester.pumpWidget(_wrapWithHost(repo));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Connect a repository'), findsOneWidget);
    expect(find.text('Repository Directory'), findsOneWidget);

    await tester.tap(find.text('Connect & Index'));
    await tester.pump();
    expect(
        find.text('Enter a local repository directory path.'), findsOneWidget);

    await tester.tap(find.text('Git URL / PAT'));
    await tester.pumpAndSettle();
    expect(find.text('Repository URL'), findsOneWidget);
    expect(find.text('Read-only Token (optional)'), findsOneWidget);

    await tester.tap(find.text('GitHub App'));
    await tester.pumpAndSettle();
    expect(
      find.text('Selected-Repos Read-Only GitHub App'),
      findsOneWidget,
    );
    expect(find.text('Install GitHub App & Select Repos'), findsOneWidget);
  });

  testWidgets('connected GitHub App picker allows selecting and indexing repo',
      (tester) async {
    final repo = _FakeConnectRepoRepository(
      stubGitHubAppStatus: const GitHubAppStatus(
        configured: true,
        appSlug: 'veraxi-app',
        manageUrl: 'https://github.com/apps/veraxi-app/installations/new',
        installations: [
          GitHubAppInstallation(
            installationId: 42,
            accountLogin: 'acme-org',
            accountType: 'Organization',
            repositorySelection: 'selected',
            status: 'active',
          ),
        ],
      ),
      stubGitHubAppRepos: const [
        GitHubAppRepoItem(
          installationId: 42,
          accountLogin: 'acme-org',
          fullName: 'acme-org/api-gateway',
          defaultBranch: 'main',
          isPrivate: true,
          indexStatus: 'available',
          autoSyncOnPush: true,
        ),
      ],
    );

    await tester.pumpWidget(_wrapWithHost(repo));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('GitHub App'));
    await tester.pumpAndSettle();

    expect(find.text('acme-org · 1 repos granted'), findsOneWidget);
    expect(find.text('acme-org/api-gateway'), findsOneWidget);

    await tester.tap(find.text('acme-org/api-gateway'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Connect & Index'));
    await tester.tap(find.text('Connect & Index'));
    await tester.pumpAndSettle();

    expect(find.text('Connect a repository'), findsNothing);
    expect(repo.indexedGitHubRepos, ['acme-org/api-gateway']);
  });

  testWidgets('unconfigured GitHub App server state shows env instructions',
      (tester) async {
    final repo = _FakeConnectRepoRepository(
      stubGitHubAppStatus: const GitHubAppStatus(
        configured: false,
        appSlug: '',
        manageUrl: '',
        installations: [],
      ),
    );
    await tester.pumpWidget(_wrapWithHost(repo));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('GitHub App'));
    await tester.pumpAndSettle();

    expect(
      find.text('GitHub App not configured on this server'),
      findsOneWidget,
    );
    expect(find.text('Use Local Path →'), findsOneWidget);
  });

  testWidgets('submitting local path starts indexing and closes modal',
      (tester) async {
    final repo = _FakeConnectRepoRepository();
    await tester.pumpWidget(_wrapWithHost(repo));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      '/home/ubuntu/src/ai/veraxi',
    );
    await tester.ensureVisible(find.text('Connect & Index'));
    await tester.tap(find.text('Connect & Index'));
    await tester.pumpAndSettle();

    expect(find.text('Connect a repository'), findsNothing);
    expect(repo.ingestedPaths, ['/home/ubuntu/src/ai/veraxi']);
  });

  testWidgets(
      'selecting already-indexed repo updates selectedIndexedRepoProvider',
      (tester) async {
    final repo = _FakeConnectRepoRepository();
    const existing = IndexedRepoItem(
      repoKey: 'veraxi',
      displayName: 'veraxi',
      rootPath: '/home/ubuntu/src/ai/veraxi',
      fileCount: 120,
      symbolCount: 450,
    );
    await tester.pumpWidget(_wrapWithHost(repo, initialRepos: [existing]));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('INDEXED IN WORKSPACE'), findsOneWidget);
    await tester.tap(find.text('Use in chat'));
    await tester.pumpAndSettle();

    expect(find.text('Connect a repository'), findsNothing);
  });

  testWidgets('GitHub App search filter and auto-sync toggle forward flag',
      (tester) async {
    final repo = _FakeConnectRepoRepository(
      stubGitHubAppStatus: const GitHubAppStatus(
        configured: true,
        appSlug: 'veraxi-app',
        manageUrl: 'https://github.com/apps/veraxi-app/installations/new',
        installations: [
          GitHubAppInstallation(
            installationId: 42,
            accountLogin: 'acme',
            accountType: 'Organization',
            repositorySelection: 'selected',
            status: 'active',
          ),
        ],
      ),
      stubGitHubAppRepos: const [
        GitHubAppRepoItem(
          installationId: 42,
          accountLogin: 'acme',
          fullName: 'acme/api-gateway',
          defaultBranch: 'main',
          isPrivate: true,
          indexStatus: 'available',
          autoSyncOnPush: true,
        ),
        GitHubAppRepoItem(
          installationId: 42,
          accountLogin: 'acme',
          fullName: 'acme/web-client',
          defaultBranch: 'main',
          isPrivate: true,
          indexStatus: 'available',
          autoSyncOnPush: true,
        ),
      ],
    );

    await tester.pumpWidget(_wrapWithHost(repo));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub App'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'web');
    await tester.pumpAndSettle();

    expect(find.text('acme/web-client'), findsOneWidget);
    expect(find.text('acme/api-gateway'), findsNothing);

    await tester.tap(find.text('acme/web-client'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Connect & Index'));
    await tester.tap(find.text('Connect & Index'));
    await tester.pumpAndSettle();

    expect(repo.indexedGitHubRepos, ['acme/web-client']);
    expect(repo.indexedAutoSyncFlags, [false]);
  });

  testWidgets('disconnect icon confirms before purging indexed GitHub App repo',
      (tester) async {
    final repo = _FakeConnectRepoRepository(
      stubGitHubAppStatus: const GitHubAppStatus(
        configured: true,
        appSlug: 'veraxi-app',
        manageUrl: 'https://github.com/apps/veraxi-app/installations/new',
        installations: [
          GitHubAppInstallation(
            installationId: 42,
            accountLogin: 'acme-org',
            accountType: 'Organization',
            repositorySelection: 'selected',
            status: 'active',
          ),
        ],
      ),
      stubGitHubAppRepos: const [
        GitHubAppRepoItem(
          installationId: 42,
          accountLogin: 'acme-org',
          fullName: 'acme-org/api-gateway',
          defaultBranch: 'main',
          isPrivate: true,
          indexStatus: 'indexed',
          autoSyncOnPush: true,
        ),
      ],
    );

    await tester.pumpWidget(_wrapWithHost(repo));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub App'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('disconnect_acme-org/api-gateway')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Disconnect acme-org/api-gateway?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(repo.disconnectedGitHubRepos, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('disconnect_acme-org/api-gateway')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect & Purge'));
    await tester.pumpAndSettle();

    expect(repo.disconnectedGitHubRepos, [('acme-org', 'api-gateway')]);
  });

  testWidgets('ConnectRepoViewModel surfaces failed ARQ job cleanly',
      (tester) async {
    final repo = _FakeConnectRepoRepository(
      stubIndexResponse: {'status': 'queued', 'job_id': 'j1'},
      stubPollResponse: {
        'status': 'failed',
        'error': 'Archive exceeds limit',
      },
    );
    final container = ProviderContainer(
      overrides: [
        connectRepoRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    const targetRepo = GitHubAppRepoItem(
      installationId: 42,
      accountLogin: 'acme-org',
      fullName: 'acme-org/api-gateway',
      defaultBranch: 'main',
      isPrivate: true,
      indexStatus: 'available',
      autoSyncOnPush: true,
    );

    final future = container
        .read(connectRepoViewModelProvider.notifier)
        .startGitHubAppIndexing(targetRepo);

    await tester.pump(const Duration(seconds: 3));
    await future;

    final state = container.read(connectRepoViewModelProvider);
    expect(state.indexing, isFalse);
    expect(state.errorMessage, contains('acme-org/api-gateway'));
  });

  testWidgets('multi-installation header displays total active accounts count',
      (tester) async {
    final repo = _FakeConnectRepoRepository(
      stubGitHubAppStatus: const GitHubAppStatus(
        configured: true,
        appSlug: 'veraxi-app',
        manageUrl: 'https://github.com/apps/veraxi-app/installations/new',
        installations: [
          GitHubAppInstallation(
            installationId: 1,
            accountLogin: 'octocat',
            accountType: 'User',
            repositorySelection: 'selected',
            status: 'active',
          ),
          GitHubAppInstallation(
            installationId: 2,
            accountLogin: 'acme-org',
            accountType: 'Organization',
            repositorySelection: 'selected',
            status: 'active',
          ),
        ],
      ),
      stubGitHubAppRepos: const [
        GitHubAppRepoItem(
          installationId: 1,
          accountLogin: 'octocat',
          fullName: 'octocat/hello-world',
          defaultBranch: 'main',
          isPrivate: false,
          indexStatus: 'available',
          autoSyncOnPush: true,
        ),
      ],
    );

    await tester.pumpWidget(_wrapWithHost(repo));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub App'));
    await tester.pumpAndSettle();

    expect(find.text('2 accounts · 1 repos granted'), findsOneWidget);
  });

  test('friendlyGitHubAppAuthError maps allowlisted callback error codes', () {
    expect(
      ConnectRepoViewModel.friendlyGitHubAppAuthError('invalid_app_config'),
      contains('GITHUB_APP_CLIENT_ID'),
    );
    expect(
      ConnectRepoViewModel.friendlyGitHubAppAuthError('state_expired'),
      contains('expired'),
    );
    expect(
      ConnectRepoViewModel.friendlyGitHubAppAuthError('missing_params'),
      contains('Request user authorization'),
    );
    expect(
      ConnectRepoViewModel.friendlyGitHubAppAuthError('access_denied'),
      contains('denied'),
    );
    expect(
      ConnectRepoViewModel.friendlyGitHubAppAuthError('oauth_failed'),
      'GitHub App authorization failed (oauth_failed).',
    );
  });

  test('hydrateActiveIndexing resumes in-flight GitHub App indexing on reload',
      () async {
    var pollCount = 0;
    final repo = _FakeConnectRepoRepository(
      stubGitHubAppStatus: const GitHubAppStatus(
        configured: true,
        appSlug: 'veraxi-app',
        manageUrl: 'https://github.com/apps/veraxi-app/installations/new',
        installations: [
          GitHubAppInstallation(
            installationId: 42,
            accountLogin: 'acme-org',
            accountType: 'Organization',
            repositorySelection: 'selected',
            status: 'active',
          ),
        ],
      ),
      stubGitHubAppRepos: const [
        GitHubAppRepoItem(
          installationId: 42,
          accountLogin: 'acme-org',
          fullName: 'acme-org/api-gateway',
          defaultBranch: 'main',
          isPrivate: true,
          autoSyncOnPush: true,
          indexStatus: 'indexing',
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        connectRepoRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(connectRepoViewModelProvider.notifier);
    final future = notifier.hydrateActiveIndexing();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(connectRepoViewModelProvider).indexing, isTrue);
    expect(
      container.read(connectRepoViewModelProvider).activeTarget,
      'acme-org/api-gateway',
    );

    pollCount++;
    repo.stubGitHubAppRepos = const [
      GitHubAppRepoItem(
        installationId: 42,
        accountLogin: 'acme-org',
        fullName: 'acme-org/api-gateway',
        defaultBranch: 'main',
        isPrivate: true,
        autoSyncOnPush: true,
        indexStatus: 'indexed',
      ),
    ];

    await future;
    expect(pollCount, 1);
    expect(container.read(connectRepoViewModelProvider).indexing, isFalse);
    expect(
      container.read(connectRepoViewModelProvider).statusMessage,
      'Indexed acme-org/api-gateway',
    );
  });
}
