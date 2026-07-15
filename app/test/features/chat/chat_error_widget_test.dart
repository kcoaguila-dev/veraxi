import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/chat/data/chat_database.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/chat_screen.dart';

class MockChatRepository extends Mock implements ChatRepository {}
class MockChatDatabase extends Mock implements ChatDatabase {}

void main() {
  late MockChatRepository mockRepository;
  late MockChatDatabase mockDatabase;

  setUp(() {
    mockRepository = MockChatRepository();
    mockDatabase = MockChatDatabase();

    when(() => mockDatabase.getMessages()).thenAnswer((_) async => []);
    when(() => mockDatabase.saveMessage(any(), any())).thenAnswer((_) async {});
  });

  testWidgets('ChatScreen shows error container instead of spinner on timeout', (WidgetTester tester) async {
    when(() => mockRepository.sendMessage(any())).thenThrow(Exception('Connection timeout: Server took too long to respond.'));

    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(mockRepository),
        chatViewModelProvider.overrideWith((ref) => ChatViewModel(mockRepository, mockDatabase)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle(); // Let the database init finish

    // Verify initial state: TextField is visible
    expect(find.byType(TextField), findsOneWidget);

    // Type a message and send it
    await tester.enterText(find.byType(TextField), 'Hello Veraxi');
    await tester.tap(find.byIcon(Icons.arrow_upward));

    // After tapping send, it should show a loading indicator
    // Using pump instead of pumpAndSettle to catch the intermediate loading state
    await tester.pump();

    // We expect the CircularProgressIndicator is present in the tree
    // if we haven't pumped to the end of the error response

    // Wait for the simulated timeout exception to resolve
    await tester.pumpAndSettle();

    // Verify loading indicator is gone
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Verify the error text is visible in ChatInput
    expect(find.textContaining('Connection timeout: Server took too long to respond.'), findsOneWidget);

    // Verify TextField and send button are replaced by error state (we show an error outline icon)
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    // Dismiss error
    await tester.tap(find.byTooltip('Dismiss error'));
    await tester.pumpAndSettle();

    // Verify it goes back to normal input state
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });
}
