import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/network/llm_request_options.dart';
import 'package:veraxi_app/core/network/sse_parser.dart';

/// Index freshness stamp attached to code-graph responses
/// (`GET /api/v1/code/overview`, `symbol`, `impact`).
class CodeIndexFreshness {
  final String? indexedCommit;
  final String? indexedAt;
  final String? repoKey;
  final String? currentCommit;
  final bool? stale;

  const CodeIndexFreshness({
    this.indexedCommit,
    this.indexedAt,
    this.repoKey,
    this.currentCommit,
    this.stale,
  });

  bool get hasIndexedCommit =>
      indexedCommit != null && indexedCommit!.trim().isNotEmpty;

  bool get isStale => stale == true;

  String get shortIndexedCommit => _shortSha(indexedCommit);

  String? get shortCurrentCommit {
    if (currentCommit == null || currentCommit!.trim().isEmpty) return null;
    return _shortSha(currentCommit);
  }

  static String _shortSha(String? sha) {
    final trimmed = (sha ?? '').trim();
    if (trimmed.length <= 7) return trimmed;
    return trimmed.substring(0, 7);
  }

  factory CodeIndexFreshness.fromJson(Map<String, dynamic> json) {
    return CodeIndexFreshness(
      indexedCommit: json['indexed_commit'] as String?,
      indexedAt: json['indexed_at'] as String?,
      repoKey: json['repo_key'] as String?,
      currentCommit: json['current_commit'] as String?,
      stale: json['stale'] as bool?,
    );
  }
}

/// Code-graph overview from GET /api/v1/code/overview.
class CodeOverview {
  final Map<String, int> nodeCounts;
  final Map<String, int> edgeCounts;
  final int totalNodes;
  final int totalEdges;
  final List<TopConnectedSymbol> topConnected;
  final CodeIndexFreshness? freshness;

  const CodeOverview({
    this.nodeCounts = const {},
    this.edgeCounts = const {},
    this.totalNodes = 0,
    this.totalEdges = 0,
    this.topConnected = const [],
    this.freshness,
  });

  factory CodeOverview.fromJson(Map<String, dynamic> json) {
    Map<String, int> intMap(dynamic raw) {
      if (raw is! Map) return const {};
      return raw.map(
        (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
      );
    }

    final top = json['top_connected'] as List<dynamic>? ?? const [];
    final rawFreshness = json['freshness'];
    final freshness = rawFreshness is Map
        ? CodeIndexFreshness.fromJson(
            Map<String, dynamic>.from(rawFreshness),
          )
        : null;
    return CodeOverview(
      nodeCounts: intMap(json['node_counts']),
      edgeCounts: intMap(json['edge_counts']),
      totalNodes: (json['total_nodes'] as num?)?.toInt() ?? 0,
      totalEdges: (json['total_edges'] as num?)?.toInt() ?? 0,
      topConnected: top
          .map((e) =>
              TopConnectedSymbol.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      freshness: freshness,
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

/// One reachable call site for a vulnerability finding.
class VulnCallSite {
  final String file;
  final int? line;
  final String symbol;
  final List<String> chain;

  const VulnCallSite({
    required this.file,
    this.line,
    required this.symbol,
    this.chain = const [],
  });

  factory VulnCallSite.fromJson(Map<String, dynamic> json) {
    final rawChain = json['chain'] as List<dynamic>? ?? const [];
    return VulnCallSite(
      file: json['file'] as String? ?? json['path'] as String? ?? '',
      line: (json['line'] as num?)?.toInt(),
      symbol:
          json['symbol'] as String? ?? json['qualified_name'] as String? ?? '',
      chain: rawChain.map((e) => e.toString()).toList(),
    );
  }
}

/// Result of POST /api/v1/vuln/audit-diff.
class DiffAuditResult {
  final List<String> filesAudited;
  final List<Map<String, dynamic>> reachableSymbols;
  final List<Map<String, dynamic>> findings;

  const DiffAuditResult({
    this.filesAudited = const [],
    this.reachableSymbols = const [],
    this.findings = const [],
  });

  factory DiffAuditResult.fromJson(Map<String, dynamic> json) {
    final files = json['files_audited'] as List<dynamic>? ?? const [];
    final symbols = json['reachable_symbols'] as List<dynamic>? ?? const [];
    final findings = json['findings'] as List<dynamic>? ?? const [];
    return DiffAuditResult(
      filesAudited: files.map((e) => e.toString()).toList(),
      reachableSymbols:
          symbols.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
      findings:
          findings.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
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

  /// Patched version from NVD/OSV advisory, when available.
  final String? fixedVersion;

  /// Dependency scope: 'direct', 'transitive', or 'unknown'.
  final String dependencyScope;

  /// Parent package or manifest file introducing this dependency.
  final String? introducedVia;

  /// Composite priority score (0..100) computed from reachability, KEV, EPSS.
  final int compositeScore;

  /// Human-readable priority explanations (e.g. "Active in CISA KEV").
  final List<String> priorityReasons;

  /// Structured call sites reaching this vulnerable package.
  final List<VulnCallSite> callSites;

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
    this.fixedVersion,
    this.dependencyScope = 'unknown',
    this.introducedVia,
    this.compositeScore = 0,
    this.priorityReasons = const [],
    this.callSites = const [],
  });

  String get findingId => '$cveId::$package';

  bool get isMatched => matchStatus == 'matched';

  /// True when the code graph shows this package is actually reached.
  bool get isReachable => reachableFileCount > 0 || callSites.isNotEmpty;

  factory VulnFinding.fromJson(Map<String, dynamic> json) {
    final cwes = json['cwe_ids'] as List<dynamic>? ?? const [];
    final reachable = json['reachable_in_code'] as List<dynamic>? ?? const [];
    final impacted = reachable
        .map(
            (e) => ImpactedSymbol.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final rawCallSites = json['call_sites'] as List<dynamic>?;
    final parsedCallSites = rawCallSites != null
        ? rawCallSites
            .map((e) =>
                VulnCallSite.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList()
        : impacted
            .where((item) => (item.path ?? '').isNotEmpty)
            .map(
              (item) => VulnCallSite(
                file: item.path ?? '',
                symbol: item.qualifiedName,
                chain: item.viaEdge != null ? [item.viaEdge!] : const [],
              ),
            )
            .toList();
    final rawReasons = json['priority_reasons'] as List<dynamic>? ?? const [];
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
      reachableInCode: impacted,
      fixedVersion: json['fixed_version'] as String?,
      dependencyScope: json['dependency_scope'] as String? ?? 'unknown',
      introducedVia: json['introduced_via'] as String?,
      compositeScore: (json['composite_score'] as num?)?.toInt() ?? 0,
      priorityReasons: rawReasons.map((e) => e.toString()).toList(),
      callSites: parsedCallSites,
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
  final DateTime? feedSyncedAt;

  const VulnReport({
    this.dependenciesChecked = 0,
    this.findings = const [],
    this.matchedCount = 0,
    this.unknownCount = 0,
    this.kevCount = 0,
    this.feedSyncedAt,
  });

  factory VulnReport.fromJson(Map<String, dynamic> json) {
    final findings = json['findings'] as List<dynamic>? ?? const [];
    final rawSync = json['feed_synced_at'] as String?;
    return VulnReport(
      dependenciesChecked: (json['dependencies_checked'] as num?)?.toInt() ?? 0,
      findings: findings
          .map((e) => VulnFinding.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      matchedCount: (json['matched_count'] as num?)?.toInt() ?? 0,
      unknownCount: (json['unknown_count'] as num?)?.toInt() ?? 0,
      kevCount: (json['kev_count'] as num?)?.toInt() ?? 0,
      feedSyncedAt: rawSync != null ? DateTime.tryParse(rawSync) : null,
    );
  }
}

final codeIntelRepositoryProvider = Provider<CodeIntelRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  final apiKeyStorage = ref.watch(apiKeyStorageProvider);
  return CodeIntelRepository(apiClient: client, apiKeyStorage: apiKeyStorage);
});

class CodeIntelRepository {
  final ApiClient apiClient;
  final ApiKeyStorage apiKeyStorage;

  CodeIntelRepository({
    required this.apiClient,
    ApiKeyStorage? apiKeyStorage,
  }) : apiKeyStorage = apiKeyStorage ?? ApiKeyStorage();

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

  /// Persist an audit-safe suppression for a CVE + package (POST /api/v1/vuln/ignore).
  Future<Map<String, dynamic>> ignoreFinding({
    required String cveId,
    required String package,
    required String reason,
    String? note,
    String? expiresAt,
  }) async {
    final data = await apiClient.post(
      '/v1/vuln/ignore',
      body: {
        'cve_id': cveId,
        'package': package,
        'reason': reason,
        if (note != null && note.isNotEmpty) 'note': note,
        if (expiresAt != null && expiresAt.isNotEmpty) 'expires_at': expiresAt,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Scope Neo4j reachability + SAST/secret checks to touched files (POST /api/v1/vuln/audit-diff).
  Future<DiffAuditResult> auditDiff({
    List<String> files = const [],
    String diff = '',
    String? repo,
  }) async {
    final data = await apiClient.post(
      '/v1/vuln/audit-diff',
      body: {
        'files': files,
        'diff': diff,
        if (repo != null && repo.isNotEmpty) 'repo': repo,
      },
    );
    return DiffAuditResult.fromJson(Map<String, dynamic>.from(data as Map));
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

  /// List indexed repositories for the tenant (GET /api/v1/code/repos).
  Future<List<Map<String, dynamic>>> fetchIndexedRepos() async {
    final data = await apiClient.get('/v1/code/repos');
    final repos = (data as Map)['repos'] as List<dynamic>? ?? const [];
    return repos.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Fetch an indexed source file for line-anchored code citation viewing.
  Future<Map<String, dynamic>> fetchIndexedFile(String path) async {
    final encoded = Uri.encodeQueryComponent(path);
    final data = await apiClient.get('/v1/code/file?path=$encoded');
    return Map<String, dynamic>.from(data as Map);
  }

  /// Stream a scoped follow-up question in the Ask Veraxi sidecar against
  /// `/api/chat` (`stream: true`, `is_temporary: true`).
  Stream<Map<String, dynamic>> streamSidecarAsk({
    required String question,
    VulnFinding? finding,
    String? repoKey,
    String? threadId,
    String? model,
  }) async* {
    final uri = Uri.parse('${apiClient.baseUrl}/chat');
    final headers = await apiClient.getDefaultHeaders()
      ..['Content-Type'] = 'application/json'
      ..['Accept'] = 'text/event-stream';

    final request = http.Request('POST', uri)..headers.addAll(headers);
    final systemPrompt = _buildSidecarSystemPrompt(finding, repoKey);
    final llmOptions = await resolveLlmRequestOptions(apiKeyStorage, model);
    request.body = jsonEncode({
      'question': question,
      if (threadId != null) 'thread_id': threadId,
      'stream': true,
      'is_temporary': true,
      'calculate_grounding': false,
      'custom_system_prompt': systemPrompt,
      ...llmOptions,
    });

    final response = await apiClient.client.send(request);
    if (response.statusCode != 200) {
      final errorBody = await response.stream.bytesToString();
      throw Exception(
          'Sidecar stream error: ${response.statusCode} - $errorBody');
    }

    yield* parseSseJsonStream(response.stream);
  }

  String _buildSidecarSystemPrompt(VulnFinding? finding, String? repoKey) {
    final buf = StringBuffer(
      'You are Veraxi Code Intelligence Sidecar. Answer concisely and ground claims in indexed repository code and vulnerability graph evidence with exact file paths and line numbers. ',
    );
    if (repoKey != null && repoKey.isNotEmpty) {
      buf.write('Active repository scope: $repoKey. ');
    }
    if (finding != null) {
      buf.write(
        'Selected finding: ${finding.cveId} affecting ${finding.package}'
        '${finding.version != null ? ' ${finding.version}' : ''} '
        '(status=${finding.matchStatus}, kev=${finding.kev}'
        '${finding.epssScore != null ? ', epss=${finding.epssScore!.toStringAsFixed(3)}' : ''}'
        '${finding.cweIds.isNotEmpty ? ', cwes=${finding.cweIds.join(",")}' : ''}). ',
      );
      if (finding.reachableInCode.isNotEmpty) {
        final hops = finding.reachableInCode
            .take(5)
            .map((h) =>
                '${h.qualifiedName} (${h.path ?? 'repo'}) via ${h.viaEdge ?? 'CALLS'}')
            .join(' -> ');
        buf.write('Static AST reachability hops: $hops. ');
      }
    }
    return buf.toString();
  }
}
