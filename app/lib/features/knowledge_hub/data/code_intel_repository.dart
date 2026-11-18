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

  /// EPSS exploit-probability score (0..1) from FIRST.org, when the
  /// backend enriched this finding; null when no EPSS data exists.
  final double? epssScore;

  /// EPSS percentile (0..1) — this CVE's score rank among all CVEs.
  final double? epssPercentile;

  /// Distinct files in the tenant code graph that reach the vulnerable
  /// package. Only populated when the report ran with reachability.
  final int reachableFileCount;

  /// The reachable code locations (same shape as an impact-analysis
  /// result). Empty when reachability was not requested or nothing in
  /// the code graph reaches the package.
  final List<ImpactedSymbol> reachableInCode;

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
    this.epssScore,
    this.epssPercentile,
    this.reachableFileCount = 0,
    this.reachableInCode = const [],
  });

  bool get isMatched => matchStatus == 'matched';

  /// True when the code graph shows this package is actually reached.
  bool get isReachable => reachableFileCount > 0;

  factory VulnFinding.fromJson(Map<String, dynamic> json) {
    final cwes = json['cwe_ids'] as List<dynamic>? ?? const [];
    final reachable = json['reachable_in_code'] as List<dynamic>? ?? const [];
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
      epssScore: (json['epss_score'] as num?)?.toDouble(),
      epssPercentile: (json['epss_percentile'] as num?)?.toDouble(),
      reachableFileCount: (json['reachable_file_count'] as num?)?.toInt() ?? 0,
      reachableInCode: reachable
          .map((e) =>
              ImpactedSymbol.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

/// Result of POST /api/v1/vuln/sarif (SARIF 2.1.0 SAST ingest).
class SarifIngestResult {
  final int findingsWritten;
  final int fileLinks;
  final int cweLinks;
  final int vectorsWritten;

  const SarifIngestResult({
    this.findingsWritten = 0,
    this.fileLinks = 0,
    this.cweLinks = 0,
    this.vectorsWritten = 0,
  });

  factory SarifIngestResult.fromJson(Map<String, dynamic> json) {
    return SarifIngestResult(
      findingsWritten: (json['findings_written'] as num?)?.toInt() ?? 0,
      fileLinks: (json['file_links'] as num?)?.toInt() ?? 0,
      cweLinks: (json['cwe_links'] as num?)?.toInt() ?? 0,
      vectorsWritten: (json['vectors_written'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Result of POST /api/v1/vuln/recon (Nuclei recon/DAST ingest).
class ReconIngestResult {
  final int findingsWritten;
  final int hostLinks;
  final int cveLinks;
  final int cweLinks;
  final int vectorsWritten;

  const ReconIngestResult({
    this.findingsWritten = 0,
    this.hostLinks = 0,
    this.cveLinks = 0,
    this.cweLinks = 0,
    this.vectorsWritten = 0,
  });

  factory ReconIngestResult.fromJson(Map<String, dynamic> json) {
    return ReconIngestResult(
      findingsWritten: (json['findings_written'] as num?)?.toInt() ?? 0,
      hostLinks: (json['host_links'] as num?)?.toInt() ?? 0,
      cveLinks: (json['cve_links'] as num?)?.toInt() ?? 0,
      cweLinks: (json['cwe_links'] as num?)?.toInt() ?? 0,
      vectorsWritten: (json['vectors_written'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Result of POST /api/v1/vuln/attack/sync (MITRE ATT&CK STIX sync).
class AttackSyncResult {
  final int techniquesWritten;
  final int tacticsWritten;
  final int mitigationsWritten;
  final int mitigatesLinks;
  final int vectorsWritten;

  const AttackSyncResult({
    this.techniquesWritten = 0,
    this.tacticsWritten = 0,
    this.mitigationsWritten = 0,
    this.mitigatesLinks = 0,
    this.vectorsWritten = 0,
  });

  factory AttackSyncResult.fromJson(Map<String, dynamic> json) {
    return AttackSyncResult(
      techniquesWritten: (json['techniques_written'] as num?)?.toInt() ?? 0,
      tacticsWritten: (json['tactics_written'] as num?)?.toInt() ?? 0,
      mitigationsWritten: (json['mitigations_written'] as num?)?.toInt() ?? 0,
      mitigatesLinks: (json['mitigates_links'] as num?)?.toInt() ?? 0,
      vectorsWritten: (json['vectors_written'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Result of POST /api/v1/vuln/alerts (SOC alert / IOC ingest).
class AlertIngestResult {
  final int alertsWritten;
  final int iocLinks;
  final int techniqueLinks;
  final int cveLinks;
  final int vectorsWritten;

  const AlertIngestResult({
    this.alertsWritten = 0,
    this.iocLinks = 0,
    this.techniqueLinks = 0,
    this.cveLinks = 0,
    this.vectorsWritten = 0,
  });

  factory AlertIngestResult.fromJson(Map<String, dynamic> json) {
    return AlertIngestResult(
      alertsWritten: (json['alerts_written'] as num?)?.toInt() ?? 0,
      iocLinks: (json['ioc_links'] as num?)?.toInt() ?? 0,
      techniqueLinks: (json['technique_links'] as num?)?.toInt() ?? 0,
      cveLinks: (json['cve_links'] as num?)?.toInt() ?? 0,
      vectorsWritten: (json['vectors_written'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One SARIF taint flow (source → sink), extracted client-side from an
/// uploaded SARIF payload's `codeFlows` because the ingest endpoint
/// returns counts only. [steps] are `uri:line` locations in flow order.
class SarifTaintFlow {
  final String ruleId;
  final List<String> steps;

  const SarifTaintFlow({required this.ruleId, required this.steps});
}

/// Extract taint flows from a parsed SARIF 2.1.0 document.
///
/// Mirrors the backend's `sarif.py` extraction: for each result with
/// `codeFlows`, walk threadFlows' locations and render each physical
/// location as `uri:line` (line omitted when absent). Results without
/// a code flow contribute nothing.
List<SarifTaintFlow> extractSarifTaintFlows(Map<String, dynamic> sarif) {
  final flows = <SarifTaintFlow>[];
  final runs = sarif['runs'] as List<dynamic>? ?? const [];
  for (final run in runs) {
    if (run is! Map) continue;
    final results = run['results'] as List<dynamic>? ?? const [];
    for (final result in results) {
      if (result is! Map) continue;
      final steps = <String>[];
      final codeFlows = result['codeFlows'] as List<dynamic>? ?? const [];
      for (final flow in codeFlows) {
        if (flow is! Map) continue;
        final threadFlows = flow['threadFlows'] as List<dynamic>? ?? const [];
        for (final threadFlow in threadFlows) {
          if (threadFlow is! Map) continue;
          final locations =
              threadFlow['locations'] as List<dynamic>? ?? const [];
          for (final entry in locations) {
            if (entry is! Map) continue;
            final location = entry['location'] as Map? ?? const {};
            final physical = location['physicalLocation'] as Map? ?? const {};
            final artifact = physical['artifactLocation'] as Map? ?? const {};
            final uri = artifact['uri'] as String? ?? '';
            if (uri.isEmpty) continue;
            final region = physical['region'] as Map? ?? const {};
            final line = (region['startLine'] as num?)?.toInt() ?? 0;
            steps.add(line > 0 ? '$uri:$line' : uri);
          }
        }
      }
      if (steps.length >= 2) {
        flows.add(SarifTaintFlow(
          ruleId: result['ruleId'] as String? ?? 'unknown-rule',
          steps: steps,
        ));
      }
    }
  }
  return flows;
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

  Future<VulnReport> runVulnReport({
    String? repoPath,
    bool includeReachability = false,
    Map<String, dynamic>? sbomJson,
  }) async {
    final data = await apiClient.post(
      '/v1/vuln/report',
      body: {
        if (repoPath != null) 'repo_path': repoPath,
        if (sbomJson != null) 'sbom_json': sbomJson,
        'include_reachability': includeReachability,
      },
    );
    return VulnReport.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Ingest a SARIF 2.1.0 document (POST /api/v1/vuln/sarif).
  Future<SarifIngestResult> ingestSarif(Map<String, dynamic> sarif) async {
    final data = await apiClient.post(
      '/v1/vuln/sarif',
      body: {'sarif': sarif},
    );
    return SarifIngestResult.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Ingest Nuclei output (POST /api/v1/vuln/recon). [nucleiPayload]
  /// is either raw JSON/JSONL text or a decoded list of findings.
  Future<ReconIngestResult> ingestRecon(dynamic nucleiPayload) async {
    final data = await apiClient.post(
      '/v1/vuln/recon',
      body: {'nuclei': nucleiPayload},
    );
    return ReconIngestResult.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Sync MITRE ATT&CK intel (POST /api/v1/vuln/attack/sync). Without
  /// [stixJson] the backend fetches the current STIX bundle itself.
  Future<AttackSyncResult> syncAttackIntel({
    Map<String, dynamic>? stixJson,
  }) async {
    final data = await apiClient.post(
      '/v1/vuln/attack/sync',
      body: {if (stixJson != null) 'stix_json': stixJson},
    );
    return AttackSyncResult.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Ingest SOC alerts / IOCs (POST /api/v1/vuln/alerts). [alerts] is a
  /// decoded JSON object or list, as the backend parser accepts both.
  Future<AlertIngestResult> ingestAlerts(dynamic alerts) async {
    final data = await apiClient.post(
      '/v1/vuln/alerts',
      body: {'alerts': alerts},
    );
    return AlertIngestResult.fromJson(Map<String, dynamic>.from(data as Map));
  }
}
