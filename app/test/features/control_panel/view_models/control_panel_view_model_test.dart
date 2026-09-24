import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/control_panel/data/control_panel_repository.dart';
import 'package:veraxi_app/features/control_panel/view_models/control_panel_view_model.dart';
import 'package:veraxi_app/core/network/api_client.dart';

class MockControlPanelRepository extends Mock
    implements ControlPanelRepository {}

void main() {
  late MockControlPanelRepository mockRepository;
  late ControlPanelViewModel viewModel;

  setUp(() {
    mockRepository = MockControlPanelRepository();
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => BackendStats(nodeCount: 0, vectorCount: 0));
    when(() => mockRepository.getSchema()).thenAnswer((_) async => {});
  });

  test('initial state loads successfully', () async {
    viewModel = ControlPanelViewModel(mockRepository);
    await Future.delayed(Duration.zero);
    expect(viewModel.state.stats, isNotNull);
    expect(viewModel.state.isIngesting, isFalse);
    expect(viewModel.state.error, isNull);
    expect(viewModel.state.requiresPayment, isFalse);
  });

  test(
      'fetchStats sets requiresPayment when PaymentRequiredException is thrown',
      () async {
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) => Future.error(PaymentRequiredException()));
    viewModel = ControlPanelViewModel(mockRepository);
    // Let async constructors finish
    await Future.delayed(Duration.zero);
    expect(viewModel.state.requiresPayment, isTrue);
  });
}
