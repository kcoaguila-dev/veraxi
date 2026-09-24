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

class MockChatRepository extends Mock implements ChatRepository {}
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
    late MockModelConfigRepository mockModelConfigRepository;
    late MockTTSRepository mockTTSRepository;
    late MockTTSSettingsStorage mockTTSSettingsStorage;
    late MockApiKeyStorage mockApiKeyStorage;

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
  });
}
