import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';

class MockChatRepository extends Mock implements ChatRepository {}

void main() {
  late MockChatRepository mockRepository;
  late ChatViewModel viewModel;

  setUp(() {
    mockRepository = MockChatRepository();
    when(() => mockRepository.getThreads()).thenAnswer((_) async => []);
    viewModel = ChatViewModel(mockRepository);
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
    
    when(() => mockRepository.streamChat(question, threadId: any(named: 'threadId')))
        .thenAnswer((_) => Stream.fromIterable([
          {'event': 'on_chat_model_stream', 'data': {'chunk': {'content': 'Hi '}}},
          {'event': 'on_chat_model_stream', 'data': {'chunk': {'content': 'there!'}}},
          {'event': 'on_chain_end', 'name': 'LangGraph'}
        ]));

    final future = viewModel.sendMessage(question);
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
}
