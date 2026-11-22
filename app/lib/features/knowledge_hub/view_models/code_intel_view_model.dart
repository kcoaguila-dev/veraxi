import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/knowledge_hub/data/code_intel_repository.dart';

// Re-export the models so views can import them from the ViewModel
// layer without violating the views → view_models → data contract.
export 'package:veraxi_app/features/knowledge_hub/data/code_intel_repository.dart'
    show
        AlertIngestResult,
        AttackSyncResult,
        CodeIndexFreshness,
        CodeOverview,
        CodeSymbolMatch,
        ImpactedSymbol,
        ReconIngestResult,
        SarifIngestResult,
        SarifTaintFlow,
        TopConnectedSymbol,
        VulnFinding,
        VulnReport;

/// Quick-filter values for the Vuln Intel findings list, following the
/// prioritization stack rivals converge on (exploited and reachable
/// first, severity second): All / KEV Only / High EPSS / Reachable.
abstract final class VulnQuickFilter {
  static const String all = 'ALL';
  static const String kevOnly = 'KEV_ONLY';
  static const String highEpss = 'HIGH_EPSS';
  static const String reachable = 'REACHABLE';

  /// EPSS threshold for the High EPSS quick filter.
  static const double highEpssThreshold = 0.5;
}

/// State for the Repo X-Ray & Vuln Intel workbench.
class CodeIntelState {
  final bool indexing;
  final String? indexStatus;
  final String? indexError;
  final CodeOverview? overview;
  final bool loadingOverview;
  final List<CodeSymbolMatch> symbolMatches;
  final String? symbolSearched;
  final List<ImpactedSymbol> impacted;
  final String? impactSymbol;
  final bool syncingVuln;
  final String? syncStatus;
  final bool scanningVuln;
  final VulnReport? vulnReport;
  final String? vulnError;
  final String severityFilter;
  final bool kevOnly;
  final bool matchedOnly;

  /// Whether the next vuln scan asks the backend to attach code-graph
  /// reachability (reachable files/symbols) to each finding.
  final bool includeReachability;

  /// Parsed SBOM (CycloneDX/SPDX) uploaded by the user. When set, the
  /// next scan uses it as the dependency source instead of a repo path.
  final Map<String, dynamic>? sbomJson;
  final String? sbomFileName;

  /// One of [VulnQuickFilter]'s values.
  final String vulnQuickFilter;

  // Security Feed (SAST / Recon / ATT&CK / SOC) per-source state.
  final bool sarifBusy;
  final String? sarifStatus;
  final String? sarifError;
  final List<SarifTaintFlow> sarifTaintFlows;
  final bool reconBusy;
  final String? reconStatus;
  final String? reconError;
  final bool attackBusy;
  final String? attackStatus;
  final String? attackError;
  final bool alertsBusy;
  final String? alertsStatus;
  final String? alertsError;

  const CodeIntelState({
    this.indexing = false,
    this.indexStatus,
    this.indexError,
    this.overview,
    this.loadingOverview = false,
    this.symbolMatches = const [],
    this.symbolSearched,
    this.impacted = const [],
    this.impactSymbol,
    this.syncingVuln = false,
    this.syncStatus,
    this.scanningVuln = false,
    this.vulnReport,
    this.vulnError,
    this.severityFilter = 'ALL',
    this.kevOnly = false,
    this.matchedOnly = false,
    this.includeReachability = false,
    this.sbomJson,
    this.sbomFileName,
    this.vulnQuickFilter = VulnQuickFilter.all,
    this.sarifBusy = false,
    this.sarifStatus,
    this.sarifError,
    this.sarifTaintFlows = const [],
    this.reconBusy = false,
    this.reconStatus,
    this.reconError,
    this.attackBusy = false,
    this.attackStatus,
    this.attackError,
    this.alertsBusy = false,
    this.alertsStatus,
    this.alertsError,
  });

  /// Findings after the client-side severity/KEV/status filters.
  List<VulnFinding> get filteredFindings {
    final report = vulnReport;
    if (report == null) return const [];
    return report.findings.where((finding) {
      if (severityFilter != 'ALL' &&
          (finding.severity ?? '').toUpperCase() != severityFilter) {
        return false;
      }
      if (kevOnly && !finding.kev) return false;
      if (matchedOnly && !finding.isMatched) return false;
      switch (vulnQuickFilter) {
        case VulnQuickFilter.kevOnly:
          if (!finding.kev) return false;
        case VulnQuickFilter.highEpss:
          if ((finding.epssScore ?? 0) < VulnQuickFilter.highEpssThreshold) {
            return false;
          }
        case VulnQuickFilter.reachable:
          if (!finding.isReachable) return false;
      }
      return true;
    }).toList();
  }

  CodeIntelState copyWith({
    bool? indexing,
    String? indexStatus,
    bool clearIndexStatus = false,
    String? indexError,
    bool clearIndexError = false,
    CodeOverview? overview,
    bool? loadingOverview,
    List<CodeSymbolMatch>? symbolMatches,
    String? symbolSearched,
    List<ImpactedSymbol>? impacted,
    String? impactSymbol,
    bool? syncingVuln,
    String? syncStatus,
    bool clearSyncStatus = false,
    bool? scanningVuln,
    VulnReport? vulnReport,
    String? vulnError,
    bool clearVulnError = false,
    String? severityFilter,
    bool? kevOnly,
    bool? matchedOnly,
    bool? includeReachability,
    Map<String, dynamic>? sbomJson,
    String? sbomFileName,
    bool clearSbom = false,
    String? vulnQuickFilter,
    bool? sarifBusy,
    String? sarifStatus,
    bool clearSarifStatus = false,
    String? sarifError,
    bool clearSarifError = false,
    List<SarifTaintFlow>? sarifTaintFlows,
    bool? reconBusy,
    String? reconStatus,
    bool clearReconStatus = false,
    String? reconError,
    bool clearReconError = false,
    bool? attackBusy,
    String? attackStatus,
    bool clearAttackStatus = false,
    String? attackError,
    bool clearAttackError = false,
    bool? alertsBusy,
    String? alertsStatus,
    bool clearAlertsStatus = false,
    String? alertsError,
    bool clearAlertsError = false,
  }) {
    return CodeIntelState(
      indexing: indexing ?? this.indexing,
      indexStatus: clearIndexStatus ? null : (indexStatus ?? this.indexStatus),
      indexError: clearIndexError ? null : (indexError ?? this.indexError),
      overview: overview ?? this.overview,
      loadingOverview: loadingOverview ?? this.loadingOverview,
      symbolMatches: symbolMatches ?? this.symbolMatches,
      symbolSearched: symbolSearched ?? this.symbolSearched,
      impacted: impacted ?? this.impacted,
      impactSymbol: impactSymbol ?? this.impactSymbol,
      syncingVuln: syncingVuln ?? this.syncingVuln,
      syncStatus: clearSyncStatus ? null : (syncStatus ?? this.syncStatus),
      scanningVuln: scanningVuln ?? this.scanningVuln,
      vulnReport: vulnReport ?? this.vulnReport,
      vulnError: clearVulnError ? null : (vulnError ?? this.vulnError),
      severityFilter: severityFilter ?? this.severityFilter,
      kevOnly: kevOnly ?? this.kevOnly,
      matchedOnly: matchedOnly ?? this.matchedOnly,
      includeReachability: includeReachability ?? this.includeReachability,
      sbomJson: clearSbom ? null : (sbomJson ?? this.sbomJson),
      sbomFileName: clearSbom ? null : (sbomFileName ?? this.sbomFileName),
      vulnQuickFilter: vulnQuickFilter ?? this.vulnQuickFilter,
      sarifBusy: sarifBusy ?? this.sarifBusy,
      sarifStatus: clearSarifStatus ? null : (sarifStatus ?? this.sarifStatus),
      sarifError: clearSarifError ? null : (sarifError ?? this.sarifError),
      sarifTaintFlows: sarifTaintFlows ?? this.sarifTaintFlows,
      reconBusy: reconBusy ?? this.reconBusy,
      reconStatus: clearReconStatus ? null : (reconStatus ?? this.reconStatus),
      reconError: clearReconError ? null : (reconError ?? this.reconError),
      attackBusy: attackBusy ?? this.attackBusy,
      attackStatus:
          clearAttackStatus ? null : (attackStatus ?? this.attackStatus),
      attackError: clearAttackError ? null : (attackError ?? this.attackError),
      alertsBusy: alertsBusy ?? this.alertsBusy,
      alertsStatus:
          clearAlertsStatus ? null : (alertsStatus ?? this.alertsStatus),
      alertsError: clearAlertsError ? null : (alertsError ?? this.alertsError),
    );
  }
}

final codeIntelViewModelProvider =
    StateNotifierProvider<CodeIntelViewModel, CodeIntelState>((ref) {
  final repository = ref.watch(codeIntelRepositoryProvider);
  return CodeIntelViewModel(repository);
});

class CodeIntelViewModel extends StateNotifier<CodeIntelState> {
  final CodeIntelRepository _repository;

  CodeIntelViewModel(this._repository) : super(const CodeIntelState());

  Future<void> indexRepo(String repoPath) async {
    final path = repoPath.trim();
    if (path.isEmpty) {
      state = state.copyWith(indexError: 'Enter a repository path first');
      return;
    }
    state = state.copyWith(
      indexing: true,
      clearIndexError: true,
      clearIndexStatus: true,
    );
    try {
      final result = await _repository.ingestRepo(path);
      state = state.copyWith(
        indexing: false,
        indexStatus:
            'Indexed ${result['nodes_written'] ?? 0} nodes, ${result['edges_written'] ?? 0} edges',
      );
      await loadOverview();
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        indexing: false,
        indexError:
            'Indexing failed — check the path is inside an allowed root',
      );
    }
  }

  Future<void> loadOverview() async {
    state = state.copyWith(loadingOverview: true);
    try {
      final overview = await _repository.fetchOverview();
      state = state.copyWith(overview: overview, loadingOverview: false);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(loadingOverview: false);
    }
  }

  Future<void> searchSymbol(String name) async {
    final query = name.trim();
    if (query.isEmpty) return;
    try {
      final matches = await _repository.lookupSymbol(query);
      state = state.copyWith(symbolMatches: matches, symbolSearched: query);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(symbolMatches: const [], symbolSearched: query);
    }
  }

  Future<void> analyzeImpact(String symbol) async {
    final query = symbol.trim();
    if (query.isEmpty) return;
    try {
      final impacted = await _repository.impactAnalysis(query);
      state = state.copyWith(impacted: impacted, impactSymbol: query);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(impacted: const [], impactSymbol: query);
    }
  }

  Future<void> syncVulnIntel() async {
    state = state.copyWith(syncingVuln: true, clearSyncStatus: true);
    try {
      final result = await _repository.syncVulnIntel();
      state = state.copyWith(
        syncingVuln: false,
        syncStatus: 'Synced ${result['cves_written'] ?? 0} CVEs',
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        syncingVuln: false,
        syncStatus: 'Sync failed — NVD/KEV unreachable',
      );
    }
  }

  Future<void> runVulnScan(String repoPath) async {
    final path = repoPath.trim();
    state = state.copyWith(scanningVuln: true, clearVulnError: true);
    try {
      final sbom = state.sbomJson;
      final report = sbom != null
          ? await _repository.runVulnReport(
              sbomJson: sbom,
              includeReachability: state.includeReachability,
            )
          : await _repository.runVulnReport(
              repoPath: path.isEmpty ? null : path,
              includeReachability: state.includeReachability,
            );
      state = state.copyWith(scanningVuln: false, vulnReport: report);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        scanningVuln: false,
        vulnError: 'Vulnerability scan failed',
      );
    }
  }

  void setSeverityFilter(String severity) {
    state = state.copyWith(severityFilter: severity);
  }

  void setKevOnly(bool value) {
    state = state.copyWith(kevOnly: value);
  }

  void setMatchedOnly(bool value) {
    state = state.copyWith(matchedOnly: value);
  }

  void setVulnQuickFilter(String filter) {
    state = state.copyWith(vulnQuickFilter: filter);
  }

  void setIncludeReachability(bool value) {
    state = state.copyWith(includeReachability: value);
  }

  /// Store an uploaded SBOM parsed from [text] (CycloneDX or SPDX JSON).
  /// Invalid JSON is reported through [CodeIntelState.vulnError] and
  /// leaves any previous SBOM untouched.
  void setSbomFromText(String text, {required String fileName}) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('SBOM root is not a JSON object');
      }
      state = state.copyWith(
        sbomJson: Map<String, dynamic>.from(decoded),
        sbomFileName: fileName,
        clearVulnError: true,
      );
    } on FormatException catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        vulnError: 'SBOM file is not valid JSON — scan source unchanged',
      );
    }
  }

  void clearSbom() {
    state = state.copyWith(clearSbom: true);
  }

  /// Ingest an uploaded SARIF 2.1.0 document given as raw file [text].
  /// Taint flows are extracted from the same payload for display,
  /// because the ingest endpoint returns counts only.
  Future<void> ingestSarifText(String text) async {
    final Map<String, dynamic> sarif;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('SARIF root is not a JSON object');
      }
      sarif = Map<String, dynamic>.from(decoded);
    } on FormatException catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(sarifError: 'SARIF file is not valid JSON');
      return;
    }
    await ingestSarif(sarif);
  }

  Future<void> ingestSarif(Map<String, dynamic> sarif) async {
    state = state.copyWith(
      sarifBusy: true,
      clearSarifStatus: true,
      clearSarifError: true,
      sarifTaintFlows: extractSarifTaintFlows(sarif),
    );
    try {
      final result = await _repository.ingestSarif(sarif);
      state = state.copyWith(
        sarifBusy: false,
        sarifStatus: 'Ingested ${result.findingsWritten} findings · '
            '${result.fileLinks} file links · ${result.cweLinks} CWE links',
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        sarifBusy: false,
        sarifError: 'SARIF ingest failed',
      );
    }
  }

  /// Ingest Nuclei output. Raw JSON/JSONL [text] is passed through to
  /// the backend parser unchanged.
  Future<void> ingestRecon(dynamic nucleiPayload) async {
    state = state.copyWith(
      reconBusy: true,
      clearReconStatus: true,
      clearReconError: true,
    );
    try {
      final result = await _repository.ingestRecon(nucleiPayload);
      state = state.copyWith(
        reconBusy: false,
        reconStatus: 'Ingested ${result.findingsWritten} findings · '
            '${result.hostLinks} hosts · ${result.cveLinks} CVE links',
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        reconBusy: false,
        reconError: 'Recon ingest failed',
      );
    }
  }

  /// Sync MITRE ATT&CK intel; with no uploaded STIX bundle the backend
  /// fetches the current bundle itself.
  Future<void> syncAttackIntel({Map<String, dynamic>? stixJson}) async {
    state = state.copyWith(
      attackBusy: true,
      clearAttackStatus: true,
      clearAttackError: true,
    );
    try {
      final result = await _repository.syncAttackIntel(stixJson: stixJson);
      state = state.copyWith(
        attackBusy: false,
        attackStatus: 'Synced ${result.techniquesWritten} techniques · '
            '${result.tacticsWritten} tactics · '
            '${result.mitigationsWritten} mitigations',
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        attackBusy: false,
        attackError: 'ATT&CK sync failed',
      );
    }
  }

  /// Sync ATT&CK from an uploaded STIX bundle given as raw file [text].
  Future<void> syncAttackIntelFromText(String text) async {
    final Map<String, dynamic> bundle;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('STIX root is not a JSON object');
      }
      bundle = Map<String, dynamic>.from(decoded);
    } on FormatException catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(attackError: 'STIX file is not valid JSON');
      return;
    }
    await syncAttackIntel(stixJson: bundle);
  }

  /// Ingest SOC alerts / IOCs from an uploaded JSON file's [text]
  /// (a JSON object or list, both accepted by the backend parser).
  Future<void> ingestAlertsText(String text) async {
    final dynamic alerts;
    try {
      alerts = jsonDecode(text);
    } on FormatException catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(alertsError: 'Alerts file is not valid JSON');
      return;
    }
    await ingestAlerts(alerts);
  }

  Future<void> ingestAlerts(dynamic alerts) async {
    state = state.copyWith(
      alertsBusy: true,
      clearAlertsStatus: true,
      clearAlertsError: true,
    );
    try {
      final result = await _repository.ingestAlerts(alerts);
      state = state.copyWith(
        alertsBusy: false,
        alertsStatus: 'Ingested ${result.alertsWritten} alerts · '
            '${result.iocLinks} IOC links · '
            '${result.techniqueLinks} technique links',
      );
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(
        alertsBusy: false,
        alertsError: 'Alert ingest failed',
      );
    }
  }
}
