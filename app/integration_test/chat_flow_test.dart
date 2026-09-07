import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

import 'package:veraxi_app/main.dart';
import 'package:veraxi_app/core/router.dart';
import 'package:veraxi_app/features/auth/data/auth_repository.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

class MockChatRepository extends Mock implements ChatRepository {}

class MockUser extends Mock implements User {}

void main() {
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

  late MockAuthRepository mockAuthRepo;
  late MockChatRepository mockChatRepo;
  late StreamController<AuthState> authStateController;

  setUp(() {
    mockAuthRepo = MockAuthRepository();
    mockChatRepo = MockChatRepository();
    authStateController = StreamController<AuthState>.broadcast();

    when(() => mockAuthRepo.authStateChanges)
        .thenAnswer((_) => authStateController.stream);

    when(() => mockAuthRepo.currentUser).thenReturn(null);

    when(() => mockChatRepo.getProviderModels()).thenAnswer((_) async => {
          'OpenAI': ['gpt-4o', 'gpt-4o-mini'],
          'Anthropic': ['Claude 3.5 Sonnet', 'Claude 3 Opus'],
          'Google': ['gemini-1.5-pro']
        });

    when(() => mockChatRepo.getThreads()).thenAnswer((_) async => []);

    when(() => mockChatRepo.getThreadHistory(any()))
        .thenAnswer((_) async => []);

    when(() => mockChatRepo.streamChat(
          any(),
          threadId: any(named: 'threadId'),
          isTemporary: any(named: 'isTemporary'),
          model: any(named: 'model'),
          calculateGrounding: any(named: 'calculateGrounding'),
          toolSettings: any(named: 'toolSettings'),
        )).thenAnswer((invocation) async* {
      yield {'type': 'content', 'content': 'Hello from Mock API!'};
      yield {'type': 'done'};
    });
  });

  tearDown(() {
    authStateController.close();
  });

  testWidgets('E2E Chat Flow: Login -> Chat -> Change Model',
      (WidgetTester tester) async {
    // 1. Bypass Supabase Initialization by setting mockIsAuth = false initially (unauthenticated)
    mockIsAuth = false;

    // Start App with overridden providers
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(mockAuthRepo),
          chatRepositoryProvider.overrideWithValue(mockChatRepo),
        ],
        child: const VeraxiApp(),
      ),
    );

    await tester.pumpAndSettle();

    // 2. Assert we are on the Login Screen
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2)); // Email and Password

    // Mock SignIn interaction
    when(() => mockAuthRepo.signInWithEmail(any(), any()))
        .thenAnswer((_) async {
      // Simulate successful login by emitting an auth event and changing the mockAuth
      final mockUser = MockUser();
      when(() => mockUser.id).thenReturn('mock_user_123');
      when(() => mockUser.email).thenReturn('test@example.com');
      when(() => mockAuthRepo.currentUser).thenReturn(mockUser);

      final mockSession = Session(
        accessToken: 'mock_access_token',
        expiresIn: 3600,
        refreshToken: 'mock_refresh_token',
        tokenType: 'bearer',
        user: mockUser,
      );

      mockIsAuth = true; // Tell router to allow access
      authStateController.add(AuthState(AuthChangeEvent.signedIn, mockSession));
    });

    // Enter credentials
    await tester.enterText(find.byType(TextField).first, 'test@example.com');
    await tester.enterText(find.byType(TextField).last, 'password123');

    // Tap Sign In button
    await tester.tap(find.text('Sign In'));

    // Allow the router redirect and animations to settle
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // 3. Assert we are on the Chat Screen
    expect(find.text('Chats'), findsOneWidget); // Sidebar thread list
    expect(find.text('Ask anything...'), findsOneWidget); // Chat input

    // 4. Test Model Provider Selector
    // By default, OpenAI is selected (Select a model / OpenAI)
    // Tap the model selector pill to open the dropdown
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down).first);
    await tester.pumpAndSettle();

    // Tap the 'Anthropic' provider row to reveal models
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();

    // Select Anthropic model
    await tester.tap(find.text('Claude 3.5 Sonnet').last);
    await tester.pumpAndSettle();

    // 5. Test Sending a message
    await tester.enterText(find.byType(TextField).last, 'Write me a poem');
    // Tap Send Button (Send icon)
    await tester.tap(find.byIcon(Icons.send_rounded).first);
    await tester.pump(); // Start the send process

    // Wait for stream to emit
    await tester.pumpAndSettle();

    // Assert the mocked response appears
    expect(find.text('Write me a poem'), findsOneWidget); // User message
    expect(find.text('Hello from Mock API!'), findsOneWidget); // Bot response
  });
}
