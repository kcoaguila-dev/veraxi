import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:veraxi_app/features/auth/view_models/auth_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/core/repositories/memory_repository.dart';
import 'package:veraxi_app/core/repositories/model_config_repository.dart';
import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/core/tts_settings_storage.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockChatRepository extends Mock implements IChatRepository {
  @override
  Stream<Map<String, dynamic>> streamSyncEvents() => const Stream.empty();
}

class MockMemoryRepository extends Mock implements MemoryRepository {}

class MockModelConfigRepository extends Mock implements ModelConfigRepository {}

class MockTTSRepository extends Mock implements TTSRepository {}

class MockTTSSettingsStorage extends Mock implements TTSSettingsStorage {}

class MockApiKeyStorage extends Mock implements ApiKeyStorage {}

class MockAudioPlayer extends Mock implements AudioPlayer {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatViewModel', () {
    late MockChatRepository mockChatRepository;
    late MockMemoryRepository mockMemoryRepository;
    late MockTTSRepository mockTTSRepository;

    setUp(() {
      mockChatRepository = MockChatRepository();
      mockMemoryRepository = MockMemoryRepository();
      mockTTSRepository = MockTTSRepository();

      when(() => mockChatRepository.getThreads()).thenAnswer((_) async => []);
    });

    test('initial state loads successfully', () async {
      SharedPreferences.setMockInitialValues({});
      final viewModel = ChatViewModel(
        mockChatRepository,
        mockTTSRepository,
        mockMemoryRepository,
      );

      expect(viewModel.state.isLoadingThreads, isFalse);
      expect(viewModel.state.pastThreads, isEmpty);
    });

    test('restores activity steps when a thread is reloaded', () async {
      SharedPreferences.setMockInitialValues({});
      when(() => mockChatRepository.getThreadHistory('thread-1'))
          .thenAnswer((_) async => [
                {
                  'id': 'assistant-1',
                  'role': 'assistant',
                  'content': 'Answer',
                  'metrics': {'response_at': '2026-11-10T05:00:00Z'},
                  'activity': [
                    {
                      'number': 1,
                      'name': 'Search context',
                      'description': 'Finding relevant sources',
                      'status': 'complete',
                      'durationMs': 420,
                      'toolEvents': [
                        {
                          'id': 'tool-1',
                          'name': 'query_graph',
                          'args': {'query': 'hello'},
                          'result': 'result',
                          'isComplete': true,
                          'durationMs': 120,
                        },
                      ],
                    },
                  ],
                },
              ]);

      final viewModel = ChatViewModel(
        mockChatRepository,
        mockTTSRepository,
        mockMemoryRepository,
      );

      await viewModel.selectThread('thread-1');

      expect(viewModel.state.messages, hasLength(1));
      expect(viewModel.state.messages.single.activity, hasLength(1));
      expect(viewModel.state.messages.single.activity.single.name,
          'Search context');
      expect(viewModel.state.messages.single.activity.single.durationMs, 420);
      expect(
          viewModel
              .state.messages.single.activity.single.toolEvents.single.name,
          'query_graph');
      expect(
        viewModel.state.messages.single.metrics?['response_at'],
        '2026-11-10T05:00:00Z',
      );
    });

    test('restores reasoning and its duration when a thread is reloaded',
        () async {
      SharedPreferences.setMockInitialValues({});
      when(() => mockChatRepository.getThreadHistory('thread-1'))
          .thenAnswer((_) async => [
                {
                  'id': 'assistant-1',
                  'role': 'assistant',
                  'content': 'Answer',
                  'reasoning': 'deep thought',
                  'reasoning_duration_seconds': 4.2,
                },
                {
                  'id': 'assistant-2',
                  'role': 'assistant',
                  'content': 'Answer without reasoning',
                  'reasoning': null,
                  'reasoning_duration_seconds': null,
                },
              ]);

      final viewModel = ChatViewModel(
        mockChatRepository,
        mockTTSRepository,
        mockMemoryRepository,
      );

      await viewModel.selectThread('thread-1');

      expect(viewModel.state.messages, hasLength(2));
      expect(viewModel.state.messages.first.reasoning, 'deep thought');
      expect(viewModel.state.messages.first.reasoningDurationSeconds, 4.2);
      expect(viewModel.state.messages.last.reasoning, isNull);
      expect(viewModel.state.messages.last.reasoningDurationSeconds, isNull);
    });

    test(
        'chatRepositoryProvider does not rebuild on null-session AuthState transitions',
        () async {
      final controller = StreamController<AuthState>.broadcast();
      addTearDown(controller.close);

      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith((ref) => controller.stream),
        ],
      );
      addTearDown(container.dispose);

      final initialRepo = container.read(chatRepositoryProvider);
      controller.add(AuthState(AuthChangeEvent.initialSession, null));
      await Future<void>.delayed(Duration.zero);

      final afterInitialSessionRepo = container.read(chatRepositoryProvider);
      expect(identical(initialRepo, afterInitialSessionRepo), isTrue);
    });

    test('loadThreads clears isLoadingThreads when repository throws',
        () async {
      SharedPreferences.setMockInitialValues({});
      when(() => mockChatRepository.getThreads())
          .thenThrow(Exception('network error'));

      final viewModel = ChatViewModel(
        mockChatRepository,
        mockTTSRepository,
        mockMemoryRepository,
      );
      await viewModel.loadThreads();

      expect(viewModel.state.isLoadingThreads, isFalse);
      expect(viewModel.state.pastThreads, isEmpty);
    });

    test('stopGeneration cancels active stream and clears loading state',
        () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      var streamCancelled = false;
      final streamStarted = Completer<void>();
      final controller = StreamController<Map<String, dynamic>>(
        onListen: () {
          if (!streamStarted.isCompleted) {
            streamStarted.complete();
          }
        },
        onCancel: () {
          streamCancelled = true;
        },
      );

      when(() => mockChatRepository.getThreads()).thenAnswer((_) async => []);
      when(
        () => mockChatRepository.streamChat(
          any(),
          threadId: any(named: 'threadId'),
          isTemporary: any(named: 'isTemporary'),
          model: any(named: 'model'),
          calculateGrounding: any(named: 'calculateGrounding'),
          toolSettings: any(named: 'toolSettings'),
          codeScope: any(named: 'codeScope'),
          thinkingLevel: any(named: 'thinkingLevel'),
          agentRuntime: any(named: 'agentRuntime'),
          attachVeraxiMcp: any(named: 'attachVeraxiMcp'),
        ),
      ).thenAnswer((_) => controller.stream);

      final viewModel = ChatViewModel(
        mockChatRepository,
        mockTTSRepository,
        mockMemoryRepository,
      );

      final sendFuture = viewModel.sendMessage('hello', model: 'gpt-4o');
      await streamStarted.future;

      expect(viewModel.state.isLoading, isTrue);
      viewModel.stopGeneration();
      await sendFuture;

      expect(streamCancelled, isTrue);
      expect(viewModel.state.isLoading, isFalse);
      expect(viewModel.state.messages.last.isStreaming, isFalse);
    });
  });
}
