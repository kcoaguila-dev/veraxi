import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_sandbox.dart';

/// The sandbox must never fake execution: before the browser-only
/// rewrite, unsupported platforms and languages returned a simulated
/// "Executed cleanly" success, and Python was sent to the server.
/// These tests pin the honest behavior — on the VM test platform there
/// is no WebView implementation, so a real run is impossible and the
/// result must be a failure, not a success.
void main() {
  group('runCodeInClientSandbox honesty', () {
    test('unsupported language returns an error, not a fake success', () async {
      final result = await runCodeInClientSandbox('rust', 'fn main() {}');
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('not supported'));
      expect(result.stdout, isNot(contains('Executed')));
      expect(result.stdout, isNot(contains('Execution complete')));
    });

    test('javascript on a platform without a WebView fails honestly', () async {
      final result = await runCodeInClientSandbox('javascript', '1 + 1');
      expect(result.exitCode, isNot(0));
      expect(result.stdout, isNot(contains('Executed')));
      expect(result.stdout, isNot(contains('Execution complete')));
    });
  });

  group('aiBridgeReply (native AI bridge delivery)', () {
    const raw = '{"type":"veraxi_complete","requestId":"r1","prompt":"Hi"}';

    test('without a handler the frame gets a clear unavailable error',
        () async {
      final reply = await aiBridgeReply(null, raw);
      expect(reply['type'], 'veraxi_complete_reply');
      expect(reply['requestId'], 'r1');
      expect(reply['ok'], isFalse);
      expect(reply['error'], 'AI is not available in this preview');
    });

    test('with a handler its reply is delivered verbatim', () async {
      final reply = await aiBridgeReply((rawMessage) async {
        return {
          'type': 'veraxi_complete_reply',
          'requestId': 'r1',
          'ok': true,
          'text': 'answer',
          'error': null,
        };
      }, raw);
      expect(reply['ok'], isTrue);
      expect(reply['text'], 'answer');
    });

    test('garbage input gets an invalid-request reply, not a throw', () async {
      final reply = await aiBridgeReply(null, 'not json');
      expect(reply['ok'], isFalse);
      expect(reply['error'], 'invalid AI request');
    });

    test('the reply script targets the shim entry point', () {
      final script = aiReplyScript({
        'type': 'veraxi_complete_reply',
        'requestId': 'r1',
        'ok': true,
        'text': 'a',
        'error': null,
      });
      expect(script, contains('window.__veraxiCompleteReply'));
      expect(script, contains('veraxi_complete_reply'));
    });
  });
}
