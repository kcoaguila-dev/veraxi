import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/network/llm_request_options.dart';
import 'package:veraxi_app/core/network/sse_parser.dart';
import 'package:veraxi_app/core/api_key_storage.dart';

import 'package:veraxi_app/features/chat/data/desktop_acp_client.dart';
import 'package:veraxi_app/features/chat/data/local_chat_repository.dart';
import 'package:veraxi_app/features/chat/data/local_chat_data_source.dart'
    if (dart.library.html) 'package:veraxi_app/features/chat/data/local_chat_data_source_web.dart';
import 'package:veraxi_app/features/auth/view_models/auth_view_model.dart';

const bool _isAuthEnabled =
    bool.fromEnvironment('AUTH_ENABLED', defaultValue: true);

final chatRepositoryProvider = Provider<IChatRepository>((ref) {
  final hasAuthSession = ref.watch(
    authStateProvider
        .select((asyncAuth) => asyncAuth.valueOrNull?.session != null),
  );
  final apiClient = ref.watch(apiClientProvider);
  final apiKeyStorage = ref.watch(apiKeyStorageProvider);

  // Also check if Supabase has a valid session to avoid returning Cloud repo when logged out
  bool isLoggedIn =
      !_isAuthEnabled || hasAuthSession || apiClient.tenantId != null;
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
      Map<String, dynamic>? toolSettings,
      Map<String, dynamic>? codeScope,
      String? thinkingLevel,
      String? agentRuntime,
      bool attachVeraxiMcp = true});
  Future<String> uploadAttachment(List<int> fileBytes, String fileName);
  Future<void> submitFeedback(String messageId, int value);
  Future<Map<String, dynamic>> confirmToolCall({
    required String toolName,
    required Map<String, dynamic> args,
    required bool approve,
  });
  Future<List<Map<String, dynamic>>> getIntegrations();
  Future<void> editMessage(String messageId, String content, String threadId);
  Future<void> regenerateResponse(String threadId);
  Future<Map<String, dynamic>> previewCompaction(String threadId,
      {String? model, int keepRecentTurns = 4, String? focus});
  Future<Map<String, dynamic>> applyCompaction(String threadId,
      {required String summary, int keepRecentTurns = 4, String? model});
  Future<Map<String, dynamic>> clearOldToolResults(String threadId,
      {int keepRecentTurns = 4, String? model});

  /// Undo the latest compaction, restoring the pre-compaction
  /// context. Messages sent after the compaction are removed.
  Future<Map<String, dynamic>> restoreCompaction(String threadId);
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

  @override
  Stream<Map<String, dynamic>> streamChat(String question,
      {String? threadId,
      bool isTemporary = false,
      String? model,
      bool calculateGrounding = true,
      Map<String, dynamic>? toolSettings,
      Map<String, dynamic>? codeScope,
      String? thinkingLevel,
      String? agentRuntime,
      bool attachVeraxiMcp = true}) async* {
    if (agentRuntime == 'antigravity_acp') {
      yield* DesktopAcpClient.instance.streamPrompt(
        threadId: threadId ?? 'default',
        prompt: question,
        model: model,
      );
      return;
    }
    if (model != null && model.endsWith('.gguf')) {
      final localDataSource = LocalChatDataSource.forModel();
      yield* localDataSource.streamChat(
        question,
        model,
        thinkingLevel: thinkingLevel ?? codeScope?['thinking_level'] as String?,
      );
      return;
    }

    try {
      final uri = Uri.parse('${apiClient.baseUrl}/chat');
      final headers = await apiClient.getDefaultHeaders();
      headers['Content-Type'] = 'application/json';

      final request = http.Request('POST', uri);
      request.headers.addAll(headers);

      final llmOptions = await resolveLlmRequestOptions(apiKeyStorage, model);

      request.body = jsonEncode({
        'question': question,
        'thread_id': threadId,
        'stream': true,
        'is_temporary': isTemporary,
        'calculate_grounding': calculateGrounding,
        ...llmOptions,
        if (toolSettings != null) 'tool_settings': toolSettings,
        if (thinkingLevel != null &&
            (codeScope == null || !codeScope.containsKey('thinking_level')))
          'thinking_level': thinkingLevel,
        // Code Mode (Phase 1): the scope fields are top-level
        // ChatRequest fields on the backend, not tool_settings.
        if (codeScope != null) ...codeScope,
        if (agentRuntime != null) 'agent_runtime': agentRuntime,
        if (agentRuntime == 'antigravity_acp')
          'attach_veraxi_mcp': attachVeraxiMcp,
      });

      final response = await apiClient.client.send(request);

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        throw Exception('Stream error: ${response.statusCode} - $errorBody');
      }

      await for (final parsed in parseSseJsonStream(response.stream)) {
        yield parsed;
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
  Future<Map<String, dynamic>> confirmToolCall({
    required String toolName,
    required Map<String, dynamic> args,
    required bool approve,
  }) async {
    final data = await apiClient.post('/chat/confirm-tool', body: {
      'tool_name': toolName,
      'args': args,
      'approve': approve,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  Future<List<Map<String, dynamic>>> getIntegrations() async {
    final data = await apiClient.get('/integrations');
    final list = data['integrations'] as List<dynamic>? ?? [];
    return list.cast<Map<String, dynamic>>();
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

  /// POST helper for the compaction endpoints: unlike ApiClient.post
  /// it surfaces the server's `detail` message, because compaction
  /// refusals (nothing to compact, <10% savings, truncated summary)
  /// are user-actionable and must not collapse into "Server error".
  Future<Map<String, dynamic>> _postCompaction(
      String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('${apiClient.baseUrl}$path');
    final headers = await apiClient.getDefaultHeaders();
    headers['Content-Type'] = 'application/json';
    final response = await apiClient.client
        .post(uri, headers: headers, body: jsonEncode(body));
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200 || response.statusCode == 201) {
      return decoded;
    }
    throw Exception(
        decoded['detail'] ?? 'Server error: ${response.statusCode}');
  }

  @override
  Future<Map<String, dynamic>> previewCompaction(String threadId,
      {String? model, int keepRecentTurns = 4, String? focus}) async {
    final llmOptions = await resolveLlmRequestOptions(apiKeyStorage, model);
    return _postCompaction('/chat/threads/$threadId/compact/preview', {
      'keep_recent_turns': keepRecentTurns,
      ...llmOptions,
      if (focus != null && focus.isNotEmpty) 'focus': focus,
    });
  }

  @override
  Future<Map<String, dynamic>> applyCompaction(String threadId,
      {required String summary, int keepRecentTurns = 4, String? model}) async {
    return _postCompaction('/chat/threads/$threadId/compact/apply', {
      'summary': summary,
      'keep_recent_turns': keepRecentTurns,
    });
  }

  @override
  Future<Map<String, dynamic>> clearOldToolResults(String threadId,
      {int keepRecentTurns = 4, String? model}) async {
    return _postCompaction('/chat/threads/$threadId/clear-tool-results', {
      'keep_recent_turns': keepRecentTurns,
    });
  }

  @override
  Future<Map<String, dynamic>> restoreCompaction(String threadId) async {
    return _postCompaction('/chat/threads/$threadId/compact/restore', const {});
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
