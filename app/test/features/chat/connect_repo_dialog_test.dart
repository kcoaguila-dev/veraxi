import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/chat/data/connect_repo_repository.dart';
import 'package:veraxi_app/features/chat/views/widgets/connect_repo_dialog.dart';

class _FakeConnectRepoRepository extends ConnectRepoRepository {
  final List<String> ingestedPaths = [];

  _FakeConnectRepoRepository() : super(apiClient: ApiClient());

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
    expect(find.text('Enter a local repository directory path.'), findsOneWidget);

    await tester.tap(find.text('Git URL / PAT'));
    await tester.pumpAndSettle();
    expect(find.text('Repository URL'), findsOneWidget);
    expect(find.text('Read-only Token (optional)'), findsOneWidget);

    await tester.tap(find.text('GitHub App'));
    await tester.pumpAndSettle();
    expect(
      find.text('GitHub App (Selected-Repos OAuth) — Coming Soon'),
      findsOneWidget,
    );
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
    await tester.tap(find.text('Connect & Index'));
    await tester.pumpAndSettle();

    expect(find.text('Connect a repository'), findsNothing);
    expect(repo.ingestedPaths, ['/home/ubuntu/src/ai/veraxi']);
  });

  testWidgets('selecting already-indexed repo updates selectedIndexedRepoProvider',
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
}
