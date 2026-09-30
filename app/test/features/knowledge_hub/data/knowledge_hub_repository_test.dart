import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/knowledge_hub/data/knowledge_hub_repository.dart';

class MockApiClient extends Mock implements ApiClient {}

void main() {
  late MockApiClient mockApiClient;
  late KnowledgeHubRepository repository;

  setUp(() {
    mockApiClient = MockApiClient();
    repository = KnowledgeHubRepository(apiClient: mockApiClient);
  });

  test('fetchStats calls apiClient correctly', () async {
    when(() => mockApiClient.get(any()))
        .thenAnswer((_) async => {'nodeCount': 100, 'vectorCount': 200});
    final res = await repository.fetchStats();
    expect(res.nodeCount, 100);
    expect(res.vectorCount, 200);
    verify(() => mockApiClient.get('/admin/stats')).called(1);
  });
}
