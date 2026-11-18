import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/data/deep_cost_repository.dart';
import 'package:veraxi_app/features/chat/views/widgets/deep_cost_preflight.dart';

DeepCostEstimate estimate({DeepCostRange? cost}) {
  return DeepCostEstimate(
    mode: 'deep',
    isEstimate: true,
    label: 'Estimate only',
    model: 'gpt-test',
    specialistAgents: 3,
    maxRounds: 3,
    llmCalls: const DeepCostRange(min: 3, max: 7),
    promptTokens: const DeepCostRange(min: 9000, max: 63000),
    completionTokens: const DeepCostRange(min: 3000, max: 21000),
    totalTokens: const DeepCostRange(min: 12000, max: 84000),
    estimatedCostUsd: cost,
  );
}

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
        iconColor: Colors.white70,
      ),
    ],
  );
}

Widget wrap(Widget child) {
  return MaterialApp(
    theme: testTheme(),
    home: Scaffold(body: child),
  );
}

class FakeDeepCostRepository extends DeepCostRepository {
  FakeDeepCostRepository(this.result)
      : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  final DeepCostEstimate? result;
  String? lastModel;

  @override
  Future<DeepCostEstimate> estimateDeepCost({required String model}) async {
    lastModel = model;
    final value = result;
    if (value == null) throw Exception('offline');
    return value;
  }
}

void main() {
  group('DeepCostEstimate.fromJson', () {
    test('parses backend shape with null cost', () {
      final parsed = DeepCostEstimate.fromJson({
        'mode': 'deep',
        'is_estimate': true,
        'label': 'Estimate only',
        'model': null,
        'specialist_agents': 3,
        'max_rounds': 3,
        'llm_calls': {'min': 3, 'max': 7},
        'prompt_tokens': {'min': 9000, 'max': 63000},
        'completion_tokens': {'min': 3000, 'max': 21000},
        'total_tokens': {'min': 12000, 'max': 84000},
        'estimated_cost_usd': null,
      });
      expect(parsed.totalTokens.min, 12000);
      expect(parsed.totalTokens.max, 84000);
      expect(parsed.estimatedCostUsd, isNull);
    });

    test('parses cost range when priced', () {
      final parsed = DeepCostEstimate.fromJson({
        'llm_calls': {'min': 3, 'max': 7},
        'prompt_tokens': {'min': 1, 'max': 2},
        'completion_tokens': {'min': 1, 'max': 2},
        'total_tokens': {'min': 2, 'max': 4},
        'estimated_cost_usd': {'min': 0.12, 'max': 0.84},
      });
      expect(parsed.estimatedCostUsd?.min, 0.12);
      expect(parsed.estimatedCostUsd?.max, 0.84);
    });
  });

  group('DeepCostPreflightChip', () {
    testWidgets('renders token range and USD range when priced',
        (tester) async {
      await tester.pumpWidget(wrap(DeepCostPreflightChip(
        estimate: estimate(cost: const DeepCostRange(min: 0.12, max: 0.84)),
      )));
      expect(find.text('Deep estimate'), findsOneWidget);
      expect(find.textContaining('12,000–84,000 tokens'), findsOneWidget);
      expect(find.textContaining('\$0.12'), findsOneWidget);
      expect(find.textContaining('\$0.84'), findsOneWidget);
    });

    testWidgets('renders NO dollar figure when pricing is unknown',
        (tester) async {
      await tester.pumpWidget(wrap(DeepCostPreflightChip(
        estimate: estimate(),
      )));
      expect(find.textContaining('12,000–84,000 tokens'), findsOneWidget);
      expect(find.textContaining('\$'), findsNothing);
      expect(find.textContaining('0.00'), findsNothing);
    });
  });

  group('DeepCostPreflight (provider)', () {
    testWidgets('shows chip after estimate loads for the model',
        (tester) async {
      final fake = FakeDeepCostRepository(
        estimate(cost: const DeepCostRange(min: 0.12, max: 0.84)),
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          deepCostRepositoryProvider.overrideWithValue(fake),
        ],
        child: wrap(const DeepCostPreflight(model: 'gpt-test')),
      ));
      // Debounce (300ms) + fetch.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(fake.lastModel, 'gpt-test');
      expect(find.text('Deep estimate'), findsOneWidget);
    });

    testWidgets('renders nothing when the fetch fails', (tester) async {
      final fake = FakeDeepCostRepository(null);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          deepCostRepositoryProvider.overrideWithValue(fake),
        ],
        child: wrap(const DeepCostPreflight(model: 'gpt-test')),
      ));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Deep estimate'), findsNothing);
    });

    testWidgets('renders nothing when no model is selected', (tester) async {
      final fake = FakeDeepCostRepository(estimate());
      await tester.pumpWidget(ProviderScope(
        overrides: [
          deepCostRepositoryProvider.overrideWithValue(fake),
        ],
        child: wrap(const DeepCostPreflight(model: null)),
      ));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(fake.lastModel, isNull);
      expect(find.text('Deep estimate'), findsNothing);
    });
  });
}
