import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// A single external integration as returned by GET /api/integrations.
/// Secrets are never included — only [hasAuth] indicates stored auth.
class IntegrationModel {
  final String id;
  final String kind; // mcp | oauth | openapi
  final String provider;
  final String slug;
  final String displayName;
  final Map<String, dynamic> config;
  final bool hasAuth;
  final bool isEnabled;
  final String status; // connected | error | expired
  final String? lastSyncedAt;

  const IntegrationModel({
    required this.id,
    required this.kind,
    required this.provider,
    required this.slug,
    required this.displayName,
    required this.config,
    required this.hasAuth,
    required this.isEnabled,
    required this.status,
    this.lastSyncedAt,
  });

  factory IntegrationModel.fromJson(Map<String, dynamic> json) {
    return IntegrationModel(
      id: json['id'] as String,
      kind: json['kind'] as String? ?? 'mcp',
      provider: json['provider'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      config: Map<String, dynamic>.from(json['config'] as Map? ?? {}),
      hasAuth: json['has_auth'] as bool? ?? false,
      isEnabled: json['is_enabled'] as bool? ?? true,
      status: json['status'] as String? ?? 'connected',
      lastSyncedAt: json['last_synced_at'] as String?,
    );
  }

  /// Number of LLM tools this integration contributes, when known.
  int get toolCount {
    final tools = config['tool_names'];
    if (tools is List) return tools.length;
    final ops = config['operations'];
    if (ops is List) return ops.length;
    if (provider == 'github') return 6; // curated GitHub toolset size
    return 0;
  }

  String? get url => config['url'] as String?;
  String get transport => config['transport'] as String? ?? 'auto';
}

/// An OAuth provider catalog entry (GET /api/integrations/oauth/providers).
class OAuthProviderModel {
  final String provider;
  final String displayName;
  final bool enabled;
  final bool configured;

  const OAuthProviderModel({
    required this.provider,
    required this.displayName,
    required this.enabled,
    required this.configured,
  });

  factory OAuthProviderModel.fromJson(Map<String, dynamic> json) {
    return OAuthProviderModel(
      provider: json['provider'] as String,
      displayName:
          json['display_name'] as String? ?? json['provider'] as String,
      enabled: json['enabled'] as bool? ?? false,
      configured: json['configured'] as bool? ?? false,
    );
  }
}

final integrationsRepositoryProvider = Provider<IntegrationsRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return IntegrationsRepository(apiClient: client);
});

class IntegrationsRepository {
  final ApiClient apiClient;

  IntegrationsRepository({required this.apiClient});

  Future<List<IntegrationModel>> getIntegrations() async {
    final data = await apiClient.get('/integrations');
    final list = data['integrations'] as List<dynamic>? ?? [];
    return list
        .cast<Map<String, dynamic>>()
        .map(IntegrationModel.fromJson)
        .toList();
  }

  Future<IntegrationModel> createMcpIntegration({
    required String displayName,
    required String url,
    String transport = 'auto',
    Map<String, String>? headers,
  }) async {
    final data = await apiClient.post('/integrations/mcp', body: {
      'display_name': displayName,
      'url': url,
      'transport': transport,
      if (headers != null && headers.isNotEmpty) 'headers': headers,
    });
    return IntegrationModel.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<IntegrationModel> patchIntegration(
    String id, {
    String? displayName,
    bool? isEnabled,
    Map<String, dynamic>? config,
  }) async {
    final data = await apiClient.patch('/integrations/$id', body: {
      if (displayName != null) 'display_name': displayName,
      if (isEnabled != null) 'is_enabled': isEnabled,
      if (config != null) 'config': config,
    });
    return IntegrationModel.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<void> deleteIntegration(String id) async {
    await apiClient.delete('/integrations/$id');
  }

  /// Live connectivity check; returns discovered tool names + latency.
  Future<Map<String, dynamic>> testIntegration(String id) async {
    final data = await apiClient.post('/integrations/$id/test');
    return Map<String, dynamic>.from(data as Map);
  }

  Future<List<OAuthProviderModel>> getOAuthProviders() async {
    final data = await apiClient.get('/integrations/oauth/providers');
    final list = data['providers'] as List<dynamic>? ?? [];
    return list
        .cast<Map<String, dynamic>>()
        .map(OAuthProviderModel.fromJson)
        .toList();
  }

  /// Begin an OAuth flow; returns the provider authorization URL.
  Future<String> startOAuth(String provider) async {
    final data = await apiClient.get('/integrations/oauth/$provider/start');
    return data['authorization_url'] as String;
  }

  Future<Map<String, dynamic>> syncIntegration(
    String id, {
    required List<String> repos,
    bool includeIssues = false,
  }) async {
    final data = await apiClient.post('/integrations/$id/sync', body: {
      'repos': repos,
      'include_issues': includeIssues,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> previewOpenApi({
    String? specText,
    String? specUrl,
  }) async {
    final data = await apiClient.post('/integrations/openapi/preview', body: {
      if (specText != null) 'spec_text': specText,
      if (specUrl != null) 'spec_url': specUrl,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  Future<IntegrationModel> createOpenApiIntegration({
    String? displayName,
    String? specText,
    String? specUrl,
    required List<String> selectedOperationIds,
    String? serverUrl,
    String authType = 'bearer',
    String? authValue,
    String? authName,
  }) async {
    final data = await apiClient.post('/integrations/openapi', body: {
      if (displayName != null) 'display_name': displayName,
      if (specText != null) 'spec_text': specText,
      if (specUrl != null) 'spec_url': specUrl,
      'selected_operation_ids': selectedOperationIds,
      if (serverUrl != null) 'server_url': serverUrl,
      'auth_type': authType,
      if (authValue != null) 'auth_value': authValue,
      if (authName != null) 'auth_name': authName,
    });
    return IntegrationModel.fromJson(Map<String, dynamic>.from(data as Map));
  }
}
