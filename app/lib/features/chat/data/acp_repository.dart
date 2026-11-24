import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/network/api_client.dart';

final acpRepositoryProvider = Provider<AcpRepository>((ref) {
  return AcpRepository(apiClient: ref.watch(apiClientProvider));
});

class AcpUsageSummary {
  final bool available;
  final int conversationCount;
  final int? totalTokens;
  final double? quotaRemainingPct;

  const AcpUsageSummary({
    this.available = false,
    this.conversationCount = 0,
    this.totalTokens,
    this.quotaRemainingPct,
  });

  factory AcpUsageSummary.fromJson(Map<String, dynamic> json) {
    return AcpUsageSummary(
      available: json['available'] == true,
      conversationCount: (json['conversation_count'] as num?)?.toInt() ?? 0,
      totalTokens: (json['total_tokens'] as num?)?.toInt(),
      quotaRemainingPct: (json['quota_remaining_pct'] as num?)?.toDouble(),
    );
  }
}

const List<String> defaultAntigravityModels = [
  'gemini-4-neon-high',
  'gemini-4-neon-xhigh',
  'gemini-4-neon-medium',
  'gemini-4-neon-low',
  'gemini-4-carbon-high',
  'gemini-4-carbon-medium',
  'gemini-4-carbon-low',
  'gemini-4-argon-high',
  'gemini-4-argon-medium',
  'gemini-4-argon-low',
  'gemini-4-hydrogen-high',
  'gemini-4-hydrogen-xhigh',
  'gemini-4-hydrogen-medium',
  'gemini-4-hydrogen-low',
  'gemini-pro-orchestrator-neon',
  'gemini-pro-orchestrator',
  'gemini-pro-orchestrator-argon',
  'gemini-3.8-flash-high',
  'gemini-3.8-flash-medium',
  'gemini-3.8-flash-low',
  'claude-opus-5-5-high',
  'claude-opus-5-5-medium',
  'claude-opus-5-5-low',
  'claude-sonnet-5-5-high',
  'claude-sonnet-5-5-medium',
  'claude-sonnet-5-5-low',
  'gpt-oss-120b-medium',
];

class AcpStatus {
  final bool available;
  final bool acpEnabled;
  final String transport;
  final String binary;
  final bool runnerConnected;
  final List<String> models;
  final AcpUsageSummary usage;

  const AcpStatus({
    this.available = false,
    this.acpEnabled = false,
    this.transport = 'unavailable',
    this.binary = 'agy',
    this.runnerConnected = false,
    this.models = defaultAntigravityModels,
    this.usage = const AcpUsageSummary(),
  });

  factory AcpStatus.fromJson(Map<String, dynamic> json) {
    final usageRaw = json['usage'];
    final rawModels = json['models'];
    final parsedModels = rawModels is List
        ? rawModels.whereType<String>().where((m) => m.isNotEmpty).toList()
        : const <String>[];
    return AcpStatus(
      available: json['available'] == true,
      acpEnabled: json['acp_enabled'] == true,
      transport: json['transport'] as String? ?? 'unavailable',
      binary: json['binary'] as String? ?? 'agy',
      runnerConnected: json['runner_connected'] == true,
      models: parsedModels.isNotEmpty ? parsedModels : defaultAntigravityModels,
      usage: usageRaw is Map<String, dynamic>
          ? AcpUsageSummary.fromJson(usageRaw)
          : const AcpUsageSummary(),
    );
  }
}

class AcpRepository {
  final ApiClient apiClient;

  AcpRepository({required this.apiClient});

  Future<AcpStatus> fetchStatus() async {
    try {
      final raw = await apiClient.get('/acp/status');
      return AcpStatus.fromJson(Map<String, dynamic>.from(raw as Map));
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      return const AcpStatus();
    }
  }

  Future<bool> resolvePermission({
    required String sessionId,
    required String requestId,
    required String outcome,
  }) async {
    try {
      final res = await apiClient.post(
        '/acp/sessions/$sessionId/permission',
        body: {'request_id': requestId, 'outcome': outcome},
      );
      return res['resolved'] == true;
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      return false;
    }
  }

  Future<bool> cancelSession(String sessionId) async {
    try {
      final res = await apiClient.post('/acp/sessions/$sessionId/cancel', body: {});
      return res['cancelled'] == true;
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      return false;
    }
  }
}
