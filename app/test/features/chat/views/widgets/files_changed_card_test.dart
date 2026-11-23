import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/views/widgets/files_changed_card.dart';

const _summary = FilesChangedSummary(
  sessionId: 'sess-1',
  turnId: 'turn-1',
  totalAdditions: 14,
  totalDeletions: 3,
  files: [
    FilesChangedFile(
      path: 'backend/retrieval/merge_rank.py',
      language: 'python',
      additions: 10,
      deletions: 2,
    ),
    FilesChangedFile(
      path: 'backend/tests/test_merge_rank.py',
      language: 'python',
      additions: 4,
      deletions: 1,
    ),
  ],
);

Widget _wrap(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: SizedBox(width: 500, child: child),
      ),
    ),
  );
}

void main() {
  group('FilesChangedSummary.fromJson', () {
    test('parses the Phase 2 diff / files_changed shape', () {
      final summary = FilesChangedSummary.fromJson(const {
        'session_id': 'sess-9',
        'turn_id': 'turn-9',
        'total_additions': 5,
        'total_deletions': 1,
        'files': [
          {
            'path': 'a/b.py',
            'language': 'python',
            'status': 'modified',
            'additions': 5,
            'deletions': 1,
            'hunks': [
              {
                'old_start': 3,
                'new_start': 3,
                'lines': ['@@ -3 +3 @@', '+x'],
              },
            ],
          },
        ],
      });

      expect(summary.sessionId, 'sess-9');
      expect(summary.turnId, 'turn-9');
      expect(summary.files.single.fileName, 'b.py');
      expect(summary.files.single.directory, 'a');
      expect(summary.files.single.hunks.single.oldStart, 3);
      expect(summary.files.single.hunks.single.lines.last, '+x');
    });
  });

  group('FilesChangedCard', () {
    testWidgets('is collapsed by default at strip height with totals',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _wrap(container, const FilesChangedCard(summary: _summary)),
      );

      expect(find.byKey(const Key('files-changed-card')), findsOneWidget);
      expect(find.text('2 files changed'), findsOneWidget);
      expect(find.text('+14 -3'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      // Per-file rows stay hidden until expanded.
      expect(find.text('merge_rank.py'), findsNothing);

      final cardSize =
          tester.getSize(find.byKey(const Key('files-changed-card')));
      // 32px strip + the card's 1px top/bottom borders.
      expect(cardSize.height, lessThan(40));
    });

    testWidgets('expands to per-file rows and collapses again',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _wrap(container, const FilesChangedCard(summary: _summary)),
      );

      await tester.tap(find.byKey(const Key('files-changed-toggle')));
      await tester.pumpAndSettle();

      expect(find.text('merge_rank.py'), findsOneWidget);
      expect(find.text('test_merge_rank.py'), findsOneWidget);
      expect(find.text('backend/retrieval'), findsOneWidget);
      expect(find.text('+10 -2'), findsOneWidget);
      expect(find.text('+4 -1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('files-changed-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('merge_rank.py'), findsNothing);
    });

    testWidgets('Review button opens the review session for the turn',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _wrap(container, const FilesChangedCard(summary: _summary)),
      );

      await tester.tap(find.byKey(const Key('files-changed-review-button')));
      await tester.pump();

      final review = container.read(activeReviewSessionProvider);
      expect(review, isNotNull);
      expect(review!.sessionId, 'sess-1');
      expect(review.turnId, 'turn-1');
      expect(review.focusedPath, isNull);
      expect(review.files.map((f) => f.path), [
        'backend/retrieval/merge_rank.py',
        'backend/tests/test_merge_rank.py',
      ]);
      expect(review.files.first.additions, 10);
    });

    testWidgets('clicking a file row opens the review focused on it',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _wrap(container, const FilesChangedCard(summary: _summary)),
      );

      await tester.tap(find.byKey(const Key('files-changed-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const Key('files-changed-file-backend/tests/test_merge_rank.py')));
      await tester.pump();

      final review = container.read(activeReviewSessionProvider);
      expect(review, isNotNull);
      expect(review!.sessionId, 'sess-1');
      expect(review.focusedPath, 'backend/tests/test_merge_rank.py');
    });
  });
}
