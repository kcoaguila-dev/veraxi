import 'package:veraxi_app/core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/features/chat/views/widgets/api_key_dialog.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('ApiKeyDialog saves key on Submit', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Center(child: ApiKeyDialog(providerName: 'Gemini')),
        ),
      ),
    ));

    // Wait for the dialog to fully load (and for getGeminiKey() Future to resolve)
    await tester.pumpAndSettle();

    // Verify dialog shows
    expect(find.text('Set API Key for Gemini'), findsOneWidget);

    // Enter a dummy API key
    await tester.enterText(find.byType(TextField), 'dummy_gemini_key_123');
    await tester.pump();

    // Tap Save
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Verify it was saved to storage
    final savedKey = await ApiKeyStorage().getKey('Gemini');
    expect(savedKey, 'dummy_gemini_key_123');
  });

  testWidgets('ApiKeyDialog triggers onModelSaved for local provider',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;

    String? savedModel;

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Center(
              child: ApiKeyDialog(
            providerName: 'local',
            onModelSaved: (m) => savedModel = m,
          )),
        ),
      ),
    ));

    await tester.pumpAndSettle();

    // Enter a local model name
    final modelNameField = find.widgetWithText(TextField, 'llama3.1');
    await tester.enterText(modelNameField, 'my-local-model.gguf');
    await tester.pump();

    // Tap Save
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(savedModel, 'my-local-model.gguf');
  });
}
