import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/chat/data/code_review_repository.dart';

// Re-export the models so views can import them from the ViewModel
// layer without violating the views → view_models → data contract.
export 'package:veraxi_app/features/chat/data/code_review_repository.dart'
    show CodeReviewDiff, CodeReviewDiffFile, CodeReviewHunk;

/// Load/action state for the Phase 5 Code review pane.
class CodeReviewLoadState {
  final CodeReviewDiff? diff;
  final bool isLoading;
  final String? error;

  /// Paths with an accept/revert request currently in flight.
  final Set<String> busyPaths;
  final bool isCommitting;

  /// Set after a successful commit so the pane can confirm it.
  final String? committedMessage;

  const CodeReviewLoadState({
    this.diff,
    this.isLoading = false,
    this.error,
    this.busyPaths = const {},
    this.isCommitting = false,
    this.committedMessage,
  });

  CodeReviewLoadState copyWith({
    CodeReviewDiff? diff,
    bool? isLoading,
    String? error,
    bool clearError = false,
    Set<String>? busyPaths,
    bool? isCommitting,
    String? committedMessage,
  }) {
    return CodeReviewLoadState(
      diff: diff ?? this.diff,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      busyPaths: busyPaths ?? this.busyPaths,
      isCommitting: isCommitting ?? this.isCommitting,
      committedMessage: committedMessage ?? this.committedMessage,
    );
  }
}

/// Drives the review pane: loads the session diff through
/// [CodeReviewRepository] and refreshes it after every accept /
/// revert so the pane always shows the server's current diff.
class CodeReviewNotifier extends StateNotifier<CodeReviewLoadState> {
  CodeReviewNotifier(this._repository) : super(const CodeReviewLoadState());

  final CodeReviewRepository _repository;
  String _sessionId = '';
  String _turnId = '';

  Future<void> load(String sessionId, {String turnId = ''}) async {
    if (sessionId.isEmpty) return;
    _sessionId = sessionId;
    _turnId = turnId;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final diff = await _repository.fetchDiff(sessionId, turnId: turnId);
      if (!mounted) return;
      state = state.copyWith(diff: diff, isLoading: false);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      if (!mounted) return;
      state = state.copyWith(isLoading: false, error: 'Failed to load diff');
    }
  }

  Future<void> _refresh() async {
    if (_sessionId.isEmpty) return;
    try {
      final diff = await _repository.fetchDiff(_sessionId, turnId: _turnId);
      if (!mounted) return;
      state = state.copyWith(diff: diff, clearError: true);
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      if (!mounted) return;
      state = state.copyWith(error: 'Failed to refresh diff');
    }
  }

  Future<void> acceptFile(String path) => _actOnFile(path, accept: true);

  Future<void> revertFile(String path) => _actOnFile(path, accept: false);

  Future<void> _actOnFile(String path, {required bool accept}) async {
    if (_sessionId.isEmpty || state.busyPaths.contains(path)) return;
    state = state.copyWith(busyPaths: {...state.busyPaths, path});
    try {
      if (accept) {
        await _repository.acceptFiles(_sessionId, [path]);
      } else {
        await _repository.revertFiles(_sessionId, [path]);
      }
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      if (!mounted) return;
      state = state.copyWith(
        busyPaths: {...state.busyPaths}..remove(path),
        error: accept ? 'Failed to accept $path' : 'Failed to revert $path',
      );
      return;
    }
    if (!mounted) return;
    state = state.copyWith(busyPaths: {...state.busyPaths}..remove(path));
    await _refresh();
  }

  /// Commits staged files with [message]; returns true on success.
  Future<bool> commit(String message) async {
    if (_sessionId.isEmpty || message.trim().isEmpty) return false;
    state = state.copyWith(isCommitting: true, clearError: true);
    try {
      await _repository.commit(_sessionId, message.trim());
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      if (!mounted) return false;
      state = state.copyWith(isCommitting: false, error: 'Commit failed');
      return false;
    }
    if (!mounted) return true;
    state = state.copyWith(isCommitting: false, committedMessage: message.trim());
    await _refresh();
    return true;
  }
}

final codeReviewProvider =
    StateNotifierProvider.autoDispose<CodeReviewNotifier, CodeReviewLoadState>(
        (ref) {
  final repository = ref.watch(codeReviewRepositoryProvider);
  return CodeReviewNotifier(repository);
});
