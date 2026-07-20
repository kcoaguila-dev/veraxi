import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';

class MockApiClient extends Mock implements ApiClient {}

void main() {
  late MockApiClient mockApiClient;
  late ChatRepository repository;

  setUp(() {
    mockApiClient = MockApiClient();
    repository = ChatRepository(apiClient: mockApiClient);
  });

  test('getThreads calls apiClient correctly', () async {
    when(() => mockApiClient.get(any())).thenAnswer((_) async => {'threads': ['thread_1']});
    final res = await repository.getThreads();
    expect(res, ['thread_1']);
    verify(() => mockApiClient.get('/v1/chat/threads')).called(1);
  });
}
