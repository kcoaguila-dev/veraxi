import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/local_ai/local_llm_engine.dart';

void main() {
  group('parseCompletionUsage', () {
    test('reads llama-server-style direct fields', () {
      final usage = parseCompletionUsage({
        'text': 'hello',
        'tokens_evaluated': 123,
        'tokens_predicted': 45,
        'tokens_cached': 0,
      });
      expect(usage, isNotNull);
      expect(usage!.promptTokens, 123);
      expect(usage.completionTokens, 45);
    });

    test('falls back to timings prompt_n / predicted_n', () {
      final usage = parseCompletionUsage({
        'timings': {'prompt_n': 100, 'predicted_n': 7, 'prompt_ms': 42.0},
      });
      expect(usage!.promptTokens, 100);
      expect(usage.completionTokens, 7);
    });

    test('direct fields win over timings', () {
      final usage = parseCompletionUsage({
        'tokens_evaluated': 10,
        'tokens_predicted': 3,
        'timings': {'prompt_n': 999, 'predicted_n': 999},
      });
      expect(usage!.promptTokens, 10);
      expect(usage.completionTokens, 3);
    });

    test('returns null when the build reports nothing', () {
      expect(parseCompletionUsage(null), isNull);
      expect(parseCompletionUsage({'text': 'hi'}), isNull);
      expect(parseCompletionUsage({}), isNull);
    });

    test('accepts double-typed counts from the platform channel', () {
      final usage = parseCompletionUsage({
        'tokens_evaluated': 12.0,
        'tokens_predicted': 4.0,
      });
      expect(usage!.promptTokens, 12);
      expect(usage.completionTokens, 4);
    });
  });
}
