import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class ChatRepository {
  final http.Client _client;
  final String _baseUrl = '${const String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8000')}/api/chat';
  final String? tenantId;

  ChatRepository({http.Client? client, this.tenantId}) : _client = client ?? http.Client();

  Future<String> sendMessage(String question) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (tenantId != null) {
      headers['Authorization'] = 'Bearer $tenantId';
    }

    try {
      final response = await _client.post(
        Uri.parse(_baseUrl),
        headers: headers,
        body: jsonEncode({
          'question': question,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['answer'] as String;
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } on SocketException {
      throw Exception('Network error: Unable to connect to the server.');
    } on TimeoutException {
      throw Exception('Connection timeout: Server took too long to respond.');
    } catch (e) {
      throw Exception(e.toString());
    }
  }
}
