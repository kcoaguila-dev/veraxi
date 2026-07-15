import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/chat_repository.dart';
import '../data/chat_database.dart';

class ChatMessage {
  final String text;
  final bool isUser;

  ChatMessage({required this.text, required this.isUser});
}

class ChatState {
  final List<ChatMessage> messages;
  final bool isLoading;
  final String? error;

  ChatState({
    this.messages = const [],
    this.isLoading = false,
    this.error,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isLoading,
    String? error,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      error: error, // Can be null if not provided, intentional overwrite
    );
  }
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository();
});

class ChatViewModel extends StateNotifier<ChatState> {
  final ChatRepository _repository;
  final ChatDatabase _database;

  ChatViewModel(this._repository, this._database) : super(ChatState()) {
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final rows = await _database.getMessages();
    final messages = rows.map((row) => ChatMessage(
      text: row['text'],
      isUser: row['is_user'] == 1,
    )).toList();
    state = state.copyWith(messages: messages);
  }

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    state = state.copyWith(
      messages: [...state.messages, ChatMessage(text: text, isUser: true)],
      isLoading: true,
      error: null,
    );

    // Save user message
    await _database.saveMessage(text, true);

    try {
      final answer = await _repository.sendMessage(text);
      
      // Save AI message
      await _database.saveMessage(answer, false);
      
      state = state.copyWith(
        messages: [...state.messages, ChatMessage(text: answer, isUser: false)],
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  Future<void> clearChat() async {
    await _database.clearHistory();
    state = state.copyWith(messages: []);
  }

  void clearError() {
    state = state.copyWith(error: null);
  }
}

final chatViewModelProvider = StateNotifierProvider<ChatViewModel, ChatState>((ref) {
  final repository = ref.watch(chatRepositoryProvider);
  return ChatViewModel(repository, ChatDatabase.instance);
});
