import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/artifact_ai_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ApiKeyStorage reads through the secure-storage channel; an
  // empty store (null reads) is all these tests need.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  ArtifactAiRepository repoWith(http.Client client) => ArtifactAiRepository(
        ApiClient(
          baseUrl: 'https://api.test/api',
          client: client,
          tenantId: 'token',
        ),
        ApiKeyStorage(),
      );

  group('ArtifactAiRepository', () {
    test('complete posts the prompt and returns the text', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'text': 'the answer'}), 200);
      });

      final text = await repoWith(client).complete(
        prompt: 'What is 2+2?',
        system: 'Be terse',
        model: 'gpt-4o',
        maxTokens: 128,
      );

      expect(text, 'the answer');
      expect(
          captured.url.toString(), 'https://api.test/api/artifacts/complete');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['prompt'], 'What is 2+2?');
      expect(body['system'], 'Be terse');
      expect(body['model'], 'gpt-4o');
      expect(body['max_tokens'], 128);
      // No key in the (mocked, empty) secure store -> no api_key
      // field is sent at all.
      expect(body.containsKey('api_key'), isFalse);
    });

    test('complete omits optional fields when not given', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'text': 'ok'}), 200);
      });

      await repoWith(client).complete(prompt: 'Hi');

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body, {'prompt': 'Hi'});
    });

    test('complete throws on a non-200 response', () async {
      final client = MockClient((request) async {
        return http.Response('nope', 502);
      });
      expect(
        () => repoWith(client).complete(prompt: 'Hi'),
        throwsException,
      );
    });

    test('complete throws when the response carries no text', () async {
      final client = MockClient((request) async {
        return http.Response(jsonEncode({'unexpected': true}), 200);
      });
      expect(
        () => repoWith(client).complete(prompt: 'Hi'),
        throwsException,
      );
    });
  });
}
