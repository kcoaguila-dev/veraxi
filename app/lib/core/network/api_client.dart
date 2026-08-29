import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Provides the ApiClient. It dynamically fetches the latest session token on 
/// every request via [getDefaultHeaders], so we don't need to rebuild this provider 
/// when auth state changes (which would destructively reset ViewModels).
final apiClientProvider = Provider<ApiClient>((ref) {
  final session = Supabase.instance.client.auth.currentSession;
  final tenantId = session?.accessToken;
  return ApiClient(tenantId: tenantId);
});



class ApiClient {
  final String baseUrl;
  final http.Client client;
  final String? tenantId;

  ApiClient({
    this.baseUrl =
        const String.fromEnvironment('API_URL', defaultValue: '/api'),
    http.Client? client,
    this.tenantId,
  }) : client = client ?? http.Client();

  Map<String, String> getDefaultHeaders() {
    final headers = <String, String>{
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Pragma': 'no-cache',
      'Expires': '0',
    };
    
    String? token = tenantId;
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        token = session.accessToken;
      }
    } catch (_) {
      // Fallback to tenantId if Supabase is not initialized
    }
    
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<dynamic> get(String path, {Map<String, String>? headers}) async {
    try {
      final requestHeaders = getDefaultHeaders();
      if (headers != null) requestHeaders.addAll(headers);

      final response = await client
          .get(
            Uri.parse('$baseUrl$path'),
            headers: requestHeaders,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      throw Exception('Server error: ${response.statusCode}');
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<dynamic> post(String path,
      {Map<String, dynamic>? body, Map<String, String>? headers}) async {
    try {
      final requestHeaders = getDefaultHeaders()
        ..['Content-Type'] = 'application/json';
      if (headers != null) requestHeaders.addAll(headers);

      final response = await client
          .post(
            Uri.parse('$baseUrl$path'),
            headers: requestHeaders,
            body: body != null ? jsonEncode(body) : null,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      throw Exception('Server error: ${response.statusCode}');
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<dynamic> put(String path,
      {Map<String, dynamic>? body, Map<String, String>? headers}) async {
    try {
      final requestHeaders = getDefaultHeaders()
        ..['Content-Type'] = 'application/json';
      if (headers != null) requestHeaders.addAll(headers);

      final response = await client
          .put(
            Uri.parse('$baseUrl$path'),
            headers: requestHeaders,
            body: body != null ? jsonEncode(body) : null,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      throw Exception('Server error: ${response.statusCode}');
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<dynamic> delete(String path, {Map<String, String>? headers}) async {
    try {
      final requestHeaders = getDefaultHeaders();
      if (headers != null) requestHeaders.addAll(headers);

      final response = await client
          .delete(
            Uri.parse('$baseUrl$path'),
            headers: requestHeaders,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      throw Exception('Server error: ${response.statusCode}');
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<dynamic> postMultipart(String path,
      {required List<int> fileBytes,
      required String fileName,
      String fileField = 'file',
      Map<String, String>? fields,
      Map<String, String>? headers}) async {
    try {
      final requestHeaders = getDefaultHeaders();
      if (headers != null) requestHeaders.addAll(headers);

      final uri = Uri.parse('$baseUrl$path');
      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(requestHeaders);

      if (fields != null) {
        request.fields.addAll(fields);
      }

      request.files.add(
        http.MultipartFile.fromBytes(
          fileField,
          fileBytes,
          filename: fileName,
        ),
      );

      final streamedResponse =
          await client.send(request).timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      throw Exception(
          'Server error: ${response.statusCode} - ${response.body}');
    } catch (e, stackTrace) {
      Sentry.captureException(e, stackTrace: stackTrace);
      rethrow;
    }
  }
}
