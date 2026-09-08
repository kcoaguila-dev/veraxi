import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';

class ChatHistoryState {
  final List<Map<String, dynamic>> pastThreads;
  final bool isLoadingHistory;
  final bool isLoadingThreads;
  final bool isTemporary;
  final String? error;

  ChatHistoryState({
    this.pastThreads = const [],
    this.isLoadingHistory = false,
    this.isLoadingThreads = false,
    this.isTemporary = false,
    this.error,
  });

  ChatHistoryState copyWith({
    List<Map<String, dynamic>>? pastThreads,
    bool? isLoadingHistory,
    bool? isLoadingThreads,
    bool? isTemporary,
    String? error,
    bool clearError = false,
  }) {
    return ChatHistoryState(
      pastThreads: pastThreads ?? this.pastThreads,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      isLoadingThreads: isLoadingThreads ?? this.isLoadingThreads,
      isTemporary: isTemporary ?? this.isTemporary,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ChatHistoryViewModel extends Notifier<ChatHistoryState> {
  StreamSubscription<AuthState>? _authSubscription;

  @override
  ChatHistoryState build() {
    _init();
    ref.onDispose(() => _authSubscription?.cancel());
    return ChatHistoryState();
  }

  void _init() {
    // Listen to Auth State changes to reload threads if they failed initially
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
    // Defer the initial load
    Future.microtask(() => loadThreads());
  }

  Future<void> loadThreads() async {
    state = state.copyWith(isLoadingThreads: true);
    try {
      final repo = ref.read(chatRepositoryProvider);
      final threads = await repo.getThreads();
      state = state.copyWith(pastThreads: threads, isLoadingThreads: false);
    } catch (e, stack) {
      Sentry.captureException(e, stackTrace: stack);
      state = state.copyWith(isLoadingThreads: false, error: e.toString());
    }
  }

  void toggleTemporaryChat() {
    state = state.copyWith(isTemporary: !state.isTemporary);
  }

  void applyThreadTitle(String threadId, String title) {
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

  Future<void> renameThread(String threadId, String newTitle) async {
    try {
      await ref.read(chatRepositoryProvider).renameThread(threadId, newTitle);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to rename chat: $e');
    }
  }

  Future<void> togglePinThread(String threadId) async {
    try {
      await ref.read(chatRepositoryProvider).togglePinThread(threadId);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to pin/unpin chat: $e');
    }
  }

  Future<void> toggleArchiveThread(String threadId) async {
    try {
      await ref.read(chatRepositoryProvider).toggleArchiveThread(threadId);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to archive/unarchive chat: $e');
    }
  }

  Future<void> deleteThread(String threadId) async {
    try {
      await ref.read(chatRepositoryProvider).deleteThread(threadId);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to delete chat: $e');
    }
  }

  Future<void> deleteAllChats() async {
    try {
      await ref.read(chatRepositoryProvider).deleteAllThreads();
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to delete all chats: $e');
    }
  }

  Future<String?> duplicateThread(String threadId) async {
    try {
      final newId = await ref.read(chatRepositoryProvider).duplicateThread(threadId);
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
      final shareId = await ref.read(chatRepositoryProvider).shareThread(threadId);
      return shareId;
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to share chat: $e');
      return null;
    }
  }

  Future<void> assignThreadToProject(String threadId, String? projectId) async {
    try {
      await ref.read(chatRepositoryProvider).assignThreadToProject(threadId, projectId);
      await loadThreads();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      state = state.copyWith(error: 'Failed to assign project: $e');
    }
  }
}

final chatHistoryProvider = NotifierProvider<ChatHistoryViewModel, ChatHistoryState>(
  () => ChatHistoryViewModel(),
);
