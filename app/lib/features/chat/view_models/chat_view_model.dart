import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/chat_repository.dart';

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

  ChatViewModel(this._repository) : super(ChatState());

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    // Add user message and set loading
    state = state.copyWith(
      messages: [...state.messages, ChatMessage(text: text, isUser: true)],
      isLoading: true,
      error: null,
    );

    try {
      final answer = await _repository.sendMessage(text);
      // Add bot message and clear loading
      state = state.copyWith(
        messages: [...state.messages, ChatMessage(text: answer, isUser: false)],
        isLoading: false,
      );
    } catch (e) {
      // Set error and clear loading
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }
}

final chatViewModelProvider = StateNotifierProvider<ChatViewModel, ChatState>((ref) {
  final repository = ref.watch(chatRepositoryProvider);
  return ChatViewModel(repository);
});
