import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/data/code_file_repository.dart';
import 'package:veraxi_app/features/chat/data/code_review_repository.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_review_drawer.dart';

class _FakeCodeReviewRepository extends CodeReviewRepository {
  _FakeCodeReviewRepository() : super(apiClient: ApiClient());

  int fetchCount = 0;
  final List<List<String>> accepted = [];
  final List<List<String>> reverted = [];
  final List<String> committed = [];

  static const _diff = CodeReviewDiff(
    sessionId: 'sess-1',
    turnId: 'turn-1',
    totalAdditions: 1,
    totalDeletions: 1,
    files: [
      CodeReviewDiffFile(
        path: 'backend/retrieval/merge_rank.py',
        language: 'python',
        additions: 1,
        deletions: 1,
        hunks: [
          CodeReviewHunk(
            oldStart: 10,
            newStart: 10,
            lines: [
              '@@ -10,3 +10,3 @@',
              ' context line',
              '-old line',
              '+new line',
            ],
          ),
        ],
      ),
    ],
  );

  @override
  Future<CodeReviewDiff> fetchDiff(String sessionId,
      {String turnId = ''}) async {
    fetchCount++;
    return _diff;
  }

  @override
  Future<void> acceptFiles(String sessionId, List<String> paths) async {
    accepted.add(paths);
  }

  @override
  Future<void> revertFiles(String sessionId, List<String> paths) async {
    reverted.add(paths);
  }

  @override
  Future<void> commit(String sessionId, String message) async {
    committed.add(message);
  }
}

class _FakeCodeFileRepository extends CodeFileRepository {
  _FakeCodeFileRepository() : super(apiClient: ApiClient());

  @override
  Future<CodeFileContent> fetchFile(String path) async {
    const lines = ['line one', 'line two', 'line three'];
    return CodeFileContent(
      path: path,
      source: 'file',
      content: lines.join('\n'),
      lines: lines,
      startLine: 1,
      endLine: 3,
      lineCount: 3,
      language: 'python',
    );
  }
}

void main() {
  late _FakeCodeReviewRepository reviewRepository;
  late WidgetRef capturedRef;

  Widget wrap(CodeReviewState review) {
    return ProviderScope(
      overrides: [
        codeReviewRepositoryProvider.overrideWithValue(reviewRepository),
        codeFileRepositoryProvider
            .overrideWithValue(_FakeCodeFileRepository()),
      ],
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              capturedRef = ref;
              return SizedBox(
                width: 1000,
                height: 700,
                child: CodeReviewDrawer(review: review),
              );
            },
          ),
        ),
      ),
    );
  }

  setUp(() {
    reviewRepository = _FakeCodeReviewRepository();
  });

  group('CodeReviewDrawer sandbox mode', () {
    const review = CodeReviewState(
      sessionId: 'sess-1',
      turnId: 'turn-1',
      turnPrompt: 'Fix the merge ranking',
      files: [
        CodeReviewFileSummary(
          path: 'backend/retrieval/merge_rank.py',
          additions: 1,
          deletions: 1,
        ),
      ],
    );

    testWidgets('shows the turn bar, diff hunks and Agent Edits rail',
        (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();

      expect(reviewRepository.fetchCount, greaterThanOrEqualTo(1));
      expect(find.text('For Turn'), findsOneWidget);
      expect(find.text('Fix the merge ranking'), findsOneWidget);
      expect(find.text('Commit'), findsWidgets);
      expect(find.text('Agent Edits'), findsOneWidget);
      expect(find.text('merge_rank.py'), findsWidgets);
      expect(find.text(' context line'), findsOneWidget);
      expect(find.text('-old line'), findsOneWidget);
      expect(find.text('+new line'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Revert'), findsOneWidget);
      expect(find.byKey(const Key('code-review-read-only-badge')),
          findsNothing);
    });

    testWidgets('Accept posts the file path and refreshes the diff',
        (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();
      final fetchesBefore = reviewRepository.fetchCount;

      await tester.tap(find.byKey(const Key(
          'code-review-accept-backend/retrieval/merge_rank.py')));
      await tester.pumpAndSettle();

      expect(reviewRepository.accepted, [
        ['backend/retrieval/merge_rank.py'],
      ]);
      expect(reviewRepository.fetchCount, greaterThan(fetchesBefore));
    });

    testWidgets('Revert posts the file path', (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key(
          'code-review-revert-backend/retrieval/merge_rank.py')));
      await tester.pumpAndSettle();

      expect(reviewRepository.reverted, [
        ['backend/retrieval/merge_rank.py'],
      ]);
    });

    testWidgets('Commit button opens the dialog and posts the message',
        (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('code-review-commit-button')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const Key('code-review-commit-message-field')),
          findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('code-review-commit-message-field')),
          'feat(retrieval): tighten merge ranking');
      await tester.tap(find.byKey(const Key('code-review-commit-confirm')));
      await tester.pumpAndSettle();

      expect(reviewRepository.committed,
          ['feat(retrieval): tighten merge ranking']);
    });

    testWidgets('close button clears the active review session',
        (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();
      capturedRef.read(activeReviewSessionProvider.notifier).state = review;

      await tester.tap(find.byKey(const Key('code-review-close')));
      await tester.pump();

      expect(capturedRef.read(activeReviewSessionProvider), isNull);
    });

    testWidgets('Esc clears the active review session', (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();
      capturedRef.read(activeReviewSessionProvider.notifier).state = review;

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(capturedRef.read(activeReviewSessionProvider), isNull);
    });
  });

  group('CodeReviewDrawer read-only mode', () {
    const review = CodeReviewState(
      sessionId: '',
      turnId: 'msg-1',
      focusedPath: 'backend/retrieval/merge_rank.py',
      focusedStartLine: 2,
      focusedEndLine: 2,
    );

    testWidgets(
        'shows the cited file and hides every git action (decision b)',
        (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('code-review-read-only-badge')),
          findsOneWidget);
      expect(find.text('Read-only'), findsOneWidget);
      expect(find.text('line one'), findsOneWidget);
      expect(find.text('line two'), findsOneWidget);
      expect(find.text('line three'), findsOneWidget);

      // No dead git buttons in read-only mode.
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Revert'), findsNothing);
      expect(find.text('Commit'), findsNothing);
      expect(find.byKey(const Key('code-review-commit-button')),
          findsNothing);

      // The sandbox diff endpoint is never called without a session.
      expect(reviewRepository.fetchCount, 0);
    });
  });
}
