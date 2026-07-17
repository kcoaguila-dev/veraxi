import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/control_panel/data/control_panel_repository.dart';
import 'package:veraxi_app/features/control_panel/view_models/control_panel_view_model.dart';

class MockControlPanelRepository extends Mock
    implements ControlPanelRepository {}

void main() {
  late MockControlPanelRepository mockRepository;

  setUpAll(() {
    registerFallbackValue('');
  });

  setUp(() {
    mockRepository = MockControlPanelRepository();
  });

  test('initial state sets nodeCount and vectorCount to 0', () {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => {'node_count': 0, 'vector_count': 0});

    final viewModel = ControlPanelViewModel(mockRepository);

    expect(viewModel.state.nodeCount, 0);
    expect(viewModel.state.vectorCount, 0);
    expect(viewModel.state.isIngesting, false);
  });

  test('fetchStats updates state correctly on success', () async {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => {'node_count': 15, 'vector_count': 10});

    final viewModel = ControlPanelViewModel(mockRepository);

    // fetchStats is called in constructor
    await Future.delayed(Duration.zero);

    expect(viewModel.state.nodeCount, 15);
    expect(viewModel.state.vectorCount, 10);
    expect(viewModel.state.error, null);
  });

  test('fetchStats updates error state on failure', () async {
    when(() => mockRepository.fetchStats()).thenThrow(Exception('API error'));

    final viewModel = ControlPanelViewModel(mockRepository);

    await Future.delayed(Duration.zero);

    expect(viewModel.state.error, contains('API error'));
  });

  test('triggerIngestion sets isIngesting and updates stats on success',
      () async {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => {'node_count': 5, 'vector_count': 5});
    when(() => mockRepository.triggerIngestion(any()))
        .thenAnswer((_) async => {'nodes_inserted': 5, 'vectors_inserted': 5});

    final viewModel = ControlPanelViewModel(mockRepository);

    // Let constructor fetch finish
    await Future.delayed(Duration.zero);

    final future = viewModel.triggerIngestion("test text");

    // State should be ingesting immediately after call
    expect(viewModel.state.isIngesting, true);

    await future;

    // State should not be ingesting and should have a success message
    expect(viewModel.state.isIngesting, false);
    expect(viewModel.state.successMessage, contains('5 nodes and 5 vectors'));
  });

  test('triggerIngestion sets error and clears isIngesting on failure',
      () async {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => {'node_count': 0, 'vector_count': 0});
    when(() => mockRepository.triggerIngestion(any()))
        .thenThrow(Exception('Server error: 500'));

    final viewModel = ControlPanelViewModel(mockRepository);

    // Let constructor fetch finish
    await Future.delayed(Duration.zero);

    await viewModel.triggerIngestion("test text");

    expect(viewModel.state.isIngesting, false);
    expect(viewModel.state.error, contains('Server error: 500'));
    expect(viewModel.state.successMessage, isNull);
  });

  test('triggerIngestion defaults counts to 0 when missing from the result',
      () async {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => {'node_count': 0, 'vector_count': 0});
    when(() => mockRepository.triggerIngestion(any()))
        .thenAnswer((_) async => <String, dynamic>{});

    final viewModel = ControlPanelViewModel(mockRepository);
    await Future.delayed(Duration.zero);

    await viewModel.triggerIngestion("test text");

    expect(viewModel.state.isIngesting, false);
    expect(viewModel.state.successMessage, contains('0 nodes and 0 vectors'));
  });

  test(
      'triggerIngestion clears a previous error and success message when '
      'starting a new ingestion', () async {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => {'node_count': 0, 'vector_count': 0});
    when(() => mockRepository.triggerIngestion(any()))
        .thenThrow(Exception('first failure'));

    final viewModel = ControlPanelViewModel(mockRepository);
    await Future.delayed(Duration.zero);

    await viewModel.triggerIngestion("first attempt");
    expect(viewModel.state.error, contains('first failure'));

    when(() => mockRepository.triggerIngestion(any()))
        .thenAnswer((_) async => {'nodes_inserted': 1, 'vectors_inserted': 1});

    final future = viewModel.triggerIngestion("second attempt");

    // clearError/clearSuccessMessage should apply immediately.
    expect(viewModel.state.error, isNull);

    await future;

    expect(viewModel.state.error, isNull);
    expect(viewModel.state.successMessage, contains('1 nodes and 1 vectors'));
  });
}
