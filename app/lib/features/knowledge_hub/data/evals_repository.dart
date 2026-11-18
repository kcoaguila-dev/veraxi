import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// Metrics for one group of cases (a query type, or overall).
///
/// [groundingScore] is null when the recorded rankings carried no
/// grounding score — the UI renders it as "n/a", never 0.
class EvalGroupMetrics {
  final int caseCount;
  final double recallAtK;
  final double hitRate;
  final double? groundingScore;

  const EvalGroupMetrics({
    this.caseCount = 0,
    this.recallAtK = 0,
    this.hitRate = 0,
    this.groundingScore,
  });

  factory EvalGroupMetrics.fromJson(Map<String, dynamic> json) {
    return EvalGroupMetrics(
      caseCount: (json['case_count'] as num?)?.toInt() ?? 0,
      recallAtK: (json['recall_at_k'] as num?)?.toDouble() ?? 0,
      hitRate: (json['hit_rate'] as num?)?.toDouble() ?? 0,
      groundingScore: (json['grounding_score'] as num?)?.toDouble(),
    );
  }
}

/// All metrics for one retrieval configuration.
class EvalConfigResults {
  final String config;
  final EvalGroupMetrics overall;
  final Map<String, EvalGroupMetrics> byQueryType;

  const EvalConfigResults({
    required this.config,
    required this.overall,
    this.byQueryType = const {},
  });

  factory EvalConfigResults.fromJson(
    String config,
    Map<String, dynamic> json,
  ) {
    final byType = json['by_query_type'] as Map? ?? const {};
    return EvalConfigResults(
      config: config,
      overall: EvalGroupMetrics.fromJson(
        Map<String, dynamic>.from(json['overall'] as Map? ?? const {}),
      ),
      byQueryType: byType.map(
        (k, v) => MapEntry(
          k.toString(),
          EvalGroupMetrics.fromJson(Map<String, dynamic>.from(v as Map)),
        ),
      ),
    );
  }
}

/// A full ablation result from POST /api/v1/evals/ablation.
class AblationReport {
  final String dataset;
  final int k;
  final List<EvalConfigResults> configurations;

  const AblationReport({
    required this.dataset,
    required this.k,
    this.configurations = const [],
  });

  /// Query types present in any configuration, in canonical order.
  List<String> get queryTypes {
    const order = ['lookup', 'multi_hop', 'global'];
    final present = <String>{};
    for (final config in configurations) {
      present.addAll(config.byQueryType.keys);
    }
    return order.where(present.contains).toList();
  }

  factory AblationReport.fromJson(Map<String, dynamic> json) {
    final configs = json['configurations'] as Map? ?? const {};
    return AblationReport(
      dataset: json['dataset'] as String? ?? '',
      k: (json['k'] as num?)?.toInt() ?? 5,
      configurations: configs.entries
          .map((e) => EvalConfigResults.fromJson(
                e.key.toString(),
                Map<String, dynamic>.from(e.value as Map),
              ))
          .toList(),
    );
  }
}

final evalsRepositoryProvider = Provider<EvalsRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return EvalsRepository(apiClient: client);
});

class EvalsRepository {
  final ApiClient apiClient;

  EvalsRepository({required this.apiClient});

  /// Run the typed ablation. [dataset] is the decoded typed-dataset
  /// JSON (an object with `cases`, or a bare case list wrapped by
  /// the caller); [rankings] maps config name → query text → ranked
  /// doc ids (or `{ranked_doc_ids, grounding_score}`), exactly like
  /// the backend CLI's rankings file.
  Future<AblationReport> runAblation({
    required Object dataset,
    required Map<String, dynamic> rankings,
    int k = 5,
  }) async {
    final body = <String, dynamic>{'rankings': rankings, 'k': k};
    if (dataset is Map) {
      body['dataset'] = Map<String, dynamic>.from(dataset);
    } else if (dataset is List) {
      body['cases'] = dataset;
    }
    final data = await apiClient.post('/v1/evals/ablation', body: body);
    return AblationReport.fromJson(Map<String, dynamic>.from(data as Map));
  }
}
