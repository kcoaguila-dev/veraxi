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
    state = state
        .copyWith(isLoadingHistory: true, threadId: threadId, messages: []);
    try {
      final history =
          await ref.read(chatRepositoryProvider).getThreadHistory(threadId);
      final messages = history.map((m) {
        List<ToolEvent> toolEvents = [];
        if (m['toolEvents'] != null) {
          final evts = m['toolEvents'] as List;
          toolEvents = evts
              .map((e) => ToolEvent(
                    id: e['id'] as String? ?? '',
                    name: e['name'] as String? ?? '',
                    args: e['args'] is Map
                        ? Map<String, dynamic>.from(e['args'] as Map)
                        : {},
                    result: e['result'],
                    isComplete: e['isComplete'] as bool? ?? true,
                  ))
              .toList();
        }
        final activity = _decodeActivity(m['activity']);
        final restoredActivity = activity.isNotEmpty || toolEvents.isEmpty
            ? activity
            : [
                ActivityStep(
                  number: 1,
                  name: 'Activity',
                  description: 'Tools used while answering',
                  status: ActivityStepStatus.complete,
                  toolEvents: toolEvents,
                ),
              ];
        return ChatMessage(
          id: m['id'] as String?,
          role: m['role'] as String,
          content: m['content'] as String,
          feedback: m['feedback'] as int? ?? 0,
          modelName: m['model_name'] as String?,
          toolEvents: toolEvents,
          activity: restoredActivity,
          metrics: m['metrics'] is Map
              ? Map<String, dynamic>.from(m['metrics'] as Map)
              : null,
        );
      }).toList();
      state = state.copyWith(messages: messages, isLoadingHistory: false);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(isLoadingHistory: false, error: e.toString());
    }
  }

  Future<void> sendMessage(String text,
      {String? model, List<dynamic>? attachments}) async {
    if (text.trim().isEmpty && (attachments == null || attachments.isEmpty))
      return;

    if (model == null || model == 'Select a model' || model.isEmpty) {
      final userMsg = ChatMessage(
          role: 'user', content: text.isEmpty ? '[Attachment]' : text);
      final errorMsg = ChatMessage(
        role: 'assistant',
        content:
            'No AI model selected. Please select a model from the top left menu.',
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
        ChatMessage(
            role: 'assistant', content: '', isStreaming: true, modelName: model)
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
            final extracted = await ref
                .read(chatRepositoryProvider)
                .uploadAttachment(fileBytes, fileName);
            if (extracted.isNotEmpty) {
              extractedTexts.add("--- Attachment: $fileName ---\n$extracted");
            }
          }
        }
        if (extractedTexts.isNotEmpty) {
          final attachmentsStr = extractedTexts.join("\n\n");
          if (queryText.isEmpty) {
            queryText =
                "Please analyze the following attached document(s):\n\n$attachmentsStr";
          } else {
            queryText =
                "Here are the attached document(s) for context:\n\n$attachmentsStr\n\nUser Query: $queryText";
          }
        }
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
        state = state.copyWith(
            isLoading: false, error: "Failed to process attachments: $e");
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
          final partialResponse =
              state.messages.isNotEmpty ? state.messages.last.content : "";
          if (partialResponse.isNotEmpty && partialResponse != "Thinking...") {
            currentQuery =
                "System: The previous response was interrupted by a network drop. Please continue generating your response EXACTLY where you left off. Do not repeat what was already said. Here is what you generated so far:\n\n$partialResponse";
          }
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        Sentry.captureException(e, stackTrace: st);
        String uiError = "Error: Unable to complete request.";
        if (isNetworkError) {
          uiError =
              "Network connection lost. Please check your internet connection and try again.";
        } else if (errorStr.contains("402") &&
            errorStr.contains("Payment Required")) {
          uiError =
              "Payment Required: Free tier users must configure Bring Your Own Database (BYOD) in Control Panel (Gear Icon) -> Infrastructure.";
        }
        String finalContent = uiError;
        if (state.messages.isNotEmpty) {
          final currentContent = state.messages.last.content;
          if (currentContent.isNotEmpty &&
              !currentContent.endsWith(uiError) &&
              !currentContent.endsWith("[$uiError]")) {
            finalContent = "$currentContent\n\n[$uiError]";
          }
        }
        _updateLastMessage(
            content: finalContent, isStreaming: false, isError: true);
        state = state.copyWith(isLoading: false);
        break;
      }
    }
  }

  void _handleStreamEvent(Map<String, dynamic> event) {
    if (event.containsKey('error')) {
      final rawError = event['error'].toString();
      String uiError = rawError;
      if (rawError.contains("API key") ||
          rawError.contains("API_KEY_INVALID") ||
          rawError.contains("AuthenticationError")) {
        uiError = "Please check your API key in Settings -> API Keys.";
      } else if (rawError.contains("model_not_found") ||
          rawError.contains("does not have access to model") ||
          rawError.contains("selected model is unavailable")) {
        uiError =
            "The selected model is unavailable. Please choose another model.";
      } else if (rawError.contains("quota") ||
          rawError.contains("rate limit") ||
          rawError.contains("RateLimitError")) {
        uiError =
            "This provider has reached its quota or rate limit. Please switch models or try again later.";
      } else if (rawError.contains("Internal server error:")) {
        final match = RegExp(r"Internal server error: ([^:]+): (.+)")
            .firstMatch(rawError);
        if (match != null) {
          uiError = match.group(2) ?? rawError;
        }
      }
      _updateLastMessage(
          content: "Error: $uiError",
          isStreaming: false,
          isError: true,
          activity: _markRunningActivityAsErrored());
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
          ref.read(chatHistoryProvider.notifier).applyThreadTitle(
              state.threadId!, data['thread_title'] as String);
        }
        if (data['metrics'] is Map) {
          _updateLastMessage(
              metrics: Map<String, dynamic>.from(data['metrics'] as Map));
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
    } else if (type == 'on_step_start') {
      final stepNumber = (event['step'] as num?)?.toInt() ?? 1;
      final name = event['name'] as String? ?? 'Processing';
      final description =
          event['description'] as String? ?? 'Working on your request...';
      if (state.messages.isNotEmpty) {
        final last = state.messages.last;
        final activity = List<ActivityStep>.from(last.activity);
        final index = activity.indexWhere((step) => step.number == stepNumber);
        for (var i = 0; i < activity.length; i++) {
          if (i != index && activity[i].status == ActivityStepStatus.running) {
            activity[i] = activity[i].copyWith(
              status: ActivityStepStatus.complete,
            );
          }
        }
        final next = ActivityStep(
          number: stepNumber,
          name: name,
          description: description,
          toolEvents: index >= 0 ? activity[index].toolEvents : const [],
        );
        if (index >= 0) {
          activity[index] = next;
        } else {
          activity.add(next);
        }
        _updateLastMessage(
          activeTool: 'Step $stepNumber: $description',
          activity: activity,
        );
      }
    } else if (type == 'on_tool_start') {
      final toolName = event['name'];
      final runId =
          event['run_id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
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
        final toolEvent = newEvents.last;
        final activity = _addToolToActivity(
          last.activity,
          (event['step'] as num?)?.toInt(),
          toolEvent,
        );
        _updateLastMessage(
          activeTool: '$friendlyName...',
          toolEvents: newEvents,
          activity: activity,
        );
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
        final activity = last.activity.map((step) {
          final tools = step.toolEvents.map((tool) {
            if (tool.id == runId) {
              return tool.copyWith(
                isComplete: true,
                result: artifact ?? output,
                durationMs: (event['duration_ms'] as num?)?.toInt(),
                summary: event['summary'] as String?,
              );
            }
            return tool;
          }).toList();
          if (!tools.any((tool) => tool.id == runId)) return step;
          return step.copyWith(
            toolEvents: tools,
            status: event['status'] == 'error'
                ? ActivityStepStatus.error
                : step.status,
          );
        }).toList();
        _updateLastMessage(
          activeTool: null,
          toolEvents: newEvents,
          activity: activity,
        );
      } else {
        _updateLastMessage(activeTool: null);
      }
    } else if (type == 'on_chain_end' && event['name'] == 'LangGraph') {
      Map<String, dynamic>? updatedMetrics;
      if (_currentRequestStartTime != null && state.messages.isNotEmpty) {
        final lastMsg = state.messages.last;
        if (lastMsg.metrics != null) {
          final elapsed = DateTime.now()
                  .difference(_currentRequestStartTime!)
                  .inMilliseconds /
              1000.0;
          updatedMetrics = Map<String, dynamic>.from(lastMsg.metrics!);
          updatedMetrics['generation_seconds'] = elapsed;
        }
      }
      final activity = state.messages.isNotEmpty
          ? state.messages.last.activity.map((step) {
              if (step.status != ActivityStepStatus.error) {
                return step.copyWith(status: ActivityStepStatus.complete);
              }
              return step;
            }).toList()
          : const <ActivityStep>[];
      _updateLastMessage(
        isStreaming: false,
        activeTool: null,
        metrics: updatedMetrics,
        activity: activity,
      );
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
    List<ActivityStep>? activity,
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
      activity: activity,
      isError: isError,
      metrics: metrics,
    );
    state = state.copyWith(messages: msgs);
  }

  List<ActivityStep> _markRunningActivityAsErrored() {
    if (state.messages.isEmpty) return const [];
    return state.messages.last.activity.map((step) {
      if (step.status == ActivityStepStatus.running) {
        return step.copyWith(status: ActivityStepStatus.error);
      }
      return step;
    }).toList();
  }

  List<ActivityStep> _decodeActivity(dynamic raw) {
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((item) {
      final tools = item['toolEvents'];
      return ActivityStep(
        number: (item['number'] as num?)?.toInt() ?? 1,
        name: item['name'] as String? ?? 'Activity',
        description: item['description'] as String? ?? '',
        status: ActivityStepStatus.values.firstWhere(
          (status) => status.name == item['status'],
          orElse: () => ActivityStepStatus.complete,
        ),
        durationMs: (item['durationMs'] as num?)?.toInt(),
        summary: item['summary'] as String?,
        toolEvents: tools is List
            ? tools.whereType<Map>().map((tool) {
                return ToolEvent(
                  id: tool['id'] as String? ?? '',
                  name: tool['name'] as String? ?? 'tool',
                  args: tool['args'] is Map
                      ? Map<String, dynamic>.from(tool['args'] as Map)
                      : const {},
                  result: tool['result'],
                  isComplete: tool['isComplete'] as bool? ?? true,
                  durationMs: (tool['durationMs'] as num?)?.toInt(),
                  summary: tool['summary'] as String?,
                );
              }).toList()
            : const [],
      );
    }).toList();
  }

  List<ActivityStep> _addToolToActivity(
      List<ActivityStep> current, int? stepNumber, ToolEvent toolEvent) {
    final activity = List<ActivityStep>.from(current);
    final targetNumber =
        stepNumber ?? (activity.isNotEmpty ? activity.last.number : 1);
    final targetIndex =
        activity.indexWhere((step) => step.number == targetNumber);
    if (targetIndex < 0) {
      activity.add(ActivityStep(
        number: targetNumber,
        name: 'Activity',
        status: ActivityStepStatus.running,
        toolEvents: [toolEvent],
      ));
      return activity;
    }
    final step = activity[targetIndex];
    activity[targetIndex] = step.copyWith(
      status: ActivityStepStatus.running,
      toolEvents: [...step.toolEvents, toolEvent],
    );
    return activity;
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
      final msgs = state.messages
          .map((m) => m.id == messageId ? m.copyWith(feedback: value) : m)
          .toList();
      state = state.copyWith(messages: msgs, clearError: true);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to submit feedback: $e');
    }
  }

  Future<void> editMessage(String messageId, String content) async {
    if (state.threadId == null) return;
    try {
      await ref
          .read(chatRepositoryProvider)
          .editMessage(messageId, content, state.threadId!);
      final msgs = state.messages
          .map((m) => m.id == messageId ? m.copyWith(content: content) : m)
          .toList();
      state = state.copyWith(messages: msgs, clearError: true);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to edit message: $e');
    }
  }

  Future<void> regenerateResponse() async {
    if (state.threadId == null) return;
    try {
      await ref
          .read(chatRepositoryProvider)
          .regenerateResponse(state.threadId!);
      state = state.copyWith(clearError: true);
      selectThread(state.threadId!);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to regenerate response: $e');
    }
  }

  Future<void> saveToMemory(String content, {String? model}) async {
    try {
      await ref
          .read(memoryRepositoryProvider)
          .saveToMemory(content, model: model);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to save memory: $e');
    }
  }
}

final chatThreadProvider =
    NotifierProvider<ChatThreadViewModel, ChatThreadState>(
  () => ChatThreadViewModel(),
);

/// Provides shared thread history for public/shared links.
/// Used by SharedChatScreen to avoid importing the data layer directly.
final sharedThreadHistoryProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
        (ref, shareId) async {
  final repo = ref.read(chatRepositoryProvider);
  return repo.getSharedThreadHistory(shareId);
});
