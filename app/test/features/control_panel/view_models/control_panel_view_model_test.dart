import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/control_panel/data/control_panel_repository.dart';
import 'package:veraxi_app/features/control_panel/view_models/control_panel_view_model.dart';

class MockControlPanelRepository extends Mock implements ControlPanelRepository {}

void main() {
  late MockControlPanelRepository mockRepository;

  setUp(() {
    mockRepository = MockControlPanelRepository();
  });

  test('initial state sets nodeCount and vectorCount to 0', () {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => {'node_count': 0, 'vector_count': 0});

    final viewModel = ControlPanelViewModel(mockRepository);

    expect(viewModel.debugState.nodeCount, 0);
    expect(viewModel.debugState.vectorCount, 0);
    expect(viewModel.debugState.isIngesting, false);
  });

  test('fetchStats updates state correctly on success', () async {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => {'node_count': 15, 'vector_count': 10});

    final viewModel = ControlPanelViewModel(mockRepository);

    // fetchStats is called in constructor
    await Future.delayed(Duration.zero);

    expect(viewModel.debugState.nodeCount, 15);
    expect(viewModel.debugState.vectorCount, 10);
    expect(viewModel.debugState.error, null);
  });

  test('fetchStats updates error state on failure', () async {
    when(() => mockRepository.fetchStats())
        .thenThrow(Exception('API error'));

    final viewModel = ControlPanelViewModel(mockRepository);

    await Future.delayed(Duration.zero);

    expect(viewModel.debugState.error, contains('API error'));
  });

  test('triggerIngestion sets isIngesting and updates stats on success', () async {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => {'node_count': 5, 'vector_count': 5});
    when(() => mockRepository.triggerIngestion())
        .thenAnswer((_) async => {'nodes_inserted': 5, 'vectors_inserted': 5});

    final viewModel = ControlPanelViewModel(mockRepository);

    // Let constructor fetch finish
    await Future.delayed(Duration.zero);

    final future = viewModel.triggerIngestion();

    // State should be ingesting immediately after call
    expect(viewModel.debugState.isIngesting, true);

    await future;

    // State should not be ingesting and should have a success message
    expect(viewModel.debugState.isIngesting, false);
    expect(viewModel.debugState.successMessage, contains('5 nodes and 5 vectors'));
  });
}
