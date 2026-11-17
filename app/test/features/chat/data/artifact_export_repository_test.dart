import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/artifact_export_repository.dart';

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

  group('ArtifactExportRepository', () {
    test('export posts the artifact and returns the raw bytes', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response.bytes([37, 80, 68, 70, 45], 200);
      });
      final repository = ArtifactExportRepository(
        ApiClient(
          baseUrl: 'https://api.test/api',
          client: client,
          tenantId: 'token',
        ),
      );

      final bytes = await repository.exportArtifact(
        format: 'pdf',
        title: 'Notes',
        content: '# Notes',
        contentType: 'markdown',
      );

      expect(bytes, Uint8List.fromList([37, 80, 68, 70, 45]));
      expect(captured.url.toString(), 'https://api.test/api/artifacts/export');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['format'], 'pdf');
      expect(body['title'], 'Notes');
      expect(body['content'], '# Notes');
      expect(body['content_type'], 'markdown');
      expect(body.containsKey('spec'), isFalse);
    });

    test('export forwards a spec when one is given', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response.bytes([80, 75], 200);
      });
      final repository = ArtifactExportRepository(
        ApiClient(
          baseUrl: 'https://api.test/api',
          client: client,
          tenantId: 'token',
        ),
      );

      await repository.exportArtifact(
        format: 'xlsx',
        title: 'Budget',
        content: '',
        contentType: 'json',
        spec: {
          'sheets': [
            {
              'name': 'S',
              'headers': ['A'],
              'rows': [
                [1]
              ]
            }
          ]
        },
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['spec'], isA<Map<String, dynamic>>());
    });

    test('export throws on a server error', () async {
      final client = MockClient((request) async {
        return http.Response('too large', 413);
      });
      final repository = ArtifactExportRepository(
        ApiClient(
          baseUrl: 'https://api.test/api',
          client: client,
          tenantId: 'token',
        ),
      );

      await expectLater(
        repository.exportArtifact(
          format: 'pdf',
          title: 'Notes',
          content: '# Notes',
          contentType: 'markdown',
        ),
        throwsA(predicate((e) => e.toString().contains('413'))),
      );
    });
  });
}
