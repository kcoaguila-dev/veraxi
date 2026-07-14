import 'dart:convert';
import 'package:http/http.dart' as http;

class ChatRepository {
  final http.Client _client;
  final String _baseUrl = 'http://localhost:8000/api/chat';
  final String? tenantId;

  ChatRepository({http.Client? client, this.tenantId}) : _client = client ?? http.Client();

  Future<String> sendMessage(String question) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (tenantId != null) {
      headers['Authorization'] = 'Bearer $tenantId';
    }

    final response = await _client.post(
      Uri.parse(_baseUrl),
      headers: headers,
      body: jsonEncode({
        'question': question,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['answer'] as String;
    } else {
      throw Exception('Failed to send message: ${response.statusCode}');
    }
  }
}
