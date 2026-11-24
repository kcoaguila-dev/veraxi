import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/models/model_thinking_capability.dart';
import 'package:veraxi_app/core/providers/thinking_level_provider.dart';
import 'package:veraxi_app/core/widgets/thinking_level_selector.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap(Widget child, Map<String, ModelThinkingCapability> caps) {
    return ProviderScope(
      overrides: [
        modelCapabilitiesProvider.overrideWith((ref) async => caps),
      ],
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('hides selector for non-reasoning model gpt-4o', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ThinkingLevelSelector(selectedModel: 'gpt-4o'),
        {'gpt-4o': ModelThinkingCapability.none},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Thinking:'), findsNothing);
  });

  testWidgets('shows toggle for deepseek-chat and updates per-model state',
      (tester) async {
    await tester.pumpWidget(
      wrap(
        const ThinkingLevelSelector(selectedModel: 'deepseek-chat'),
        {
          'deepseek-chat': const ModelThinkingCapability(
            mode: 'toggle',
            levels: ['off', 'on'],
            defaultLevel: 'off',
            supportsReasoning: true,
          ),
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Thinking: Off'), findsOneWidget);

    await tester.tap(find.text('Thinking: Off'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();
    expect(find.text('Thinking: On'), findsOneWidget);
  });
}
