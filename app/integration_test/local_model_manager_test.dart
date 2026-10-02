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
    // 1. Pump the ModelSelectorMenu inside a MaterialApp with ProviderScope
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          providerModelsProvider.overrideWith((ref) => {
                'Local': ['Llama 3.2 1B (curated)'],
                'Ollama': ['llama3.1:8b'],
              }),
          localGgufModelsProvider.overrideWith((ref) => []),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Center(
              child: ModelSelectorMenu(
                selectedModel: 'gpt-4o',
                onModelSelected: (model) {},
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

    // 3. Find 'Local' provider and open its submenu
    final localProviderText = find.text('Local');
    expect(localProviderText, findsWidgets);

    // Tap the 'Local' text to trigger the submenu
    await tester.tap(localProviderText.last);
    await tester.pumpAndSettle();

    // 4. Verify that "Manage / Download Models" button appears in the submenu
    final manageButton = find.text('Manage / Download Models');
    expect(manageButton, findsOneWidget);

    // 5. Tap the Manage button
    await tester.tap(manageButton);
    await tester.pumpAndSettle();

    // 6. Verify ApiKeyDialog appears with 'Local' properties
    final dialogTitle = find.text('Set API Key for Local');
    expect(dialogTitle, findsOneWidget);

    // 7. Verify the "Model Manager" section is visible
    final modelManagerTitle = find.text('Model Manager (Download & Pull)');
    expect(modelManagerTitle, findsOneWidget);

    // 8. Verify the presence of Llama 3.2 1B curated option
    final llama1B = find.text('Llama 3.2 1B (1.3 GB)');
    expect(llama1B, findsOneWidget);
  });
}
