import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';
import 'package:veraxi_app/features/chat/view_models/token_usage.dart';
import 'package:veraxi_app/features/chat/views/widgets/token_usage_ring.dart';

ChatMessage assistant(Map<String, dynamic> metrics) =>
    ChatMessage(role: 'assistant', content: 'reply', metrics: metrics);

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

void main() {
  group('summarizeTokenUsage', () {
    test('returns null when no message carries usage', () {
      expect(summarizeTokenUsage(const []), isNull);
      expect(
        summarizeTokenUsage([ChatMessage(role: 'user', content: 'hi')]),
        isNull,
      );
      expect(
        summarizeTokenUsage([
          assistant({'confidence': 0.9})
        ]),
        isNull,
      );
    });

    test('context is the latest prompt count, totals are sums', () {
      final summary = summarizeTokenUsage([
        ChatMessage(role: 'user', content: 'q1'),
        assistant({
          'prompt_tokens': 100,
          'completion_tokens': 20,
          'total_tokens': 120,
          'context_window_tokens': 1000,
          'estimated_cost_usd': 0.001,
        }),
        ChatMessage(role: 'user', content: 'q2'),
        assistant({
          'prompt_tokens': 250,
          'completion_tokens': 30,
          'total_tokens': 280,
          'context_window_tokens': 1000,
          'estimated_cost_usd': 0.002,
        }),
      ])!;
      // Latest prompt (250), NOT the sum (350): each request resends
      // the conversation, so 250 is how full the window is.
      expect(summary.contextTokens, 250);
      expect(summary.contextWindowTokens, 1000);
      expect(summary.contextFraction, 0.25);
      expect(summary.contextTokensRemaining, 750);
      expect(summary.sessionPromptTokens, 350);
      expect(summary.sessionCompletionTokens, 50);
      expect(summary.sessionTotalTokens, 400);
      expect(summary.sessionEstimatedCostUsd, closeTo(0.003, 1e-9));
      expect(summary.hasSessionCost, isTrue);
      expect(summary.responseCount, 2);
      expect(summary.lastTotalTokens, 280);
    });

    test('unknown window yields counts but no fraction', () {
      final summary = summarizeTokenUsage([
        assistant({
          'prompt_tokens': 41203,
          'completion_tokens': 812,
          'total_tokens': 42015,
          'context_window_tokens': null,
        }),
      ])!;
      expect(summary.contextTokens, 41203);
      expect(summary.contextWindowTokens, isNull);
      expect(summary.contextFraction, isNull);
      expect(summary.contextTokensRemaining, isNull);
      expect(summary.hasSessionCost, isFalse);
    });

    test('fraction clamps at 1.0 when prompt exceeds the window', () {
      final summary = summarizeTokenUsage([
        assistant({
          'prompt_tokens': 1500,
          'completion_tokens': 10,
          'total_tokens': 1510,
          'context_window_tokens': 1000,
        }),
      ])!;
      expect(summary.contextFraction, 1.0);
      expect(summary.contextTokensRemaining, 0);
    });

    test('accepts the nested usage map from older payloads', () {
      final summary = summarizeTokenUsage([
        assistant({
          'usage': {
            'prompt_tokens': 10,
            'completion_tokens': 5,
            'total_tokens': 15,
            'context_window_tokens': 100,
          },
        }),
      ])!;
      expect(summary.contextTokens, 10);
      expect(summary.contextFraction, 0.1);
    });

    test('derives total when the provider omitted it', () {
      final summary = summarizeTokenUsage([
        assistant({'prompt_tokens': 10, 'completion_tokens': 5}),
      ])!;
      expect(summary.sessionTotalTokens, 15);
    });
  });

  group('formatTokenCount', () {
    test('compact labels', () {
      expect(formatTokenCount(812), '812');
      expect(formatTokenCount(1500), '1.5k');
      expect(formatTokenCount(41203), '41k');
      expect(formatTokenCount(128000), '128k');
      expect(formatTokenCount(1500000), '1.5M');
    });

    test('full labels use thousands separators', () {
      expect(formatTokenCountFull(812), '812');
      expect(formatTokenCountFull(41203), '41,203');
      expect(formatTokenCountFull(1000000), '1,000,000');
    });
  });

  group('TokenUsageRing', () {
    TokenUsageSummary summaryFor(Map<String, dynamic> metrics) =>
        summarizeTokenUsage([assistant(metrics)])!;

    testWidgets('shows percentage when the window is known', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: TokenUsageRing(
            usage: summaryFor({
              'prompt_tokens': 320,
              'completion_tokens': 10,
              'total_tokens': 330,
              'context_window_tokens': 1000,
            }),
          ),
        ),
      ));
      expect(find.text('32%'), findsOneWidget);
    });

    testWidgets('shows token count on a dashed ring when window unknown',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: TokenUsageRing(
            usage: summaryFor({
              'prompt_tokens': 41203,
              'completion_tokens': 812,
              'total_tokens': 42015,
            }),
          ),
        ),
      ));
      expect(find.text('41k'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('tap opens the breakdown sheet with session totals',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: TokenUsageRing(
            usage: summarizeTokenUsage([
              assistant({
                'prompt_tokens': 100,
                'completion_tokens': 20,
                'total_tokens': 120,
                'context_window_tokens': 1000,
              }),
              assistant({
                'prompt_tokens': 250,
                'completion_tokens': 30,
                'total_tokens': 280,
                'context_window_tokens': 1000,
                'estimated_cost_usd': 0.002,
              }),
            ])!,
          ),
        ),
      ));
      await tester.tap(find.byType(TokenUsageRing));
      await tester.pumpAndSettle();
      expect(find.text('Token Usage'), findsOneWidget);
      expect(find.text('250 of 1,000 tokens · 750 left'), findsOneWidget);
      expect(find.textContaining('Total 400 tokens · 2 responses'),
          findsOneWidget);
      expect(find.text('\$0.0020'), findsWidgets);
    });
  });

  group('TokenUsageIndicatorStyle', () {
    test('fromStorage parses stored values and defaults to ring', () {
      expect(TokenUsageIndicatorStyle.fromStorage('ring'),
          TokenUsageIndicatorStyle.ring);
      expect(TokenUsageIndicatorStyle.fromStorage('bar'),
          TokenUsageIndicatorStyle.bar);
      expect(TokenUsageIndicatorStyle.fromStorage('off'),
          TokenUsageIndicatorStyle.off);
      expect(TokenUsageIndicatorStyle.fromStorage(null),
          TokenUsageIndicatorStyle.ring);
      expect(TokenUsageIndicatorStyle.fromStorage('bogus'),
          TokenUsageIndicatorStyle.ring);
    });
  });

  group('TokenUsageBar', () {
    TokenUsageSummary summaryFor(Map<String, dynamic> metrics) =>
        summarizeTokenUsage([assistant(metrics)])!;

    testWidgets('prints counts and percentage as text', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: TokenUsageBar(
            usage: summaryFor({
              'prompt_tokens': 41203,
              'completion_tokens': 812,
              'total_tokens': 42015,
              'context_window_tokens': 128000,
            }),
          ),
        ),
      ));
      expect(find.text('41,203 / 128,000 · 32%'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(0.322, 0.001));
    });

    testWidgets('unknown window shows the count only, with an empty track',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: TokenUsageBar(
            usage: summaryFor({
              'prompt_tokens': 41203,
              'completion_tokens': 812,
              'total_tokens': 42015,
            }),
          ),
        ),
      ));
      expect(find.text('41,203 tokens'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, 0);
    });

    testWidgets('style switcher in the sheet reports the chosen style',
        (tester) async {
      TokenUsageIndicatorStyle? chosen;
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: TokenUsageBar(
            usage: summaryFor({
              'prompt_tokens': 100,
              'completion_tokens': 10,
              'total_tokens': 110,
              'context_window_tokens': 1000,
            }),
            indicatorStyle: TokenUsageIndicatorStyle.bar,
            onIndicatorStyleChanged: (style) => chosen = style,
          ),
        ),
      ));
      await tester.tap(find.byType(TokenUsageBar));
      await tester.pumpAndSettle();
      expect(find.text('INDICATOR STYLE'), findsOneWidget);
      await tester.tap(find.text('Ring'));
      await tester.pumpAndSettle();
      expect(chosen, TokenUsageIndicatorStyle.ring);
    });
  });

  group('context breakdown aggregation', () {
    test('reads the flattened segment fields from the latest metrics', () {
      final summary = summarizeTokenUsage([
        assistant({
          'prompt_tokens': 1000,
          'completion_tokens': 50,
          'total_tokens': 1050,
          'context_window_tokens': 8000,
          'context_system_tokens': 100,
          'context_tools_tokens': 200,
          'context_tool_results_tokens': 300,
          'context_messages_tokens': 400,
        }),
      ])!;
      expect(summary.hasBreakdown, isTrue);
      expect(summary.contextSystemTokens, 100);
      expect(summary.contextToolsTokens, 200);
      expect(summary.contextToolResultsTokens, 300);
      expect(summary.contextMessagesTokens, 400);
      expect(summary.breakdownTotal, 1000);
    });

    test('payloads without segments have no breakdown', () {
      final summary = summarizeTokenUsage([
        assistant({
          'prompt_tokens': 100,
          'completion_tokens': 5,
          'total_tokens': 105,
        }),
      ])!;
      expect(summary.hasBreakdown, isFalse);
    });

    testWidgets('breakdown sheet renders the segment legend', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: TokenUsageRing(
            usage: summarizeTokenUsage([
              assistant({
                'prompt_tokens': 1000,
                'completion_tokens': 50,
                'total_tokens': 1050,
                'context_window_tokens': 8000,
                'context_system_tokens': 100,
                'context_tools_tokens': 200,
                'context_tool_results_tokens': 300,
                'context_messages_tokens': 400,
              }),
            ])!,
          ),
        ),
      ));
      await tester.tap(find.byType(TokenUsageRing));
      await tester.pumpAndSettle();
      expect(find.text('WHAT FILLS IT · LAST REQUEST'), findsOneWidget);
      expect(find.text('Tool results (incl. retrieved)'), findsOneWidget);
      expect(find.text('300'), findsOneWidget);
    });
  });
}
