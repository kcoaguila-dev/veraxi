import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

class BackendStats {
  final int nodeCount;
  final int vectorCount;

  BackendStats({required this.nodeCount, required this.vectorCount});

  factory BackendStats.fromJson(Map<String, dynamic> json) {
    return BackendStats(
      nodeCount: json['nodeCount'] ?? 0,
      vectorCount: json['vectorCount'] ?? 0,
    );
  }
}

final controlPanelRepositoryProvider = Provider<ControlPanelRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ControlPanelRepository(apiClient: apiClient);
});

class ControlPanelRepository {
  final ApiClient apiClient;

  ControlPanelRepository({required this.apiClient});

  Future<BackendStats> fetchStats() async {
    final data = await apiClient.get('/api/admin/stats');
    return BackendStats.fromJson(data);
  }

  Future<Map<String, dynamic>> triggerIngestion(String text) async {
    final data = await apiClient.post('/api/admin/ingest', body: {'text': text});
    return data as Map<String, dynamic>;
  }
}
