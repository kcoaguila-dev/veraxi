import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/core/widgets/code_lines_view.dart';
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
  Future<CodeFileContent> fetchFile(String path, {String? repoKey}) async {
    final isMarkdown = path.endsWith('.md');
    final lines = isMarkdown
        ? const ['# Heading One', '', 'Body text']
        : const ['line one', 'line two', 'line three'];
    return CodeFileContent(
      path: path,
      source: 'file',
      content: lines.join('\n'),
      lines: lines,
      startLine: 1,
      endLine: lines.length,
      lineCount: lines.length,
      language: isMarkdown ? 'markdown' : 'python',
    );
  }
}

void main() {
  late _FakeCodeReviewRepository reviewRepository;
  late WidgetRef capturedRef;

  Widget wrap(CodeReviewState review, {double? maxSplitWidth}) {
    return ProviderScope(
      overrides: [
        codeReviewRepositoryProvider.overrideWithValue(reviewRepository),
        codeFileRepositoryProvider.overrideWithValue(_FakeCodeFileRepository()),
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
                child: CodeReviewDrawer(
                  review: review,
                  maxSplitWidth: maxSplitWidth,
                ),
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
      expect(
          find.byKey(const Key('code-review-read-only-badge')), findsNothing);
    });

    testWidgets('Accept posts the file path and refreshes the diff',
        (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();
      final fetchesBefore = reviewRepository.fetchCount;

      await tester.tap(find.byKey(
          const Key('code-review-accept-backend/retrieval/merge_rank.py')));
      await tester.pumpAndSettle();

      expect(reviewRepository.accepted, [
        ['backend/retrieval/merge_rank.py'],
      ]);
      expect(reviewRepository.fetchCount, greaterThan(fetchesBefore));
    });

    testWidgets('Revert posts the file path', (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(
          const Key('code-review-revert-backend/retrieval/merge_rank.py')));
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
      expect(find.byKey(const Key('code-review-commit-message-field')),
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

    testWidgets('shows the cited file and hides every git action (decision b)',
        (tester) async {
      await tester.pumpWidget(wrap(review));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const Key('code-review-read-only-badge')), findsOneWidget);
      expect(find.text('Read-only'), findsOneWidget);
      expect(find.text('line one'), findsOneWidget);
      expect(find.text('line two'), findsOneWidget);
      expect(find.text('line three'), findsOneWidget);

      // No dead git buttons in read-only mode.
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Revert'), findsNothing);
      expect(find.text('Commit'), findsNothing);
      expect(find.byKey(const Key('code-review-commit-button')), findsNothing);
      expect(
          find.byKey(const Key('code-review-markdown-toggle')), findsNothing);

      // The sandbox diff endpoint is never called without a session.
      expect(reviewRepository.fetchCount, 0);
    });

    testWidgets(
        'markdown file defaults to rendered preview and toggles to raw code',
        (tester) async {
      const mdReview = CodeReviewState(
        sessionId: '',
        turnId: 'msg-2',
        focusedPath: 'README.md',
      );
      await tester.pumpWidget(wrap(mdReview));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const Key('code-review-markdown-toggle')), findsOneWidget);
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.byType(CodeLinesView), findsNothing);
      expect(find.text('Heading One'), findsOneWidget);

      await tester
          .tap(find.byKey(const Key('code-review-markdown-raw-toggle')));
      await tester.pumpAndSettle();

      expect(find.byType(CodeLinesView), findsOneWidget);
      expect(find.byType(MarkdownBody), findsNothing);
      expect(find.text('# Heading One'), findsOneWidget);

      await tester
          .tap(find.byKey(const Key('code-review-markdown-preview-toggle')));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.byType(CodeLinesView), findsNothing);
    });

    testWidgets('line-anchored markdown citation opens in raw mode',
        (tester) async {
      const anchoredMdReview = CodeReviewState(
        sessionId: '',
        turnId: 'msg-3',
        focusedPath: 'README.md',
        focusedStartLine: 3,
        focusedEndLine: 3,
      );
      await tester.pumpWidget(wrap(anchoredMdReview));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const Key('code-review-markdown-toggle')), findsOneWidget);
      expect(find.byType(CodeLinesView), findsOneWidget);
      expect(find.byType(MarkdownBody), findsNothing);
    });

    testWidgets(
        'markdown preview uses explicit light foreground for tables and headings',
        (tester) async {
      const mdReview = CodeReviewState(
        sessionId: '',
        turnId: 'msg-table-contrast',
        focusedPath: 'README.md',
      );
      await tester.pumpWidget(wrap(mdReview));
      await tester.pumpAndSettle();

      final mdBody = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      expect(mdBody.selectable, isFalse);
      expect(
        find.ancestor(
          of: find.byType(MarkdownBody),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
      final sheet = mdBody.styleSheet!;
      expect(sheet.tableHead?.color, Colors.white);
      expect(sheet.tableBody?.color, const Color(0xFFE2E8F0));
      expect(sheet.h4?.color, Colors.white);
      expect(sheet.h5?.color, Colors.white);
      expect(sheet.h6?.color, const Color(0xFFE2E8F0));
      expect(sheet.p?.color, const Color(0xFFE2E8F0));
    });
  });

  group('CodeReviewDrawer resizable width', () {
    const mdReview = CodeReviewState(
      sessionId: '',
      turnId: 'msg-resize',
      focusedPath: 'README.md',
    );

    test('computeReviewPaneWidth clamps within safe bounds', () {
      expect(computeReviewPaneWidth(1400, 0.55), closeTo(770.0, 0.001));
      expect(computeReviewPaneWidth(1400, 0.1), 380.0);
      expect(computeReviewPaneWidth(1400, 0.95), 1020.0);
    });

    testWidgets(
        'hides resize sash and expand button when maxSplitWidth is null',
        (tester) async {
      await tester.pumpWidget(wrap(mdReview));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('code-review-resize-sash')), findsNothing);
      expect(find.byKey(const Key('code-review-expand-button')), findsNothing);
    });

    testWidgets('drag sash widens pane and expand button toggles width',
        (tester) async {
      await tester.pumpWidget(wrap(mdReview, maxSplitWidth: 1600));
      await tester.pumpAndSettle();

      final sash = find.byKey(const Key('code-review-resize-sash'));
      final expand = find.byKey(const Key('code-review-expand-button'));
      expect(sash, findsOneWidget);
      expect(expand, findsOneWidget);

      final initialFraction = capturedRef.read(reviewPaneWidthFractionProvider);
      expect(initialFraction, kDefaultReviewPaneFraction);

      await tester.drag(sash, const Offset(-160, 0));
      await tester.pumpAndSettle();

      expect(
        capturedRef.read(reviewPaneWidthFractionProvider),
        greaterThan(initialFraction),
      );

      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(
        capturedRef.read(reviewPaneWidthFractionProvider),
        kExpandedReviewPaneFraction,
      );

      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(
        capturedRef.read(reviewPaneWidthFractionProvider),
        kDefaultReviewPaneFraction,
      );
    });
  });

  group('resolveMarkdownImageUri', () {
    test('resolves repo-relative and nested paths against GitHub slug', () {
      expect(
        resolveMarkdownImageUri(
          Uri.parse('docs/images/demo.png'),
          markdownFilePath: 'README.md',
          repoKey: 'kcoaguila-dev/veraxi',
        ).toString(),
        'https://raw.githubusercontent.com/kcoaguila-dev/veraxi/HEAD/docs/images/demo.png',
      );
      expect(
        resolveMarkdownImageUri(
          Uri.parse('./images/arch.png'),
          markdownFilePath: 'docs/architecture.md',
          repoKey: 'kcoaguila-dev/veraxi',
        ).toString(),
        'https://raw.githubusercontent.com/kcoaguila-dev/veraxi/HEAD/docs/images/arch.png',
      );
      expect(
        resolveMarkdownImageUri(
          Uri.parse('../assets/logo.png'),
          markdownFilePath: 'docs/sub/guide.md',
          repoKey: 'kcoaguila-dev/veraxi',
        ).toString(),
        'https://raw.githubusercontent.com/kcoaguila-dev/veraxi/HEAD/docs/assets/logo.png',
      );
    });

    test('passes through http/https and rejects traversal or unsafe schemes',
        () {
      expect(
        resolveMarkdownImageUri(
          Uri.parse('https://example.com/pic.png'),
          markdownFilePath: 'README.md',
        ).toString(),
        'https://example.com/pic.png',
      );
      expect(
        resolveMarkdownImageUri(
          Uri.parse('../../etc/passwd'),
          markdownFilePath: 'docs/README.md',
          repoKey: 'kcoaguila-dev/veraxi',
        ),
        isNull,
      );
      expect(
        resolveMarkdownImageUri(
          Uri.parse('file:///etc/passwd'),
          markdownFilePath: 'README.md',
          repoKey: 'kcoaguila-dev/veraxi',
        ),
        isNull,
      );
      expect(
        resolveMarkdownImageUri(
          Uri.parse('docs/images/demo.png'),
          markdownFilePath: 'README.md',
          repoKey: null,
        ),
        isNull,
      );
    });
  });
}
