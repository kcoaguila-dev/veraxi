import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/tts_settings_storage.dart';
import 'package:veraxi_app/core/web_speech_service.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';

class ChatMessage {
  final String? id;
  final String role; // 'user' or 'assistant'
  final String content;
  final bool isStreaming;
  final String? activeTool; // E.g. "Searching Neo4j..."
  final bool isError;
  final int feedback; // 1 (up), -1 (down), 0 (none)
  final String? modelName; // Store the AI model that generated this message

  ChatMessage({
    this.id,
    required this.role,
    required this.content,
    this.isStreaming = false,
    this.activeTool,
    this.isError = false,
    this.feedback = 0,
    this.modelName,
  });

  bool get isUser => role == 'user';
  String get text => content;

  ChatMessage copyWith(
      {String? id,
      String? content,
      bool? isStreaming,
      String? activeTool,
      bool? isError,
      int? feedback,
      String? modelName}) {
    return ChatMessage(
      id: id ?? this.id,
      role: role,
      content: content ?? this.content,
      isStreaming: isStreaming ?? this.isStreaming,
      activeTool: activeTool, // allow null to clear tool
      isError: isError ?? this.isError,
      feedback: feedback ?? this.feedback,
      modelName: modelName ?? this.modelName,
    );
  }
}

class ChatState {
  final String? threadId;
  final List<ChatMessage> messages;
  final List<Map<String, dynamic>> pastThreads;
  final bool isLoadingHistory;
  final bool isLoading;
  final bool isTemporary;
  final String? error;
  final String? currentlyPlayingMessageId;

  ChatState({
    this.threadId,
    this.messages = const [],
    this.pastThreads = const [],
    this.isLoadingHistory = false,
    this.isLoading = false,
    this.isTemporary = false,
    this.error,
    this.currentlyPlayingMessageId,
  });

  ChatState copyWith({
    String? threadId,
    List<ChatMessage>? messages,
    List<Map<String, dynamic>>? pastThreads,
    bool? isLoadingHistory,
    bool? isLoading,
    bool? isTemporary,
    String? error,
    bool clearError = false,
    String? currentlyPlayingMessageId,
    bool clearPlayingId = false,
  }) {
    return ChatState(
      threadId: threadId ?? this.threadId,
      messages: messages ?? this.messages,
      pastThreads: pastThreads ?? this.pastThreads,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      isLoading: isLoading ?? this.isLoading,
      isTemporary: isTemporary ?? this.isTemporary,
      error: clearError ? null : (error ?? this.error),
      currentlyPlayingMessageId: clearPlayingId ? null : (currentlyPlayingMessageId ?? this.currentlyPlayingMessageId),
    );
  }
}

final chatViewModelProvider =
    StateNotifierProvider<ChatViewModel, ChatState>((ref) {
  final repo = ref.watch(chatRepositoryProvider);
  return ChatViewModel(repo, ref);
});

class ChatViewModel extends StateNotifier<ChatState> {
  final ChatRepository _repository;
  final Ref _ref;
  final AudioPlayer _audioPlayer = AudioPlayer();

  ChatViewModel(this._repository, this._ref) : super(ChatState()) {
    loadThreads();
    _audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        state = state.copyWith(clearPlayingId: true);
      }
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
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
    state = state
        .copyWith(isLoadingHistory: true, threadId: threadId, messages: []);
    try {
      final history = await _repository.getThreadHistory(threadId);
      final messages = history
          .map((m) => ChatMessage(
                id: m['id'] as String?,
                role: m['role'] as String,
                content: m['content'] as String,
                feedback: m['feedback'] as int? ?? 0,
                modelName: m['model_name'] as String?,
              ))
          .toList();
      state = state.copyWith(messages: messages, isLoadingHistory: false);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(isLoadingHistory: false);
    }
  }

  void startNewChat() {
    state = state.copyWith(threadId: null, messages: []);
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

  Future<void> sendMessage(String text, {String? model}) async {
    if (text.trim().isEmpty) return;

    if (model == null || model == 'Select a model' || model.isEmpty) {
      final userMsg = ChatMessage(role: 'user', content: text);
      final errorMsg = ChatMessage(
        role: 'assistant',
        content:
            'No AI model selected. Please select a model from the top left menu.',
        isError: true,
      );
      state = state.copyWith(messages: [...state.messages, userMsg, errorMsg]);
      return;
    }

    final hasExpired = await ApiKeyStorage().isGeminiKeyExpired();
    if (hasExpired &&
        (model.startsWith('gemini') || model.startsWith('Google'))) {
      final expireDate = await ApiKeyStorage().getGeminiKeyExpirationDate();
      final userMsg = ChatMessage(role: 'user', content: text);
      final errorMsg = ChatMessage(
        role: 'assistant',
        content:
            'Provided key for google expired at $expireDate. Please provide a new key and try again.',
        isError: true,
      );
      state = state.copyWith(messages: [...state.messages, userMsg, errorMsg]);
      return;
    }

    final userMsg = ChatMessage(role: 'user', content: text);
    // Add user message and empty AI message
    state = state.copyWith(messages: [
      ...state.messages,
      userMsg,
      ChatMessage(
          role: 'assistant', content: '', isStreaming: true, modelName: model)
    ]);

    try {
      await for (final event in _repository.streamChat(text,
          threadId: state.threadId,
          isTemporary: state.isTemporary,
          model: model)) {
        _handleStreamEvent(event);
      }
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      final errorStr = e.toString();
      String uiError = "Error: Unable to complete request.";
      if (errorStr.contains("No AI model selected")) {
        uiError =
            "No AI model selected. Please select a model from the top left menu.";
      }
      _updateLastMessage(content: uiError, isStreaming: false, isError: true);
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
          msgs[msgs.length - 1] =
              last.copyWith(content: last.content + content);
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

  void _updateLastMessage(
      {String? content, bool? isStreaming, String? activeTool, bool? isError}) {
    if (state.messages.isEmpty) return;
    final msgs = List<ChatMessage>.from(state.messages);
    final last = msgs.last;

    msgs[msgs.length - 1] = ChatMessage(
      id: last.id,
      role: last.role,
      content: content ?? last.content,
      isStreaming: isStreaming ?? last.isStreaming,
      activeTool: activeTool, // This will clear it if activeTool is null
      isError: isError ?? last.isError,
      feedback: last.feedback,
      modelName: last.modelName,
    );
    state = state.copyWith(messages: msgs);
  }

  void clearError() {
    state = state.copyWith(clearError: true);
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
      final wasPlayingSameMessage = state.currentlyPlayingMessageId == messageId;

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
      final gptSovitsUrl = await storage.getGptSovitsUrl() ?? 'http://localhost:9880';

      if (engine == 'GPT-SoVITS') {
        if (voiceId == 'default_system') {
          // Auto-fix corrupted state if user never opened settings menu
          try {
            final voices = await _repository.getVoices(gptSovitsUrl: gptSovitsUrl);
            final customVoices = voices.where((v) => v['id'] != 'default_system').toList();
            if (customVoices.isNotEmpty) {
              voiceId = customVoices.first['id'] as String;
              await storage.saveVoiceId(voiceId);
            }
          } catch (e) {
            // Ignore fetch errors, let backend synthesis fail normally
          }
        }

        // Use custom backend synthesis
        final audioBytes = await _repository.getAudioBytes(text, voiceId, gptSovitsUrl: gptSovitsUrl);
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
}

class BytesAudioSource extends StreamAudioSource {
  final List<int> bytes;
  BytesAudioSource(this.bytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= bytes.length;
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(bytes.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}
