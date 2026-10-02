import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/repositories/model_config_repository.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:flutter/services.dart';

class MockHttpClient extends Mock implements http.Client {}
class FakeUri extends Fake implements Uri {}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall methodCall) async {
        return null;
      },
    );
    registerFallbackValue(FakeUri());
  });

  group('ModelConfigRepository', () {
    late MockHttpClient mockHttpClient;
    late ApiClient apiClient;
    late ModelConfigRepository repository;

    setUp(() {
      mockHttpClient = MockHttpClient();
      apiClient = ApiClient(client: mockHttpClient, baseUrl: 'http://localhost');
      repository = ModelConfigRepository(apiClient: apiClient);
    });

    test('getProviderModels successfully parses JSON into Map<String, List<String>>', () async {
      when(() => mockHttpClient.get(
        any(),
        headers: any(named: 'headers'),
      )).thenAnswer((_) async => http.Response(
            '{"OpenAI":["gpt-4","gpt-3.5-turbo"],"Anthropic":["claude-3-opus"]}',
            200,
          ));

      final models = await repository.getProviderModels();

      expect(models.keys.length, 2);
      expect(models['OpenAI'], equals(['gpt-4', 'gpt-3.5-turbo']));
      expect(models['Anthropic'], equals(['claude-3-opus']));
    });

    test('getProviderModels throws exception on non-200 response', () async {
      when(() => mockHttpClient.get(
        any(),
        headers: any(named: 'headers'),
      )).thenAnswer((_) async => http.Response('Not Found', 404));

      expect(() => repository.getProviderModels(), throwsException);
    });

    test('getProviderModels throws exception on malformed JSON response', () async {
      when(() => mockHttpClient.get(
        any(),
        headers: any(named: 'headers'),
      )).thenAnswer((_) async => http.Response('["Not", "A", "Map"]', 200));

      expect(() => repository.getProviderModels(), throwsException);
    });
  });
}
