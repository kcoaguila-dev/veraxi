import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

class ControlPanelRepository {
  final String baseUrl;
  final http.Client client;
  final String? tenantId;

  ControlPanelRepository({
    this.baseUrl = const String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8000'),
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
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/admin/stats'),
        headers: _getHeaders(),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } on Exception catch (e, stackTrace) {
      _handleNetworkException(e, stackTrace);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> triggerIngestion(String text) async {
    final headers = _getHeaders()..['Content-Type'] = 'application/json';
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/admin/ingest'),
        headers: headers,
        body: jsonEncode({'text': text}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } on Exception catch (e, stackTrace) {
      _handleNetworkException(e, stackTrace);
      rethrow;
    }
  }

  void _handleNetworkException(Exception e, StackTrace stackTrace) {
    Sentry.captureException(e, stackTrace: stackTrace);
    if (e.toString().contains('SocketException')) {
      throw Exception('Network error: Unable to connect to the server.');
    }
    if (e.toString().contains('TimeoutException')) {
      throw Exception('Connection timeout: Server took too long to respond.');
    }
  }
}
