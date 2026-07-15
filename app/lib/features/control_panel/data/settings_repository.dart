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
    final response = await http.get(Uri.parse('$_baseUrl/api/admin/stats'));

    if (response.statusCode == 200) {
      return BackendStats.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to load stats: ${response.body}');
    }
  }

  Future<void> saveGeminiKey(String key) async {
    await _storage.saveGeminiKey(key);
  }

  Future<String?> getGeminiKey() async {
    return await _storage.getGeminiKey();
  }
}
