import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:veraxi_app/core/api_key_storage.dart';

class BackendStats {
  final int nodeCount;
  final int vectorCount;

  BackendStats({required this.nodeCount, required this.vectorCount});

  factory BackendStats.fromJson(Map<String, dynamic> json) {
    return BackendStats(
      nodeCount: json['node_count'] ?? 0,
      vectorCount: json['vector_count'] ?? 0,
    );
  }
}

class SettingsRepository {
  final ApiKeyStorage _storage = ApiKeyStorage();
  final String _baseUrl = const String.fromEnvironment('API_URL', defaultValue: 'http://127.0.0.1:8000'); // Default API Gateway URL

  Future<BackendStats> fetchStats() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/api/admin/stats')).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return BackendStats.fromJson(jsonDecode(response.body));
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } on Exception catch (e) {
      if (e.toString().contains('SocketException')) {
        throw Exception('Network error: Unable to connect to the server.');
      }
      if (e.toString().contains('TimeoutException')) {
        throw Exception('Connection timeout: Server took too long to respond.');
      }
      rethrow;
    }
  }

  Future<void> saveGeminiKey(String key) async {
    await _storage.saveGeminiKey(key);
  }

  Future<String?> getGeminiKey() async {
    return await _storage.getGeminiKey();
  }
}
