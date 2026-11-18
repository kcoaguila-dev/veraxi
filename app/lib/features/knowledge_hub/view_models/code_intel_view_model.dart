import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/knowledge_hub/data/code_intel_repository.dart';

// Re-export the models so views can import them from the ViewModel
// layer without violating the views → view_models → data contract.
export 'package:veraxi_app/features/knowledge_hub/data/code_intel_repository.dart'
    show
        CodeOverview,
        CodeSymbolMatch,
        ImpactedSymbol,
        TopConnectedSymbol,
        VulnFinding,
        VulnReport;

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
      final report =
          await _repository.runVulnReport(repoPath: path.isEmpty ? null : path);
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
}
