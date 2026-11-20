import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/features/chat/view_models/auto_compact.dart';
import 'package:veraxi_app/features/chat/view_models/token_usage.dart';

TokenUsageSummary summary({int? contextTokens, int? window}) {
  return TokenUsageSummary(
    contextTokens: contextTokens,
    contextWindowTokens: window,
    lastPromptTokens: contextTokens,
    lastCompletionTokens: 0,
    lastTotalTokens: contextTokens,
    lastEstimatedCostUsd: null,
    sessionPromptTokens: contextTokens ?? 0,
    sessionCompletionTokens: 0,
    sessionTotalTokens: contextTokens ?? 0,
    sessionEstimatedCostUsd: 0,
    hasSessionCost: false,
    responseCount: 1,
  );
}

void main() {
  group('AutoCompactMode.fromStorage', () {
    test('parses stored values, defaults to ask', () {
      expect(AutoCompactMode.fromStorage('off'), AutoCompactMode.off);
      expect(AutoCompactMode.fromStorage('auto'), AutoCompactMode.auto);
      expect(AutoCompactMode.fromStorage('ask'), AutoCompactMode.ask);
      expect(AutoCompactMode.fromStorage(null), AutoCompactMode.ask);
      expect(AutoCompactMode.fromStorage('bogus'), AutoCompactMode.ask);
    });
  });

  group('autoCompactDue', () {
    test('fires at 80% of a known window, not below', () {
      expect(autoCompactDue(summary(contextTokens: 102400, window: 128000)),
          isTrue);
      expect(autoCompactDue(summary(contextTokens: 101000, window: 128000)),
          isFalse);
      expect(autoCompactDue(summary(contextTokens: 64000, window: 128000)),
          isFalse);
    });

    test('unknown window: absolute 20k floor on estimated counts', () {
      expect(autoCompactDue(summary(contextTokens: 20000)), isTrue);
      expect(autoCompactDue(summary(contextTokens: 45000)), isTrue);
      expect(autoCompactDue(summary(contextTokens: 19999)), isFalse);
    });

    test('no counts at all: never due', () {
      expect(autoCompactDue(summary()), isFalse);
    });
  });

  group('AutoCompactGate', () {
    test('fires when due, then a skip re-arms only after +10% growth', () {
      final gate = AutoCompactGate();
      final at80 = summary(contextTokens: 102400, window: 128000);
      expect(gate.shouldFire(at80), isTrue);
      gate.skip(at80);
      // Same level and small growth: stay quiet.
      expect(gate.shouldFire(at80), isFalse);
      expect(
          gate.shouldFire(summary(contextTokens: 110000, window: 128000)),
          isFalse);
      // Past skipped level (0.80) + 0.10 delta: ask again.
      expect(
          gate.shouldFire(summary(contextTokens: 116000, window: 128000)),
          isTrue);
    });

    test('reset forgets the skip', () {
      final gate = AutoCompactGate();
      final at80 = summary(contextTokens: 102400, window: 128000);
      gate.skip(at80);
      expect(gate.shouldFire(at80), isFalse);
      gate.reset();
      expect(gate.shouldFire(at80), isTrue);
    });

    test('never fires below the trigger even without a skip', () {
      final gate = AutoCompactGate();
      expect(gate.shouldFire(summary(contextTokens: 100, window: 128000)),
          isFalse);
    });
  });
}
