import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';



class MockChatRepository extends Mock implements ChatRepository {}


class MockRef extends Mock implements Ref {}

void main() {
  late MockChatRepository mockRepository;
    late ChatViewModel viewModel;

  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

late ProviderContainer container;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    mockRepository = MockChatRepository();
    when(() => mockRepository.getThreads()).thenAnswer((_) async => []);
    container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(mockRepository),
      ],
    );
    viewModel = container.read(chatViewModelProvider.notifier);
  });

  tearDown(() {
    container.dispose();
  });

  Future<void> pumpEventQueue() => Future.delayed(Duration.zero);

  test('initial state should be empty and not loading', () async {
    await pumpEventQueue();
    expect(container.read(chatViewModelProvider).messages, isEmpty);
    expect(container.read(chatViewModelProvider).isLoading, isFalse);
    expect(container.read(chatViewModelProvider).error, isNull);
  });

  test('sendMessage handles successful stream response', () async {
    await pumpEventQueue();
    const question = 'Hello?';

    when(() => mockRepository.streamChat(question,
            threadId: any(named: 'threadId'),
            model: 'test-model',
            isTemporary: false,
            calculateGrounding: any(named: 'calculateGrounding'),
            toolSettings: any(named: 'toolSettings')))
        .thenAnswer((_) => Stream.fromIterable([
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

    expect(container.read(chatViewModelProvider).messages.length, 2);
    expect(container.read(chatViewModelProvider).messages[1].text, 'Hi there!');
    expect(container.read(chatViewModelProvider).messages[1].isUser, isFalse);
  });

  test('sendMessage ignores empty text', () async {
    await pumpEventQueue();
    await viewModel.sendMessage('   ');

    expect(container.read(chatViewModelProvider).messages, isEmpty);
    verifyNever(() => mockRepository.streamChat(any()));
  });

  test('sendMessage shows error when no model is selected', () async {
    await pumpEventQueue();
    await viewModel.sendMessage('Hello', model: null);

    expect(container.read(chatViewModelProvider).messages.length, 2);
    expect(container.read(chatViewModelProvider).messages[1].isError, isTrue);
    expect(container.read(chatViewModelProvider).messages[1].content,
        'No AI model selected. Please select a model from the top left menu.');
    verifyNever(() => mockRepository.streamChat(any()));
  });

  test(
      'sendMessage handles network disconnection mid-stream and preserves content',
      () async {
    await pumpEventQueue();
    const question = 'Tell me a story';

    when(() => mockRepository.streamChat(any(),
        threadId: any(named: 'threadId'),
        model: 'test-model',
        isTemporary: false,
        calculateGrounding: any(named: 'calculateGrounding'),
        toolSettings: any(named: 'toolSettings'))).thenAnswer((_) async* {
      yield {
        'event': 'on_chat_model_stream',
        'data': {
          'chunk': {'content': 'Once upon '}
        }
      };
      yield {
        'event': 'on_chat_model_stream',
        'data': {
          'chunk': {'content': 'a time'}
        }
      };
      throw Exception('SocketException: Connection refused');
    });

    await viewModel.sendMessage(question, model: 'test-model');

    expect(container.read(chatViewModelProvider).messages.length, 2);
    expect(container.read(chatViewModelProvider).messages[1].isError, isTrue);
    expect(container.read(chatViewModelProvider).messages[1].content, contains('Once upon a time'));
    expect(
        container.read(chatViewModelProvider).messages[1].content,
        contains(
            '[Network connection lost. Please check your internet connection and try again.]'));
  });

  test('sendMessage handles network disconnection with no prior content',
      () async {
    await pumpEventQueue();
    const question = 'Tell me a story';

    when(() => mockRepository.streamChat(any(),
        threadId: any(named: 'threadId'),
        model: 'test-model',
        isTemporary: false,
        calculateGrounding: any(named: 'calculateGrounding'),
        toolSettings: any(named: 'toolSettings'))).thenAnswer((_) async* {
      throw Exception('SocketException: Connection refused');
    });

    await viewModel.sendMessage(question, model: 'test-model');

    expect(container.read(chatViewModelProvider).messages.length, 2);
    expect(container.read(chatViewModelProvider).messages[1].isError, isTrue);
    expect(container.read(chatViewModelProvider).messages[1].content,
        'Network connection lost. Please check your internet connection and try again.');
  });

  test('sendMessage handles tool calls during streaming', () async {
    await pumpEventQueue();
    const question = 'Search graph';

    when(() => mockRepository.streamChat(question,
            threadId: any(named: 'threadId'),
            model: 'test-model',
            isTemporary: false,
            calculateGrounding: any(named: 'calculateGrounding'),
            toolSettings: any(named: 'toolSettings')))
        .thenAnswer((_) => Stream.fromIterable([
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

    expect(container.read(chatViewModelProvider).messages.length, 2);
    expect(container.read(chatViewModelProvider).messages[1].text, 'Result found');
  });

  test('sendMessage extracts artifact during tool end if present', () async {
    await pumpEventQueue();
    const question = 'Search web';

    when(() => mockRepository.streamChat(question,
            threadId: any(named: 'threadId'),
            model: 'test-model',
            isTemporary: false,
            calculateGrounding: any(named: 'calculateGrounding'),
            toolSettings: any(named: 'toolSettings')))
        .thenAnswer((_) => Stream.fromIterable([
              {
                'event': 'on_tool_start',
                'name': 'web_search',
                'run_id': 'run123',
                'data': {'input': {}}
              },
              {
                'event': 'on_tool_end',
                'name': 'web_search',
                'run_id': 'run123',
                'data': {
                  'output': 'some output string',
                  'artifact': [
                    {'title': 'Art1'}
                  ]
                }
              },
              {
                'event': 'on_chat_model_stream',
                'data': {
                  'chunk': {'content': 'Result found'}
                }
              },
            ]));

    await viewModel.sendMessage(question, model: 'test-model');

    expect(container.read(chatViewModelProvider).messages.length, 2);
    expect(container.read(chatViewModelProvider).messages[1].toolEvents.length, 1);
    expect(container.read(chatViewModelProvider).messages[1].toolEvents.first.result, [
      {'title': 'Art1'}
    ]);
  });

  test('regenerateResponse calls repository and selectThread', () async {
    await pumpEventQueue();

    when(() => mockRepository.regenerateResponse(any()))
        .thenAnswer((_) async {});
    when(() => mockRepository.getThreadHistory(any()))
        .thenAnswer((_) async => []);

    // Set threadId to simulate an active thread
    viewModel.setStateForTesting(container.read(chatViewModelProvider).copyWith(threadId: 'test-thread'));

    await viewModel.regenerateResponse();

    verify(() => mockRepository.regenerateResponse('test-thread')).called(1);
    verify(() => mockRepository.getThreadHistory('test-thread')).called(1);
  });



  test('regenerateResponse catches exception and sets error', () async {
    await pumpEventQueue();
    viewModel.setStateForTesting(container.read(chatViewModelProvider).copyWith(threadId: 'test-thread'));

    when(() => mockRepository.regenerateResponse(any()))
        .thenThrow(Exception('Regen Error'));

    await viewModel.regenerateResponse();

    expect(container.read(chatViewModelProvider).error,
        contains('Failed to regenerate response: Exception: Regen Error'));
  });

  test('clearError resets error state', () async {
    await pumpEventQueue();
    
    viewModel.setStateForTesting(container.read(chatViewModelProvider).copyWith(error: 'Some error'));

    // expect(container.read(chatViewModelProvider).error, 'Some error');

    viewModel.clearError();
    expect(container.read(chatViewModelProvider).error, isNull);
  });

  test('toggleTelemetry flips showTelemetry and persists to SharedPreferences',
      () async {
    await pumpEventQueue();

    // Default is false
    expect(container.read(chatViewModelProvider).showTelemetry, isFalse);

    // Toggle ON
    await viewModel.toggleTelemetry();
    expect(container.read(chatViewModelProvider).showTelemetry, isTrue);

    // Verify persistence
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('show_telemetry'), isTrue);

    // Toggle OFF
    await viewModel.toggleTelemetry();
    expect(container.read(chatViewModelProvider).showTelemetry, isFalse);
    expect(prefs.getBool('show_telemetry'), isFalse);
  });




}
