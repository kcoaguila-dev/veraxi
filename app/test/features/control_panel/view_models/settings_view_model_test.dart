import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/control_panel/data/settings_repository.dart';
import 'package:veraxi_app/features/control_panel/view_models/settings_view_model.dart';

class MockSettingsRepository extends Mock implements SettingsRepository {}

void main() {
  late MockSettingsRepository mockRepository;

  setUpAll(() {
    registerFallbackValue('');
  });

  setUp(() {
    mockRepository = MockSettingsRepository();
  });

  // Helper to let the async _init() logic in the constructor settle.
  Future<void> pumpEventQueue() => Future.delayed(Duration.zero);

  test('loads the saved key and stats on init', () async {
    when(() => mockRepository.getGeminiKey())
        .thenAnswer((_) async => 'saved-key');
    when(() => mockRepository.fetchStats()).thenAnswer(
        (_) async => BackendStats(nodeCount: 2, vectorCount: 5));

    final viewModel = SettingsViewModel(mockRepository);
    await pumpEventQueue();

    expect(viewModel.state.geminiKey, 'saved-key');
    expect(viewModel.state.stats?.nodeCount, 2);
    expect(viewModel.state.stats?.vectorCount, 5);
    expect(viewModel.state.isLoading, isFalse);
    expect(viewModel.state.error, isNull);
  });

  test('still loads the saved key when fetchStats fails', () async {
    when(() => mockRepository.getGeminiKey())
        .thenAnswer((_) async => 'saved-key');
    when(() => mockRepository.fetchStats())
        .thenThrow(Exception('Network error: Unable to connect to the server.'));

    final viewModel = SettingsViewModel(mockRepository);
    await pumpEventQueue();

    expect(viewModel.state.geminiKey, 'saved-key');
    expect(viewModel.state.stats, isNull);
    expect(viewModel.state.isLoading, isFalse);
    expect(viewModel.state.error,
        contains('Network error: Unable to connect to the server.'));
  });

  group('refreshStats', () {
    test('updates stats and clears any previous error on success', () async {
      when(() => mockRepository.getGeminiKey()).thenAnswer((_) async => '');
      when(() => mockRepository.fetchStats())
          .thenThrow(Exception('boom'));

      final viewModel = SettingsViewModel(mockRepository);
      await pumpEventQueue();
      expect(viewModel.state.error, isNotNull);

      when(() => mockRepository.fetchStats()).thenAnswer(
          (_) async => BackendStats(nodeCount: 7, vectorCount: 3));

      await viewModel.refreshStats();

      expect(viewModel.state.stats?.nodeCount, 7);
      expect(viewModel.state.stats?.vectorCount, 3);
      expect(viewModel.state.isLoading, isFalse);
      expect(viewModel.state.error, isNull);
    });

    test('sets the error message when the repository throws', () async {
      when(() => mockRepository.getGeminiKey()).thenAnswer((_) async => '');
      when(() => mockRepository.fetchStats()).thenAnswer(
          (_) async => BackendStats(nodeCount: 1, vectorCount: 1));

      final viewModel = SettingsViewModel(mockRepository);
      await pumpEventQueue();

      when(() => mockRepository.fetchStats())
          .thenThrow(Exception('Connection timeout: Server took too long to respond.'));

      await viewModel.refreshStats();

      expect(viewModel.state.isLoading, isFalse);
      expect(viewModel.state.error,
          contains('Connection timeout: Server took too long to respond.'));
    });
  });

  test('saveGeminiKey persists the key and updates state', () async {
    when(() => mockRepository.getGeminiKey()).thenAnswer((_) async => '');
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => BackendStats(nodeCount: 0, vectorCount: 0));
    when(() => mockRepository.saveGeminiKey(any())).thenAnswer((_) async {});

    final viewModel = SettingsViewModel(mockRepository);
    await pumpEventQueue();

    await viewModel.saveGeminiKey('new-key');

    expect(viewModel.state.geminiKey, 'new-key');
    verify(() => mockRepository.saveGeminiKey('new-key')).called(1);
  });
}