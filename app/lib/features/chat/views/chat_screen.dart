import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/sidebar_provider.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/code_workbench_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'package:veraxi_app/features/chat/view_models/auto_compact.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/token_usage.dart';
import 'package:veraxi_app/features/chat/views/widgets/token_usage_ring.dart';
import 'package:veraxi_app/features/chat/views/widgets/compaction_sheet.dart';
import 'package:veraxi_app/features/chat/views/widgets/acp_permission_banner.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_empty_state.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_sidebar.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_list_item.dart';
import 'package:veraxi_app/features/chat/views/widgets/project_dashboard_view.dart';
import 'package:veraxi_app/features/chat/views/widgets/all_projects_dashboard_view.dart';
import 'package:veraxi_app/core/models/model_thinking_capability.dart';
import 'package:veraxi_app/core/providers/model_selection_provider.dart';
import 'package:veraxi_app/core/providers/thinking_level_provider.dart';
import 'package:veraxi_app/core/widgets/model_selector_menu.dart';
import 'package:veraxi_app/core/widgets/provider_icon.dart';
import 'package:veraxi_app/core/widgets/thinking_level_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/features/chat/view_models/audio_player_service.dart';

import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/core/widgets/veraxi_switch.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_sidebar.dart';
import 'package:veraxi_app/core/widgets/profile_menu_button.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_artifact_panel.dart';
import 'package:veraxi_app/features/chat/view_models/sandbox_drawer_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/sandbox_toggle_view_model.dart';
import 'package:veraxi_app/core/providers/active_sources_provider.dart';
import 'package:veraxi_app/features/chat/views/widgets/sandbox_drawer.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_review_drawer.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  static const _scrollThreadIdKey = 'last_active_thread_scroll_thread_id';
  static const _scrollOffsetKey = 'last_active_thread_scroll_offset';
  static const _scrollAtBottomKey = 'last_active_thread_scroll_at_bottom';

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final ScrollController _scrollController = ScrollController();

  String _selectedModel = 'Select a model';
  final Set<String> _pinnedModels = {};
  bool _isScrolledUp = false;
  bool _pendingHistoryScrollRestore = false;
  bool _historyScrollRestoreScheduled = false;
  String? _savedScrollThreadId;
  double? _savedScrollOffset;
  bool _savedScrollAtBottom = true;
  double? _lastPersistedPixels;
  bool? _lastPersistedAtBottom;

  /// Artifacts the panel has already auto-opened (or the user manually
  /// closed): auto-open fires at most once per artifact occurrence.
  final Set<String> _autoOpenSuppressedKeys = {};

  void _onScroll() {
    if (!_scrollController.hasClients || _pendingHistoryScrollRestore) return;
    final position = _scrollController.position;
    _syncScrolledUp(position);
    _persistScrollPosition(position);
  }

  void _persistScrollPosition(ScrollMetrics metrics) {
    if (_pendingHistoryScrollRestore) return;
    final threadId = ref.read(chatViewModelProvider).threadId;
    if (threadId == null || threadId.isEmpty) return;

    final atBottom = (metrics.maxScrollExtent - metrics.pixels) <= 24.0;
    _savedScrollThreadId = threadId;
    _savedScrollOffset = metrics.pixels;
    _savedScrollAtBottom = atBottom;

    final movedEnough = _lastPersistedPixels == null ||
        (metrics.pixels - _lastPersistedPixels!).abs() >= 16.0;
    if (!movedEnough && _lastPersistedAtBottom == atBottom) return;

    _lastPersistedPixels = metrics.pixels;
    _lastPersistedAtBottom = atBottom;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_scrollThreadIdKey, threadId);
      prefs.setDouble(_scrollOffsetKey, metrics.pixels);
      prefs.setBool(_scrollAtBottomKey, atBottom);
    });
  }

  void _clearSavedScrollPosition() {
    _savedScrollThreadId = null;
    _savedScrollOffset = null;
    _savedScrollAtBottom = true;
    _lastPersistedPixels = null;
    _lastPersistedAtBottom = null;
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove(_scrollThreadIdKey);
      prefs.remove(_scrollOffsetKey);
      prefs.remove(_scrollAtBottomKey);
    });
  }

  bool _isMetricsScrolledUp(ScrollMetrics metrics) =>
      metrics.maxScrollExtent > 0 &&
      (metrics.maxScrollExtent - metrics.pixels) > 400;

  /// Per-thread Ask-mode gate (re-arms after a "Not now" only when
  /// the context grows meaningfully) + re-entry guard for Auto runs.
  final AutoCompactGate _autoCompactGate = AutoCompactGate();
  bool _autoCompactBusy = false;

  void _openCompaction(BuildContext context, ChatViewModel viewModel) {
    showCompactionSheet(
      context,
      onPreview: () => viewModel.previewCompaction(
          model: _selectedModel == 'Select a model' ? null : _selectedModel),
      onApply: (summary) => viewModel.applyCompaction(
          summary: summary,
          model: _selectedModel == 'Select a model' ? null : _selectedModel),
      onClearToolResults: () => viewModel.clearOldToolResults(
          model: _selectedModel == 'Select a model' ? null : _selectedModel),
    );
  }

  /// Turn-end auto-compact check: runs when a response finishes,
  /// never mid-generation. Ask mode prompts and opens the same
  /// review sheet as manual compaction; Auto mode runs the same
  /// fail-closed pipeline unattended (Stage 0 pruning first) and
  /// always leaves a notice. Failures change nothing.
  Future<void> _maybeAutoCompact(ChatViewModel viewModel) async {
    if (_autoCompactBusy || !mounted) return;
    final mode = viewModel.autoCompactMode;
    if (mode == AutoCompactMode.off) return;
    final state = ref.read(chatViewModelProvider);
    if (state.isLoading || state.threadId == null) return;
    final summary = summarizeTokenUsage(state.messages);
    if (summary == null || !_autoCompactGate.shouldFire(summary)) return;
    if (mode == AutoCompactMode.ask) {
      await _askAutoCompact(viewModel, summary);
    } else {
      await _runAutoCompact(viewModel, summary, state.threadId!);
    }
  }

  Future<void> _askAutoCompact(
      ChatViewModel viewModel, TokenUsageSummary summary) async {
    final fraction = summary.contextFraction;
    final title = fraction != null
        ? 'Context is ${(fraction * 100).round()}% full'
        : 'This conversation is getting long';
    final body = fraction != null
        ? 'Compacting summarizes earlier messages to free context. '
            'Nothing changes until you review and approve the summary.'
        : 'About ${formatTokenCountFull(summary.contextTokens ?? 0)} tokens '
            'so far (estimated). Compacting summarizes earlier messages '
            'to free context — nothing changes until you review and '
            'approve the summary.';
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('off'),
            child: const Text('Turn off'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('skip'),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('review'),
            child: const Text('Review & compact'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'review':
        _openCompaction(context, viewModel);
      case 'off':
        await viewModel.setAutoCompactMode(AutoCompactMode.off);
        _showAutoCompactNotice(
            'Auto-compact is off. You can turn it back on from the token usage sheet.');
      default:
        // 'skip' or a dismissed dialog: don't ask again until the
        // context grows past the re-arm delta.
        _autoCompactGate.skip(summary);
    }
  }

  void _setAutoCompactBusy(bool busy) {
    if (!mounted) {
      _autoCompactBusy = busy;
      return;
    }
    setState(() {
      _autoCompactBusy = busy;
    });
  }

  bool _canContinueAutoCompact(String targetThreadId) {
    if (!mounted) return false;
    final current = ref.read(chatViewModelProvider);
    return current.threadId == targetThreadId && !current.isLoading;
  }

  TokenUsageSummary? _postStage0Summary(
      TokenUsageSummary prior, Map<String, dynamic>? stage0Result) {
    final postTokens = stage0Result?['tokens_after_estimate'];
    if (postTokens is int) {
      return TokenUsageSummary(
        contextTokens: postTokens,
        contextWindowTokens: prior.contextWindowTokens,
        lastPromptTokens: postTokens,
        lastCompletionTokens: prior.lastCompletionTokens,
        lastTotalTokens: prior.lastTotalTokens,
        lastEstimatedCostUsd: prior.lastEstimatedCostUsd,
        sessionPromptTokens: prior.sessionPromptTokens,
        sessionCompletionTokens: prior.sessionCompletionTokens,
        sessionTotalTokens: prior.sessionTotalTokens,
        sessionEstimatedCostUsd: prior.sessionEstimatedCostUsd,
        hasSessionCost: prior.hasSessionCost,
        responseCount: prior.responseCount,
        isEstimated: prior.isEstimated,
      );
    }
    return summarizeTokenUsage(ref.read(chatViewModelProvider).messages);
  }

  Future<Map<String, dynamic>?> _tryStage0Clear(
      ChatViewModel viewModel, String targetThreadId, String? model) async {
    try {
      return await viewModel.clearOldToolResults(
          threadId: targetThreadId, model: model);
    } catch (_) {
      // Stage 0 is best-effort; summarisation below is the gate.
      return null;
    }
  }

  Future<void> _runAutoCompact(ChatViewModel viewModel,
      TokenUsageSummary summary, String targetThreadId) async {
    _setAutoCompactBusy(true);
    final model = _selectedModel == 'Select a model' ? null : _selectedModel;
    var stage0Cleared = false;
    try {
      // Stage 0 first: clearing old tool results is deterministic
      // and may free enough on its own — summarise only if not.
      final stage0Result =
          await _tryStage0Clear(viewModel, targetThreadId, model);
      stage0Cleared = stage0Result != null;
      if (!_canContinueAutoCompact(targetThreadId)) return;
      final afterStage0 = _postStage0Summary(summary, stage0Result);
      if (afterStage0 != null && !autoCompactDue(afterStage0)) {
        _autoCompactGate.reset();
        _showAutoCompactNotice(
            'Freed context by clearing old tool results — no summary needed.');
        return;
      }
      final preview = await viewModel.previewCompaction(
          threadId: targetThreadId, model: model);
      if (!_canContinueAutoCompact(targetThreadId)) return;
      await viewModel.applyCompaction(
          threadId: targetThreadId,
          summary: preview['summary'] as String,
          model: model);
      _autoCompactGate.reset();
      final before = formatTokenCountFull(summary.contextTokens ?? 0);
      final afterTokens = preview['tokens_after_estimate'];
      final after =
          afterTokens is int ? formatTokenCountFull(afterTokens) : 'less';
      _showAutoCompactNotice(
          'Conversation compacted automatically (~$before → ~$after tokens). '
          'Tap the divider in the chat to read the summary.');
    } catch (_) {
      // Report Stage 0 accurately if tool results were cleared before failure.
      _showAutoCompactNotice(
        stage0Cleared
            ? 'Cleared old tool results to free context; full summary was skipped.'
            : 'Auto-compact could not run — your context is unchanged.',
      );
    } finally {
      _setAutoCompactBusy(false);
    }
  }

  void _showAutoCompactNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  void _syncScrolledUp(ScrollMetrics metrics) {
    if (_pendingHistoryScrollRestore) return;
    final isUp = _isMetricsScrolledUp(metrics);
    if (isUp == _isScrolledUp) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_scrollController.hasClients ||
            _pendingHistoryScrollRestore) {
          return;
        }
        final currentUp = _isMetricsScrolledUp(_scrollController.position);
        if (currentUp != _isScrolledUp) {
          setState(() {
            _isScrolledUp = currentUp;
          });
        }
      });
    } else {
      setState(() {
        _isScrolledUp = isUp;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _pendingHistoryScrollRestore =
        ref.read(chatViewModelProvider).isLoadingHistory;
    _scrollController.addListener(_onScroll);
    _loadSavedModel();
  }

  Future<void> _loadSavedModel() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted && _lastPersistedPixels == null) {
      _savedScrollThreadId = prefs.getString(_scrollThreadIdKey);
      _savedScrollOffset = prefs.getDouble(_scrollOffsetKey);
      _savedScrollAtBottom = prefs.getBool(_scrollAtBottomKey) ?? true;
    }
    final savedModel = prefs.getString('selected_model');
    final availableModels = ref
        .read(providerModelsProvider)
        .values
        .expand((models) => models)
        .toSet();
    if (savedModel != null && availableModels.contains(savedModel) && mounted) {
      setState(() {
        _selectedModel = savedModel;
      });
    } else if (savedModel != null) {
      await prefs.remove('selected_model');
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// Closes the artifact panel, remembering the artifact so auto-open
  /// does not immediately reopen what the user just closed.
  void _closeArtifactPanel() {
    final open = ref.read(openCodeArtifactProvider);
    if (open != null) {
      _autoOpenSuppressedKeys.add(autoOpenArtifactKey(open));
    }
    ref.read(openCodeArtifactProvider.notifier).state = null;
    ref.read(artifactPanelExpandedProvider.notifier).state = false;
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  bool _applyRestoredScrollJump(String? threadId) {
    final position = _scrollController.position;
    final maxExtent = position.maxScrollExtent;
    final hasSavedOffset = threadId != null &&
        threadId == _savedScrollThreadId &&
        !_savedScrollAtBottom &&
        _savedScrollOffset != null;
    final target =
        hasSavedOffset ? _savedScrollOffset!.clamp(0.0, maxExtent) : maxExtent;
    if ((position.pixels - target).abs() <= 0.5) return false;
    _scrollController.jumpTo(target);
    return true;
  }

  void _scheduleHistoryScrollRestore(String? threadId) {
    if (_historyScrollRestoreScheduled) return;
    _historyScrollRestoreScheduled = true;
    _settleHistoryScroll(threadId, remainingPasses: 4);
  }

  void _settleHistoryScroll(String? threadId, {required int remainingPasses}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        setState(() {
          _pendingHistoryScrollRestore = false;
          _historyScrollRestoreScheduled = false;
        });
        return;
      }
      final moved = _applyRestoredScrollJump(threadId);
      if (moved && remainingPasses > 1) {
        SchedulerBinding.instance.ensureVisualUpdate();
        _settleHistoryScroll(threadId, remainingPasses: remainingPasses - 1);
        return;
      }
      setState(() {
        _isScrolledUp = _isMetricsScrolledUp(_scrollController.position);
        _pendingHistoryScrollRestore = false;
        _historyScrollRestoreScheduled = false;
      });
      _persistScrollPosition(_scrollController.position);
    });
  }

  bool _shouldAutoScrollOnMessagesChange(
      List<ChatMessage>? previous, List<ChatMessage> next) {
    if (previous == null || previous.isEmpty) {
      return next.last.isStreaming;
    }
    return next.last.isStreaming ||
        previous.last.isStreaming ||
        next.length > previous.length;
  }

  Widget build(BuildContext context) {
    final state = ref.watch(chatViewModelProvider);
    final isSidebarOpen = ref.watch(sidebarStateProvider);
    final openArtifact = ref.watch(openCodeArtifactProvider);
    final sandboxEnabled = ref.watch(sandboxToggleViewModelProvider).enabled;
    final panelExpanded = ref.watch(artifactPanelExpandedProvider);
    final viewModel = ref.read(chatViewModelProvider.notifier);
    final usageSummary = summarizeTokenUsage(state.messages);
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    final allProviderModels = ref.watch(providerModelsProvider);

    String? currentProvider;
    if (_selectedModel != 'Select a model') {
      for (final entry in allProviderModels.entries) {
        if (entry.value.contains(_selectedModel)) {
          currentProvider = entry.key;
          break;
        }
      }
    }

    ref.listen<String?>(
      chatViewModelProvider.select((s) => s.threadId),
      (previous, next) {
        if (previous != next) {
          _autoCompactGate.reset();
          if (_isScrolledUp) {
            setState(() {
              _isScrolledUp = false;
            });
          }
          if (next == null ||
              (previous != null && previous != next) ||
              (_savedScrollThreadId != null && next != _savedScrollThreadId)) {
            _clearSavedScrollPosition();
          }
        }
      },
    );

    ref.listen<(bool, bool)>(
      chatViewModelProvider
          .select((s) => (s.isLoadingHistory, s.messages.isEmpty)),
      (previous, next) {
        final (isLoadingHistory, isEmpty) = next;
        if (isLoadingHistory) {
          _pendingHistoryScrollRestore = true;
          _historyScrollRestoreScheduled = false;
        } else if (isEmpty) {
          _pendingHistoryScrollRestore = false;
          _historyScrollRestoreScheduled = false;
        }
      },
    );

    // Auto-compact is evaluated only at a turn boundary: when a
    // response finishes generating, never mid-stream.
    ref.listen<bool>(
      chatViewModelProvider.select((s) => s.isLoading),
      (previous, next) {
        if (previous == true && next == false) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _maybeAutoCompact(viewModel);
          });
        }
      },
    );

    ref.listen<List<ChatMessage>>(
      chatViewModelProvider.select((s) => s.messages),
      (previous, next) {
        if (next.isEmpty && _isScrolledUp) {
          setState(() {
            _isScrolledUp = false;
          });
        }
        // Feed sandbox tool events into the Terminal & Diff drawer.
        // ChatViewModel's SSE handler is private and message-bound, so
        // the drawer is fed from chat state here (its view model
        // de-duplicates by tool-event id); raw sandbox_stdout /
        // sandbox_stderr / approval_required SSE events can later be
        // bridged through SandboxDrawerViewModel.handleSandboxEvent.
        if (next.isNotEmpty) {
          ref
              .read(sandboxDrawerViewModelProvider.notifier)
              .ingestToolEvents(next.last.toolEvents);
        }
        // An open code panel belongs to the previous conversation; close
        // it when the chat is emptied (new chat / thread switch to empty).
        if (next.isEmpty && ref.read(openCodeArtifactProvider) != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ref.read(openCodeArtifactProvider.notifier).state = null;
            }
          });
        }
        // Claude-style: a newly generated previewable artifact (slides,
        // HTML, SVG, Mermaid, …) opens the panel on its own, once per
        // artifact — a manual close is recorded in the suppressed set
        // by _closeArtifactPanel and never overridden.
        if (previous != null && ref.read(openCodeArtifactProvider) == null) {
          final candidate = findNewPreviewableArtifact(
            previous: previous,
            next: next,
            threadId: ref.read(chatViewModelProvider).threadId,
            suppressedKeys: _autoOpenSuppressedKeys,
          );
          if (candidate != null) {
            _autoOpenSuppressedKeys.add(autoOpenArtifactKey(candidate));
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && ref.read(openCodeArtifactProvider) == null) {
                ref.read(openCodeArtifactProvider.notifier).state = candidate;
              }
            });
          }
        }
        if (!_pendingHistoryScrollRestore &&
            !_isScrolledUp &&
            next.isNotEmpty &&
            _shouldAutoScrollOnMessagesChange(previous, next)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_isScrolledUp && !_pendingHistoryScrollRestore) {
              _scrollToBottom(animate: false);
            }
          });
        }
      },
    );

    if (_pendingHistoryScrollRestore &&
        !state.isLoadingHistory &&
        state.messages.isNotEmpty) {
      _scheduleHistoryScrollRestore(state.threadId);
    }

    ref.listen(audioPlayerServiceProvider, (previous, next) {
      if (next.errorMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.errorMessage!),
            backgroundColor: Colors.red.shade900,
            behavior: SnackBarBehavior.floating,
          ),
        );
        ref.read(audioPlayerServiceProvider.notifier).clearErrorMessage();
      }
    });

    ref.listen<ModelSelectionState>(modelSelectionProvider, (_, next) {
      if (next.selectedModel != _selectedModel &&
          next.selectedModel != 'Select a model') {
        setState(() => _selectedModel = next.selectedModel);
      }
    });

    final workspaceMode = ref.watch(workspaceModeProvider);
    final activeReview = ref.watch(activeReviewSessionProvider);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () {
          ref.read(workspaceModeProvider.notifier).state = WorkspaceMode.chat;
        },
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () {
          ref.read(workspaceModeProvider.notifier).state = WorkspaceMode.chat;
        },
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () {
          ref.read(workspaceModeProvider.notifier).state = WorkspaceMode.code;
        },
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () {
          ref.read(workspaceModeProvider.notifier).state = WorkspaceMode.code;
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: _scaffoldKey, // Add a key to access the scaffold
          backgroundColor: theme.scaffoldBackgroundColor,
          drawer: Builder(builder: (context) {
            return SizedBox(
              width: MediaQuery.sizeOf(context).width,
              child: Drawer(
                backgroundColor: const Color(0xFF171717),
                shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero),
                child: const ChatSidebar(isSidebarOpen: true, isMobile: true),
              ),
            );
          }),
          endDrawer: Consumer(
            builder: (context, ref, child) {
              final sources = ref.watch(activeSourcesProvider);
              final showTelemetry = ref.watch(
                chatViewModelProvider.select((s) => s.showTelemetry),
              );
              return SourcesSidebar(
                sources: sources,
                showTelemetry: showTelemetry,
              );
            },
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < 800;
              return Row(
                children: [
                  // Inner Navigation Sidebar (Projects / Chats)
                  isMobile
                      ? const SizedBox.shrink()
                      : ChatSidebar(
                          isSidebarOpen: isSidebarOpen, isMobile: false),
                  // Main Workspace: [ Chat | Code ] preserved via IndexedStack
                  Expanded(
                    child: IndexedStack(
                      index: workspaceMode == WorkspaceMode.chat ? 0 : 1,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: SafeArea(
                                child: Stack(
                                  children: [
                                    // Main Content
                                    Column(
                                      children: [
                                        Expanded(
                                          child: state.showAllProjectsDashboard
                                              ? const AllProjectsDashboardView()
                                              : state.showProjectDashboard
                                                  ? const ProjectDashboardView()
                                                  : state.isLoadingHistory
                                                      ? const Center(
                                                          child: SizedBox(
                                                            width: 24,
                                                            height: 24,
                                                            child:
                                                                CircularProgressIndicator(
                                                              strokeWidth: 2.0,
                                                              valueColor:
                                                                  AlwaysStoppedAnimation<
                                                                          Color>(
                                                                      Color(
                                                                          0xFF878787)),
                                                            ),
                                                          ),
                                                        )
                                                      : state.messages.isEmpty
                                                          ? _buildEmptyState(
                                                              theme,
                                                              ext,
                                                              state,
                                                              viewModel,
                                                              sandboxEnabled:
                                                                  sandboxEnabled)
                                                          : Opacity(
                                                              opacity:
                                                                  _pendingHistoryScrollRestore
                                                                      ? 0.0
                                                                      : 1.0,
                                                              child: NotificationListener<
                                                                  ScrollMetricsNotification>(
                                                                onNotification:
                                                                    (notification) {
                                                                  _syncScrolledUp(
                                                                      notification
                                                                          .metrics);
                                                                  return false;
                                                                },
                                                                child: ListView
                                                                    .builder(
                                                                  controller:
                                                                      _scrollController,
                                                                  scrollCacheExtent:
                                                                      const ScrollCacheExtent
                                                                          .pixels(
                                                                          3000),
                                                                  padding: const EdgeInsets
                                                                      .only(
                                                                      left: 16,
                                                                      right: 16,
                                                                      top: 80,
                                                                      bottom:
                                                                          140),
                                                                  itemCount: state
                                                                      .messages
                                                                      .length,
                                                                  itemBuilder:
                                                                      (context,
                                                                          index) {
                                                                    final msg =
                                                                        state.messages[
                                                                            index];
                                                                    return ChatMessageListItem(
                                                                      msg: msg,
                                                                      theme:
                                                                          theme,
                                                                      ext: ext,
                                                                      showTelemetry:
                                                                          state
                                                                              .showTelemetry,
                                                                    );
                                                                  },
                                                                ),
                                                              ),
                                                            ),
                                        ),
                                      ],
                                    ),

                                    // Top Bar Background to prevent text overlap
                                    if (!state.showAllProjectsDashboard &&
                                        !state.showProjectDashboard) ...[
                                      Positioned(
                                        top: 0,
                                        left: 0,
                                        right: 0,
                                        height: 60,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                theme.scaffoldBackgroundColor,
                                                theme.scaffoldBackgroundColor
                                                    .withValues(alpha: 0.9),
                                                theme.scaffoldBackgroundColor
                                                    .withValues(alpha: 0.0),
                                              ],
                                              stops: const [0.6, 0.9, 1.0],
                                            ),
                                          ),
                                        ),
                                      ),

                                      // Top Bar: Model Selector (like LibreChat)
                                      Positioned(
                                        top: 12,
                                        left: isMobile ? 56 : 16,
                                        right: 16,
                                        child: Wrap(
                                          alignment: WrapAlignment.start,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          spacing: 12,
                                          runSpacing: 8,
                                          children: [
                                            ModelSelectorMenu(
                                              selectedModel: _selectedModel,
                                              pinnedModels:
                                                  _pinnedModels.toList(),
                                              onModelSelected: (model) async {
                                                setState(() {
                                                  _selectedModel = model;
                                                });
                                                ref
                                                    .read(modelSelectionProvider
                                                        .notifier)
                                                    .selectModel(model);
                                                final prefs =
                                                    await SharedPreferences
                                                        .getInstance();
                                                await prefs.setString(
                                                    'selected_model', model);
                                              },
                                              onModelPinned: (model) {
                                                setState(() =>
                                                    _pinnedModels.add(model));
                                              },
                                              onModelUnpinned: (model) {
                                                setState(() => _pinnedModels
                                                    .remove(model));
                                              },
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 12,
                                                        vertical: 6),
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFF1E1E1E),
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  border: Border.all(
                                                      color: const Color(
                                                          0xFF2A2A2A)),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    if (_selectedModel !=
                                                        'Select a model') ...[
                                                      currentProvider != null
                                                          ? buildProviderIcon(
                                                              currentProvider)
                                                          : const Icon(
                                                              Icons.psychology,
                                                              size: 16,
                                                              color:
                                                                  Colors.white),
                                                      const SizedBox(width: 8),
                                                    ],
                                                    Text(_selectedModel,
                                                        style: const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 14,
                                                            fontWeight:
                                                                FontWeight
                                                                    .w500)),
                                                    const SizedBox(width: 4),
                                                    const Icon(
                                                        Icons
                                                            .keyboard_arrow_down,
                                                        size: 16,
                                                        color: Colors.white),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            ThinkingLevelSelector(
                                              selectedModel: _selectedModel,
                                            ),
                                            // Metrics toggle — flush next to the model pill
                                            Tooltip(
                                              message: state.showTelemetry
                                                  ? 'Metrics (On)'
                                                  : 'Show Metrics',
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                onTap: () =>
                                                    viewModel.toggleTelemetry(),
                                                child: Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 8,
                                                      vertical: 4),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(
                                                        'Metrics',
                                                        style: TextStyle(
                                                          color: const Color(
                                                              0xFF878787),
                                                          fontSize: 13,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      VeraxiSwitch(
                                                        value:
                                                            state.showTelemetry,
                                                        onChanged: (_) => viewModel
                                                            .toggleTelemetry(),
                                                        semanticLabel:
                                                            'Metrics',
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                            // Token-usage indicator style — always in
                                            // the header so "Off" stays reversible.
                                            PopupMenuButton<
                                                TokenUsageIndicatorStyle>(
                                              tooltip: 'Token usage indicator',
                                              color: const Color(0xFF1C1C1C),
                                              icon: const Icon(
                                                Icons.data_usage_outlined,
                                                size: 18,
                                                color: Color(0xFF878787),
                                              ),
                                              onSelected:
                                                  viewModel.setTokenUsageStyle,
                                              itemBuilder: (menuContext) => [
                                                for (final style
                                                    in TokenUsageIndicatorStyle
                                                        .values)
                                                  PopupMenuItem(
                                                    value: style,
                                                    child: Row(
                                                      children: [
                                                        Icon(
                                                          viewModel.tokenUsageStyle ==
                                                                  style
                                                              ? Icons.check
                                                              : null,
                                                          size: 16,
                                                          color: Colors.white,
                                                        ),
                                                        const SizedBox(
                                                            width: 8),
                                                        Text(
                                                          style ==
                                                                  TokenUsageIndicatorStyle
                                                                      .ring
                                                              ? 'Ring'
                                                              : style ==
                                                                      TokenUsageIndicatorStyle
                                                                          .bar
                                                                  ? 'Bar'
                                                                  : 'Off',
                                                          style:
                                                              const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 13,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Temporary Chat before the first message; afterward,
                                      // this becomes the action for starting a new thread.
                                      Positioned(
                                        top: 12,
                                        right: 16,
                                        child: Tooltip(
                                          message: state.messages.isNotEmpty
                                              ? 'New chat'
                                              : state.isTemporary
                                                  ? 'Temporary Chat (Enabled)'
                                                  : 'Temporary Chat',
                                          child: IconButton(
                                            icon: Icon(
                                              state.messages.isNotEmpty
                                                  ? Icons.edit_square
                                                  : Icons.data_usage,
                                              color: state.messages.isNotEmpty
                                                  ? const Color(0xFF878787)
                                                  : state.isTemporary
                                                      ? ext.primaryGradientStart
                                                      : const Color(0xFF878787),
                                              size: 20,
                                            ),
                                            onPressed: state.messages.isNotEmpty
                                                ? viewModel.startNewChat
                                                : viewModel.toggleTemporaryChat,
                                          ),
                                        ),
                                      ),
                                    ],

                                    if (isMobile)
                                      Positioned(
                                        top: 12,
                                        left: 8,
                                        child: IconButton(
                                          icon: const Icon(Icons.menu,
                                              color: Color(0xFFB4B4B4)),
                                          onPressed: () =>
                                              Scaffold.of(context).openDrawer(),
                                        ),
                                      ),

                                    // Gradient background at bottom behind input
                                    if (state.messages.isNotEmpty)
                                      Positioned(
                                        bottom: 0,
                                        left: 0,
                                        right: 0,
                                        height: 140,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                theme.scaffoldBackgroundColor
                                                    .withValues(alpha: 0.0),
                                                theme.scaffoldBackgroundColor,
                                              ],
                                              stops: const [0.0, 0.3],
                                            ),
                                          ),
                                        ),
                                      ),

                                    // Floating scroll to bottom button
                                    if (_isScrolledUp &&
                                        state.messages.isNotEmpty)
                                      Positioned(
                                        bottom: 180,
                                        left: 0,
                                        right: 0,
                                        child: Center(
                                          child: GestureDetector(
                                            onTap: () {
                                              _scrollToBottom();
                                            },
                                            child: Container(
                                              width: 32,
                                              height: 32,
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF2A2A2A),
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                    color: const Color(
                                                        0xFF3F3F3F)),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.black
                                                        .withValues(alpha: 0.2),
                                                    blurRadius: 4,
                                                    offset: const Offset(0, 2),
                                                  )
                                                ],
                                              ),
                                              child: const Icon(
                                                  Icons.arrow_downward,
                                                  color: Colors.white,
                                                  size: 16),
                                            ),
                                          ),
                                        ),
                                      ),

                                    // Floating Input Area at Bottom (only if messages exist)
                                    if (state.messages.isNotEmpty)
                                      Positioned(
                                        bottom: 40,
                                        left: 0,
                                        right: 0,
                                        child: Center(
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                maxWidth: 800),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 16),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  if (sandboxEnabled) ...[
                                                    const SandboxDrawer(),
                                                    const SizedBox(height: 8),
                                                  ],
                                                  if (viewModel
                                                              .tokenUsageStyle ==
                                                          TokenUsageIndicatorStyle
                                                              .bar &&
                                                      usageSummary != null) ...[
                                                    TokenUsageBar(
                                                      usage: usageSummary,
                                                      indicatorStyle: viewModel
                                                          .tokenUsageStyle,
                                                      onIndicatorStyleChanged:
                                                          viewModel
                                                              .setTokenUsageStyle,
                                                      autoCompactMode: viewModel
                                                          .autoCompactMode,
                                                      onAutoCompactModeChanged:
                                                          viewModel
                                                              .setAutoCompactMode,
                                                      onCompactPressed: () =>
                                                          _openCompaction(
                                                              context,
                                                              viewModel),
                                                    ),
                                                    const SizedBox(height: 8),
                                                  ],
                                                  const AcpPermissionBanner(),
                                                  ChatInput(
                                                    usageSummary: viewModel
                                                                .tokenUsageStyle ==
                                                            TokenUsageIndicatorStyle
                                                                .ring
                                                        ? usageSummary
                                                        : null,
                                                    tokenUsageStyle: viewModel
                                                        .tokenUsageStyle,
                                                    onTokenUsageStyleChanged:
                                                        viewModel
                                                            .setTokenUsageStyle,
                                                    autoCompactMode: viewModel
                                                        .autoCompactMode,
                                                    onAutoCompactModeChanged:
                                                        viewModel
                                                            .setAutoCompactMode,
                                                    onCompactPressed: () =>
                                                        _openCompaction(
                                                            context, viewModel),
                                                    model: _selectedModel ==
                                                            'Select a model'
                                                        ? null
                                                        : _selectedModel,
                                                    projectName:
                                                        state.activeProjectName,
                                                    isLoading:
                                                        state.isLoading ||
                                                            _autoCompactBusy,
                                                    onSend: (text,
                                                            {attachments}) =>
                                                        viewModel.sendMessage(
                                                            text,
                                                            model: _selectedModel ==
                                                                    'Select a model'
                                                                ? null
                                                                : _selectedModel,
                                                            attachments:
                                                                attachments,
                                                            thinkingLevel:
                                                                _effectiveThinkingLevel()),
                                                    errorText: state.error,
                                                    onDismissError: () =>
                                                        viewModel.clearError(),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),

                                    // Footer Legal Text
                                    if (MediaQuery.of(context).size.width > 600)
                                      Positioned(
                                        bottom: 16,
                                        left: 16,
                                        right: 16,
                                        child: Center(
                                          child: Text(
                                            'Veraxi v0.1.0 - Sovereign Intelligence. Privacy policy | Terms of service',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                color: const Color(0xFF878787),
                                                fontSize: 12),
                                          ),
                                        ),
                                      ),

                                    // Mobile: the code panel covers the chat full-screen
                                    // instead of splitting beside it.
                                    if (isMobile && openArtifact != null)
                                      Positioned.fill(
                                        child: CodeArtifactPanel(
                                          key: ValueKey(openArtifact),
                                          open: openArtifact,
                                          onClose: _closeArtifactPanel,
                                          onQuickAction: (prompt) =>
                                              viewModel.sendMessage(
                                            prompt,
                                            model: _selectedModel,
                                            thinkingLevel:
                                                _effectiveThinkingLevel(),
                                          ),
                                        ),
                                      ),
                                    if (workspaceMode == WorkspaceMode.chat &&
                                        activeReview != null &&
                                        constraints.maxWidth < 1200)
                                      Positioned.fill(
                                        child: GestureDetector(
                                          onTap: () => ref
                                              .read(activeReviewSessionProvider
                                                  .notifier)
                                              .state = null,
                                          child: Container(
                                            color: Colors.black54,
                                            alignment: Alignment.centerRight,
                                            child: GestureDetector(
                                              onTap: () {},
                                              child: SizedBox(
                                                width: (constraints.maxWidth *
                                                        0.92)
                                                    .clamp(320.0, 640.0),
                                                child: CodeReviewDrawer(
                                                  key: ValueKey(
                                                      'review-sheet-${activeReview.sessionId}-${activeReview.turnId}'),
                                                  review: activeReview,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            // Desktop / web: code panel splits in on the right side,
                            // Claude-style, narrowing the chat column. The split is
                            // responsive — ~55% of the window, clamped so the slide
                            // viewer's thumbnail rail and 16:9 stage breathe — and
                            // the panel's expand toggle widens it further.
                            if (!isMobile && openArtifact != null)
                              SizedBox(
                                width: panelExpanded
                                    ? (constraints.maxWidth * 0.85)
                                        .clamp(520.0, 1400.0)
                                    : (constraints.maxWidth * 0.55)
                                        .clamp(520.0, 900.0),
                                child: CodeArtifactPanel(
                                  key: ValueKey(openArtifact),
                                  open: openArtifact,
                                  onClose: _closeArtifactPanel,
                                  onQuickAction: (prompt) =>
                                      viewModel.sendMessage(
                                    prompt,
                                    model: _selectedModel,
                                    thinkingLevel: _effectiveThinkingLevel(),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        SafeArea(
                          child: CodeWorkbenchView(
                            onOpenMobileSidebar: isMobile
                                ? () => _scaffoldKey.currentState?.openDrawer()
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Phase 5 review pane host (Chat Mode, wide
                  // layouts): a ~55% right split beside the chat /
                  // code IndexedStack. Code Mode hosts the drawer
                  // itself (split + narrow overlay) inside
                  // CodeWorkbenchView, so this host is gated to
                  // Chat Mode to avoid mounting it twice.
                  if (workspaceMode == WorkspaceMode.chat &&
                      activeReview != null &&
                      constraints.maxWidth >= 1200)
                    SizedBox(
                      width: (constraints.maxWidth * 0.55).clamp(520.0, 900.0),
                      child: CodeReviewDrawer(
                        key: ValueKey(
                            'review-${activeReview.sessionId}-${activeReview.turnId}'),
                        review: activeReview,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  String? _effectiveThinkingLevel() {
    final caps = ref.read(modelCapabilitiesProvider).valueOrNull ??
        const <String, ModelThinkingCapability>{};
    return resolveEffectiveThinkingLevel(
      modelName: _selectedModel,
      savedByModel: ref.read(thinkingLevelByModelProvider),
      capabilities: caps,
    );
  }

  Widget _buildEmptyState(ThemeData theme, AppThemeExtension ext,
      ChatState state, ChatViewModel viewModel,
      {bool sandboxEnabled = false}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Good afternoon, ${resolveDisplayName()}',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ).animate().fade(duration: 800.ms).slideY(begin: 0.1, end: 0),
              const SizedBox(height: 32),
              const AcpPermissionBanner(),
              ChatInput(
                model:
                    _selectedModel == 'Select a model' ? null : _selectedModel,
                projectName: state.activeProjectName,
                isLoading: state.isLoading,
                onSend: (text, {attachments}) => viewModel.sendMessage(text,
                    model: _selectedModel == 'Select a model'
                        ? null
                        : _selectedModel,
                    attachments: attachments,
                    thinkingLevel: _effectiveThinkingLevel()),
                errorText: state.error,
                onDismissError: () => viewModel.clearError(),
              )
                  .animate()
                  .fade(duration: 800.ms, delay: 100.ms)
                  .slideY(begin: 0.1, end: 0),
              const SizedBox(height: 16),
              HybridStarterChipsRow(
                isLoading: state.isLoading,
                onSelectPrompt: (prompt) => viewModel.sendMessage(
                  prompt,
                  model: _selectedModel == 'Select a model'
                      ? null
                      : _selectedModel,
                  thinkingLevel: _effectiveThinkingLevel(),
                ),
              ),
              if (sandboxEnabled) ...[
                const SizedBox(height: 16),
                const SandboxDrawer(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
