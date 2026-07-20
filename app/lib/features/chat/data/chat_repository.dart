import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:veraxi_app/core/network/api_client.dart';

class ChatRepository {
  final ApiClient apiClient;

  ChatRepository({required this.apiClient});

  Future<List<String>> getThreads() async {
    final data = await apiClient.get('/api/chat/threads');
    return List<String>.from(data['threads'] ?? []);
  }

  Future<List<Map<String, dynamic>>> getThreadHistory(String threadId) async {
    final data = await apiClient.get('/api/chat/threads/$threadId');
    return List<Map<String, dynamic>>.from(data['messages'] ?? []);
  }

  /// Streams the chat response using Server-Sent Events (SSE)
  Stream<Map<String, dynamic>> streamChat(String question, {String? threadId}) async* {
    try {
      final uri = Uri.parse('${apiClient.baseUrl}/api/chat');
      final headers = apiClient.getDefaultHeaders()..['Content-Type'] = 'application/json';
      
      final request = http.Request('POST', uri);
      request.headers.addAll(headers);
      request.body = jsonEncode({
        'question': question,
        'thread_id': threadId,
        'stream': true,
      });

      final response = await apiClient.client.send(request);
      
      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        throw Exception('Stream error: ${response.statusCode} - $errorBody');
      }

      await for (final chunk in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (chunk.isEmpty) continue;
        
        if (chunk.startsWith('data: ')) {
          final data = chunk.substring(6);
          if (data == '[DONE]') {
            break;
          }
          try {
            final parsed = jsonDecode(data);
            yield parsed;
          } catch (e) {
            // Ignore parse errors for malformed chunks
            continue;
          }
        }
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      rethrow;
    }
  }
}
