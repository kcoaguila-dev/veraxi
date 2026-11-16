import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/artifact_publish_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ApiClient reads BYOD keys from secure storage for its default
  // headers; an empty store is all this test needs.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  group('ArtifactPublishRepository', () {
    test('publish posts the artifact and parses id + url', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'id': 'abc123', 'url': 'https://veraxi.me/a/abc123'}),
          200,
        );
      });
      final repository = ArtifactPublishRepository(
        ApiClient(
          baseUrl: 'https://api.test/api',
          client: client,
          tenantId: 'token',
        ),
      );

      final published = await repository.publish(
        title: 'Hello world',
        fileName: 'hello_world.py',
        language: 'python',
        code: 'print("hi")',
        kind: 'code',
      );

      expect(published.id, 'abc123');
      expect(published.url, 'https://veraxi.me/a/abc123');
      expect(captured.url.toString(), 'https://api.test/api/artifacts/publish');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['title'], 'Hello world');
      expect(body['file_name'], 'hello_world.py');
      expect(body['language'], 'python');
      expect(body['code'], 'print("hi")');
      expect(body['kind'], 'code');
      expect(body.containsKey('id'), isFalse);
    });

    test('publish with an existing id sends it for in-place update', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'id': 'abc123', 'url': 'https://veraxi.me/a/abc123'}),
          200,
        );
      });
      final repository = ArtifactPublishRepository(
        ApiClient(
          baseUrl: 'https://api.test/api',
          client: client,
          tenantId: 'token',
        ),
      );

      await repository.publish(
        title: 'Hello world',
        language: 'python',
        code: 'print("v2")',
        kind: 'code',
        existingId: 'abc123',
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['id'], 'abc123');
    });

    test('unpublish deletes the artifact path', () async {
      late String capturedUrl;
      late String capturedMethod;
      final client = MockClient((request) async {
        capturedUrl = request.url.toString();
        capturedMethod = request.method;
        return http.Response('{}', 200);
      });
      final repository = ArtifactPublishRepository(
        ApiClient(
          baseUrl: 'https://api.test/api',
          client: client,
          tenantId: 'token',
        ),
      );

      await repository.unpublish('abc123');

      expect(capturedMethod, 'DELETE');
      expect(capturedUrl, 'https://api.test/api/artifacts/abc123');
    });
  });
}
