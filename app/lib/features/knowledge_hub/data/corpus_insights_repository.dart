import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// One entity inside a briefing community.
class BriefingEntity {
  final String name;
  final String? type;
  final int degree;

  const BriefingEntity({required this.name, this.type, this.degree = 0});

  factory BriefingEntity.fromJson(Map<String, dynamic> json) {
    return BriefingEntity(
      name: json['name'] as String? ?? '',
      type: json['type'] as String?,
      degree: (json['degree'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One top community (theme) in a corpus briefing.
class BriefingCommunity {
  final String id;
  final int size;
  final List<BriefingEntity> topEntities;

  const BriefingCommunity({
    required this.id,
    required this.size,
    this.topEntities = const [],
  });

  factory BriefingCommunity.fromJson(Map<String, dynamic> json) {
    final entities = json['top_entities'] as List<dynamic>? ?? const [];
    return BriefingCommunity(
      id: json['id']?.toString() ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      topEntities: entities
          .map((e) =>
              BriefingEntity.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

/// One newest-entity row (first_seen is a relationship-derived proxy).
class NewestEntity {
  final String name;
  final String? type;
  final String? firstSeen;

  const NewestEntity({required this.name, this.type, this.firstSeen});

  factory NewestEntity.fromJson(Map<String, dynamic> json) {
    return NewestEntity(
      name: json['name'] as String? ?? '',
      type: json['type'] as String?,
      firstSeen: json['first_seen']?.toString(),
    );
  }
}

/// One heuristic contradiction flag: worth a human look, not truth.
class ContradictionFlag {
  final String entity;
  final String relation;
  final List<String> targets;

  const ContradictionFlag({
    required this.entity,
    required this.relation,
    this.targets = const [],
  });

  factory ContradictionFlag.fromJson(Map<String, dynamic> json) {
    final targets = json['targets'] as List<dynamic>? ?? const [];
    return ContradictionFlag(
      entity: json['entity'] as String? ?? '',
      relation: json['relation'] as String? ?? '',
      targets: targets.map((e) => e.toString()).toList(),
    );
  }
}

/// A corpus briefing as returned by GET /api/v1/corpus/briefing,
/// including the server-rendered [markdown].
class CorpusBriefing {
  final String tenant;
  final int totalNodes;
  final int totalRelationships;
  final Map<String, int> nodesByLabel;
  final Map<String, int> relationshipsByType;
  final int communityCount;
  final List<BriefingCommunity> topCommunities;
  final List<NewestEntity> newestEntities;
  final List<ContradictionFlag> contradictionFlags;
  final String contradictionRule;
  final String markdown;

  const CorpusBriefing({
    required this.tenant,
    required this.totalNodes,
    required this.totalRelationships,
    this.nodesByLabel = const {},
    this.relationshipsByType = const {},
    required this.communityCount,
    this.topCommunities = const [],
    this.newestEntities = const [],
    this.contradictionFlags = const [],
    this.contradictionRule = '',
    this.markdown = '',
  });

  factory CorpusBriefing.fromJson(Map<String, dynamic> json) {
    Map<String, int> intMap(dynamic raw) {
      if (raw is! Map) return const {};
      return raw.map(
        (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
      );
    }

    final generated =
        Map<String, dynamic>.from(json['generated_from'] as Map? ?? const {});
    final communities = json['top_communities'] as List<dynamic>? ?? const [];
    final newest = json['newest_entities'] as List<dynamic>? ?? const [];
    final flags = json['contradiction_flags'] as List<dynamic>? ?? const [];
    return CorpusBriefing(
      tenant: json['tenant'] as String? ?? 'default',
      totalNodes: (generated['total_nodes'] as num?)?.toInt() ?? 0,
      totalRelationships:
          (generated['total_relationships'] as num?)?.toInt() ?? 0,
      nodesByLabel: intMap(generated['nodes_by_label']),
      relationshipsByType: intMap(generated['relationships_by_type']),
      communityCount: (generated['community_count'] as num?)?.toInt() ?? 0,
      topCommunities: communities
          .map((e) =>
              BriefingCommunity.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      newestEntities: newest
          .map(
              (e) => NewestEntity.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      contradictionFlags: flags
          .map((e) =>
              ContradictionFlag.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      contradictionRule: json['contradiction_rule'] as String? ?? '',
      markdown: json['markdown'] as String? ?? '',
    );
  }
}

/// A dbt dataset/model match with one-hop lineage.
class DbtDatasetMatch {
  final String name;
  final String label;
  final String uniqueId;
  final List<String> matchedBy;
  final List<String> upstream;
  final List<String> downstream;

  const DbtDatasetMatch({
    required this.name,
    required this.label,
    required this.uniqueId,
    this.matchedBy = const [],
    this.upstream = const [],
    this.downstream = const [],
  });

  factory DbtDatasetMatch.fromJson(Map<String, dynamic> json) {
    List<String> names(dynamic raw) {
      if (raw is! List) return const [];
      return raw.map((e) {
        if (e is Map) return (e['name'] ?? e['unique_id'] ?? '').toString();
        return e.toString();
      }).toList();
    }

    final matchedBy = json['matched_by'] as List<dynamic>? ?? const [];
    return DbtDatasetMatch(
      name: json['name'] as String? ?? '',
      label: json['label'] as String? ?? '',
      uniqueId: json['unique_id'] as String? ?? '',
      matchedBy: matchedBy.map((e) => e.toString()).toList(),
      upstream: names(json['upstream']),
      downstream: names(json['downstream']),
    );
  }
}

final corpusInsightsRepositoryProvider =
    Provider<CorpusInsightsRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return CorpusInsightsRepository(apiClient: client);
});

class CorpusInsightsRepository {
  final ApiClient apiClient;

  CorpusInsightsRepository({required this.apiClient});

  Future<CorpusBriefing> fetchBriefing() async {
    final data = await apiClient.get('/v1/corpus/briefing');
    return CorpusBriefing.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Ingest a decoded dbt manifest.json. The backend expects a JSON
  /// body of `{"manifest": {...}}` and validates the `nodes` mapping.
  Future<Map<String, dynamic>> ingestDbtManifest(
    Map<String, dynamic> manifest,
  ) async {
    final data = await apiClient.post(
      '/v1/dbt/ingest',
      body: {'manifest': manifest},
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<List<DbtDatasetMatch>> searchDatasets(String query) async {
    final encoded = Uri.encodeQueryComponent(query);
    final data = await apiClient.get('/v1/dbt/datasets?q=$encoded');
    final matches = (data as Map)['matches'] as List<dynamic>? ?? const [];
    return matches
        .map((e) =>
            DbtDatasetMatch.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
