import "package:veraxi_app/core/theme.dart";
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/widgets/model_selector_menu.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/model_download_provider.dart';

void main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Local Model Manager Test', (WidgetTester tester) async {
    String? selectedModelFromCallback;

    // 1. Pump the ModelSelectorMenu inside a MaterialApp with ProviderScope
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          providerModelsProvider.overrideWith((ref) => {
                'Local': ['Llama 3.2 1B (curated)'],
                'Ollama': ['llama3.1:8b'],
              }),
          localGgufModelsProvider.overrideWith((ref) => ['llama-3.2-1b-instruct-q8_0.gguf']),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Center(
              child: ModelSelectorMenu(
                selectedModel: 'gpt-4o',
                onModelSelected: (model) {
                  selectedModelFromCallback = model;
                },
                pinnedModels: const [],
                child: const Text("Tap me"),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 2. Find and tap the ModelSelectorMenu
    final modelSelector = find.byType(ModelSelectorMenu);
    expect(modelSelector, findsOneWidget);
    await tester.tap(modelSelector);
    await tester.pumpAndSettle();

    // 3. Find 'Local' provider row
    final localProviderText = find.text('Local');
    expect(localProviderText, findsWidgets);

    // 4. Tap the settings icon on the Local provider row to open ApiKeyDialog
    final settingsIcon = find.descendant(
      of: find.ancestor(
        of: localProviderText.last,
        matching: find.byType(Row),
      ),
      matching: find.byIcon(Icons.settings_outlined),
    );
    expect(settingsIcon, findsOneWidget);

    // 5. Tap the settings icon
    await tester.tap(settingsIcon);
    await tester.pumpAndSettle();

    // 6. Verify ApiKeyDialog appears with 'Local' properties
    final dialogTitle = find.text('Set API Key for Local');
    expect(dialogTitle, findsOneWidget);

    // 7. Verify the "Model Manager" section is visible
    final modelManagerTitle = find.text('Model Manager (Download & Pull)');
    expect(modelManagerTitle, findsOneWidget);

    // 8. Verify the presence of Llama 3.2 1B curated option
    final llama1B = find.text('Llama 3.2 1B');
    expect(llama1B, findsOneWidget);

    // 10. Tap the Select button next to the downloaded model
    // The Select button is in the same Row as the model name
    final selectButton = find.descendant(
      of: find.ancestor(
        of: llama1B,
        matching: find.byType(Row),
      ),
      matching: find.text('Select'),
    );
    expect(selectButton, findsOneWidget);
    await tester.tap(selectButton);
    await tester.pumpAndSettle();

    // 11. Tap Save
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // 12. Verify onModelSelected was called with the model name
    expect(selectedModelFromCallback, 'llama-3.2-1b-instruct-q8_0.gguf');
  });
}
