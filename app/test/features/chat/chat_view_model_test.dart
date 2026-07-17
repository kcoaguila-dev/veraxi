import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/data/chat_database.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';

class MockChatRepository extends Mock implements ChatRepository {}

class MockChatDatabase extends Mock implements ChatDatabase {}

void main() {
  late MockChatRepository mockRepository;
  late MockChatDatabase mockDatabase;
  late ChatViewModel viewModel;

  setUp(() {
    mockRepository = MockChatRepository();
    mockDatabase = MockChatDatabase();

    // Stub database load history call which happens in the constructor
    when(() => mockDatabase.getMessages()).thenAnswer((_) async => []);
    when(() => mockDatabase.saveMessage(any(), any())).thenAnswer((_) async {});

    viewModel = ChatViewModel(mockRepository, mockDatabase);
  });

  // Helper to ensure async constructor logic completes
  Future<void> pumpEventQueue() => Future.delayed(Duration.zero);

  test('initial state should be empty and not loading', () {
    expect(viewModel.state.messages, isEmpty);
    expect(viewModel.state.isLoading, isFalse);
    expect(viewModel.state.error, isNull);
  });

  test('sendMessage handles successful response', () async {
    await pumpEventQueue();
    const question = 'Hello?';
    const answer = 'Hi there!';

    when(() => mockRepository.sendMessage(question))
        .thenAnswer((_) async => answer);

    final future = viewModel.sendMessage(question);

    // Initial state right after sending (before await finishes)
    expect(viewModel.state.isLoading, isTrue);
    expect(viewModel.state.messages.length, 1);
    expect(viewModel.state.messages[0].text, question);
    expect(viewModel.state.messages[0].isUser, isTrue);

    await future;

    // Final state
    expect(viewModel.state.isLoading, isFalse);
    expect(viewModel.state.messages.length, 2);
    expect(viewModel.state.messages[1].text, answer);
    expect(viewModel.state.messages[1].isUser, isFalse);
    expect(viewModel.state.error, isNull);
  });

  test('sendMessage handles errors gracefully', () async {
    await pumpEventQueue();
    const question = 'Break it?';

    when(() => mockRepository.sendMessage(question))
        .thenThrow(Exception('API error'));

    await viewModel.sendMessage(question);

    expect(viewModel.state.isLoading, isFalse);
    expect(viewModel.state.messages.length, 1);
    expect(viewModel.state.messages[0].text, question);
    expect(viewModel.state.error, contains('API error'));
  });

  test('sendMessage ignores empty text', () async {
    await pumpEventQueue();
    await viewModel.sendMessage('   ');

    expect(viewModel.state.messages, isEmpty);
    verifyNever(() => mockRepository.sendMessage(any()));
  });

  test('clearError resets the error to null without touching messages',
      () async {
    await pumpEventQueue();
    const question = 'Break it?';

    when(() => mockRepository.sendMessage(question))
        .thenThrow(Exception('API error'));

    await viewModel.sendMessage(question);
    expect(viewModel.state.error, isNotNull);

    viewModel.clearError();

    expect(viewModel.state.error, isNull);
    expect(viewModel.state.messages.length, 1);
    expect(viewModel.state.isLoading, isFalse);
  });

  test('clearError is a no-op when there is no error', () async {
    await pumpEventQueue();

    viewModel.clearError();

    expect(viewModel.state.error, isNull);
    expect(viewModel.state.messages, isEmpty);
  });
}
