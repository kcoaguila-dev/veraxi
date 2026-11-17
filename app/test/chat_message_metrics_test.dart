import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_metrics.dart';

ThemeData testTheme() {
  return ThemeData().copyWith(
    extensions: [
      AppThemeExtension(
        primaryGradientStart: Colors.blue,
        primaryGradientEnd: Colors.blueAccent,
        surfaceHighlight: Colors.grey.shade800,
        sidebarBackground: Colors.black,
        cardBackground: Colors.black54,
        dialogBackground: Colors.black87,
        borderColor: Colors.white24,
        borderColorStrong: Colors.white54,
        textTertiary: Colors.grey,
        iconColor: Colors.white,
      ),
    ],
  );
}

Widget wrapMetrics(Map<String, dynamic> metrics) {
  return MaterialApp(
    theme: testTheme(),
    home: Scaffold(body: ChatMessageMetrics(metrics: metrics)),
  );
}

void main() {
  group('ChatMessageMetrics usage', () {
    testWidgets('shows token usage and cost when present', (tester) async {
      await tester.pumpWidget(wrapMetrics({
        'context_adherence': 0.9,
        'confidence': 0.8,
        'generation_seconds': 1.5,
        'prompt_tokens': 120,
        'completion_tokens': 30,
        'total_tokens': 150,
        'estimated_cost_usd': 0.0012,
      }));
      await tester.pumpAndSettle();

      expect(find.text('CONTEXT ADHERENCE'), findsOneWidget);
      expect(find.text('TOKEN USAGE'), findsOneWidget);
      expect(find.text('150 tokens'), findsOneWidget);
      expect(find.text('Prompt 120 · Completion 30'), findsOneWidget);
      expect(find.text('Est. cost \$0.0012'), findsOneWidget);
    });

    testWidgets('shows tokens without a cost line when cost is null',
        (tester) async {
      await tester.pumpWidget(wrapMetrics({
        'context_adherence': 0.9,
        'prompt_tokens': 10,
        'completion_tokens': 5,
        'total_tokens': 15,
        'estimated_cost_usd': null,
      }));
      await tester.pumpAndSettle();

      expect(find.text('15 tokens'), findsOneWidget);
      expect(find.textContaining('Est. cost'), findsNothing);
    });

    testWidgets('accepts a nested usage map', (tester) async {
      await tester.pumpWidget(wrapMetrics({
        'usage': {
          'prompt_tokens': 7,
          'completion_tokens': 3,
          'total_tokens': 10,
          'estimated_cost_usd': 0.5,
        },
      }));
      await tester.pumpAndSettle();

      expect(find.text('10 tokens'), findsOneWidget);
      expect(find.text('Est. cost \$0.5000'), findsOneWidget);
    });

    testWidgets('no usage tile when the provider reported no usage',
        (tester) async {
      await tester.pumpWidget(wrapMetrics({
        'context_adherence': 0.9,
        'confidence': 0.8,
        'prompt_tokens': null,
        'completion_tokens': null,
        'total_tokens': null,
        'estimated_cost_usd': null,
      }));
      await tester.pumpAndSettle();

      expect(find.text('TOKEN USAGE'), findsNothing);
      expect(find.text('CONTEXT ADHERENCE'), findsOneWidget);
    });
  });
}
