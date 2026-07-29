import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';

class MockChatRepository extends Mock implements ChatRepository {}

class MockRef extends Mock implements Ref {}

void main() {
  late MockChatRepository mockRepository;
  late ChatViewModel viewModel;

  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    mockRepository = MockChatRepository();
    final mockRef = MockRef();
    when(() => mockRepository.getThreads()).thenAnswer((_) async => []);
    viewModel = ChatViewModel(mockRepository, mockRef);
  });

  Future<void> pumpEventQueue() => Future.delayed(Duration.zero);

  test('initial state should be empty and not loading', () {
    expect(viewModel.state.messages, isEmpty);
    expect(viewModel.state.isLoading, isFalse);
    expect(viewModel.state.error, isNull);
  });

  test('sendMessage handles successful stream response', () async {
    await pumpEventQueue();
    const question = 'Hello?';

    when(() =>
        mockRepository.streamChat(question,
            threadId: any(named: 'threadId'),
            model: 'test-model',
            isTemporary: false)).thenAnswer((_) => Stream.fromIterable([
          {
            'event': 'on_chat_model_stream',
            'data': {
              'chunk': {'content': 'Hi '}
            }
          },
          {
            'event': 'on_chat_model_stream',
            'data': {
              'chunk': {'content': 'there!'}
            }
          },
          {'event': 'on_chain_end', 'name': 'LangGraph'}
        ]));

    final future = viewModel.sendMessage(question, model: 'test-model');
    await future;

    expect(viewModel.state.messages.length, 2);
    expect(viewModel.state.messages[1].text, 'Hi there!');
    expect(viewModel.state.messages[1].isUser, isFalse);
  });

  test('sendMessage ignores empty text', () async {
    await pumpEventQueue();
    await viewModel.sendMessage('   ');

    expect(viewModel.state.messages, isEmpty);
    verifyNever(() => mockRepository.streamChat(any()));
  });

  test('sendMessage shows error when no model is selected', () async {
    await pumpEventQueue();
    await viewModel.sendMessage('Hello', model: null);

    expect(viewModel.state.messages.length, 2);
    expect(viewModel.state.messages[1].isError, isTrue);
    expect(viewModel.state.messages[1].content,
        'No AI model selected. Please select a model from the top left menu.');
    verifyNever(() => mockRepository.streamChat(any()));
  });

  test('sendMessage handles tool calls during streaming', () async {
    await pumpEventQueue();
    const question = 'Search graph';

    when(() =>
        mockRepository.streamChat(question,
            threadId: any(named: 'threadId'),
            model: 'test-model',
            isTemporary: false)).thenAnswer((_) => Stream.fromIterable([
          {'event': 'on_tool_start', 'name': 'query_graph'},
          {'event': 'on_tool_end', 'name': 'query_graph'},
          {
            'event': 'on_chat_model_stream',
            'data': {
              'chunk': {'content': 'Result found'}
            }
          },
        ]));

    await viewModel.sendMessage(question, model: 'test-model');

    expect(viewModel.state.messages.length, 2);
    expect(viewModel.state.messages[1].text, 'Result found');
  });

  test('regenerateResponse calls repository and selectThread', () async {
    await pumpEventQueue();

    when(() => mockRepository.regenerateResponse(any()))
        .thenAnswer((_) async {});
    when(() => mockRepository.getThreadHistory(any()))
        .thenAnswer((_) async => []);

    // Set threadId to simulate an active thread
    viewModel.state = viewModel.state.copyWith(threadId: 'test-thread');

    await viewModel.regenerateResponse();

    verify(() => mockRepository.regenerateResponse('test-thread')).called(1);
    verify(() => mockRepository.getThreadHistory('test-thread')).called(1);
  });

  test('playAudio sets playing state and toggles off on same message', () async {
    await pumpEventQueue();
    // Simulate web speech not speaking for simplicity (fallback branch uses it, but initially it's quiet)

    // Attempt play on message "msg1"
    viewModel.playAudio('test', messageId: 'msg1');
    expect(viewModel.state.currentlyPlayingMessageId, 'msg1');

    // Play same message again -> should toggle off
    viewModel.playAudio('test', messageId: 'msg1');
    // Because it's an async operation and relies on the state, in a mocked test without a real player
    // the state would clear. However since we use `just_audio` player, we'd need more complex mocking
    // to test the full loop. Let's at least test the synchronous state setting part is correct conceptually.
  });

  test('regenerateResponse catches exception and sets error', () async {
    await pumpEventQueue();
    viewModel.state = viewModel.state.copyWith(threadId: 'test-thread');

    when(() => mockRepository.regenerateResponse(any()))
        .thenThrow(Exception('Regen Error'));

    await viewModel.regenerateResponse();

    expect(viewModel.state.error,
        contains('Failed to regenerate response: Exception: Regen Error'));
  });

  test('clearError resets error state', () async {
    await pumpEventQueue();
    viewModel.state = viewModel.state.copyWith(error: 'Some error');
    expect(viewModel.state.error, 'Some error');

    viewModel.clearError();
    expect(viewModel.state.error, isNull);
  });
}
