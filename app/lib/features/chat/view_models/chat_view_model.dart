import 'dart:convert';
import 'dart:async';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/tts_settings_storage.dart';
import 'package:veraxi_app/core/web_speech_service.dart';
import 'package:veraxi_app/core/network/tts_repository.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';

class ToolEvent {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  final dynamic result;
  final bool isComplete;

  ToolEvent({
    required this.id,
    required this.name,
    this.args = const {},
    this.result,
    this.isComplete = false,
  });

  ToolEvent copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? args,
    dynamic result,
    bool? isComplete,
  }) {
    return ToolEvent(
      id: id ?? this.id,
      name: name ?? this.name,
      args: args ?? this.args,
      result: result ?? this.result,
      isComplete: isComplete ?? this.isComplete,
    );
  }
}

class ChatMessage {
  final String? id;
  final String role; // 'user' or 'assistant'
  final String content;
  final bool isStreaming;
  final String? activeTool; // E.g. "Searching Neo4j..."
  final List<ToolEvent> toolEvents;
  final bool isError;
  final int feedback; // 1 (up), -1 (down), 0 (none)
  final String? modelName; // Store the AI model that generated this message
  final Map<String, dynamic>? metrics;

  ChatMessage({
    this.id,
    required this.role,
    required this.content,
    this.isStreaming = false,
    this.activeTool,
    this.toolEvents = const [],
    this.isError = false,
    this.feedback = 0,
    this.modelName,
    this.metrics,
  });

  bool get isUser => role == 'user';
  String get text => content;

  ChatMessage copyWith(
      {String? id,
      String? content,
      bool? isStreaming,
      String? activeTool,
      List<ToolEvent>? toolEvents,
      bool? isError,
      int? feedback,
      String? modelName,
      Map<String, dynamic>? metrics}) {
    return ChatMessage(
      id: id ?? this.id,
      role: role,
      content: content ?? this.content,
      isStreaming: isStreaming ?? this.isStreaming,
      activeTool: activeTool, // allow null to clear tool
      toolEvents: toolEvents ?? this.toolEvents,
      isError: isError ?? this.isError,
      feedback: feedback ?? this.feedback,
      modelName: modelName ?? this.modelName,
      metrics: metrics ?? this.metrics,
    );
  }
}

class ChatState {
  final String? threadId;
  final List<ChatMessage> messages;
  final List<Map<String, dynamic>> pastThreads;
  final List<Map<String, dynamic>> projects;
  final bool isLoadingHistory;
  final bool isLoadingThreads;
  final bool isLoading;
  final bool isTemporary;
  final bool showTelemetry;
  final String? error;
  final String? currentlyPlayingMessageId;
  final String? activeProjectId;
  final String? activeProjectName;
  final bool showProjectDashboard;
  final bool showAllProjectsDashboard;

  ChatState({
    this.threadId,
    this.messages = const [],
    this.pastThreads = const [],
    this.projects = const [],
    this.isLoadingHistory = false,
    this.isLoadingThreads = false,
    this.isLoading = false,
    this.isTemporary = false,
    this.showTelemetry = false,
    this.error,
    this.currentlyPlayingMessageId,
    this.activeProjectId,
    this.activeProjectName,
    this.showProjectDashboard = false,
    this.showAllProjectsDashboard = false,
  });

  ChatState copyWith({
    String? threadId,
    bool clearThreadId = false,
    List<ChatMessage>? messages,
    List<Map<String, dynamic>>? pastThreads,
    List<Map<String, dynamic>>? projects,
    bool? isLoadingHistory,
    bool? isLoadingThreads,
    bool? isLoading,
    bool? isTemporary,
    bool? showTelemetry,
    String? error,
    bool clearError = false,
    String? currentlyPlayingMessageId,
    bool clearPlayingId = false,
    String? activeProjectId,
    bool clearActiveProject = false,
    String? activeProjectName,
    bool? showProjectDashboard,
    bool? showAllProjectsDashboard,
  }) {
    return ChatState(
      threadId: clearThreadId ? null : (threadId ?? this.threadId),
      messages: messages ?? this.messages,
      pastThreads: pastThreads ?? this.pastThreads,
      projects: projects ?? this.projects,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      isLoadingThreads: isLoadingThreads ?? this.isLoadingThreads,
      isLoading: isLoading ?? this.isLoading,
      isTemporary: isTemporary ?? this.isTemporary,
      showTelemetry: showTelemetry ?? this.showTelemetry,
      error: clearError ? null : (error ?? this.error),
      currentlyPlayingMessageId: clearPlayingId
          ? null
          : (currentlyPlayingMessageId ?? this.currentlyPlayingMessageId),
      activeProjectId:
          clearActiveProject ? null : (activeProjectId ?? this.activeProjectId),
      activeProjectName: clearActiveProject
          ? null
          : (activeProjectName ?? this.activeProjectName),
      showProjectDashboard: showProjectDashboard ?? this.showProjectDashboard,
      showAllProjectsDashboard:
          showAllProjectsDashboard ?? this.showAllProjectsDashboard,
    );
  }
}

final chatViewModelProvider =
    StateNotifierProvider<ChatViewModel, ChatState>((ref) {
  final repo = ref.watch(chatRepositoryProvider);
  final ttsRepo = ref.watch(ttsRepositoryProvider);
  return ChatViewModel(repo, ttsRepo);
});

final providerModelsProvider =
    FutureProvider<Map<String, List<String>>>((ref) async {
  final repo = ref.watch(chatRepositoryProvider);
  return await repo.getProviderModels();
});

class ChatViewModel extends StateNotifier<ChatState> {
  final ChatRepository _repository;
  final TTSRepository _ttsRepository;
  final AudioPlayer _audioPlayer = AudioPlayer();
  DateTime? _currentRequestStartTime;
  StreamSubscription<AuthState>? _authSubscription;

  ChatViewModel(this._repository, this._ttsRepository) : super(ChatState()) {
    _init();
    _audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        state = state.copyWith(clearPlayingId: true);
      }
    });

    // Listen to Auth State changes to reload threads if they failed initially
    // (e.g., due to an expired token on app startup that was just refreshed)
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
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTelemetry = prefs.getBool('show_telemetry') ?? false;

    // Force clear old tool_settings to ensure everyone defaults to false
    // for file_search_enabled. This avoids the stale 'true' state.
    await prefs.remove('tool_settings');

    state = state.copyWith(showTelemetry: savedTelemetry);
    await loadThreads();
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
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> loadThreads() async {
    state = state.copyWith(isLoadingThreads: true);
    try {
      final threads = await _repository.getThreads();
      final projects = await _repository.getProjects();
      state = state.copyWith(
          pastThreads: threads, projects: projects, isLoadingThreads: false);
    } catch (e, stack) {
      Sentry.captureException(e, stackTrace: stack);
      state = state.copyWith(isLoadingThreads: false);
    }
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

    String getProviderFromModel(String? m) {
      if (m == null || m.isEmpty) return 'unknown';
      m = m.toLowerCase();
      if (m.startsWith('gemini')) return 'google';
      if (m.startsWith('gpt') || m.startsWith('o1') || m.startsWith('o3'))
        return 'openai';
      if (m.startsWith('claude')) return 'anthropic';
      if (m.startsWith('mistral')) return 'mistral';
      if (m.startsWith('deepseek')) return 'deepseek';
      if (m.startsWith('llama') ||
          m.startsWith('qwen') ||
          m.startsWith('allam') ||
          m.startsWith('canopy') ||
          m.startsWith('groq') ||
          m.startsWith('meta')) return 'groq';
      return 'unknown';
    }

    final provider = getProviderFromModel(model);
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
      _updateLastMessage(
          content: "Error: ${event['error']}",
          isStreaming: false,
          isError: true);
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
            assignThreadToProject(newThreadId, state.activeProjectId);
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
    if (type == 'on_chat_model_stream') {
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
      final friendlyName = _friendlyToolLabel(toolName);
      final runId =
          event['run_id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
      final args = event['data']?['input'] ?? {};

      if (state.messages.isNotEmpty) {
        final last = state.messages.last;
        final newEvents = List<ToolEvent>.from(last.toolEvents);
        newEvents.add(ToolEvent(
          id: runId,
          name: toolName,
          args: args is Map ? Map<String, dynamic>.from(args) : {},
          isComplete: false,
        ));
        _updateLastMessage(
            activeTool: '$friendlyName...', toolEvents: newEvents);
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
      _updateLastMessage(
          isStreaming: false, activeTool: null, metrics: updatedMetrics);
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
      List<ToolEvent>? toolEvents,
      bool? isError,
      Map<String, dynamic>? metrics}) {
    if (state.messages.isEmpty) return;
    final msgs = List<ChatMessage>.from(state.messages);
    final last = msgs.last;

    msgs[msgs.length - 1] = ChatMessage(
      id: last.id,
      role: last.role,
      content: content ?? last.content,
      isStreaming: isStreaming ?? last.isStreaming,
      activeTool: activeTool, // This will clear it if activeTool is null
      toolEvents: toolEvents ?? last.toolEvents,
      isError: isError ?? last.isError,
      feedback: last.feedback,
      modelName: last.modelName,
      metrics: metrics ?? last.metrics,
    );
    state = state.copyWith(messages: msgs);
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

  /// Speaks [text] aloud.
  ///
  /// Uses GPT-SoVITS via backend if a custom voice is selected.
  /// Falls back to the browser's built-in Web Speech API otherwise.
  Future<void> playAudio(String text, {required String messageId}) async {
    try {
      final wasPlayingSameMessage =
          state.currentlyPlayingMessageId == messageId;

      // Check if we are already playing something via just_audio
      if (_audioPlayer.playing) {
        await _audioPlayer.stop();
      }

      if (WebSpeechService.instance.isSpeaking) {
        WebSpeechService.instance.stop();
      }

      // If neither was actually reporting as "playing" to the view model (e.g. mock test environments),
      // we still need to respect the toggle behavior conceptually if the IDs match
      if (wasPlayingSameMessage) {
        state = state.copyWith(clearPlayingId: true);
        return; // True toggle off
      }

      state = state.copyWith(currentlyPlayingMessageId: messageId);

      final storage = TTSSettingsStorage();
      final engine = await storage.getEngine() ?? 'Browser';
      String voiceId = await storage.getVoiceId() ?? 'default_system';
      final gptSovitsUrl =
          await storage.getGptSovitsUrl() ?? 'http://localhost:9880';

      if (engine == 'GPT-SoVITS') {
        if (voiceId == 'default_system') {
          // Auto-fix corrupted state if user never opened settings menu
          try {
            final voices =
                await _ttsRepository.getVoices(gptSovitsUrl: gptSovitsUrl);
            final customVoices =
                voices.where((v) => v['id'] != 'default_system').toList();
            if (customVoices.isNotEmpty) {
              voiceId = customVoices.first['id'] as String;
              await storage.saveVoiceId(voiceId);
            }
          } catch (e, stack) {
            Sentry.captureException(e, stackTrace: stack);
          }
        }

        // Use custom backend synthesis
        final audioBytes = await _ttsRepository.getAudioBytes(text, voiceId,
            gptSovitsUrl: gptSovitsUrl);
        await _audioPlayer.setAudioSource(BytesAudioSource(audioBytes));
        await _audioPlayer.play();
        state = state.copyWith(clearError: true);
        return;
      }

      // Fallback to Web Speech API
      if (!WebSpeechService.instance.isSupported) {
        state = state.copyWith(
            error: 'Text-to-speech is not supported in this browser.');
        return;
      }
      WebSpeechService.instance.speak(text);
      state = state.copyWith(clearError: true);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);

      // Try fallback if backend failed
      try {
        if (WebSpeechService.instance.isSupported) {
          WebSpeechService.instance.speak(text);
          state = state.copyWith(clearError: true);
        } else {
          state = state.copyWith(error: 'Failed to play audio: $e');
        }
      } catch (fallbackError) {
        state = state.copyWith(error: 'Failed to play audio: $e');
      }
    }
  }

  /// Stops any currently playing TTS audio.
  void stopAudio() {
    _audioPlayer.stop();
    WebSpeechService.instance.stop();
    state = state.copyWith(clearPlayingId: true);
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

  Future<void> assignThreadToProject(String threadId, String? projectId) async {
    try {
      await _repository.assignThreadToProject(threadId, projectId);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to assign project: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getProjects() async {
    try {
      return await _repository.getProjects();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      return [];
    }
  }

  Future<Map<String, dynamic>?> createProject(String name) async {
    try {
      final project = await _repository.createProject(name);
      await loadThreads();
      return project;
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to create project: $e');
      return null;
    }
  }

  Future<void> renameProject(String projectId, String newName) async {
    try {
      await _repository.renameProject(projectId, newName);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to rename project: $e');
    }
  }

  Future<void> deleteProject(String projectId) async {
    try {
      await _repository.deleteProject(projectId);
      if (state.activeProjectId == projectId) {
        state = state.copyWith(
          activeProjectId: null,
          threadId: null,
          messages: [],
        );
      }
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to delete project: $e');
    }
  }
}

// ignore: experimental_member_use
class BytesAudioSource extends StreamAudioSource {
  final List<int> bytes;
  BytesAudioSource(this.bytes);

  @override
  // ignore: experimental_member_use
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= bytes.length;
    // ignore: experimental_member_use
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(bytes.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}
