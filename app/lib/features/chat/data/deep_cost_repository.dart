import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// A min/max range as returned by POST /api/chat/estimate-deep.
class DeepCostRange {
  final num min;
  final num max;

  const DeepCostRange({required this.min, required this.max});

  factory DeepCostRange.fromJson(Map<String, dynamic> json) {
    return DeepCostRange(
      min: json['min'] as num? ?? 0,
      max: json['max'] as num? ?? 0,
    );
  }
}

/// Pre-flight estimate for Deep (multi-agent debate) mode.
///
/// Mirrors `estimate_deep_usage` in backend/mcp_server/formatter.py.
/// The estimate is derived from the debate workflow's configured
/// limits — it does NOT depend on the query text. [estimatedCostUsd]
/// is null when the model has no pricing configured; the UI must
/// render no dollar figure in that case (never an invented $0.00).
class DeepCostEstimate {
  final String mode;
  final bool isEstimate;
  final String label;
  final String? model;
  final int specialistAgents;
  final int maxRounds;
  final DeepCostRange llmCalls;
  final DeepCostRange promptTokens;
  final DeepCostRange completionTokens;
  final DeepCostRange totalTokens;
  final DeepCostRange? estimatedCostUsd;

  const DeepCostEstimate({
    required this.mode,
    required this.isEstimate,
    required this.label,
    required this.model,
    required this.specialistAgents,
    required this.maxRounds,
    required this.llmCalls,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.estimatedCostUsd,
  });

  factory DeepCostEstimate.fromJson(Map<String, dynamic> json) {
    DeepCostRange range(String key) => DeepCostRange.fromJson(
          Map<String, dynamic>.from(json[key] as Map? ?? const {}),
        );
    final cost = json['estimated_cost_usd'];
    return DeepCostEstimate(
      mode: json['mode'] as String? ?? 'deep',
      isEstimate: json['is_estimate'] as bool? ?? true,
      label: json['label'] as String? ?? '',
      model: json['model'] as String?,
      specialistAgents: (json['specialist_agents'] as num?)?.toInt() ?? 0,
      maxRounds: (json['max_rounds'] as num?)?.toInt() ?? 0,
      llmCalls: range('llm_calls'),
      promptTokens: range('prompt_tokens'),
      completionTokens: range('completion_tokens'),
      totalTokens: range('total_tokens'),
      estimatedCostUsd: cost is Map
          ? DeepCostRange.fromJson(Map<String, dynamic>.from(cost))
          : null,
    );
  }
}

final deepCostRepositoryProvider = Provider<DeepCostRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return DeepCostRepository(apiClient: client);
});

class DeepCostRepository {
  final ApiClient apiClient;

  DeepCostRepository({required this.apiClient});

  /// Fetch the Deep-mode pre-flight estimate for [model].
  ///
  /// Sends ONLY the model: the backend estimate is derived from
  /// debate constants, not from any query text.
  Future<DeepCostEstimate> estimateDeepCost({required String model}) async {
    final data = await apiClient.post(
      '/chat/estimate-deep',
      body: {'model': model},
    );
    return DeepCostEstimate.fromJson(Map<String, dynamic>.from(data as Map));
  }
}
