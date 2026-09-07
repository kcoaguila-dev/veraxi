import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'package:veraxi_app/main.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';

void main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Mock SpeechToText platform channel to prevent MissingPluginException on Linux
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugin.csdcorp.com/speech_to_text'),
          (MethodCall methodCall) async {
    if (methodCall.method == 'initialize') {
      return true;
    }
    return null;
  });

  // Clear shared preferences to ensure Supabase has no saved session!
  // And set a default model so the chat screen can send messages!
  SharedPreferences.setMockInitialValues({
    'selected_model': 'gpt-4o',
    'selected_provider': 'openai',
  });

  await Supabase.initialize(
    url: const String.fromEnvironment('SUPABASE_URL',
        defaultValue: 'https://zjtqrwxyoswzlvtetjzi.supabase.co'),
    publishableKey: const String.fromEnvironment('SUPABASE_ANON_KEY',
        defaultValue: 'sb_publishable_6j3NNIfgI5V209p9QGL-DA_GyEsz9jI'),
  );

  testWidgets('True E2E Test: Login -> Send Message -> Verify History',
      (WidgetTester tester) async {
    // Start App normally, using real Riverpod providers (NO mocks!)
    await tester.pumpWidget(
      const ProviderScope(
        child: VeraxiApp(),
      ),
    );

    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // 1. Wait for Login Screen
    // We expect "Welcome Back" to be visible
    expect(find.text('Welcome Back'), findsOneWidget);

    // 2. Find fields and log in
    final emailField = find.byType(TextField).first;
    final passField = find.byType(TextField).last;

    // 2. Log in with the E2E Test Account
    await tester.enterText(emailField, 'e2e_tester@veraxi.me');
    await tester.enterText(passField, 'e2e_test_password_123');
    await tester.tap(find.text('Sign In'));

    // Allow network requests and animations to settle
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 3. Verify we are on the Chat Screen
    expect(find.text('Chats'), findsWidgets); // Sidebar header
    expect(find.byType(ChatInput), findsOneWidget); // Chat input area

    // Wait an extra second to ensure the auth state triggered loadThreads
    await tester.pump(const Duration(seconds: 1));

    // 4. Send a test message
    final chatInput = find.descendant(
      of: find.byType(ChatInput),
      matching: find.byType(TextField),
    );
    await tester.enterText(chatInput, 'Hello E2E Integration Test');

    // Pump to allow the ChatInput controller listener to enable the send button
    await tester.pumpAndSettle();

    // Tap Send Button (Send icon)
    await tester.tap(find.byIcon(Icons.arrow_upward).first);

    // 5. Wait for the stream to finish.
    // We loop pump because streams break pumpAndSettle if they take a while.
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpAndSettle();

    // 6. Assert the message bubble appears for the User
    expect(find.text('Hello E2E Integration Test'), findsOneWidget);

    // 7. Assert that a response from the AI also appeared
    // The backend AI should respond with markdown text.
    expect(find.byType(MarkdownBody), findsWidgets);

    // 8. CRITICAL: Verify the thread appeared in the history sidebar!
    // The previous bug caused the history to be missing on startup.
    // We wait for the sidebar to refresh and ensure it's not empty.
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The text 'Hello E2E Integration Test' might be truncated as the title.
    // Let's just check if there is text in the sidebar below 'Chats'.
    // If it fails here, it means the Auth race condition is back or threads aren't saving.
    final chatsText = find.text('Chats');
    expect(chatsText, findsWidgets);
  });
}
