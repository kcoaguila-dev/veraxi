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

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
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

    when(() =>
        mockRepository.streamChat(question,
            threadId: any(named: 'threadId'),
            model: 'test-model',
            isTemporary: false,
            calculateGrounding: any(named: 'calculateGrounding'),
            toolSettings: any(named: 'toolSettings'))).thenAnswer((_) => Stream.fromIterable([
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
            isTemporary: false,
            calculateGrounding: any(named: 'calculateGrounding'),
            toolSettings: any(named: 'toolSettings'))).thenAnswer((_) => Stream.fromIterable([
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

  test('sendMessage extracts artifact during tool end if present', () async {
    await pumpEventQueue();
    const question = 'Search web';

    when(() =>
        mockRepository.streamChat(question,
            threadId: any(named: 'threadId'),
            model: 'test-model',
            isTemporary: false,
            calculateGrounding: any(named: 'calculateGrounding'),
            toolSettings: any(named: 'toolSettings'))).thenAnswer((_) => Stream.fromIterable([
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
              'artifact': [{'title': 'Art1'}]
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

    expect(viewModel.state.messages.length, 2);
    expect(viewModel.state.messages[1].toolEvents.length, 1);
    expect(viewModel.state.messages[1].toolEvents.first.result, [{'title': 'Art1'}]);
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

    // Initial call on msg1
    await viewModel.playAudio('test', messageId: 'msg1');
    expect(viewModel.state.currentlyPlayingMessageId, 'msg1');

    // Play same message again -> should toggle off to null
    await viewModel.playAudio('test', messageId: 'msg1');
    expect(viewModel.state.currentlyPlayingMessageId, isNull);
  });

  test('playAudio switches to new message if another is currently playing', () async {
    await pumpEventQueue();

    // Play msg1
    await viewModel.playAudio('test', messageId: 'msg1');
    expect(viewModel.state.currentlyPlayingMessageId, 'msg1');

    // Play msg2
    await viewModel.playAudio('test2', messageId: 'msg2');
    expect(viewModel.state.currentlyPlayingMessageId, 'msg2');
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

  test('toggleTelemetry flips showTelemetry and persists to SharedPreferences',
      () async {
    await pumpEventQueue();

    // Default is false
    expect(viewModel.state.showTelemetry, isFalse);

    // Toggle ON
    await viewModel.toggleTelemetry();
    expect(viewModel.state.showTelemetry, isTrue);

    // Verify persistence
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('show_telemetry'), isTrue);

    // Toggle OFF
    await viewModel.toggleTelemetry();
    expect(viewModel.state.showTelemetry, isFalse);
    expect(prefs.getBool('show_telemetry'), isFalse);
  });

  test('selectProject sets active project and opens dashboard', () async {
    await pumpEventQueue();
    
    viewModel.selectProject('proj-123', 'Secret Project X');
    
    expect(viewModel.state.activeProjectId, 'proj-123');
    expect(viewModel.state.activeProjectName, 'Secret Project X');
    expect(viewModel.state.showProjectDashboard, isTrue);
    expect(viewModel.state.threadId, isNull);
  });

  test('startNewChatInProject hides dashboard and keeps project active', () async {
    await pumpEventQueue();
    
    viewModel.selectProject('proj-123', 'Secret Project X');
    viewModel.startNewChatInProject();
    
    expect(viewModel.state.activeProjectId, 'proj-123');
    expect(viewModel.state.activeProjectName, 'Secret Project X');
    expect(viewModel.state.showProjectDashboard, isFalse);
    expect(viewModel.state.threadId, isNull);
  });

  test('exitProject clears active project and hides dashboard', () async {
    await pumpEventQueue();
    
    viewModel.selectProject('proj-123', 'Secret Project X');
    viewModel.exitProject();
    
    expect(viewModel.state.activeProjectId, isNull);
    expect(viewModel.state.activeProjectName, isNull);
    expect(viewModel.state.showProjectDashboard, isFalse);
  });

  test('sendMessage assigns new thread to active project', () async {
    await pumpEventQueue();
    
    viewModel.selectProject('proj-123', 'Secret Project X');
    viewModel.startNewChatInProject();
    
    const question = 'Hello?';
    when(() => mockRepository.assignThreadToProject('new-thread-id', 'proj-123'))
        .thenAnswer((_) async {});
    when(() => mockRepository.getThreads()).thenAnswer((_) async => []);
    when(() => mockRepository.getProjects()).thenAnswer((_) async => []);

    when(() =>
        mockRepository.streamChat(question,
            threadId: null,
            model: 'test-model',
            isTemporary: false,
            calculateGrounding: any(named: 'calculateGrounding'),
            toolSettings: any(named: 'toolSettings'))).thenAnswer((_) => Stream.fromIterable([
          {
            'event': 'metadata',
            'data': {
              'thread_id': 'new-thread-id'
            }
          },
          {
            'event': 'on_chat_model_stream',
            'run_id': 'new-thread-id',
            'data': {
              'chunk': {'content': 'Hi '}
            }
          },
        ]));

    await viewModel.sendMessage(question, model: 'test-model');
    
    // Check that assignThreadToProject was called because there was an active project
    verify(() => mockRepository.assignThreadToProject('new-thread-id', 'proj-123')).called(1);
  });
}
