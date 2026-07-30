import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/api_key_storage.dart';

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ChatRepository(apiClient: apiClient);
});

class ChatRepository {
  final ApiClient apiClient;

  ChatRepository({required this.apiClient});

  Future<List<Map<String, dynamic>>> getVoices({String? gptSovitsUrl}) async {
    String path = '/voices';
    if (gptSovitsUrl != null && gptSovitsUrl.isNotEmpty) {
      path += '?gpt_sovits_url=${Uri.encodeQueryComponent(gptSovitsUrl)}';
    }
    final data = await apiClient.get(path);
    final List<dynamic> rawVoices = data['voices'] ?? [];
    return rawVoices.map((v) => Map<String, dynamic>.from(v)).toList();
  }

  Future<void> saveVoices(List<Map<String, dynamic>> voices) async {
    await apiClient.post('/voices', body: {'voices': voices});
  }

  Future<List<Map<String, dynamic>>> getThreads() async {
    final url = '/chat/threads?_=' + DateTime.now().millisecondsSinceEpoch.toString();
    print("DEBUG_GET_THREADS_URL: \$url");
    try {
      final data = await apiClient.get(url);
      print("DEBUG_GET_THREADS_DATA: \$data");
      final threads = List<Map<String, dynamic>>.from(data['threads'] ?? []);
      print("DEBUG_GET_THREADS_COUNT: \${threads.length}");
      return threads;
    } catch (e) {
      print("DEBUG_GET_THREADS_ERROR: \$e");
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getThreadHistory(String threadId) async {
    final data = await apiClient.get('/chat/threads/$threadId');
    return List<Map<String, dynamic>>.from(data['messages'] ?? []);
  }

  /// Streams the chat response using Server-Sent Events (SSE)
  Stream<Map<String, dynamic>> streamChat(String question,
      {String? threadId, bool isTemporary = false, String? model}) async* {
    try {
      final uri = Uri.parse('${apiClient.baseUrl}/chat');
      final headers = apiClient.getDefaultHeaders()
        ..['Content-Type'] = 'application/json';

      final request = http.Request('POST', uri);
      request.headers.addAll(headers);
      final apiKey = await ApiKeyStorage().getGeminiKey();

      request.body = jsonEncode({
        'question': question,
        'thread_id': threadId,
        'stream': true,
        'is_temporary': isTemporary,
        if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey,
        if (model != null && model.isNotEmpty && model != 'Select a model')
          'model': model,
      });

      final response = await apiClient.client.send(request);

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        throw Exception('Stream error: ${response.statusCode} - $errorBody');
      }

      await for (final chunk in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
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

  Future<void> submitFeedback(String messageId, int value) async {
    await apiClient
        .post('/chat/messages/$messageId/feedback', body: {'value': value});
  }

  Future<void> editMessage(
      String messageId, String content, String threadId) async {
    await apiClient.put('/chat/messages/$messageId',
        body: {'content': content, 'thread_id': threadId});
  }

  Future<void> regenerateResponse(String threadId) async {
    await apiClient.post('/chat/threads/$threadId/regenerate', body: {});
  }

  Future<List<int>> getAudioBytes(String text, String voiceId, {String? gptSovitsUrl}) async {
    final uri = Uri.parse('${apiClient.baseUrl}/chat/audio');
    final headers = apiClient.getDefaultHeaders()
      ..['Content-Type'] = 'application/json';
    if (gptSovitsUrl != null) {
      headers['X-GPT-SoVITS-Url'] = gptSovitsUrl;
    }
    final body = jsonEncode({'text': text, 'voice_id': voiceId});

    final response =
        await apiClient.client.post(uri, headers: headers, body: body);

    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      throw Exception('Backend synthesis failed: ${response.statusCode}');
    }
  }
}
