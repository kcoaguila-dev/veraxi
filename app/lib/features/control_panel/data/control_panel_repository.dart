import 'dart:convert';
import 'package:http/http.dart' as http;

class ControlPanelRepository {
  final String baseUrl;
  final http.Client client;

  ControlPanelRepository({
    this.baseUrl = 'http://localhost:8000',
    http.Client? client,
  }) : client = client ?? http.Client();

  Future<Map<String, dynamic>> fetchStats() async {
    final response = await client.get(Uri.parse('$baseUrl/api/admin/stats'));

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to load stats: ${response.statusCode}');
    }
  }

  Future<Map<String, dynamic>> triggerIngestion() async {
    final response = await client.post(Uri.parse('$baseUrl/api/admin/ingest'));

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Failed to trigger ingestion: ${response.statusCode}');
    }
  }
}
