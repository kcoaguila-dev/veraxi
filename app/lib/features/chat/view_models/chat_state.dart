import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/view_models/model_download_provider.dart';

class ToolEvent {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  final dynamic result;
  final bool isComplete;
  final int? durationMs;
  final String? summary;

  ToolEvent({
    required this.id,
    required this.name,
    this.args = const {},
    this.result,
    this.isComplete = false,
    this.durationMs,
    this.summary,
  });

  ToolEvent copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? args,
    dynamic result,
    bool? isComplete,
    int? durationMs,
    String? summary,
  }) {
    return ToolEvent(
      id: id ?? this.id,
      name: name ?? this.name,
      args: args ?? this.args,
      result: result ?? this.result,
      isComplete: isComplete ?? this.isComplete,
      durationMs: durationMs ?? this.durationMs,
      summary: summary ?? this.summary,
    );
  }
}

class ChatMessage {
  final String? id;
  final String role; // 'user' or 'assistant'
  final String content;
  final bool isStreaming;
  final String? activeTool; // E.g. "Step 1: Searching Neo4j..."
  final String? reasoning; // Collapsible chain of thought / reasoning trace
  final double? reasoningDurationSeconds; // E.g. "Thought for 4.2s"
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
    this.reasoning,
    this.reasoningDurationSeconds,
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
      String? reasoning,
      double? reasoningDurationSeconds,
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
      reasoning: reasoning ?? this.reasoning,
      reasoningDurationSeconds:
          reasoningDurationSeconds ?? this.reasoningDurationSeconds,
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

final providerModelsProvider = Provider<Map<String, List<String>>>((ref) {
  final localModelsAsync = ref.watch(localGgufModelsProvider);
  final localModels = localModelsAsync.valueOrNull ?? [];

  return {
    'openai': [
      'gpt-5.5',
      'gpt-5.5-pro',
      'gpt-5.4',
      'gpt-5.4-pro',
      'gpt-5.4-mini',
      'gpt-5.4-nano',
      'gpt-5.3-codex',
      'gpt-5.2',
      'gpt-5.2-chat',
      'gpt-5.2-pro',
      'gpt-5.1',
      'gpt-5.1-chat-latest',
      'gpt-5',
      'gpt-5-chat-latest',
      'gpt-5-mini',
      'o3-mini',
      'o1-pro',
      'o1',
      'o1-mini',
      'o1-preview',
      'gpt-4o',
      'gpt-4o-mini',
      'gpt-4-turbo',
      'gpt-4-turbo-preview',
      'gpt-4-0125-preview',
      'gpt-4-1106-preview',
      'gpt-4-1106-vision-preview',
      'gpt-4',
      'gpt-4-0613',
      'gpt-4-0314',
      'gpt-4-32k',
      'gpt-4-32k-0314',
      'gpt-3.5-turbo',
      'gpt-3.5-turbo-0125',
      'gpt-3.5-turbo-1106',
      'gpt-3.5-turbo-0613',
      'gpt-3.5-turbo-16k',
      'gpt-3.5-turbo-16k-0613',
      'gpt-3.5-0301',
      'gpt-3.5-turbo-instruct',
      'davinci-002',
      'babbage-002'
    ],
    'anthropic': [
      'claude-fable-5',
      'claude-opus-5',
      'claude-opus-4-8',
      'claude-opus-4-7',
      'claude-sonnet-5',
      'claude-sonnet-4-6',
      'claude-opus-4-6',
      'claude-opus-4-20250514',
      'claude-3-7-sonnet-20250219',
      'claude-3-5-sonnet-latest',
      'claude-3-5-sonnet-20241022',
      'claude-3-5-haiku-latest',
      'claude-3-5-haiku-20241022',
      'claude-3-opus-20240229',
      'claude-3-sonnet-20240229',
      'claude-3-haiku-20240307'
    ],
    'deepseek': [
      'deepseek-chat',
      'deepseek-coder',
      'deepseek-reasoner',
      'deepseek-r1'
    ],
    'kimi': [
      'moonshot-v1-8k',
      'moonshot-v1-32k',
      'moonshot-v1-128k',
      'moonshot-v1-auto'
    ],
    'google': [
      'gemini-3.6-flash',
      'gemini-3.5-flash',
      'gemini-3.5-flash-lite',
      'gemini-3.1-pro-preview',
      'gemini-3.1-pro-preview-customtools',
      'gemini-3.1-flash-lite-preview',
      'gemini-3-pro-preview',
      'gemini-3-flash-preview',
      'gemini-2.5-pro',
      'gemini-2.5-flash',
      'gemini-2.5-flash-lite'
    ],
    'mistral': [
      'codestral-2405',
      'codestral-2411-rc5',
      'codestral-2412',
      'codestral-2501',
      'codestral-latest',
      'codestral-mamba-2407',
      'codestral-mamba-latest',
      'devstral-small-2505',
      'devstral-small-latest',
      'ministral-3b-2410',
      'ministral-3b-latest',
      'ministral-8b-2410',
      'ministral-8b-latest',
      'mistral-embed',
      'mistral-large-2402',
      'mistral-large-2407',
      'mistral-large-latest',
      'mistral-medium',
      'mistral-medium-2312',
      'mistral-medium-latest',
      'mistral-small',
      'mistral-small-2312',
      'mistral-small-2402',
      'mistral-small-2409',
      'mistral-small-latest',
      'mistral-tiny',
      'pixtral-12b-2409',
      'pixtral-12b-latest',
      'pixtral-large-2411',
      'pixtral-large-latest'
    ],
    'groq': [
      'allam-2-7b',
      'canopylabs/orpheus-arabic-saudi',
      'canopylabs/orpheus-v1-english',
      'groq/compound',
      'groq/compound-mini',
      'llama-3.1-8b-instant',
      'llama-3.3-70b-versatile',
      'meta-llama/llama-prompt-guard-2-22m',
      'meta-llama/llama-prompt-guard-2-86m',
      'openai/gpt-oss-120b',
      'qwen/qwen3.6-27b'
    ],
    'local': localModels,
  };
});
