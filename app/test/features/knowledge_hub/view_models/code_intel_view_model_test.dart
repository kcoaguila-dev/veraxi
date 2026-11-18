import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/knowledge_hub/data/code_intel_repository.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';

class RecordingCodeIntelRepository extends CodeIntelRepository {
  RecordingCodeIntelRepository()
      : super(
          apiClient: ApiClient(
            baseUrl: 'https://api.test/api',
            tenantId: 'test-token',
          ),
        );

  String? lastRepoPath;
  bool? lastIncludeReachability;
  Map<String, dynamic>? lastSbomJson;
  Map<String, dynamic>? lastSarif;
  dynamic lastRecon;
  Map<String, dynamic>? lastStix;
  bool attackSyncCalled = false;
  dynamic lastAlerts;

  @override
  Future<VulnReport> runVulnReport({
    String? repoPath,
    bool includeReachability = false,
    Map<String, dynamic>? sbomJson,
  }) async {
    lastRepoPath = repoPath;
    lastIncludeReachability = includeReachability;
    lastSbomJson = sbomJson;
    return const VulnReport(dependenciesChecked: 1);
  }

  @override
  Future<SarifIngestResult> ingestSarif(Map<String, dynamic> sarif) async {
    lastSarif = sarif;
    return const SarifIngestResult(
      findingsWritten: 5,
      fileLinks: 5,
      cweLinks: 2,
    );
  }

  @override
  Future<ReconIngestResult> ingestRecon(dynamic nucleiPayload) async {
    lastRecon = nucleiPayload;
    return const ReconIngestResult(
      findingsWritten: 3,
      hostLinks: 2,
      cveLinks: 1,
    );
  }

  @override
  Future<AttackSyncResult> syncAttackIntel({
    Map<String, dynamic>? stixJson,
  }) async {
    attackSyncCalled = true;
    lastStix = stixJson;
    return const AttackSyncResult(
      techniquesWritten: 10,
      tacticsWritten: 3,
      mitigationsWritten: 4,
    );
  }

  @override
  Future<AlertIngestResult> ingestAlerts(dynamic alerts) async {
    lastAlerts = alerts;
    return const AlertIngestResult(
      alertsWritten: 7,
      iocLinks: 2,
      techniqueLinks: 1,
    );
  }
}

Map<String, dynamic> sarifWithTaint() {
  return {
    'version': '2.1.0',
    'runs': [
      {
        'tool': {
          'driver': {'name': 'codeql'}
        },
        'results': [
          {
            'ruleId': 'py/sql-injection',
            'codeFlows': [
              {
                'threadFlows': [
                  {
                    'locations': [
                      {
                        'location': {
                          'physicalLocation': {
                            'artifactLocation': {'uri': 'app/views.py'},
                            'region': {'startLine': 14},
                          },
                        },
                      },
                      {
                        'location': {
                          'physicalLocation': {
                            'artifactLocation': {'uri': 'app/db.py'},
                            'region': {'startLine': 88},
                          },
                        },
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  };
}

void main() {
  group('CodeIntelViewModel security actions', () {
    test('ingestSarif records status and extracts taint flows', () async {
      final repo = RecordingCodeIntelRepository();
      final vm = CodeIntelViewModel(repo);
      await vm.ingestSarif(sarifWithTaint());
      expect(vm.state.sarifBusy, isFalse);
      expect(vm.state.sarifError, isNull);
      expect(vm.state.sarifStatus, contains('Ingested 5 findings'));
      expect(vm.state.sarifTaintFlows, hasLength(1));
      expect(vm.state.sarifTaintFlows.single.ruleId, 'py/sql-injection');
      expect(vm.state.sarifTaintFlows.single.steps,
          ['app/views.py:14', 'app/db.py:88']);
    });

    test('ingestSarifText rejects invalid JSON without calling the repo',
        () async {
      final repo = RecordingCodeIntelRepository();
      final vm = CodeIntelViewModel(repo);
      await vm.ingestSarifText('{not json');
      expect(vm.state.sarifError, 'SARIF file is not valid JSON');
      expect(repo.lastSarif, isNull);
    });

    test('ingestRecon passes raw JSONL text through and records status',
        () async {
      final repo = RecordingCodeIntelRepository();
      final vm = CodeIntelViewModel(repo);
      const jsonl = '{"template-id":"x"}\n{"template-id":"y"}';
      await vm.ingestRecon(jsonl);
      expect(repo.lastRecon, jsonl);
      expect(vm.state.reconStatus, contains('Ingested 3 findings'));
    });

    test('syncAttackIntel without a bundle lets the backend fetch STIX',
        () async {
      final repo = RecordingCodeIntelRepository();
      final vm = CodeIntelViewModel(repo);
      await vm.syncAttackIntel();
      expect(repo.attackSyncCalled, isTrue);
      expect(repo.lastStix, isNull);
      expect(vm.state.attackStatus, contains('Synced 10 techniques'));
    });

    test('syncAttackIntelFromText forwards a parsed STIX bundle', () async {
      final repo = RecordingCodeIntelRepository();
      final vm = CodeIntelViewModel(repo);
      await vm.syncAttackIntelFromText(
          jsonEncode({'type': 'bundle', 'objects': []}));
      expect(repo.lastStix?['type'], 'bundle');
      expect(vm.state.attackError, isNull);
    });

    test('ingestAlertsText parses a JSON list and records status', () async {
      final repo = RecordingCodeIntelRepository();
      final vm = CodeIntelViewModel(repo);
      await vm.ingestAlertsText('[{"id": "a1"}]');
      expect(repo.lastAlerts, isList);
      expect(vm.state.alertsStatus, contains('Ingested 7 alerts'));
    });

    test('SBOM upload becomes the scan source with reachability', () async {
      final repo = RecordingCodeIntelRepository();
      final vm = CodeIntelViewModel(repo);
      vm.setSbomFromText('{"bomFormat": "CycloneDX", "components": []}',
          fileName: 'sbom.json');
      expect(vm.state.sbomFileName, 'sbom.json');
      expect(vm.state.vulnError, isNull);
      vm.setIncludeReachability(true);
      await vm.runVulnScan('/repos/demo');
      expect(repo.lastSbomJson?['bomFormat'], 'CycloneDX');
      expect(repo.lastRepoPath, isNull);
      expect(repo.lastIncludeReachability, isTrue);
      vm.clearSbom();
      expect(vm.state.sbomJson, isNull);
      await vm.runVulnScan('/repos/demo');
      expect(repo.lastRepoPath, '/repos/demo');
    });

    test('invalid SBOM text sets an error and keeps the scan source', () async {
      final repo = RecordingCodeIntelRepository();
      final vm = CodeIntelViewModel(repo);
      vm.setSbomFromText('[1,2,3]', fileName: 'bad.json');
      expect(vm.state.sbomJson, isNull);
      expect(vm.state.vulnError, contains('not valid JSON'));
    });
  });
}
