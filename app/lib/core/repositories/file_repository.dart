import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/network/api_client.dart';

final fileRepositoryProvider = Provider<FileRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return FileRepository(apiClient: apiClient);
});

/// Repository for user file operations (listing, deleting uploaded files).
class FileRepository {
  final ApiClient apiClient;

  FileRepository({required this.apiClient});

  Future<List<Map<String, dynamic>>> getFiles() async {
    final data = await apiClient.get('/chat/files');
    return List<Map<String, dynamic>>.from(data['files'] ?? []);
  }

  Future<void> deleteFile(String fileId) async {
    await apiClient.delete('/chat/files/$fileId');
  }
}
