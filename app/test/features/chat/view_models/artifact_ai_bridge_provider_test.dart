import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_ai_bridge_provider.dart';

class _FakeAiRepository extends ArtifactAiRepository {
  _FakeAiRepository() : super(ApiClient(), ApiKeyStorage());

  final List<Map<String, dynamic>> calls = [];
  String result = 'model text';
  Object? failure;
  Completer<String>? gate;

  @override
  Future<String> complete({
    required String prompt,
    String? system,
    String? model,
    int? maxTokens,
  }) async {
    calls.add({
      'prompt': prompt,
      'system': system,
      'model': model,
      'maxTokens': maxTokens,
    });
    if (failure != null) throw failure!;
    if (gate != null) return gate!.future;
    return result;
  }
}

Map<String, dynamic> _msg({
  String requestId = 'r1',
  String prompt = 'Hello?',
  String? system,
  String? model,
  int? maxTokens,
}) =>
    {
      'type': 'veraxi_complete',
      'requestId': requestId,
      'prompt': prompt,
      if (system != null) 'system': system,
      if (model != null) 'model': model,
      if (maxTokens != null) 'maxTokens': maxTokens,
    };

void main() {
  group('ArtifactAiBridge', () {
    test('a valid message returns an ok reply with the text', () async {
      final repo = _FakeAiRepository();
      final bridge = ArtifactAiBridge(
        repository: repo,
        modelResolver: () async => 'selected-model',
      );

      final reply =
          await bridge.handle(_msg(system: 'Be terse', maxTokens: 64));

      expect(reply['type'], 'veraxi_complete_reply');
      expect(reply['requestId'], 'r1');
      expect(reply['ok'], isTrue);
      expect(reply['text'], 'model text');
      expect(reply['error'], isNull);
      expect(repo.calls, [
        {
          'prompt': 'Hello?',
          'system': 'Be terse',
          'model': 'selected-model',
          'maxTokens': 64,
        }
      ]);
    });

    test('a message model wins over the selected model', () async {
      final repo = _FakeAiRepository();
      final bridge = ArtifactAiBridge(
        repository: repo,
        modelResolver: () async => 'selected-model',
      );

      await bridge.handle(_msg(model: 'frame-model'));

      expect(repo.calls.single['model'], 'frame-model');
    });

    test('accepts a raw JSON string message', () async {
      final repo = _FakeAiRepository();
      final bridge = ArtifactAiBridge(
        repository: repo,
        modelResolver: () async => null,
      );

      final reply = await bridge
          .handle('{"type":"veraxi_complete","requestId":"r9","prompt":"Hi"}');

      expect(reply['ok'], isTrue);
      expect(reply['requestId'], 'r9');
      expect(repo.calls.single['model'], isNull);
    });

    test('malformed messages get an error reply and never reach the repo',
        () async {
      final repo = _FakeAiRepository();
      final bridge = ArtifactAiBridge(
        repository: repo,
        modelResolver: () async => null,
      );

      final bad = <dynamic>[
        {'type': 'veraxi_storage', 'requestId': 'r', 'prompt': 'x'},
        {'type': 'veraxi_complete', 'prompt': 'x'},
        {'type': 'veraxi_complete', 'requestId': '', 'prompt': 'x'},
        {'type': 'veraxi_complete', 'requestId': 'r'},
        {'type': 'veraxi_complete', 'requestId': 'r', 'prompt': '  '},
        {'type': 'veraxi_complete', 'requestId': 'r', 'prompt': 42},
        {
          'type': 'veraxi_complete',
          'requestId': 'r',
          'prompt': 'x' * (maxArtifactAiPromptChars + 1),
        },
        {
          'type': 'veraxi_complete',
          'requestId': 'r',
          'prompt': 'x',
          'system': 'x' * (maxArtifactAiSystemChars + 1),
        },
        {
          'type': 'veraxi_complete',
          'requestId': 'r',
          'prompt': 'x',
          'maxTokens': 0,
        },
        {
          'type': 'veraxi_complete',
          'requestId': 'r',
          'prompt': 'x',
          'maxTokens': maxArtifactAiTokens + 1,
        },
        {
          'type': 'veraxi_complete',
          'requestId': 'r',
          'prompt': 'x',
          'maxTokens': 1.5,
        },
        'not json at all',
        42,
      ];
      for (final raw in bad) {
        final reply = await bridge.handle(raw);
        expect(reply['type'], 'veraxi_complete_reply', reason: '$raw');
        expect(reply['ok'], isFalse, reason: '$raw');
        expect(reply['error'], 'invalid AI request', reason: '$raw');
      }
      expect(repo.calls, isEmpty);
    });

    test('a repository failure becomes an error reply, never a throw',
        () async {
      final repo = _FakeAiRepository()..failure = Exception('backend down');
      final bridge = ArtifactAiBridge(
        repository: repo,
        modelResolver: () async => null,
      );

      final reply = await bridge.handle(_msg());

      expect(reply['ok'], isFalse);
      expect(reply['error'], contains('backend down'));
      expect(reply['text'], isNull);
    });

    test('the in-flight guard rejects beyond the cap', () async {
      final repo = _FakeAiRepository()..gate = Completer<String>();
      final bridge = ArtifactAiBridge(
        repository: repo,
        modelResolver: () async => null,
      );

      final pending = <Future<Map<String, dynamic>>>[
        for (var i = 0; i < maxArtifactAiInFlight; i++)
          bridge.handle(_msg(requestId: 'r$i')),
      ];
      // Let the first calls reach the repository.
      await Future<void>.delayed(Duration.zero);

      final rejected = await bridge.handle(_msg(requestId: 'overflow'));
      expect(rejected['ok'], isFalse);
      expect(rejected['error'], contains('rate limit'));
      expect(repo.calls, hasLength(maxArtifactAiInFlight));

      repo.gate!.complete('done');
      final replies = await Future.wait(pending);
      expect(replies.every((r) => r['ok'] == true), isTrue);
    });

    test('the per-minute guard rejects beyond the cap and recovers', () async {
      final repo = _FakeAiRepository();
      var now = DateTime(2026, 1, 1, 12);
      final bridge = ArtifactAiBridge(
        repository: repo,
        modelResolver: () async => null,
        now: () => now,
      );

      for (var i = 0; i < maxArtifactAiPerMinute; i++) {
        final reply = await bridge.handle(_msg(requestId: 'r$i'));
        expect(reply['ok'], isTrue, reason: 'call $i');
      }
      final rejected = await bridge.handle(_msg(requestId: 'overflow'));
      expect(rejected['ok'], isFalse);
      expect(rejected['error'], contains('rate limit'));
      expect(repo.calls, hasLength(maxArtifactAiPerMinute));

      now = now.add(const Duration(minutes: 1, seconds: 1));
      final after = await bridge.handle(_msg(requestId: 'after'));
      expect(after['ok'], isTrue);
    });
  });

  group('parseArtifactAiMessage', () {
    test('parses a full message', () {
      final request = parseArtifactAiMessage({
        'type': 'veraxi_complete',
        'requestId': 'abc',
        'prompt': 'Hi',
        'system': 'sys',
        'model': 'm',
        'maxTokens': 10,
      });
      expect(request, isNotNull);
      expect(request!.requestId, 'abc');
      expect(request.prompt, 'Hi');
      expect(request.system, 'sys');
      expect(request.model, 'm');
      expect(request.maxTokens, 10);
    });
  });
}
