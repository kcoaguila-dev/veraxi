import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/views/widgets/compaction_divider.dart';
import 'package:veraxi_app/features/chat/views/widgets/compaction_sheet.dart';

ChatMessage summaryMessage() => ChatMessage(
      role: 'user',
      content: '[Conversation summary — earlier messages were compacted]\n\n'
          '## Goal\nShip the thing.',
      metrics: const {
        'compaction': {
          'messages_compacted': 12,
          'compacted_at': '2026-11-20T00:00:00Z',
          'tokens_before': 42000,
        },
      },
    );

void main() {
  group('CompactionDivider', () {
    test('detects compaction summary messages only', () {
      expect(CompactionDivider.isCompactionMessage(summaryMessage()), isTrue);
      expect(
        CompactionDivider.isCompactionMessage(
            ChatMessage(role: 'user', content: 'hello')),
        isFalse,
      );
      expect(
        CompactionDivider.isCompactionMessage(ChatMessage(
            role: 'assistant',
            content: 'hi',
            metrics: const {'prompt_tokens': 5})),
        isFalse,
      );
    });

    testWidgets('renders the divider label with the compacted count',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CompactionDivider(message: summaryMessage())),
      ));
      expect(
        find.text('Conversation compacted · 12 messages summarized'),
        findsOneWidget,
      );
    });

    testWidgets('tap opens the summary without the machine prefix',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CompactionDivider(message: summaryMessage())),
      ));
      await tester.tap(find.text('Conversation compacted · 12 messages summarized'));
      await tester.pumpAndSettle();
      expect(find.text('Conversation summary'), findsOneWidget);
      expect(find.textContaining('Ship the thing.'), findsOneWidget);
      expect(find.textContaining('[Conversation summary'), findsNothing);
    });
  });

  group('compaction sheet flow', () {
    testWidgets('preview is editable and apply sends the edited text',
        (tester) async {
      String? applied;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCompactionSheet(
                context,
                onPreview: () async => {
                  'summary': 'original summary',
                  'messages_compacted': 9,
                  'tokens_before': 40000,
                  'tokens_after_estimate': 9000,
                },
                onApply: (summary) async => applied = summary,
                onClearToolResults: () async => {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('original summary'), findsOneWidget);
      expect(find.textContaining('9 messages'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'edited summary');
      await tester.tap(find.text('Compact'));
      await tester.pumpAndSettle();
      expect(applied, 'edited summary');
    });

    testWidgets('preview failure shows the server reason, applies nothing',
        (tester) async {
      var applyCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCompactionSheet(
                context,
                onPreview: () async =>
                    throw Exception('Nothing old enough to compact yet.'),
                onApply: (_) async => applyCalls++,
                onClearToolResults: () async => {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing old enough to compact yet.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Compact'), findsOneWidget);
      final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Compact'));
      expect(button.onPressed, isNull);
      expect(applyCalls, 0);
    });
  });
}
