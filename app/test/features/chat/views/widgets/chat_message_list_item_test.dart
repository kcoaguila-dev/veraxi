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
}
