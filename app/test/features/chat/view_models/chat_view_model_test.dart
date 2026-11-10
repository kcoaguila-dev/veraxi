import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
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
    });
  });
}
