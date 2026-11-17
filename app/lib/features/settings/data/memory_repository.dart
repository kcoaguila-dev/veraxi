import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

/// One user-visible memory as returned by GET /api/v1/memories.
///
/// Memories are temporal: [validTo] is null while the memory is still
/// valid; a non-null [validTo] means it has been soft-expired.
class UserMemory {
  final String id;
  final String content;
  final String source; // chat | manual | import
  final String? validFrom;
  final String? validTo;

  const UserMemory({
    required this.id,
    required this.content,
    this.source = 'manual',
    this.validFrom,
    this.validTo,
  });

  bool get isValid => validTo == null;

  factory UserMemory.fromJson(Map<String, dynamic> json) {
    return UserMemory(
      id: json['id'] as String,
      content: json['content'] as String? ?? '',
      source: json['source'] as String? ?? 'manual',
      validFrom: json['valid_from'] as String?,
      validTo: json['valid_to'] as String?,
    );
  }
}

final memoryRepositoryProvider = Provider<MemoryRepository>((ref) {
  final client = ref.watch(apiClientProvider);
  return MemoryRepository(apiClient: client);
});

class MemoryRepository {
  final ApiClient apiClient;

  MemoryRepository({required this.apiClient});

  Future<List<UserMemory>> getMemories() async {
    final data = await apiClient.get('/v1/memories');
    final list = (data as Map)['memories'] as List<dynamic>? ?? const [];
    return list
        .map((e) => UserMemory.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<UserMemory> createMemory(String content) async {
    final data = await apiClient.post(
      '/v1/memories',
      body: {'content': content, 'source': 'manual'},
    );
    return UserMemory.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<UserMemory> updateMemory(String id, String content) async {
    final data = await apiClient.put(
      '/v1/memories/$id',
      body: {'content': content},
    );
    return UserMemory.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<UserMemory> expireMemory(String id) async {
    final data = await apiClient.post('/v1/memories/$id/expire');
    return UserMemory.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<void> deleteMemory(String id) async {
    await apiClient.delete('/v1/memories/$id');
  }
}
