import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/models/model_provider_mapper.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/data/local_chat_migration_service.dart';
import 'package:veraxi_app/core/repositories/memory_repository.dart';
export 'chat_state.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';

final chatViewModelProvider =
    StateNotifierProvider<ChatViewModel, ChatState>((ref) {
  final repo = ref.watch(chatRepositoryProvider);
  final ttsRepo = ref.watch(ttsRepositoryProvider);
  final memoryRepo = ref.watch(memoryRepositoryProvider);
  final migrationService = LocalChatMigrationService(
    apiClient: ref.watch(apiClientProvider),
  );
  return ChatViewModel(repo, ttsRepo, memoryRepo, migrationService);
});

class ChatViewModel extends StateNotifier<ChatState> {
  @visibleForTesting
  void setStateForTesting(ChatState s) => state = s;

  final IChatRepository _repository;
  final MemoryRepository _memoryRepository;
  final LocalChatMigrationService? _localChatMigrationService;
  DateTime? _currentRequestStartTime;
  StreamSubscription<AuthState>? _authSubscription;
  StreamSubscription<Map<String, dynamic>>? _syncSubscription;

  ChatViewModel(this._repository, TTSRepository? _, this._memoryRepository,
      [this._localChatMigrationService])
      : super(ChatState()) {
    _init();

    // Listen to Auth State changes to reload threads if they failed initially
    // (e.g., due to an expired token on app startup that was just refreshed)
    try {
      _authSubscription =
          Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        if (data.event == AuthChangeEvent.signedIn ||
            data.event == AuthChangeEvent.tokenRefreshed ||
            data.event == AuthChangeEvent.initialSession) {
          if (state.pastThreads.isEmpty && !state.isLoadingThreads) {
            loadThreads();
          }
        }
      });
    } catch (_) {
      // Ignore in test environments where Supabase is not initialized
    }
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTelemetry = prefs.getBool('show_telemetry') ?? false;

    // Force clear old tool_settings to ensure everyone defaults to false
    // for file_search_enabled. This avoids the stale 'true' state.
    await prefs.remove('tool_settings');

    state = state.copyWith(showTelemetry: savedTelemetry);
    await _migrateLocalChats();
    await loadThreads();

    _syncSubscription?.cancel();
    _syncSubscription = _repository.streamSyncEvents().listen((event) {
      final type = event['event'] as String?;
      final data = event['data'] as Map<String, dynamic>?;

      if (type == 'thread_created' ||
          type == 'thread_renamed' ||
          type == 'thread_deleted' ||
          type == 'thread_updated') {
        loadThreads();
      }

      if ((type == 'message_updated' ||
              type == 'message_added' ||
              type == 'thread_updated') &&
          data != null) {
        final threadId = data['thread_id'] as String?;
        if (threadId != null &&
            state.threadId == threadId &&
            !state.isLoading) {
          _repository.getThreadHistory(threadId).then((history) {
            if (state.threadId == threadId && !state.isLoading) {
              final messages = _parseHistory(history);
              state = state.copyWith(messages: messages);
            }
          }).catchError((e) {
            debugPrint('Failed to sync thread history: $e');
          });
        }
      }
    });
  }

  Future<void> _migrateLocalChats() async {
    Session? session;
    try {
      session = Supabase.instance.client.auth.currentSession;
    } catch (_) {
      return;
    }
    if (session == null) return;
    try {
      await _localChatMigrationService?.migrate();
    } catch (error, stackTrace) {
      Sentry.captureException(error, stackTrace: stackTrace);
      debugPrint(
          'Local chat migration failed; local records remain on the device: $error');
    }
  }

  /// Toggle the response telemetry panel on/off and persist the preference.
  Future<void> toggleTelemetry() async {
    final next = !state.showTelemetry;
    state = state.copyWith(showTelemetry: next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_telemetry', next);
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _syncSubscription?.cancel();
    super.dispose();
  }

  Future<void> loadThreads() async {
    state = state.copyWith(isLoadingThreads: true);
    try {
      final threads = await _repository.getThreads();
      state = state.copyWith(pastThreads: threads, isLoadingThreads: false);
    } catch (e, stack) {
      Sentry.captureException(e, stackTrace: stack);
      state = state.copyWith(isLoadingThreads: false);
    }
  }

  List<ChatMessage> _parseHistory(List<Map<String, dynamic>> history) {
    return history.map((m) {
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

      return ChatMessage(
        id: m['id'] as String?,
        role: m['role'] as String,
        content: m['content'] as String,
        feedback: m['feedback'] as int? ?? 0,
        modelName: m['model_name'] as String?,
        toolEvents: toolEvents,
        metrics: m['metrics'] is Map
            ? Map<String, dynamic>.from(m['metrics'] as Map)
            : null,
      );
    }).toList();
  }

  Future<void> selectThread(String threadId) async {
    state = state.copyWith(
        isLoadingHistory: true,
        threadId: threadId,
        messages: [],
        showProjectDashboard: false,
        showAllProjectsDashboard: false);
    try {
      final history = await _repository.getThreadHistory(threadId);
      final messages = _parseHistory(history);
      state = state.copyWith(messages: messages, isLoadingHistory: false);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(isLoadingHistory: false);
    }
  }

  void startNewChat() {
    state = state.copyWith(
      clearThreadId: true,
      messages: [],
      clearActiveProject: true,
      showProjectDashboard: false,
      showAllProjectsDashboard: false,
    );
  }

  void selectProject(String id, String name) {
    state = state.copyWith(
      activeProjectId: id,
      activeProjectName: name,
      showProjectDashboard: true,
      showAllProjectsDashboard: false,
      clearThreadId: true,
      messages: [],
    );
  }

  void startNewChatInProject([String? projectId]) {
    state = state.copyWith(
      activeProjectId: projectId ?? state.activeProjectId,
      showProjectDashboard: false,
      showAllProjectsDashboard: false,
      clearThreadId: true,
      messages: [],
    );
  }

  void openAllProjectsDashboard() {
    state = state.copyWith(
      showAllProjectsDashboard: true,
      showProjectDashboard: false,
      clearThreadId: true,
      messages: [],
      clearActiveProject: true,
    );
  }

  void exitProject() {
    state = state.copyWith(
      clearActiveProject: true,
      showProjectDashboard: false,
      showAllProjectsDashboard: false,
      clearThreadId: true,
      messages: [],
    );
  }

  void toggleTemporaryChat() {
    final newIsTemporary = !state.isTemporary;
    if (newIsTemporary) {
      // If toggling ON, clear the current context
      state = state
          .copyWith(isTemporary: newIsTemporary, threadId: null, messages: []);
    } else {
      state = state.copyWith(isTemporary: newIsTemporary);
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

    final provider = ModelProviderMapper.resolve(model);
    final hasExpired = await ApiKeyStorage().isKeyExpired(provider);
    if (hasExpired) {
      final expireDate = await ApiKeyStorage().getKeyExpirationDate(provider);
      final userMsg = ChatMessage(role: 'user', content: text);
      final errorMsg = ChatMessage(
        role: 'assistant',
        content:
            'Provided key for $provider expired at $expireDate. Please provide a new key and try again.',
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
    // Add user message and empty AI message, and set loading state
    state = state.copyWith(
      messages: [
        ...state.messages,
        userMsgForUI,
        ChatMessage(
            role: 'assistant', content: '', isStreaming: true, modelName: model)
      ],
      isLoading: true,
      error: null,
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
            final extracted =
                await _repository.uploadAttachment(fileBytes, fileName);
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
        // If upload fails, just fail the message
        state = state.copyWith(
          isLoading: false,
          error: "Failed to process attachments: $e",
        );
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
        await for (final event in _repository.streamChat(
          currentQuery,
          threadId: state.threadId,
          isTemporary: state.isTemporary,
          model: model,
          calculateGrounding: state.showTelemetry,
          toolSettings: toolSettings,
        )) {
          _handleStreamEvent(event);
        }
        _updateLastMessage(isStreaming: false);
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
        } else if (errorStr.contains("No AI model selected")) {
          uiError =
              "No AI model selected. Please select a model from the top left menu.";
        } else if (errorStr.contains("402") &&
            errorStr.contains("Payment Required")) {
          uiError =
              "Payment Required: Free tier users must configure Bring Your Own Database (BYOD) in Control Panel (Gear Icon) -> Infrastructure.";
        } else if (errorStr.contains("Guest users must provide") ||
            errorStr.contains("API key")) {
          uiError =
              "Please add your API key in Settings -> API Keys to use this feature.";
        } else if (errorStr.contains("Internal server error:")) {
          // Extract the actual error details for debugging
          // Format: "Internal server error: ExceptionType: error message"
          final match = RegExp(r"Internal server error: ([^:]+): (.+)")
              .firstMatch(errorStr);
          if (match != null) {
            uiError = "Error: ${match.group(2)}";
          } else {
            uiError = errorStr;
          }
        } else if (errorStr.contains("timeout") ||
            errorStr.contains("Timeout")) {
          uiError = "Request timed out. Please try again.";
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
            content: finalContent,
            isStreaming: false,
            isError: true,
            activity: _markRunningActivityAsErrored());
        state = state.copyWith(isLoading: false);
        break;
      }
    }
  }

  void _applyThreadTitle(String title) {
    final threadId = state.threadId;
    if (threadId == null) return;

    final updatedThreads = state.pastThreads.map((thread) {
      if (thread['thread_id'] == threadId) {
        return {...thread, 'title': title};
      }
      return thread;
    }).toList();

    final threadExists =
        updatedThreads.any((thread) => thread['thread_id'] == threadId);
    state = state.copyWith(
      pastThreads: threadExists
          ? updatedThreads
          : [
              {'thread_id': threadId, 'title': title},
              ...state.pastThreads,
            ],
    );
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

    final type = event['event']; // astream_events v2 provides 'event'
    if (type == 'metadata') {
      final data = event['data'];
      bool shouldLoad = false;
      if (data != null) {
        if (data['thread_id'] != null) {
          final isNewThread = state.threadId == null;
          final newThreadId = data['thread_id'] as String;
          state = state.copyWith(threadId: newThreadId);
          if (isNewThread && state.activeProjectId != null) {
            try {
              _repository
                  .assignThreadToProject(newThreadId, state.activeProjectId)
                  .catchError((e, s) {
                Sentry.captureException(e, stackTrace: s);
              });
            } catch (e, s) {
              Sentry.captureException(e, stackTrace: s);
            }
          }
        }
        if (data['thread_title'] != null) {
          _applyThreadTitle(data['thread_title'] as String);
          shouldLoad = true;
        }
        if (data['metrics'] is Map) {
          _updateLastMessage(
              metrics: Map<String, dynamic>.from(data['metrics'] as Map));
        }
      }
      if (shouldLoad) {
        loadThreads();
      }
      return;
    }
    if (type == 'on_step_start') {
      final step = (event['step'] as num?)?.toInt() ?? 1;
      final name = event['name'] as String? ?? 'Processing';
      final description =
          event['description'] as String? ?? 'Working on your request...';
      final current = state.messages.last;
      final activity = List<ActivityStep>.from(current.activity);
      final existingIndex = activity.indexWhere((item) => item.number == step);
      for (var index = 0; index < activity.length; index++) {
        if (index != existingIndex &&
            activity[index].status == ActivityStepStatus.running) {
          activity[index] = activity[index].copyWith(
            status: ActivityStepStatus.complete,
          );
        }
      }
      final nextStep = ActivityStep(
        number: step,
        name: name,
        description: description,
        status: ActivityStepStatus.running,
        toolEvents:
            existingIndex >= 0 ? activity[existingIndex].toolEvents : const [],
      );
      if (existingIndex >= 0) {
        activity[existingIndex] = nextStep;
      } else {
        activity.add(nextStep);
      }
      _updateLastMessage(
        activeTool: 'Step $step: $description',
        activity: activity,
      );
      return;
    } else if (type == 'on_reasoning_stream') {
      final text = event['data']?['text'] ?? '';
      if (text is String && text.isNotEmpty && state.messages.isNotEmpty) {
        final last = state.messages.last;
        final currentReasoning = last.reasoning ?? '';
        final updatedReasoning = currentReasoning + text;
        final msgs = List<ChatMessage>.from(state.messages);
        msgs[msgs.length - 1] = last.copyWith(reasoning: updatedReasoning);
        state = state.copyWith(messages: msgs);
      }
      return;
    } else if (type == 'on_reasoning_end') {
      final seconds = (event['seconds'] as num?)?.toDouble() ??
          ((event['duration_ms'] as num?) != null
              ? (event['duration_ms'] as num).toDouble() / 1000.0
              : null);
      if (seconds != null && state.messages.isNotEmpty) {
        final last = state.messages.last;
        final msgs = List<ChatMessage>.from(state.messages);
        msgs[msgs.length - 1] =
            last.copyWith(reasoningDurationSeconds: seconds);
        state = state.copyWith(messages: msgs);
      }
      return;
    } else if (type == 'on_chat_model_stream') {
      final chunk = event['data']?['chunk'];
      if (chunk != null) {
        final content = chunk['content'];
        if (content != null && content is String) {
          final msgs = List<ChatMessage>.from(state.messages);
          final last = msgs.last;

          // Remove the default 'Thinking...' if this is the first chunk of real text
          String newContent = last.content;
          if (newContent == 'Thinking...') {
            newContent = '';
          }
          newContent += content;

          msgs[msgs.length - 1] = last.copyWith(content: newContent);
          state = state.copyWith(messages: msgs);
        }
      }
    } else if (type == 'on_tool_start') {
      final toolName = event['name'];
      final friendlyName = event['label'] ?? _friendlyToolLabel(toolName);
      final step = event['step'];
      final stepPrefix = step != null ? 'Step $step: ' : '';
      final runId =
          event['run_id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
      final args = event['data']?['input'] ?? {};

      if (state.messages.isNotEmpty) {
        final last = state.messages.last;
        final newEvents = List<ToolEvent>.from(last.toolEvents);
        final toolEvent = ToolEvent(
          id: runId,
          name: toolName,
          args: args is Map ? Map<String, dynamic>.from(args) : {},
          isComplete: false,
        );
        newEvents.add(toolEvent);
        final activity = _addToolToActivity(
          last.activity,
          step is num ? step.toInt() : null,
          toolEvent,
        );
        _updateLastMessage(
          activeTool: '$stepPrefix$friendlyName...',
          toolEvents: newEvents,
          activity: activity,
        );
      } else {
        _updateLastMessage(activeTool: '$stepPrefix$friendlyName...');
      }
    } else if (type == 'on_tool_end') {
      final runId = event['run_id'];
      final output = event['data']?['output'];
      final artifact = event['data']?['artifact'];

      if (state.messages.isNotEmpty && runId != null) {
        final last = state.messages.last;
        final newEvents = last.toolEvents.map((t) {
          if (t.id == runId) {
            return t.copyWith(
              isComplete: true,
              result: artifact ?? output,
              durationMs: (event['duration_ms'] as num?)?.toInt(),
              summary: event['summary'] as String?,
            );
          }
          return t;
        }).toList();
        final activity = last.activity.map((step) {
          final updatedTools = step.toolEvents.map((tool) {
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
          if (!updatedTools.any((tool) => tool.id == runId)) return step;
          return step.copyWith(
            toolEvents: updatedTools,
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
        _updateLastMessage(activeTool: null); // Clear tool indicator
      }
    } else if (type == 'on_chain_end' && event['name'] == 'LangGraph') {
      // Graph finished
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

      // If this was a new chat, we need to extract the thread ID from somewhere, or reload threads
      loadThreads();
    }
  }

  void _updateLastMessage(
      {String? content,
      bool? isStreaming,
      String? activeTool,
      String? reasoning,
      double? reasoningDurationSeconds,
      List<ToolEvent>? toolEvents,
      List<ActivityStep>? activity,
      bool? isError,
      Map<String, dynamic>? metrics}) {
    if (state.messages.isEmpty) return;
    final msgs = List<ChatMessage>.of(state.messages, growable: false);
    final last = msgs.last;

    msgs[msgs.length - 1] = ChatMessage(
      id: last.id,
      role: last.role,
      content: content ?? last.content,
      isStreaming: isStreaming ?? last.isStreaming,
      activeTool: activeTool, // This will clear it if activeTool is null
      reasoning: reasoning ?? last.reasoning,
      reasoningDurationSeconds:
          reasoningDurationSeconds ?? last.reasoningDurationSeconds,
      toolEvents: toolEvents ?? last.toolEvents,
      activity: activity ?? last.activity,
      isError: isError ?? last.isError,
      feedback: last.feedback,
      modelName: last.modelName,
      metrics: metrics ?? last.metrics,
    );
    state = state.copyWith(messages: msgs);
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

  List<ActivityStep> _markRunningActivityAsErrored() {
    if (state.messages.isEmpty) return const [];
    return state.messages.last.activity.map((step) {
      if (step.status == ActivityStepStatus.running) {
        return step.copyWith(status: ActivityStepStatus.error);
      }
      return step;
    }).toList();
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  /// Maps internal tool names to user-friendly display labels.
  String _friendlyToolLabel(String toolName) {
    // Hybrid search uses both vectors and the knowledge graph via merge_rank.
    if (toolName == 'search_vectors') return 'Running hybrid search';
    if (toolName == 'query_graph') return 'Traversing knowledge graph';
    if (toolName == 'web_search') return 'Searching the web';
    if (toolName == 'run_python_code') return 'Running code';
    if (toolName == 'fetch_url') return 'Fetching URL';
    if (toolName == 'get_current_time') return 'Checking time';
    // Dynamic MCP tool: mcp__{server}__{tool}
    if (toolName.startsWith('mcp__')) {
      final parts = toolName.split('__');
      if (parts.length >= 3) {
        final serverName = parts[1].replaceAll('_', ' ');
        return 'Using skill ($serverName)';
      }
    }
    return 'Calling $toolName';
  }

  Future<void> submitFeedback(String messageId, int value) async {
    try {
      await _repository.submitFeedback(messageId, value);
      // Update local state
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
      await _repository.editMessage(messageId, content, state.threadId!);
      // Update local state
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
      await _repository.regenerateResponse(state.threadId!);
      state = state.copyWith(clearError: true);
      // Mock refresh - in reality we should drop the last message and call streamChat again
      selectThread(state.threadId!);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to regenerate response: $e');
    }
  }

  Future<void> saveToMemory(String content, {String? model}) async {
    try {
      await _memoryRepository.saveToMemory(content, model: model);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to save memory: $e');
    }
  }

  Future<void> renameThread(String threadId, String newTitle) async {
    try {
      await _repository.renameThread(threadId, newTitle);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to rename chat: $e');
    }
  }

  Future<void> togglePinThread(String threadId) async {
    try {
      await _repository.togglePinThread(threadId);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to pin/unpin chat: $e');
    }
  }

  Future<void> toggleArchiveThread(String threadId) async {
    try {
      await _repository.toggleArchiveThread(threadId);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to archive/unarchive chat: $e');
    }
  }

  Future<void> deleteThread(String threadId) async {
    try {
      await _repository.deleteThread(threadId);
      if (state.threadId == threadId) {
        startNewChat();
      }
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to delete chat: $e');
    }
  }

  Future<void> deleteAllChats() async {
    try {
      await _repository.deleteAllThreads();
      startNewChat();
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to delete all chats: $e');
    }
  }

  Future<String?> duplicateThread(String threadId) async {
    try {
      final newId = await _repository.duplicateThread(threadId);
      await loadThreads();
      return newId;
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to duplicate chat: $e');
      return null;
    }
  }

  Future<String?> shareThread(String threadId) async {
    try {
      final shareId = await _repository.shareThread(threadId);
      return shareId;
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to share chat: $e');
      return null;
    }
  }
}
