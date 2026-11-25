import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veraxi_app/core/network/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('ApiClient.post decodes 202 Accepted JSON responses', () async {
    final mockClient = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/github-app/index');
      return http.Response(
        jsonEncode({
          'status': 'queued',
          'job_id': 'job-123',
          'repo_full_name': 'acme/repo',
        }),
        202,
      );
    });

    final apiClient = ApiClient(
      baseUrl: 'https://example.test/api',
      client: mockClient,
      tenantId: 'token-1',
    );

    final result = await apiClient.post(
      '/v1/github-app/index',
      body: {'repo_full_name': 'acme/repo'},
    );

    expect(result, {
      'status': 'queued',
      'job_id': 'job-123',
      'repo_full_name': 'acme/repo',
    });
  });

  test('ApiClient.post handles empty 202 Accepted body without throwing',
      () async {
    final mockClient = MockClient((request) async {
      return http.Response('', 202);
    });

    final apiClient = ApiClient(
      baseUrl: 'https://example.test/api',
      client: mockClient,
      tenantId: 'token-1',
    );

    final result = await apiClient.post('/v1/github-app/index');
    expect(result, <String, dynamic>{});
  });
}
