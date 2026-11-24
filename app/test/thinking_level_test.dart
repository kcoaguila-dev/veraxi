import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/local_ai/think_tag_stream_parser.dart';
import 'package:veraxi_app/core/models/model_thinking_capability.dart';
import 'package:veraxi_app/core/providers/thinking_level_provider.dart';

void main() {
  group('ModelThinkingCapability', () {
    test('identifies reasoning vs non-reasoning models and clamps levels', () {
      final gpt5 = ModelThinkingCapability.forModel('gpt-5.4');
      expect(gpt5.supportsReasoning, isTrue);
      expect(gpt5.levels, containsAll(['off', 'minimal', 'low', 'medium', 'high', 'max']));
      expect(gpt5.clampLevel('max'), 'max');

      final gpt4o = ModelThinkingCapability.forModel('gpt-4o');
      expect(gpt4o.supportsReasoning, isFalse);
      expect(gpt4o.clampLevel('high'), isNull);

      final o3 = ModelThinkingCapability.forModel('o3-mini');
      expect(o3.clampLevel('off'), 'low');
      expect(o3.clampLevel('max'), 'high');

      final deepseek = ModelThinkingCapability.forModel('deepseek-chat');
      expect(deepseek.mode, 'toggle');
      expect(deepseek.clampLevel('high'), 'on');
      expect(deepseek.clampLevel('off'), 'off');

      final ggufQwen = ModelThinkingCapability.forModel('qwen3-8b-q4_k_m.gguf');
      expect(ggufQwen.supportsReasoning, isTrue);
      expect(ggufQwen.levels, contains('off'));
    });

    test('resolveEffectiveThinkingLevel uses per-model preference and clamps', () {
      const caps = {
        'gpt-5.4': ModelThinkingCapability(
          mode: 'effort',
          levels: ['off', 'minimal', 'low', 'medium', 'high', 'max'],
          defaultLevel: 'medium',
          supportsReasoning: true,
        ),
        'gpt-4o': ModelThinkingCapability.none,
      };
      expect(
        resolveEffectiveThinkingLevel(
          modelName: 'gpt-5.4',
          savedByModel: {'gpt-5.4': 'max'},
          capabilities: caps,
        ),
        'max',
      );
      expect(
        resolveEffectiveThinkingLevel(
          modelName: 'gpt-4o',
          savedByModel: {'gpt-4o': 'high'},
          capabilities: caps,
        ),
        isNull,
      );
    });
  });

  group('ThinkTagStreamParser', () {
    test('separates split <think> tags across chunk boundaries', () {
      final parser = ThinkTagStreamParser();
      final chunks = ['Start ', '<thi', 'nk>step 1 ', 'step 2</th', 'ink>Done'];
      final reasoning = StringBuffer();
      final content = StringBuffer();
      var endedCount = 0;

      for (final chunk in chunks) {
        final res = parser.feed(chunk);
        res.reasoningDeltas.forEach(reasoning.write);
        res.contentDeltas.forEach(content.write);
        if (res.reasoningEndedMs != null) endedCount++;
      }
      final tail = parser.flush();
      tail.reasoningDeltas.forEach(reasoning.write);
      tail.contentDeltas.forEach(content.write);

      expect(reasoning.toString(), 'step 1 step 2');
      expect(content.toString(), 'Start Done');
      expect(endedCount, 1);
    });
  });
}
