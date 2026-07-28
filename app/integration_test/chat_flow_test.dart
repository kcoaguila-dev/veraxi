import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/main.dart' as app;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});

  group('End-to-end test', () {
    testWidgets('send message and verify mock response streams in', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: app.VeraxiApp()));
      await tester.pumpAndSettle();
      // We should be on the chat screen.
      // 1. Open the model selector to find the API key settings gear for Google Gemini
      final modelSelector = find.text('gemini-3.5-flash-lite');
      expect(modelSelector, findsOneWidget);
      await tester.tap(modelSelector);
      await tester.pumpAndSettle();

      // Tap the settings icon next to Google
      final geminiItem = find.ancestor(
        of: find.text('Google'),
        matching: find.byType(InkWell),
      ).first;
      
      final geminiSettingsIcon = find.descendant(
        of: geminiItem,
        matching: find.byIcon(Icons.settings_outlined),
      ).first;
      
      await tester.tap(geminiSettingsIcon);
      await tester.pumpAndSettle();

      // 2. The ApiKeyDialog opens, type in a key
      final apiKeyField = find.descendant(
        of: find.byType(Dialog), 
        matching: find.byType(TextField),
      ).first;
      expect(apiKeyField, findsOneWidget);
      await tester.enterText(apiKeyField, "dummy_e2e_key_123");
      await tester.pumpAndSettle();

      // 3. Hit Save
      final saveBtn = find.widgetWithText(TextButton, 'Submit');
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      // 4. Send a message
      final chatInput = find.byType(TextField);
      expect(chatInput, findsOneWidget);
      await tester.enterText(chatInput, "Hello Veraxi");
      await tester.pump();
      
      final sendBtn = find.byIcon(Icons.arrow_upward);
      await tester.tap(sendBtn);
      
      // 5. Wait for the SSE stream response to settle.
      // Our mock server returns a 0.1s delay between chunks, total ~0.8s. pumpAndSettle waits until no new frames are scheduled.
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // 6. Verify the mock response is in the chat list.
      // Our mock server yields "Hello from the Mock LLM Server!"
      final mockResponse = find.textContaining("Mock LLM Server");
      expect(mockResponse, findsOneWidget, reason: 'Mock server response was not displayed in the UI');
    });
  });
}
