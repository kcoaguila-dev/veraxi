import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/settings/data/integrations_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  IntegrationsRepository repoWith(MockClient client) {
    return IntegrationsRepository(
      apiClient: ApiClient(
        baseUrl: 'https://api.test/api',
        client: client,
        tenantId: 'token',
      ),
    );
  }

  group('IntegrationsRepository', () {
    test('getIntegrations parses rows and tool counts', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://api.test/api/integrations');
        return http.Response(
          jsonEncode({
            'integrations': [
              {
                'id': '1',
                'kind': 'mcp',
                'provider': 'custom_mcp',
                'slug': 'docs-mcp',
                'display_name': 'Docs MCP',
                'config': {
                  'url': 'https://mcp.example.com/mcp',
                  'transport': 'auto',
                  'tool_names': ['a', 'b'],
                },
                'has_auth': true,
                'is_enabled': true,
                'status': 'connected',
              },
              {
                'id': '2',
                'kind': 'oauth',
                'provider': 'github',
                'slug': 'github',
                'display_name': 'GitHub',
                'config': {},
                'has_auth': true,
                'is_enabled': true,
                'status': 'connected',
              },
            ],
          }),
          200,
        );
      });
      final integrations = await repoWith(client).getIntegrations();
      expect(integrations, hasLength(2));
      expect(integrations.first.displayName, 'Docs MCP');
      expect(integrations.first.toolCount, 2);
      expect(integrations.first.hasAuth, isTrue);
      expect(integrations.last.toolCount, 6); // curated GitHub toolset
    });

    test('createMcpIntegration posts name/url/transport/headers', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'id': '9',
            'kind': 'mcp',
            'provider': 'custom_mcp',
            'slug': 'docs',
            'display_name': 'Docs',
            'config': {},
            'has_auth': true,
            'is_enabled': true,
            'status': 'connected',
          }),
          201,
        );
      });
      final created = await repoWith(client).createMcpIntegration(
        displayName: 'Docs',
        url: 'https://mcp.example.com/mcp',
        transport: 'sse',
        headers: {'Authorization': 'Bearer x'},
      );
      expect(captured.method, 'POST');
      expect(captured.url.path, '/api/integrations/mcp');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['display_name'], 'Docs');
      expect(body['transport'], 'sse');
      expect(body['headers'], {'Authorization': 'Bearer x'});
      expect(created.slug, 'docs');
    });

    test('patchIntegration uses PATCH with only the changed fields',
        () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'id': '1',
            'kind': 'mcp',
            'provider': 'custom_mcp',
            'slug': 'docs',
            'display_name': 'Docs',
            'config': {},
            'has_auth': false,
            'is_enabled': false,
            'status': 'connected',
          }),
          200,
        );
      });
      final updated =
          await repoWith(client).patchIntegration('1', isEnabled: false);
      expect(captured.method, 'PATCH');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body, {'is_enabled': false});
      expect(updated.isEnabled, isFalse);
    });

    test('startOAuth returns the authorization url', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/integrations/oauth/github/start');
        return http.Response(
          jsonEncode({
            'authorization_url': 'https://github.com/login/oauth/authorize?x=1',
            'provider': 'github',
          }),
          200,
        );
      });
      final url = await repoWith(client).startOAuth('github');
      expect(url, startsWith('https://github.com/login/oauth/authorize'));
    });
  });
}
