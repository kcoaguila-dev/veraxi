import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/api_key_storage.dart';

import 'package:veraxi_app/features/chat/data/local_chat_repository.dart';
import 'package:veraxi_app/features/chat/data/local_chat_data_source.dart';
import 'package:veraxi_app/features/auth/view_models/auth_view_model.dart';

final chatRepositoryProvider = Provider<IChatRepository>((ref) {
  ref.watch(authStateProvider);
  final apiClient = ref.watch(apiClientProvider);
  final apiKeyStorage = ref.watch(apiKeyStorageProvider);

  // Also check if Supabase has a valid session to avoid returning Cloud repo when logged out
  bool isLoggedIn = apiClient.tenantId != null;
  if (!isLoggedIn) {
    try {
      isLoggedIn = Supabase.instance.client.auth.currentSession != null;
    } catch (_) {}
  }

  if (!isLoggedIn) {
    return LocalChatRepository(
        apiClient: apiClient, apiKeyStorage: apiKeyStorage);
  }

  return CloudChatRepository(
      apiClient: apiClient, apiKeyStorage: apiKeyStorage);
});

abstract class IChatRepository {
  Future<void> assignThreadToProject(String threadId, String? projectId);
  Future<List<Map<String, dynamic>>> getThreads();
  Future<List<Map<String, dynamic>>> getThreadHistory(String threadId);
  Future<List<Map<String, dynamic>>> getSharedThreadHistory(String threadId);
  Stream<Map<String, dynamic>> streamChat(String question,
      {String? threadId,
      bool isTemporary = false,
      String? model,
      bool calculateGrounding = true,
      Map<String, dynamic>? toolSettings});
  Future<String> uploadAttachment(List<int> fileBytes, String fileName);
  Future<void> submitFeedback(String messageId, int value);
  Future<void> editMessage(String messageId, String content, String threadId);
  Future<void> regenerateResponse(String threadId);
  Future<void> renameThread(String threadId, String newTitle);
  Future<void> togglePinThread(String threadId);
  Future<void> toggleArchiveThread(String threadId);
  Future<void> deleteThread(String threadId);
  Future<void> deleteAllThreads();
  Future<String> duplicateThread(String threadId);
  Future<String> shareThread(String threadId);
  Stream<Map<String, dynamic>> streamSyncEvents();
}

class CloudChatRepository implements IChatRepository {
  final ApiClient apiClient;
  final ApiKeyStorage apiKeyStorage;

  CloudChatRepository({required this.apiClient, required this.apiKeyStorage});

  @override
  Future<void> assignThreadToProject(String threadId, String? projectId) async {
    await apiClient.post('/chat/threads/$threadId/project', body: {
      'project_id': projectId ?? '',
    });
  }

  @override
  Future<List<Map<String, dynamic>>> getThreads() async {
    final url =
        '/chat/threads?_=' + DateTime.now().millisecondsSinceEpoch.toString();
    try {
      final data = await apiClient.get(url);
      final threads = List<Map<String, dynamic>>.from(data['threads'] ?? []);
      return threads;
    } catch (e) {
      debugPrint('[ChatRepository] getThreads error: $e');
      rethrow;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getThreadHistory(String threadId) async {
    final data = await apiClient.get('/chat/threads/$threadId');
    return List<Map<String, dynamic>>.from(data['messages'] ?? []);
  }

  @override
  Future<List<Map<String, dynamic>>> getSharedThreadHistory(
      String threadId) async {
    final data = await apiClient.get('/shared/threads/$threadId');
    return List<Map<String, dynamic>>.from(data['messages'] ?? []);
  }

  String _getProviderFromModel(String? model) {
    if (model == null || model.isEmpty) return 'unknown';
    model = model.toLowerCase();
    if (model.startsWith('gemini')) return 'google';
    if (model.startsWith('gpt') ||
        model.startsWith('o1') ||
        model.startsWith('o3')) return 'openai';
    if (model.startsWith('claude')) return 'anthropic';
    if (model.startsWith('deepseek')) return 'deepseek';
    if (model.startsWith('moonshot')) return 'kimi';
    if (model.endsWith('.gguf')) return 'local';
    if (model.contains(':')) return 'ollama';
    if (model.startsWith('llama') ||
        model.startsWith('qwen') ||
        model.startsWith('allam') ||
        model.startsWith('canopy') ||
        model.startsWith('groq') ||
        model.startsWith('meta')) return 'groq';
    if (model == 'local-model') return 'local';
    return 'unknown';
  }

  @override
  Stream<Map<String, dynamic>> streamChat(String question,
      {String? threadId,
      bool isTemporary = false,
      String? model,
      bool calculateGrounding = true,
      Map<String, dynamic>? toolSettings}) async* {
    if (model != null && model.endsWith('.gguf')) {
      final localDataSource = LocalChatDataSource.forModel();
      yield* localDataSource.streamChat(question, model);
      return;
    }

    try {
      final uri = Uri.parse('${apiClient.baseUrl}/chat');
      final headers = await apiClient.getDefaultHeaders();
      headers['Content-Type'] = 'application/json';

      final request = http.Request('POST', uri);
      request.headers.addAll(headers);

      final provider = _getProviderFromModel(model);
      final apiKey = await apiKeyStorage.getKey(provider);
      String? baseUrl;

      if (provider == 'local') {
        final customBaseUrl = await apiKeyStorage.getValue('local_base_url');
        final customModelName =
            await apiKeyStorage.getValue('local_model_name');
        if (customBaseUrl != null && customBaseUrl.isNotEmpty)
          baseUrl = customBaseUrl;
        if (customModelName != null && customModelName.isNotEmpty)
          model = customModelName;
      }

      request.body = jsonEncode({
        'question': question,
        'thread_id': threadId,
        'stream': true,
        'is_temporary': isTemporary,
        'calculate_grounding': calculateGrounding,
        if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey,
        if (baseUrl != null) 'base_url': baseUrl,
        if (model != null &&
            model.isNotEmpty &&
            model != 'Select a model' &&
            model != 'local-model')
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

  @override
  Future<String> uploadAttachment(List<int> fileBytes, String fileName) async {
    final response = await apiClient.postMultipart(
      '/chat/upload_attachment',
      fileBytes: fileBytes,
      fileName: fileName,
    );
    return response['text'] ?? '';
  }

  @override
  Future<void> submitFeedback(String messageId, int value) async {
    await apiClient
        .post('/chat/messages/$messageId/feedback', body: {'value': value});
  }

  @override
  Future<void> editMessage(
      String messageId, String content, String threadId) async {
    await apiClient.put('/chat/messages/$messageId',
        body: {'content': content, 'thread_id': threadId});
  }

  @override
  Future<void> regenerateResponse(String threadId) async {
    await apiClient.post('/chat/threads/$threadId/regenerate', body: {});
  }

  @override
  Future<void> renameThread(String threadId, String newTitle) async {
    await apiClient
        .put('/chat/threads/$threadId/title', body: {'title': newTitle});
  }

  @override
  Future<void> togglePinThread(String threadId) async {
    await apiClient.post('/chat/threads/$threadId/pin', body: {});
  }

  @override
  Future<void> toggleArchiveThread(String threadId) async {
    await apiClient.post('/chat/threads/$threadId/archive', body: {});
  }

  @override
  Future<void> deleteThread(String threadId) async {
    await apiClient.delete('/chat/threads/$threadId');
  }

  @override
  Future<void> deleteAllThreads() async {
    await apiClient.delete('/chat/threads');
  }

  @override
  Future<String> duplicateThread(String threadId) async {
    final response =
        await apiClient.post('/chat/threads/$threadId/duplicate', body: {});
    return response['new_thread_id'] as String;
  }

  @override
  Future<String> shareThread(String threadId) async {
    final response =
        await apiClient.post('/chat/threads/$threadId/share', body: {});
    return response['share_id'] as String;
  }

  @override
  Stream<Map<String, dynamic>> streamSyncEvents() async* {
    try {
      final uri = Uri.parse('${apiClient.baseUrl}/chat/sync');
      final headers = await apiClient.getDefaultHeaders();

      final request = http.Request('GET', uri);
      request.headers.addAll(headers);

      final response = await apiClient.client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Sync stream error: ${response.statusCode}');
      }

      await for (final chunk in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (chunk.isEmpty) continue;

        if (chunk.startsWith('data: ')) {
          final data = chunk.substring(6);
          try {
            final parsed = jsonDecode(data);
            yield parsed;
          } catch (e) {
            continue;
          }
        }
      }
    } catch (e) {
      debugPrint('[ChatRepository] streamSyncEvents error: $e');
      // Do not rethrow, let the UI handle reconnection if needed
    }
  }
}
