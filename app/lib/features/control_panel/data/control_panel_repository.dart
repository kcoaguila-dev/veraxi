import 'dart:convert';
import 'package:http/http.dart' as http;

class ControlPanelRepository {
  final String baseUrl;
  final http.Client client;
  final String? tenantId;

  ControlPanelRepository({
    this.baseUrl = 'http://localhost:8000',
    http.Client? client,
    this.tenantId,
  }) : client = client ?? http.Client();

  Map<String, String> _getHeaders() {
    final headers = <String, String>{};
    if (tenantId != null) {
      headers['Authorization'] = 'Bearer $tenantId';
    }
    return headers;
  }

  Future<Map<String, dynamic>> fetchStats() async {
    final response = await client.get(
      Uri.parse('$baseUrl/api/admin/stats'),
      headers: _getHeaders(),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to load stats: ${response.statusCode}');
    }
  }

  Future<Map<String, dynamic>> triggerIngestion() async {
    final response = await client.post(
      Uri.parse('$baseUrl/api/admin/ingest'),
      headers: _getHeaders(),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to trigger ingestion: ${response.statusCode}');
    }
  }
}
