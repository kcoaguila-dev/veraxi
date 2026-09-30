import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/features/knowledge_hub/data/knowledge_hub_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/knowledge_hub_view_model.dart';
import 'package:veraxi_app/core/network/api_client.dart';

class MockKnowledgeHubRepository extends Mock
    implements KnowledgeHubRepository {}

void main() {
  late MockKnowledgeHubRepository mockRepository;
  late KnowledgeHubViewModel viewModel;

  setUp(() {
    mockRepository = MockKnowledgeHubRepository();
    when(() => mockRepository.fetchStats())
        .thenAnswer((_) async => BackendStats(nodeCount: 0, vectorCount: 0));
    when(() => mockRepository.getSchema()).thenAnswer((_) async => {});
  });

  test('initial state loads successfully', () async {
    viewModel = KnowledgeHubViewModel(mockRepository);
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
    viewModel = KnowledgeHubViewModel(mockRepository);
    // Let async constructors finish
    await Future.delayed(Duration.zero);
    expect(viewModel.state.requiresPayment, isTrue);
  });
}
