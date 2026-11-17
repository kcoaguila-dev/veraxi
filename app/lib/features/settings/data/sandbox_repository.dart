import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// Sandbox configuration as returned by GET /api/v1/sandboxes/config.
///
/// Secrets are never included — only [hasSecrets] indicates that the
/// tenant has stored provider credentials server-side. Saving accepts
/// write-only secrets via [SandboxRepository.saveConfig].
class SandboxConfig {
  final String provider; // disabled | modal | e2b | remote_mcp | local_runner
  final String displayName;
  final String baseImage;
  final int cpuCores;
  final int memoryMb;
  final int diskGb;
  final int idleTimeoutSec;
  final int maxSessionSec;
  final String autonomyMode; // ask_all | auto_read_test | autonomous
  final String egressMode; // offline | allowlist | unrestricted
  final List<String> allowedDomains;
  final bool isolateGitBranch;
  final Map<String, dynamic> config;
  final bool hasSecrets;

  const SandboxConfig({
    this.provider = 'disabled',
    this.displayName = '',
    this.baseImage = 'polyglot',
    this.cpuCores = 2,
    this.memoryMb = 4096,
    this.diskGb = 10,
    this.idleTimeoutSec = 900,
    this.maxSessionSec = 3600,
    this.autonomyMode = 'auto_read_test',
    this.egressMode = 'allowlist',
    this.allowedDomains = const [
      'pypi.org',
      'files.pythonhosted.org',
      'registry.npmjs.org',
      'pub.dev',
      'github.com',
    ],
    this.isolateGitBranch = true,
    this.config = const {},
    this.hasSecrets = false,
  });

  factory SandboxConfig.fromJson(Map<String, dynamic> json) {
    return SandboxConfig(
      provider: json['provider'] as String? ?? 'disabled',
      displayName: json['display_name'] as String? ?? '',
      baseImage: json['base_image'] as String? ?? 'polyglot',
      cpuCores: (json['cpu_cores'] as num?)?.toInt() ?? 2,
      memoryMb: (json['memory_mb'] as num?)?.toInt() ?? 4096,
      diskGb: (json['disk_gb'] as num?)?.toInt() ?? 10,
      idleTimeoutSec: (json['idle_timeout_sec'] as num?)?.toInt() ?? 900,
      maxSessionSec: (json['max_session_sec'] as num?)?.toInt() ?? 3600,
      autonomyMode: json['autonomy_mode'] as String? ?? 'auto_read_test',
      egressMode: json['egress_mode'] as String? ?? 'allowlist',
      allowedDomains: (json['allowed_domains'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      isolateGitBranch: json['isolate_git_branch'] as bool? ?? true,
      config: Map<String, dynamic>.from(json['config'] as Map? ?? {}),
      hasSecrets: json['has_secrets'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'provider': provider,
      'display_name': displayName,
      'base_image': baseImage,
      'cpu_cores': cpuCores,
      'memory_mb': memoryMb,
      'disk_gb': diskGb,
      'idle_timeout_sec': idleTimeoutSec,
      'max_session_sec': maxSessionSec,
      'autonomy_mode': autonomyMode,
      'egress_mode': egressMode,
      'allowed_domains': allowedDomains,
      'isolate_git_branch': isolateGitBranch,
      'config': config,
    };
  }

  /// Remote MCP endpoint URL (stored in the non-secret [config] bag).
  String get remoteUrl => config['url'] as String? ?? '';

  SandboxConfig copyWith({
    String? provider,
    String? displayName,
    String? baseImage,
    int? cpuCores,
    int? memoryMb,
    int? diskGb,
    int? idleTimeoutSec,
    int? maxSessionSec,
    String? autonomyMode,
    String? egressMode,
    List<String>? allowedDomains,
    bool? isolateGitBranch,
    Map<String, dynamic>? config,
    bool? hasSecrets,
  }) {
    return SandboxConfig(
      provider: provider ?? this.provider,
      displayName: displayName ?? this.displayName,
      baseImage: baseImage ?? this.baseImage,
      cpuCores: cpuCores ?? this.cpuCores,
      memoryMb: memoryMb ?? this.memoryMb,
      diskGb: diskGb ?? this.diskGb,
      idleTimeoutSec: idleTimeoutSec ?? this.idleTimeoutSec,
      maxSessionSec: maxSessionSec ?? this.maxSessionSec,
      autonomyMode: autonomyMode ?? this.autonomyMode,
      egressMode: egressMode ?? this.egressMode,
      allowedDomains: allowedDomains ?? this.allowedDomains,
      isolateGitBranch: isolateGitBranch ?? this.isolateGitBranch,
      config: config ?? this.config,
      hasSecrets: hasSecrets ?? this.hasSecrets,
    );
  }
}

/// Result of POST /api/v1/sandboxes/test.
class SandboxTestResult {
  final bool ok;
  final int? latencyMs;
  final String output;
  final String? error;

  const SandboxTestResult({
    required this.ok,
    this.latencyMs,
    this.output = '',
    this.error,
  });

  factory SandboxTestResult.fromJson(Map<String, dynamic> json) {
    return SandboxTestResult(
      ok: json['ok'] as bool? ?? false,
      latencyMs: (json['latency_ms'] as num?)?.toInt(),
      output: json['output'] as String? ?? '',
      error: json['error'] as String?,
    );
  }
}

/// One live sandbox session from GET /api/v1/sandboxes/sessions.
class SandboxSessionInfo {
  final String id;
  final String status; // starting | running | paused | stopped | error
  final String provider;
  final String? gitBranch;
  final String? lastActiveAt;

  const SandboxSessionInfo({
    required this.id,
    required this.status,
    this.provider = '',
    this.gitBranch,
    this.lastActiveAt,
  });

  factory SandboxSessionInfo.fromJson(Map<String, dynamic> json) {
    return SandboxSessionInfo(
      id: json['id'] as String,
      status: json['status'] as String? ?? 'running',
      provider: json['provider'] as String? ?? '',
      gitBranch: json['git_branch'] as String?,
      lastActiveAt: json['last_active_at'] as String?,
    );
  }
}

final sandboxRepositoryProvider = Provider<SandboxRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return SandboxRepository(apiClient: client);
});

class SandboxRepository {
  final ApiClient apiClient;

  SandboxRepository({required this.apiClient});

  Future<SandboxConfig> getConfig() async {
    final data = await apiClient.get('/v1/sandboxes/config');
    return SandboxConfig.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Saves [config]. [secrets] is write-only: non-empty entries are
  /// sent once and encrypted server-side; they are never read back.
  Future<SandboxConfig> saveConfig(
    SandboxConfig config, {
    Map<String, String>? secrets,
  }) async {
    final body = config.toJson();
    if (secrets != null && secrets.isNotEmpty) {
      body['secrets'] = secrets;
    }
    final data = await apiClient.put('/v1/sandboxes/config', body: body);
    if (data is Map) {
      return SandboxConfig.fromJson(Map<String, dynamic>.from(data));
    }
    return config;
  }

  Future<SandboxTestResult> testSandbox() async {
    final data = await apiClient.post('/v1/sandboxes/test');
    return SandboxTestResult.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<List<SandboxSessionInfo>> getSessions() async {
    final data = await apiClient.get('/v1/sandboxes/sessions');
    final list =
        (data as Map)['sessions'] as List<dynamic>? ?? const <dynamic>[];
    return list
        .cast<Map<String, dynamic>>()
        .map(SandboxSessionInfo.fromJson)
        .toList();
  }

  Future<void> pauseSession(String id) async {
    await apiClient.post('/v1/sandboxes/sessions/$id/pause');
  }

  Future<void> destroySession(String id) async {
    await apiClient.delete('/v1/sandboxes/sessions/$id');
  }
}
