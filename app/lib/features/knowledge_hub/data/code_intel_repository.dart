import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// Code-graph overview from GET /api/v1/code/overview.
class CodeOverview {
  final Map<String, int> nodeCounts;
  final Map<String, int> edgeCounts;
  final int totalNodes;
  final int totalEdges;
  final List<TopConnectedSymbol> topConnected;

  const CodeOverview({
    this.nodeCounts = const {},
    this.edgeCounts = const {},
    this.totalNodes = 0,
    this.totalEdges = 0,
    this.topConnected = const [],
  });

  factory CodeOverview.fromJson(Map<String, dynamic> json) {
    Map<String, int> intMap(dynamic raw) {
      if (raw is! Map) return const {};
      return raw.map(
        (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
      );
    }

    final top = json['top_connected'] as List<dynamic>? ?? const [];
    return CodeOverview(
      nodeCounts: intMap(json['node_counts']),
      edgeCounts: intMap(json['edge_counts']),
      totalNodes: (json['total_nodes'] as num?)?.toInt() ?? 0,
      totalEdges: (json['total_edges'] as num?)?.toInt() ?? 0,
      topConnected: top
          .map((e) =>
              TopConnectedSymbol.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

/// One row of the overview's most-connected symbols list.
class TopConnectedSymbol {
  final String name;
  final String qualifiedName;
  final String? label;
  final String? path;
  final int degree;

  const TopConnectedSymbol({
    required this.name,
    required this.qualifiedName,
    this.label,
    this.path,
    this.degree = 0,
  });

  factory TopConnectedSymbol.fromJson(Map<String, dynamic> json) {
    return TopConnectedSymbol(
      name: json['name'] as String? ?? '',
      qualifiedName: json['qualified_name'] as String? ?? '',
      label: json['label'] as String?,
      path: json['path'] as String?,
      // The backend calls the count `connections` (code_queries.py).
      degree: (json['connections'] as num?)?.toInt() ??
          (json['degree'] as num?)?.toInt() ??
          0,
    );
  }
}

/// One symbol match from GET /api/v1/code/symbol.
class CodeSymbolMatch {
  final String name;
  final String qualifiedName;
  final String? label;
  final String? path;
  final int? line;

  const CodeSymbolMatch({
    required this.name,
    required this.qualifiedName,
    this.label,
    this.path,
    this.line,
  });

  factory CodeSymbolMatch.fromJson(Map<String, dynamic> json) {
    return CodeSymbolMatch(
      name: json['name'] as String? ?? '',
      qualifiedName: json['qualified_name'] as String? ?? '',
      label: json['label'] as String?,
      path: json['path'] as String?,
      line: (json['line'] as num?)?.toInt(),
    );
  }
}

/// One impacted node from GET /api/v1/code/impact.
class ImpactedSymbol {
  final String qualifiedName;
  final String? name;
  final String? label;
  final String? path;
  final int depth;
  final String? viaEdge;

  const ImpactedSymbol({
    required this.qualifiedName,
    this.name,
    this.label,
    this.path,
    required this.depth,
    this.viaEdge,
  });

  factory ImpactedSymbol.fromJson(Map<String, dynamic> json) {
    return ImpactedSymbol(
      qualifiedName: json['qualified_name'] as String? ?? '',
      name: json['name'] as String?,
      label: json['label'] as String?,
      path: json['path'] as String?,
      depth: (json['depth'] as num?)?.toInt() ?? 0,
      viaEdge: json['via_edge'] as String?,
    );
  }
}

/// One vulnerability finding from POST /api/v1/vuln/report.
///
/// [matchStatus] is 'matched' (version provably in the affected
/// range) or 'unknown' (version/range unparseable) — the two must
/// stay visually distinct in the UI.
class VulnFinding {
  final String package;
  final String? version;
  final String? ecosystem;
  final String? sourceFile;
  final String cveId;
  final String? severity;
  final List<String> cweIds;
  final String matchStatus;
  final bool kev;

  const VulnFinding({
    required this.package,
    this.version,
    this.ecosystem,
    this.sourceFile,
    required this.cveId,
    this.severity,
    this.cweIds = const [],
    required this.matchStatus,
    this.kev = false,
  });

  bool get isMatched => matchStatus == 'matched';

  factory VulnFinding.fromJson(Map<String, dynamic> json) {
    final cwes = json['cwe_ids'] as List<dynamic>? ?? const [];
    return VulnFinding(
      package: json['package'] as String? ?? '',
      version: json['version'] as String?,
      ecosystem: json['ecosystem'] as String?,
      sourceFile: json['source_file'] as String?,
      cveId: json['cve_id'] as String? ?? '',
      severity: json['severity'] as String?,
      cweIds: cwes.map((e) => e.toString()).toList(),
      matchStatus: json['match_status'] as String? ?? 'unknown',
      kev: json['kev'] as bool? ?? false,
    );
  }
}

/// A vulnerability report from POST /api/v1/vuln/report.
class VulnReport {
  final int dependenciesChecked;
  final List<VulnFinding> findings;
  final int matchedCount;
  final int unknownCount;
  final int kevCount;

  const VulnReport({
    this.dependenciesChecked = 0,
    this.findings = const [],
    this.matchedCount = 0,
    this.unknownCount = 0,
    this.kevCount = 0,
  });

  factory VulnReport.fromJson(Map<String, dynamic> json) {
    final findings = json['findings'] as List<dynamic>? ?? const [];
    return VulnReport(
      dependenciesChecked: (json['dependencies_checked'] as num?)?.toInt() ?? 0,
      findings: findings
          .map((e) => VulnFinding.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      matchedCount: (json['matched_count'] as num?)?.toInt() ?? 0,
      unknownCount: (json['unknown_count'] as num?)?.toInt() ?? 0,
      kevCount: (json['kev_count'] as num?)?.toInt() ?? 0,
    );
  }
}

final codeIntelRepositoryProvider = Provider<CodeIntelRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return CodeIntelRepository(apiClient: client);
});

class CodeIntelRepository {
  final ApiClient apiClient;

  CodeIntelRepository({required this.apiClient});

  Future<Map<String, dynamic>> ingestRepo(String repoPath) async {
    final data = await apiClient.post(
      '/v1/code/ingest',
      body: {'repo_path': repoPath},
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<CodeOverview> fetchOverview() async {
    final data = await apiClient.get('/v1/code/overview');
    return CodeOverview.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<List<CodeSymbolMatch>> lookupSymbol(String name) async {
    final encoded = Uri.encodeQueryComponent(name);
    final data = await apiClient.get('/v1/code/symbol?name=$encoded');
    final matches = (data as Map)['matches'] as List<dynamic>? ?? const [];
    return matches
        .map((e) =>
            CodeSymbolMatch.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<List<ImpactedSymbol>> impactAnalysis(
    String symbol, {
    int maxDepth = 3,
  }) async {
    final encoded = Uri.encodeQueryComponent(symbol);
    final data = await apiClient.get(
      '/v1/code/impact?symbol=$encoded&max_depth=$maxDepth',
    );
    final impacted = (data as Map)['impacted'] as List<dynamic>? ?? const [];
    return impacted
        .map(
            (e) => ImpactedSymbol.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> syncVulnIntel() async {
    final data = await apiClient.post('/v1/vuln/sync');
    return Map<String, dynamic>.from(data as Map);
  }

  Future<VulnReport> runVulnReport({String? repoPath}) async {
    final data = await apiClient.post(
      '/v1/vuln/report',
      body: {if (repoPath != null) 'repo_path': repoPath},
    );
    return VulnReport.fromJson(Map<String, dynamic>.from(data as Map));
  }
}
