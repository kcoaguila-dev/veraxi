import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// Model representing a single API key as returned by the backend list endpoint.
/// The raw key itself is never included here.
class ApiKeyModel {
  final String id;
  final String name;
  final String keyPrefix;
  final String createdAt;
  final String? lastUsedAt;
  final String? expiresAt;

  const ApiKeyModel({
    required this.id,
    required this.name,
    required this.keyPrefix,
    required this.createdAt,
    this.lastUsedAt,
    this.expiresAt,
  });

  factory ApiKeyModel.fromJson(Map<String, dynamic> json) {
    return ApiKeyModel(
      id: json['id'] as String,
      name: json['name'] as String,
      keyPrefix: json['key_prefix'] as String,
      createdAt: json['created_at'] as String,
      lastUsedAt: json['last_used_at'] as String?,
      expiresAt: json['expires_at'] as String?,
    );
  }
}

final apiKeysRepositoryProvider = Provider<ApiKeysRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return ApiKeysRepository(apiClient: client);
});

class ApiKeysRepository {
  final ApiClient apiClient;

  ApiKeysRepository({required this.apiClient});

  /// Fetch all active API keys for the current user (never includes raw keys).
  Future<List<ApiKeyModel>> getApiKeys() async {
    final data = await apiClient.get('/user/api-keys');
    final list = data['api_keys'] as List<dynamic>? ?? [];
    return list.cast<Map<String, dynamic>>().map(ApiKeyModel.fromJson).toList();
  }

  /// Create a new API key with the given name.
  ///
  /// Returns a map with `id`, `name`, `key` (raw — shown once), `key_prefix`,
  /// and `created_at`.
  Future<Map<String, dynamic>> createApiKey(
    String name, {
    String? expiresAt,
  }) async {
    final data = await apiClient.post('/user/api-keys', body: {
      'name': name,
      if (expiresAt != null) 'expires_at': expiresAt,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  /// Revoke an API key by ID. The key becomes immediately invalid.
  Future<void> revokeApiKey(String keyId) async {
    await apiClient.delete('/user/api-keys/$keyId');
  }
}
