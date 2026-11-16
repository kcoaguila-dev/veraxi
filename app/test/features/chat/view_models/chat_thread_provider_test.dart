import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/view_models/chat_thread_provider.dart';

class MockChatRepository extends Mock implements IChatRepository {
  @override
  Stream<Map<String, dynamic>> streamSyncEvents() => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockChatRepository mockRepository;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockRepository = MockChatRepository();
    container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(mockRepository),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  test('selectThread restores reasoning and its duration', () async {
    when(() => mockRepository.getThreadHistory('thread-1'))
        .thenAnswer((_) async => [
              {
                'id': 'assistant-1',
                'role': 'assistant',
                'content': 'Answer',
                'reasoning': 'deep thought',
                'reasoning_duration_seconds': 4.2,
              },
            ]);

    final viewModel = container.read(chatThreadProvider.notifier);
    await viewModel.selectThread('thread-1');

    final messages = container.read(chatThreadProvider).messages;
    expect(messages, hasLength(1));
    expect(messages.single.reasoning, 'deep thought');
    expect(messages.single.reasoningDurationSeconds, 4.2);
  });

  test('live reasoning events accumulate on the streaming message', () async {
    when(() => mockRepository.getThreads()).thenAnswer((_) async => []);
    when(() => mockRepository.streamChat(any(),
            threadId: any(named: 'threadId'),
            isTemporary: any(named: 'isTemporary'),
            model: any(named: 'model'),
            calculateGrounding: any(named: 'calculateGrounding'),
            toolSettings: any(named: 'toolSettings')))
        .thenAnswer((_) => Stream.fromIterable([
              {
                'event': 'on_reasoning_stream',
                'data': {'text': 'deep '}
              },
              {
                'event': 'on_reasoning_stream',
                'data': {'text': 'thought'}
              },
              {
                'event': 'on_reasoning_end',
                'data': {'seconds': 4.2}
              },
              {
                'event': 'on_chat_model_stream',
                'data': {
                  'chunk': {'content': 'Answer'}
                }
              },
            ]));

    final viewModel = container.read(chatThreadProvider.notifier);
    await viewModel.sendMessage('Hello?', model: 'test-model');

    final messages = container.read(chatThreadProvider).messages;
    expect(messages, hasLength(2));
    expect(messages.last.reasoning, 'deep thought');
    expect(messages.last.reasoningDurationSeconds, 4.2);
    expect(messages.last.content, 'Answer');
  });
}
