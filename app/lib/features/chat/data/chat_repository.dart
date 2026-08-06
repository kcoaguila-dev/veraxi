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

  Future<void> uploadVoice(String name, String promptText, List<int> fileBytes, String fileName) async {
    final uri = Uri.parse('${apiClient.baseUrl}/voices/upload');
    final request = http.MultipartRequest('POST', uri);
    
    final headers = apiClient.getDefaultHeaders();
    request.headers.addAll(headers);
    
    request.fields['name'] = name;
    request.fields['prompt_text'] = promptText;
    
    final multipartFile = http.MultipartFile.fromBytes(
      'file',
      fileBytes,
      filename: fileName,
    );
    request.files.add(multipartFile);
    
    final streamedResponse = await apiClient.client.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    
    if (response.statusCode != 200) {
      throw Exception('Failed to upload voice: ${response.statusCode} - ${response.body}');
    }
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

  String _getProviderFromModel(String? model) {
    if (model == null || model.isEmpty) return 'unknown';
    model = model.toLowerCase();
    if (model.startsWith('gemini')) return 'google';
    if (model.startsWith('gpt') || model.startsWith('o1') || model.startsWith('o3')) return 'openai';
    if (model.startsWith('claude')) return 'anthropic';
    if (model.startsWith('mistral')) return 'mistral';
    if (model.startsWith('deepseek')) return 'deepseek';
    if (model.startsWith('llama') || model.startsWith('qwen') || model.startsWith('allam') || model.startsWith('canopy') || model.startsWith('groq') || model.startsWith('meta')) return 'groq';
    return 'unknown';
  }

  /// Streams the chat response using Server-Sent Events (SSE)
  Stream<Map<String, dynamic>> streamChat(String question,
      {String? threadId, bool isTemporary = false, String? model, bool calculateGrounding = true, Map<String, dynamic>? toolSettings}) async* {
    try {
      final uri = Uri.parse('${apiClient.baseUrl}/chat');
      final headers = apiClient.getDefaultHeaders()
        ..['Content-Type'] = 'application/json';

      final request = http.Request('POST', uri);
      request.headers.addAll(headers);
      
      final provider = _getProviderFromModel(model);
      final apiKey = await ApiKeyStorage().getKey(provider);

      request.body = jsonEncode({
        'question': question,
        'thread_id': threadId,
        'stream': true,
        'is_temporary': isTemporary,
        'calculate_grounding': calculateGrounding,
        if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey,
        if (model != null && model.isNotEmpty && model != 'Select a model')
          'model': model,
        if (toolSettings != null) 'tool_settings': toolSettings,
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

  Future<String> uploadAttachment(List<int> fileBytes, String fileName) async {
    final response = await apiClient.postMultipart(
      '/chat/upload_attachment',
      fileBytes: fileBytes,
      fileName: fileName,
    );
    return response['text'] ?? '';
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

  Future<void> renameThread(String threadId, String newTitle) async {
    await apiClient.put('/chat/threads/$threadId/title', body: {'title': newTitle});
  }

  Future<void> togglePinThread(String threadId) async {
    await apiClient.post('/chat/threads/$threadId/pin', body: {});
  }

  Future<void> toggleArchiveThread(String threadId) async {
    await apiClient.post('/chat/threads/$threadId/archive', body: {});
  }

  Future<void> deleteThread(String threadId) async {
    await apiClient.delete('/chat/threads/$threadId');
  }

  Future<void> deleteAllThreads() async {
    await apiClient.delete('/chat/threads');
  }

  Future<String> duplicateThread(String threadId) async {
    final response = await apiClient.post('/chat/threads/$threadId/duplicate', body: {});
    return response['new_thread_id'] as String;
  }

  Future<String> shareThread(String threadId) async {
    final response = await apiClient.post('/chat/threads/$threadId/share', body: {});
    return response['share_id'] as String;
  }

  Future<void> assignThreadToProject(String threadId, String? projectId) async {
    await apiClient.post('/chat/threads/$threadId/project', body: {
      'project_id': projectId ?? '',
    });
  }

  Future<List<Map<String, dynamic>>> getProjects() async {
    final data = await apiClient.get('/projects');
    return List<Map<String, dynamic>>.from(data['projects'] ?? []);
  }

  Future<Map<String, dynamic>> createProject(String name) async {
    final data = await apiClient.post('/projects', body: {'name': name});
    return data;
  }

  Future<void> renameProject(String projectId, String newName) async {
    await apiClient.put('/projects/$projectId', body: {'name': newName});
  }

  Future<void> deleteProject(String projectId) async {
    await apiClient.delete('/projects/$projectId');
  }
}
