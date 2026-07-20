import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/network/api_client.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';

class ChatMessage {
  final String role; // 'user' or 'assistant'
  final String content;
  final bool isStreaming;
  final String? activeTool; // E.g. "Searching Neo4j..."

  ChatMessage({
    required this.role,
    required this.content,
    this.isStreaming = false,
    this.activeTool,
  });

  bool get isUser => role == 'user';
  String get text => content;

  ChatMessage copyWith({String? content, bool? isStreaming, String? activeTool}) {
    return ChatMessage(
      role: role,
      content: content ?? this.content,
      isStreaming: isStreaming ?? this.isStreaming,
      activeTool: activeTool, // allow null to clear tool
    );
  }
}

class ChatState {
  final String? threadId;
  final List<ChatMessage> messages;
  final List<String> pastThreads;
  final bool isLoadingHistory;
  final bool isLoading;
  final String? error;

  ChatState({
    this.threadId,
    this.messages = const [],
    this.pastThreads = const [],
    this.isLoadingHistory = false,
    this.isLoading = false,
    this.error,
  });

  ChatState copyWith({
    String? threadId,
    List<ChatMessage>? messages,
    List<String>? pastThreads,
    bool? isLoadingHistory,
    bool? isLoading,
    String? error,
  }) {
    return ChatState(
      threadId: threadId ?? this.threadId,
      messages: messages ?? this.messages,
      pastThreads: pastThreads ?? this.pastThreads,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
    );
  }
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return ChatRepository(apiClient: apiClient);
});

final chatViewModelProvider = StateNotifierProvider<ChatViewModel, ChatState>((ref) {
  final repo = ref.watch(chatRepositoryProvider);
  return ChatViewModel(repo);
});

class ChatViewModel extends StateNotifier<ChatState> {
  final ChatRepository _repository;

  ChatViewModel(this._repository) : super(ChatState()) {
    loadThreads();
  }

  Future<void> loadThreads() async {
    try {
      final threads = await _repository.getThreads();
      state = state.copyWith(pastThreads: threads);
    } catch (e) {
      // Non-fatal, just log
    }
  }

  Future<void> selectThread(String threadId) async {
    state = state.copyWith(isLoadingHistory: true, threadId: threadId, messages: []);
    try {
      final history = await _repository.getThreadHistory(threadId);
      final messages = history.map((m) => ChatMessage(
        role: m['role'] as String,
        content: m['content'] as String,
      )).toList();
      state = state.copyWith(messages: messages, isLoadingHistory: false);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(isLoadingHistory: false);
    }
  }

  void startNewChat() {
    state = state.copyWith(threadId: null, messages: []);
  }

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    final userMsg = ChatMessage(role: 'user', content: text);
    // Add user message and empty AI message
    state = state.copyWith(messages: [...state.messages, userMsg, ChatMessage(role: 'assistant', content: '', isStreaming: true)]);
    
    try {
      await for (final event in _repository.streamChat(text, threadId: state.threadId)) {
        _handleStreamEvent(event);
      }
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      _updateLastMessage(content: "Error: Unable to complete request.", isStreaming: false);
    }
  }

  void _handleStreamEvent(Map<String, dynamic> event) {
    final type = event['event']; // astream_events v2 provides 'event'
    if (type == 'on_chat_model_stream') {
      final chunk = event['data']?['chunk'];
      if (chunk != null) {
        final content = chunk['content'];
        if (content != null && content is String) {
          final msgs = List<ChatMessage>.from(state.messages);
          final last = msgs.last;
          msgs[msgs.length - 1] = last.copyWith(content: last.content + content);
          state = state.copyWith(messages: msgs);
        }
      }
    } else if (type == 'on_tool_start') {
      final toolName = event['name'];
      _updateLastMessage(activeTool: 'Calling $toolName...');
    } else if (type == 'on_tool_end') {
      _updateLastMessage(activeTool: null); // Clear tool indicator
    } else if (type == 'on_chain_end' && event['name'] == 'LangGraph') {
      // Graph finished
      _updateLastMessage(isStreaming: false, activeTool: null);
      
      // If this was a new chat, we need to extract the thread ID from somewhere, or reload threads
      loadThreads();
    }
  }

  void _updateLastMessage({String? content, bool? isStreaming, String? activeTool}) {
    if (state.messages.isEmpty) return;
    final msgs = List<ChatMessage>.from(state.messages);
    final last = msgs.last;
    
    // Explicit null check required for activeTool because we want to be able to set it to null
    // To cleanly do this, we re-create the object if activeTool is explicitly provided, otherwise we use copyWith
    msgs[msgs.length - 1] = ChatMessage(
      role: last.role,
      content: content ?? last.content,
      isStreaming: isStreaming ?? last.isStreaming,
      activeTool: activeTool, // This will clear it if activeTool is null
    );
    
    state = state.copyWith(messages: msgs);
  }
}
