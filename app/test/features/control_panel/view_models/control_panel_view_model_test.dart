import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/control_panel/data/control_panel_repository.dart';
import 'package:veraxi_app/features/control_panel/view_models/control_panel_view_model.dart';

class MockControlPanelRepository extends Mock implements ControlPanelRepository {}

void main() {
  late MockControlPanelRepository mockRepository;
  late ControlPanelViewModel viewModel;

  setUp(() {
    mockRepository = MockControlPanelRepository();
    when(() => mockRepository.fetchStats()).thenAnswer((_) async => BackendStats(nodeCount: 0, vectorCount: 0));
    viewModel = ControlPanelViewModel(mockRepository);
  });

  test('initial state loads successfully', () async {
    await Future.delayed(Duration.zero);
    expect(viewModel.state.stats, isNotNull);
    expect(viewModel.state.isIngesting, isFalse);
    expect(viewModel.state.error, isNull);
  });
}
