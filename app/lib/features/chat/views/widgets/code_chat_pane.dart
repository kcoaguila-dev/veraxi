import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/model_selection_provider.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/token_usage.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_list_item.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_chat_composer.dart';
import 'package:veraxi_app/features/chat/views/widgets/compaction_sheet.dart';

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
    final repos = ref.read(indexedReposProvider);
    final sources = ref.read(codeSelectedSourcesProvider);
    final repoKey = selectedRepo ??
        (sources.repoKeys.isNotEmpty
            ? sources.repoKeys.first
            : (repos.isNotEmpty ? repos.first.repoKey : null));
    final scope = buildCodeScope(
      repoKey: repoKey,
      branch: ref.read(codeBranchProvider),
      thinkingLevel: ref.read(codeThinkingLevelProvider),
      executionMode: ref.read(codeExecutionModeProvider),
      autonomyMode: ref.read(codeAutonomyModeProvider),
      sources: sources,
    );
    final model = ref.read(modelSelectionProvider).selectedModel;
    ref.read(chatViewModelProvider.notifier).sendMessage(
          text,
          model: model == 'Select a model' ? null : model,
          attachments: attachments,
          codeScope: scope,
        );
  }

  void _handleSlashCommand(String command) {
    final viewModel = ref.read(chatViewModelProvider.notifier);
    switch (command) {
      case '/clear':
        viewModel.startNewChat();
      case '/security':
        ref.read(codeSubViewProvider.notifier).state = CodeSubView.vulnIntel;
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
    final title = _threadTitle(state);
    return repoLabel == null ? title : '$repoLabel / $title';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatViewModelProvider);
    final viewModel = ref.read(chatViewModelProvider.notifier);
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    final isEmpty = state.messages.isEmpty;

    ref.listen<List<ChatMessage>>(
      chatViewModelProvider.select((s) => s.messages),
      (previous, next) {
        if (next.isNotEmpty) _scrollToBottom();
      },
    );

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Container(
        decoration: BoxDecoration(
          color: ObsidianTokens.recessedCanvas,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ObsidianTokens.canvasBorder),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildBreadcrumbHeader(state),
              Expanded(
                child: state.isLoadingHistory
                    ? const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Color(0xFF878787),
                            ),
                          ),
                        ),
                      )
                    : isEmpty
                        ? _buildEmptyBody(state)
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
                          onTokenUsageStyleChanged:
                              viewModel.setTokenUsageStyle,
                          autoCompactMode: viewModel.autoCompactMode,
                          onAutoCompactModeChanged:
                              viewModel.setAutoCompactMode,
                          onCompactPressed: () =>
                              _handleSlashCommand('/compact'),
                          onSlashCommand: _handleSlashCommand,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBreadcrumbHeader(ChatState state) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: ObsidianTokens.hairline, width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: ObsidianTokens.card,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: ObsidianTokens.borderStrong),
            ),
            child: const Text(
              'VX',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _repoBreadcrumb(state),
              style: const TextStyle(
                color: Color(0xFFD4D4D8),
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

  Widget _buildEmptyBody(ChatState state) {
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.code,
              size: 28,
              color: Color(0xFF52525B),
            ),
            const SizedBox(height: 12),
            Text(
              selectedRepo == null
                  ? 'Ask anything about your indexed code.'
                  : 'Ask anything about $selectedRepo.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFA1A1AA),
                fontSize: 14,
              ),
            ),
          ],
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(indexedReposProvider);
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);
    final branch = ref.watch(codeBranchProvider);
    const branches = <String>['main'];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ObsidianTokens.weldedTray,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ObsidianTokens.canvasBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 15, color: Color(0xFFA1A1AA)),
          const SizedBox(width: 8),
          Expanded(
            child: repos.isEmpty
                ? const Text(
                    'No indexed repos',
                    style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12.5),
                  )
                : DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: repos.any((r) => r.repoKey == selectedRepo)
                          ? selectedRepo
                          : repos.first.repoKey,
                      isDense: true,
                      dropdownColor: ObsidianTokens.card,
                      icon: const Icon(Icons.keyboard_arrow_down,
                          size: 16, color: Color(0xFFA1A1AA)),
                      style: const TextStyle(
                        color: Color(0xFFE4E4E7),
                        fontSize: 12.5,
                      ),
                      items: [
                        for (final repo in repos)
                          DropdownMenuItem<String>(
                            value: repo.repoKey,
                            child: Text(repo.displayName),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        ref.read(selectedIndexedRepoProvider.notifier).state =
                            value;
                        // A welded-tray repo pick replaces the repo
                        // selection (preserving any selected docs) so
                        // the first send is scoped to this repo.
                        final sources = ref.read(codeSelectedSourcesProvider);
                        ref.read(codeSelectedSourcesProvider.notifier).state =
                            sources.copyWith(repoKeys: {value});
                      },
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          const Icon(Icons.call_split, size: 14, color: Color(0xFFA1A1AA)),
          const SizedBox(width: 6),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: branches.contains(branch) ? branch : branches.first,
              isDense: true,
              dropdownColor: ObsidianTokens.card,
              icon: const Icon(Icons.keyboard_arrow_down,
                  size: 16, color: Color(0xFFA1A1AA)),
              style: const TextStyle(
                color: Color(0xFFE4E4E7),
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
