import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/core/repositories/memory_repository.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/chat_history_provider.dart';

class ChatThreadState {
  final String? threadId;
  final List<ChatMessage> messages;
  final bool isLoading;
  final bool isLoadingHistory;
  final bool showTelemetry;
  final String? error;

  ChatThreadState({
    this.threadId,
    this.messages = const [],
    this.isLoading = false,
    this.isLoadingHistory = false,
    this.showTelemetry = false,
    this.error,
  });

  ChatThreadState copyWith({
    String? threadId,
    bool clearThreadId = false,
    List<ChatMessage>? messages,
    bool? isLoading,
    bool? isLoadingHistory,
    bool? showTelemetry,
    String? error,
    bool clearError = false,
  }) {
    return ChatThreadState(
      threadId: clearThreadId ? null : (threadId ?? this.threadId),
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      showTelemetry: showTelemetry ?? this.showTelemetry,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ChatThreadViewModel extends Notifier<ChatThreadState> {
  DateTime? _currentRequestStartTime;

  @override
  ChatThreadState build() {
    _init();
    return ChatThreadState();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTelemetry = prefs.getBool('show_telemetry') ?? false;
    await prefs.remove('tool_settings');
    state = state.copyWith(showTelemetry: savedTelemetry);
  }

  Future<void> toggleTelemetry() async {
    final next = !state.showTelemetry;
    state = state.copyWith(showTelemetry: next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_telemetry', next);
  }

  void startNewChat() {
    state = state.copyWith(clearThreadId: true, messages: []);
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void clearThread() {
    state = state.copyWith(clearThreadId: true, messages: []);
  }

  Future<void> selectThread(String threadId) async {
    state = state.copyWith(isLoadingHistory: true, threadId: threadId, messages: []);
    try {
      final history = await ref.read(chatRepositoryProvider).getThreadHistory(threadId);
      final messages = history.map((m) {
        List<ToolEvent> toolEvents = [];
        if (m['toolEvents'] != null) {
          final evts = m['toolEvents'] as List;
          toolEvents = evts
              .map((e) => ToolEvent(
                    id: e['id'] as String? ?? '',
                    name: e['name'] as String? ?? '',
                    args: e['args'] is Map ? Map<String, dynamic>.from(e['args'] as Map) : {},
                    result: e['result'],
                    isComplete: e['isComplete'] as bool? ?? true,
                  ))
              .toList();
        }
        return ChatMessage(
          id: m['id'] as String?,
          role: m['role'] as String,
          content: m['content'] as String,
          feedback: m['feedback'] as int? ?? 0,
          modelName: m['model_name'] as String?,
          toolEvents: toolEvents,
          metrics: m['metrics'] is Map ? Map<String, dynamic>.from(m['metrics'] as Map) : null,
        );
      }).toList();
      state = state.copyWith(messages: messages, isLoadingHistory: false);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(isLoadingHistory: false, error: e.toString());
    }
  }

  Future<void> sendMessage(String text, {String? model, List<dynamic>? attachments}) async {
    if (text.trim().isEmpty && (attachments == null || attachments.isEmpty)) return;

    if (model == null || model == 'Select a model' || model.isEmpty) {
      final userMsg = ChatMessage(role: 'user', content: text.isEmpty ? '[Attachment]' : text);
      final errorMsg = ChatMessage(
        role: 'assistant',
        content: 'No AI model selected. Please select a model from the top left menu.',
        isError: true,
      );
      state = state.copyWith(messages: [...state.messages, userMsg, errorMsg]);
      return;
    }

    final userMsgForUI = ChatMessage(
        role: 'user',
        content: text.isEmpty && attachments != null && attachments.isNotEmpty
            ? '[Sent ${attachments.length} attachment(s)]'
            : text);

    state = state.copyWith(
      messages: [
        ...state.messages,
        userMsgForUI,
        ChatMessage(role: 'assistant', content: '', isStreaming: true, modelName: model)
      ],
      isLoading: true,
      clearError: true,
    );

    _currentRequestStartTime = DateTime.now();
    String queryText = text;

    if (attachments != null && attachments.isNotEmpty) {
      try {
        final List<String> extractedTexts = [];
        for (final attachment in attachments) {
          final fileBytes = attachment.bytes as List<int>?;
          final fileName = attachment.name as String;
          if (fileBytes != null) {
            final extracted = await ref.read(chatRepositoryProvider).uploadAttachment(fileBytes, fileName);
            if (extracted.isNotEmpty) {
              extractedTexts.add("--- Attachment: $fileName ---\n$extracted");
            }
          }
        }
        if (extractedTexts.isNotEmpty) {
          final attachmentsStr = extractedTexts.join("\n\n");
          if (queryText.isEmpty) {
            queryText = "Please analyze the following attached document(s):\n\n$attachmentsStr";
          } else {
            queryText = "Here are the attached document(s) for context:\n\n$attachmentsStr\n\nUser Query: $queryText";
          }
        }
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
        state = state.copyWith(isLoading: false, error: "Failed to process attachments: $e");
        return;
      }
    }

    Map<String, dynamic>? toolSettings;
    try {
      final prefs = await SharedPreferences.getInstance();
      final toolSettingsJson = prefs.getString('tool_settings');
      if (toolSettingsJson != null) {
        toolSettings = jsonDecode(toolSettingsJson) as Map<String, dynamic>;
      }
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
    }

    int retries = 0;
    const int maxRetries = 1;
    bool success = false;
    String currentQuery = queryText;

    while (!success && retries <= maxRetries) {
      try {
        await for (final event in ref.read(chatRepositoryProvider).streamChat(
          currentQuery,
          threadId: state.threadId,
          isTemporary: ref.read(chatHistoryProvider).isTemporary,
          model: model,
          calculateGrounding: state.showTelemetry,
          toolSettings: toolSettings,
        )) {
          _handleStreamEvent(event);
        }
        state = state.copyWith(isLoading: false);
        success = true;
      } catch (e, st) {
        final errorStr = e.toString();
        bool isNetworkError = errorStr.contains("SocketException") ||
            errorStr.contains("ClientException") ||
            errorStr.contains("Failed host lookup") ||
            errorStr.contains("Connection refused") ||
            errorStr.contains("XMLHttpRequest error");

        if (isNetworkError && retries < maxRetries) {
          retries++;
          final partialResponse = state.messages.isNotEmpty ? state.messages.last.content : "";
          if (partialResponse.isNotEmpty && partialResponse != "Thinking...") {
            currentQuery = "System: The previous response was interrupted by a network drop. Please continue generating your response EXACTLY where you left off. Do not repeat what was already said. Here is what you generated so far:\n\n$partialResponse";
          }
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        Sentry.captureException(e, stackTrace: st);
        String uiError = "Error: Unable to complete request.";
        if (isNetworkError) {
          uiError = "Network connection lost. Please check your internet connection and try again.";
        }
        String finalContent = uiError;
        if (state.messages.isNotEmpty) {
          final currentContent = state.messages.last.content;
          if (currentContent.isNotEmpty && !currentContent.endsWith(uiError) && !currentContent.endsWith("[$uiError]")) {
            finalContent = "$currentContent\n\n[$uiError]";
          }
        }
        _updateLastMessage(content: finalContent, isStreaming: false, isError: true);
        state = state.copyWith(isLoading: false);
        break;
      }
    }
  }

  void _handleStreamEvent(Map<String, dynamic> event) {
    if (event.containsKey('error')) {
      _updateLastMessage(content: "Error: ${event['error']}", isStreaming: false, isError: true);
      return;
    }
    final type = event['event'];
    if (type == 'metadata') {
      final data = event['data'];
      if (data != null) {
        if (data['thread_id'] != null) {
          final newThreadId = data['thread_id'] as String;
          state = state.copyWith(threadId: newThreadId);
        }
        if (data['thread_title'] != null) {
          ref.read(chatHistoryProvider.notifier).applyThreadTitle(state.threadId!, data['thread_title'] as String);
        }
        if (data['metrics'] is Map) {
          _updateLastMessage(metrics: Map<String, dynamic>.from(data['metrics'] as Map));
        }
      }
      return;
    }
    if (type == 'on_chat_model_stream') {
      final chunk = event['data']?['chunk'];
      if (chunk != null) {
        final content = chunk['content'];
        if (content != null && content is String) {
          final msgs = List<ChatMessage>.from(state.messages);
          final last = msgs.last;
          String newContent = last.content == 'Thinking...' ? '' : last.content;
          newContent += content;
          msgs[msgs.length - 1] = last.copyWith(content: newContent);
          state = state.copyWith(messages: msgs);
        }
      }
    } else if (type == 'on_tool_start') {
      final toolName = event['name'];
      final runId = event['run_id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
      final args = event['data']?['input'] ?? {};
      final friendlyName = _friendlyToolLabel(toolName);
      if (state.messages.isNotEmpty) {
        final last = state.messages.last;
        final newEvents = List<ToolEvent>.from(last.toolEvents);
        newEvents.add(ToolEvent(
          id: runId,
          name: toolName,
          args: args is Map ? Map<String, dynamic>.from(args) : {},
          isComplete: false,
        ));
        _updateLastMessage(activeTool: '$friendlyName...', toolEvents: newEvents);
      } else {
        _updateLastMessage(activeTool: '$friendlyName...');
      }
    } else if (type == 'on_tool_end') {
      final runId = event['run_id'];
      final output = event['data']?['output'];
      final artifact = event['data']?['artifact'];
      if (state.messages.isNotEmpty && runId != null) {
        final last = state.messages.last;
        final newEvents = last.toolEvents.map((t) {
          if (t.id == runId) {
            return t.copyWith(isComplete: true, result: artifact ?? output);
          }
          return t;
        }).toList();
        _updateLastMessage(activeTool: null, toolEvents: newEvents);
      } else {
        _updateLastMessage(activeTool: null);
      }
    } else if (type == 'on_chain_end' && event['name'] == 'LangGraph') {
      Map<String, dynamic>? updatedMetrics;
      if (_currentRequestStartTime != null && state.messages.isNotEmpty) {
        final lastMsg = state.messages.last;
        if (lastMsg.metrics != null) {
          final elapsed = DateTime.now().difference(_currentRequestStartTime!).inMilliseconds / 1000.0;
          updatedMetrics = Map<String, dynamic>.from(lastMsg.metrics!);
          updatedMetrics['generation_seconds'] = elapsed;
        }
      }
      _updateLastMessage(isStreaming: false, activeTool: null, metrics: updatedMetrics);
      state = state.copyWith(isLoading: false);
      _currentRequestStartTime = null;
      ref.read(chatHistoryProvider.notifier).loadThreads();
    }
  }

  void _updateLastMessage({
    String? content,
    bool? isStreaming,
    String? activeTool,
    List<ToolEvent>? toolEvents,
    bool? isError,
    Map<String, dynamic>? metrics,
  }) {
    if (state.messages.isEmpty) return;
    final msgs = List<ChatMessage>.from(state.messages);
    final last = msgs.last;
    msgs[msgs.length - 1] = last.copyWith(
      content: content,
      isStreaming: isStreaming,
      activeTool: activeTool,
      toolEvents: toolEvents,
      isError: isError,
      metrics: metrics,
    );
    state = state.copyWith(messages: msgs);
  }

  String _friendlyToolLabel(String toolName) {
    if (toolName == 'search_vectors') return 'Running hybrid search';
    if (toolName == 'query_graph') return 'Traversing knowledge graph';
    if (toolName == 'web_search') return 'Searching the web';
    if (toolName == 'run_python_code') return 'Running code';
    if (toolName == 'fetch_url') return 'Fetching URL';
    if (toolName == 'get_current_time') return 'Checking time';
    if (toolName.startsWith('mcp__')) {
      final parts = toolName.split('__');
      if (parts.length >= 3) {
        return 'Using skill (${parts[1].replaceAll('_', ' ')})';
      }
    }
    return 'Calling $toolName';
  }

  Future<void> submitFeedback(String messageId, int value) async {
    try {
      await ref.read(chatRepositoryProvider).submitFeedback(messageId, value);
      final msgs = state.messages.map((m) => m.id == messageId ? m.copyWith(feedback: value) : m).toList();
      state = state.copyWith(messages: msgs, clearError: true);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to submit feedback: $e');
    }
  }

  Future<void> editMessage(String messageId, String content) async {
    if (state.threadId == null) return;
    try {
      await ref.read(chatRepositoryProvider).editMessage(messageId, content, state.threadId!);
      final msgs = state.messages.map((m) => m.id == messageId ? m.copyWith(content: content) : m).toList();
      state = state.copyWith(messages: msgs, clearError: true);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to edit message: $e');
    }
  }

  Future<void> regenerateResponse() async {
    if (state.threadId == null) return;
    try {
      await ref.read(chatRepositoryProvider).regenerateResponse(state.threadId!);
      state = state.copyWith(clearError: true);
      selectThread(state.threadId!);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to regenerate response: $e');
    }
  }

  Future<void> saveToMemory(String content, {String? model}) async {
    try {
      await ref.read(memoryRepositoryProvider).saveToMemory(content, model: model);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to save memory: $e');
    }
  }
}

final chatThreadProvider = NotifierProvider<ChatThreadViewModel, ChatThreadState>(
  () => ChatThreadViewModel(),
);

/// Provides shared thread history for public/shared links.
/// Used by SharedChatScreen to avoid importing the data layer directly.
final sharedThreadHistoryProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, shareId) async {
  final repo = ref.read(chatRepositoryProvider);
  return repo.getSharedThreadHistory(shareId);
});
