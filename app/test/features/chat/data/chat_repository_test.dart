import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:http/http.dart' as http;
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'dart:convert';

class MockHttpClient extends Mock implements http.Client {}

void main() {
  late MockHttpClient mockHttpClient;
  late ApiClient apiClient;
  late ChatRepository repository;

  setUp(() {
    mockHttpClient = MockHttpClient();
    apiClient = ApiClient(client: mockHttpClient, baseUrl: 'http://test.com');
    repository = ChatRepository(apiClient: apiClient);
    registerFallbackValue(Uri.parse('http://test.com'));
  });

  test('getThreads parses json correctly', () async {
    final mockResponse = jsonEncode({
      "threads": [
        {"thread_id": "abc", "title": "New Chat"}
      ]
    });

    when(() => mockHttpClient.get(any(), headers: any(named: 'headers')))
        .thenAnswer((_) async => http.Response(mockResponse, 200));

    final threads = await repository.getThreads();
    expect(threads.length, 1);
    expect(threads.first['thread_id'], 'abc');
  });
}
