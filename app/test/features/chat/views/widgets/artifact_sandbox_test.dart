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
}
