import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/models/model_thinking_capability.dart';
import 'package:veraxi_app/core/providers/model_selection_provider.dart';
import 'package:veraxi_app/core/providers/thinking_level_provider.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/core/widgets/profile_menu_button.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_review_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/connect_repo_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/sandbox_toggle_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/token_usage.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_list_item.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_chat_composer.dart';
import 'package:veraxi_app/features/chat/views/widgets/compaction_sheet.dart';
import 'package:veraxi_app/features/chat/views/widgets/connect_repo_dialog.dart';
import 'package:veraxi_app/features/settings/views/widgets/settings_dialog.dart';

/// Code Chat pane: the Code Mode center stage.
///
/// Lives in the chat feature on purpose — it renders the shared
/// [ChatViewModel] thread with the same message list items
/// ([ChatMessageListItem], which builds `ChatBubble`-style bubbles,
/// `ChatActivityDisclosure` and citation chips) as Chat Mode, so a
/// thread looks identical in both modes. The pane is the 6th child
/// of the Code workbench `IndexedStack`, mapped to
/// [CodeSubView.codeChat].
///
/// Layout: recessed `#060709` canvas (rounded 14, 1px canvas border)
/// inside the shell, a 52px breadcrumb header (VX badge + repo /
/// thread breadcrumb — no sub-view toggle here; the workbench owns
/// navigation), the message list, and the composer with its welded
/// New Chat tray in the empty state.
class CodeChatPane extends ConsumerStatefulWidget {
  const CodeChatPane({super.key});

  @override
  ConsumerState<CodeChatPane> createState() => _CodeChatPaneState();
}

class _CodeChatPaneState extends ConsumerState<CodeChatPane> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  /// Sends [text] as a Code Mode turn: the Phase 1 scope (workspace
  /// mode, repo, branch, thinking/execution/autonomy, source scope)
  /// is stamped onto the request at send time from the live Code
  /// providers, and the repository stamps the same scope onto the
  /// local (Drift) thread row when it creates the thread.
  void _handleSend(String text, {List<PlatformFile>? attachments}) {
    final selectedRepo = ref.read(selectedIndexedRepoProvider);
    final sources = ref.read(codeSelectedSourcesProvider);
    final repoKey = selectedRepo ??
        (sources.repoKeys.isNotEmpty ? sources.repoKeys.first : null);
    final model = ref.read(modelSelectionProvider).selectedModel;
    final caps = ref.read(modelCapabilitiesProvider).valueOrNull ??
        const <String, ModelThinkingCapability>{};
    final effectiveThinking = resolveEffectiveThinkingLevel(
      modelName: model,
      savedByModel: ref.read(thinkingLevelByModelProvider),
      capabilities: caps,
      fallbackLevel: ref.read(codeThinkingLevelProvider),
    );
    final scope = buildCodeScope(
      repoKey: repoKey,
      branch: ref.read(codeBranchProvider),
      thinkingLevel: effectiveThinking,
      executionMode: ref.read(codeExecutionModeProvider),
      autonomyMode: ref.read(codeAutonomyModeProvider),
      sources: sources,
    );
    ref.read(codeChatViewModelProvider.notifier).sendMessage(
          text,
          model: model == 'Select a model' ? null : model,
          attachments: attachments,
          codeScope: scope,
        );
  }

  void _handleSlashCommand(String command) {
    final viewModel = ref.read(codeChatViewModelProvider.notifier);
    switch (command) {
      case '/clear':
        viewModel.startNewChat();
      case '/security':
        ref.read(codeSubViewProvider.notifier).state = CodeSubView.vulnIntel;
      case '/security-review':
        final activeReview = ref.read(activeReviewSessionProvider);
        final files =
            activeReview?.files.map((f) => f.path).toList() ?? const <String>[];
        final repo = ref.read(selectedIndexedRepoProvider);
        ref
            .read(codeReviewProvider.notifier)
            .runSecurityDiffAudit(files: files, repo: repo)
            .then((auditSummary) {
          if (mounted) _handleSend(auditSummary);
        });
      case '/compact':
        final model = ref.read(modelSelectionProvider).selectedModel;
        final effectiveModel = model == 'Select a model' ? null : model;
        showCompactionSheet(
          context,
          onPreview: () => viewModel.previewCompaction(model: effectiveModel),
          onApply: (summary) => viewModel.applyCompaction(
            summary: summary,
            model: effectiveModel,
          ),
          onClearToolResults: () =>
              viewModel.clearOldToolResults(model: effectiveModel),
        );
    }
  }

  String _threadTitle(ChatState state) {
    final threadId = state.threadId;
    if (threadId == null) return 'New chat';
    for (final thread in state.pastThreads) {
      if (thread['thread_id'] == threadId) {
        final title = thread['title'] as String?;
        if (title != null && title.isNotEmpty) return title;
      }
    }
    return 'New chat';
  }

  String _repoBreadcrumb(ChatState state) {
    final repos = ref.watch(indexedReposProvider);
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);
    String? repoLabel;
    for (final repo in repos) {
      if (repo.repoKey == selectedRepo) {
        repoLabel = repo.displayName;
        break;
      }
    }
    repoLabel ??= selectedRepo;
    if (repoLabel == null && state.threadId == null) return '';
    final title = _threadTitle(state);
    return repoLabel == null ? title : '$repoLabel / $title';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(codeChatViewModelProvider);
    final viewModel = ref.read(codeChatViewModelProvider.notifier);
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    final isEmpty = state.messages.isEmpty;

    ref.listen<List<ChatMessage>>(
      codeChatViewModelProvider.select((s) => s.messages),
      (previous, next) {
        if (next.isNotEmpty) _scrollToBottom();
      },
    );

    ref.listen<String?>(
      pendingSecurityThreadPromptProvider,
      (previous, next) {
        if (next != null && next.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ref.read(pendingSecurityThreadPromptProvider.notifier).state = null;
            _handleSend(next);
          });
        }
      },
    );

    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildBreadcrumbHeader(state, theme, ext),
          Expanded(
            child: state.isLoadingHistory
                ? Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          ext.textTertiary,
                        ),
                      ),
                    ),
                  )
                : isEmpty
                    ? _buildEmptyBody(state, ext)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.only(
                          left: 16,
                          right: 16,
                          top: 24,
                          bottom: 24,
                        ),
                        itemCount: state.messages.length,
                        itemBuilder: (context, index) {
                          return ChatMessageListItem(
                            msg: state.messages[index],
                            theme: theme,
                            ext: ext,
                            showTelemetry: state.showTelemetry,
                          );
                        },
                      ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isEmpty && !state.isLoadingHistory) ...[
                      const _WeldedNewChatTray(),
                      const SizedBox(height: 10),
                    ],
                    CodeChatComposer(
                      isLoading: state.isLoading,
                      onSend: _handleSend,
                      errorText: state.error,
                      onDismissError: () => viewModel.clearError(),
                      usageSummary: viewModel.tokenUsageStyle ==
                              TokenUsageIndicatorStyle.ring
                          ? summarizeTokenUsage(state.messages)
                          : null,
                      tokenUsageStyle: viewModel.tokenUsageStyle,
                      onTokenUsageStyleChanged: viewModel.setTokenUsageStyle,
                      autoCompactMode: viewModel.autoCompactMode,
                      onAutoCompactModeChanged: viewModel.setAutoCompactMode,
                      onCompactPressed: () => _handleSlashCommand('/compact'),
                      onSlashCommand: _handleSlashCommand,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbHeader(
      ChatState state, ThemeData theme, AppThemeExtension ext) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: state.messages.isEmpty
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(color: ext.borderColor, width: 1),
              ),
            ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _repoBreadcrumb(state),
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyBody(ChatState state, AppThemeExtension ext) {
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);
    final theme = Theme.of(context);
    final displayName = resolveDisplayName();

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Good to see you, $displayName. What\'s next?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                selectedRepo == null
                    ? 'Ask anything, paste code, or connect a repo.'
                    : 'Ask anything about $selectedRepo.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ext.textTertiary,
                  fontSize: 13.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Welded New Chat tray: docked directly above the composer in the
/// empty state, carrying the repo and branch the new thread will be
/// scoped to. Repo options are the indexed repos; branch options
/// are the known branches for the repo — no branch-list endpoint
/// exists yet, so `main` is the only entry until one does.
class _WeldedNewChatTray extends ConsumerWidget {
  const _WeldedNewChatTray();

  static const String _noRepoSentinel = '__no_repo__';
  static const String _execChatOnly = 'chat_only';
  static const String _execSandbox = 'sandbox';
  static const String _execConfigure = 'configure_sandbox';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(indexedReposProvider);
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);
    final branch = ref.watch(codeBranchProvider);
    final sandboxEnabled = ref.watch(sandboxToggleViewModelProvider).enabled;
    final connectState = ref.watch(connectRepoViewModelProvider);
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    const branches = <String>['main'];
    final hasSelectedRepo =
        selectedRepo != null && repos.any((r) => r.repoKey == selectedRepo);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ext.borderColor),
      ),
      child: Row(
        children: [
          Icon(
            sandboxEnabled
                ? Icons.terminal_outlined
                : Icons.chat_bubble_outline,
            size: 14,
            color: sandboxEnabled ? const Color(0xFF34D399) : ext.iconColor,
          ),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: 'Execution target',
            color: ext.cardBackground,
            padding: EdgeInsets.zero,
            onSelected: (value) {
              if (value == _execConfigure) {
                showDialog<void>(
                  context: context,
                  builder: (_) =>
                      const SettingsDialog(initialTab: 'Code Sandboxes'),
                );
                return;
              }
              ref
                  .read(sandboxToggleViewModelProvider.notifier)
                  .setEnabled(value == _execSandbox);
            },
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                value: _execChatOnly,
                child: Text('Chat only'),
              ),
              const PopupMenuItem<String>(
                value: _execSandbox,
                child: Text('Cloud Sandbox'),
              ),
              const PopupMenuItem<String>(
                value: _execConfigure,
                child: Text(
                  'Configure Sandbox…',
                  style: TextStyle(color: Color(0xFF34D399)),
                ),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sandboxEnabled ? 'Cloud Sandbox' : 'Chat only',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.keyboard_arrow_down,
                      size: 16, color: ext.iconColor),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.folder_outlined, size: 15, color: ext.iconColor),
          const SizedBox(width: 8),
          Expanded(
            child: repos.isEmpty
                ? Row(
                    children: [
                      Flexible(
                        child: Text(
                          'No repo (Scratchpad)',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: ext.textTertiary, fontSize: 12.5),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (connectState.indexing)
                        _IndexingStatusPill(
                          target: connectState.activeTarget ?? 'repo',
                        )
                      else if (connectState.errorMessage != null)
                        _IndexingErrorPill(
                          message: connectState.errorMessage!,
                          onRetry: () => showConnectRepoDialog(context),
                          onDismiss: () => ref
                              .read(connectRepoViewModelProvider.notifier)
                              .clearBanner(),
                        )
                      else
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => showConnectRepoDialog(context),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            child: Text(
                              '+ Connect repo',
                              style: TextStyle(
                                color: Color(0xFF34D399),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  )
                : DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: hasSelectedRepo ? selectedRepo : _noRepoSentinel,
                      isDense: true,
                      isExpanded: true,
                      dropdownColor: ext.cardBackground,
                      icon: Icon(Icons.keyboard_arrow_down,
                          size: 16, color: ext.iconColor),
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 12.5,
                      ),
                      items: [
                        DropdownMenuItem<String>(
                          value: _noRepoSentinel,
                          child: Text(
                            'No repo (Scratchpad)',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: ext.textTertiary),
                          ),
                        ),
                        for (final repo in repos)
                          DropdownMenuItem<String>(
                            value: repo.repoKey,
                            child: Text(
                              repo.displayName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        final sources = ref.read(codeSelectedSourcesProvider);
                        if (value == _noRepoSentinel) {
                          ref.read(selectedIndexedRepoProvider.notifier).state =
                              null;
                          ref.read(codeSelectedSourcesProvider.notifier).state =
                              sources.copyWith(repoKeys: const {});
                          return;
                        }
                        ref.read(selectedIndexedRepoProvider.notifier).state =
                            value;
                        // A welded-tray repo pick replaces the repo
                        // selection (preserving any selected docs) so
                        // the first send is scoped to this repo.
                        ref.read(codeSelectedSourcesProvider.notifier).state =
                            sources.copyWith(repoKeys: {value});
                      },
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.call_split, size: 14, color: ext.iconColor),
          const SizedBox(width: 6),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: branches.contains(branch) ? branch : branches.first,
              isDense: true,
              dropdownColor: ext.cardBackground,
              icon: Icon(Icons.keyboard_arrow_down,
                  size: 16, color: ext.iconColor),
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: 12.5,
              ),
              items: [
                for (final name in branches)
                  DropdownMenuItem<String>(
                    value: name,
                    child: Text(name),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                ref.read(codeBranchProvider.notifier).state = value;
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _IndexingStatusPill extends StatelessWidget {
  final String target;

  const _IndexingStatusPill({required this.target});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF14231D),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF224438)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: Color(0xFF34D399),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Indexing $target…',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF34D399),
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IndexingErrorPill extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  const _IndexingErrorPill({
    required this.message,
    required this.onRetry,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF2A1618),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF5C262B)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onRetry,
              child: const Text(
                'Index failed · Retry',
                style: TextStyle(
                  color: Color(0xFFFCA5A5),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 6),
            InkWell(
              onTap: onDismiss,
              child: const Icon(
                Icons.close,
                size: 13,
                color: Color(0xFFFCA5A5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
