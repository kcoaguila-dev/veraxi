import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_list_item.dart';

void main() {
  Widget wrap(Widget child) {
    final theme = AppTheme.darkTheme;
    return ProviderScope(
      child: MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SizedBox(width: 900, child: child),
        ),
      ),
    );
  }

  testWidgets('user message is right-aligned without name or person icon',
      (tester) async {
    final theme = AppTheme.darkTheme;
    final ext = theme.extension<AppThemeExtension>()!;
    final msg = ChatMessage(
      role: 'user',
      content: 'give me hello world webpage',
    );

    await tester.pumpWidget(
      wrap(
        ChatMessageListItem(
          msg: msg,
          theme: theme,
          ext: ext,
          showTelemetry: false,
        ),
      ),
    );

    expect(find.text('give me hello world webpage'), findsOneWidget);
    expect(find.text('User'), findsNothing);
    expect(find.byIcon(Icons.person), findsNothing);

    final align = tester.widget<Align>(find.byType(Align).first);
    expect(align.alignment, Alignment.centerRight);

    final textBox = tester.getRect(find.text('give me hello world webpage'));
    expect(textBox.center.dx, greaterThan(450));
  });

  testWidgets('assistant message shows model name on the left', (tester) async {
    final theme = AppTheme.darkTheme;
    final ext = theme.extension<AppThemeExtension>()!;
    final msg = ChatMessage(
      role: 'assistant',
      content: 'Here is a minimal webpage.',
      modelName: 'openai/gpt-oss-20b',
    );

    await tester.pumpWidget(
      wrap(
        ChatMessageListItem(
          msg: msg,
          theme: theme,
          ext: ext,
          showTelemetry: false,
        ),
      ),
    );

    expect(find.text('openai/gpt-oss-20b'), findsOneWidget);
    final nameBox = tester.getRect(find.text('openai/gpt-oss-20b'));
    expect(nameBox.left, lessThan(450));
  });

  testWidgets('assistant markdown headings render in light foreground',
      (tester) async {
    final theme = AppTheme.darkTheme;
    final ext = theme.extension<AppThemeExtension>()!;
    final msg = ChatMessage(
      role: 'assistant',
      content: '# Big Title\n\n## Section\n\n### Subsection\n\nBody text.',
    );

    await tester.pumpWidget(
      wrap(
        ChatMessageListItem(
          msg: msg,
          theme: theme,
          ext: ext,
          showTelemetry: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    TextStyle? styleFor(String text) {
      TextStyle? search(InlineSpan span, TextStyle? inherited) {
        if (span is! TextSpan) return null;
        final effective =
            inherited == null ? span.style : inherited.merge(span.style);
        if (span.text == text) return effective;
        for (final child in span.children ?? const <InlineSpan>[]) {
          final found = search(child, effective);
          if (found != null) return found;
        }
        return null;
      }

      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        final found = search(rich.text, null);
        if (found != null) return found;
      }
      return null;
    }

    for (final heading in ['Big Title', 'Section', 'Subsection']) {
      final style = styleFor(heading);
      expect(style, isNotNull, reason: '$heading not rendered');
      expect(style!.color, Colors.white,
          reason: '$heading must not be dark-on-dark');
      expect(style.fontWeight, isIn([FontWeight.w600, FontWeight.w700]));
    }
  });

  group('formatRelativeTimestamp', () {
    final now = DateTime(2026, 11, 17, 12, 0, 0);

    test('shows just now for the entire first minute', () {
      expect(
        formatRelativeTimestamp(now.subtract(const Duration(seconds: 5)),
            now: now),
        'just now',
      );
      expect(
        formatRelativeTimestamp(now.subtract(const Duration(seconds: 45)),
            now: now),
        'just now',
      );
    });

    test('shows minutes, hours, days, and calendar dates', () {
      expect(
        formatRelativeTimestamp(now.subtract(const Duration(minutes: 5)),
            now: now),
        '5m ago',
      );
      expect(
        formatRelativeTimestamp(now.subtract(const Duration(hours: 3)),
            now: now),
        '3h ago',
      );
      expect(
        formatRelativeTimestamp(now.subtract(const Duration(days: 4)),
            now: now),
        '4d ago',
      );
      expect(
        formatRelativeTimestamp(now.subtract(const Duration(days: 10)),
            now: now),
        'Nov 7',
      );
      expect(
        formatRelativeTimestamp(DateTime(2025, 11, 7, 12, 0, 0), now: now),
        'Nov 7, 2025',
      );
    });
  });

  group('nextRelativeTimestampDelay', () {
    final now = DateTime(2026, 11, 17, 12, 0, 0);

    test('waits until the 60s boundary instead of ticking every second', () {
      expect(
        nextRelativeTimestampDelay(
          now.subtract(const Duration(seconds: 15)),
          now: now,
        ),
        const Duration(seconds: 45),
      );
    });

    test('returns null once the message is at least 7 days old', () {
      expect(
        nextRelativeTimestampDelay(
          now.subtract(const Duration(days: 7)),
          now: now,
        ),
        isNull,
      );
    });
  });

  group('retrieval coverage banners', () {
    testWidgets('shows no-solid-evidence banner when retrieval returns 0 hits',
        (tester) async {
      final theme = AppTheme.darkTheme;
      final ext = theme.extension<AppThemeExtension>()!;
      final msg = ChatMessage(
        role: 'assistant',
        content: 'I could not find indexed documents matching your query.',
        toolEvents: [
          ToolEvent(
            id: 't1',
            name: 'search_vectors',
            isComplete: true,
            result: const [],
          ),
        ],
      );

      await tester.pumpWidget(
        wrap(
          ChatMessageListItem(
            msg: msg,
            theme: theme,
            ext: ext,
            showTelemetry: false,
          ),
        ),
      );

      expect(
        find.byKey(const Key('no-solid-evidence-banner')),
        findsOneWidget,
      );
      expect(
        find.text('No solid evidence found in indexed sources'),
        findsOneWidget,
      );
    });

    testWidgets(
        'shows low-evidence banner when all hits score below 0.015 threshold',
        (tester) async {
      final theme = AppTheme.darkTheme;
      final ext = theme.extension<AppThemeExtension>()!;
      final msg = ChatMessage(
        role: 'assistant',
        content: 'Here is a tentative match.',
        toolEvents: [
          ToolEvent(
            id: 't1',
            name: 'merge_rank',
            isComplete: true,
            result: const [
              {
                'title': 'Weak note',
                'provenance': {
                  'legs': ['vector'],
                  'fused_score': 0.011
                },
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        wrap(
          ChatMessageListItem(
            msg: msg,
            theme: theme,
            ext: ext,
            showTelemetry: false,
          ),
        ),
      );

      expect(find.byKey(const Key('low-evidence-banner')), findsOneWidget);
      expect(
        find.text('Low-confidence retrieval match — verify cited lines'),
        findsOneWidget,
      );
    });

    testWidgets('hides coverage banners when high or medium hits exist',
        (tester) async {
      final theme = AppTheme.darkTheme;
      final ext = theme.extension<AppThemeExtension>()!;
      final msg = ChatMessage(
        role: 'assistant',
        content: 'Here is a well-grounded answer.',
        toolEvents: [
          ToolEvent(
            id: 't1',
            name: 'merge_rank',
            isComplete: true,
            result: const [
              {
                'title': 'Strong source',
                'provenance': {
                  'legs': ['vector', 'graph'],
                  'fused_score': 0.032
                },
              },
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        wrap(
          ChatMessageListItem(
            msg: msg,
            theme: theme,
            ext: ext,
            showTelemetry: false,
          ),
        ),
      );

      expect(find.byKey(const Key('no-solid-evidence-banner')), findsNothing);
      expect(find.byKey(const Key('low-evidence-banner')), findsNothing);
    });
  });
}
