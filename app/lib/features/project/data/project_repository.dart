import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

final projectRepositoryProvider = Provider<ProjectRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ProjectRepository(apiClient: apiClient);
});

class ProjectRepository {
  final ApiClient apiClient;

  ProjectRepository({required this.apiClient});



  Future<List<Map<String, dynamic>>> getProjects() async {
    final data = await apiClient.get('/projects');
    return List<Map<String, dynamic>>.from(data['projects'] ?? []);
  }

  Future<Map<String, dynamic>> createProject(String name) async {
    final data = await apiClient.post('/projects', body: {'name': name});
    return data;
  }

  Future<void> renameProject(String projectId, String newName) async {
    await apiClient.put('/projects/$projectId', body: {'name': newName});
  }

  Future<void> deleteProject(String projectId) async {
    await apiClient.delete('/projects/$projectId');
  }
}
