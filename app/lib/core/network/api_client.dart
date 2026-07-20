import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  const bool isAuthEnabled = bool.fromEnvironment('AUTH_ENABLED', defaultValue: true);
  String? tenantId;
  if (isAuthEnabled) {
    tenantId = Supabase.instance.client.auth.currentSession?.user.id;
  }
  return ApiClient(tenantId: tenantId);
});

class ApiClient {
  final String baseUrl;
  final http.Client client;
  final String? tenantId;

  ApiClient({
    this.baseUrl = const String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8000'),
    http.Client? client,
    this.tenantId,
  }) : client = client ?? http.Client();

  Map<String, String> getDefaultHeaders() {
    final headers = <String, String>{};
    if (tenantId != null) {
      headers['Authorization'] = 'Bearer $tenantId';
    }
    return headers;
  }

  Future<dynamic> get(String path) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl$path'),
        headers: getDefaultHeaders(),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      throw Exception('Server error: ${response.statusCode}');
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<dynamic> post(String path, {Map<String, dynamic>? body}) async {
    try {
      final headers = getDefaultHeaders()..['Content-Type'] = 'application/json';
      final response = await client.post(
        Uri.parse('$baseUrl$path'),
        headers: headers,
        body: body != null ? jsonEncode(body) : null,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      throw Exception('Server error: ${response.statusCode}');
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      rethrow;
    }
  }
}
