import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/model_selection_provider.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/core/widgets/language_file_icon.dart';
import 'package:veraxi_app/core/widgets/model_selector_menu.dart';
import 'package:veraxi_app/features/chat/view_models/auto_compact.dart';
import 'package:veraxi_app/features/chat/view_models/code_chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_file_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/sandbox_toggle_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/token_usage.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_sources_popover.dart';

/// The active autocomplete trigger in the Code composer draft: the
/// sigil (`@`, `$`, `/`), the partial token after it, and the offset
/// where the token starts in the draft.
class _ComposerTrigger {
  final String sigil;
  final String query;
  final int tokenStart;

  const _ComposerTrigger({
    required this.sigil,
    required this.query,
    required this.tokenStart,
  });
}

/// Code Mode composer: the shared [ChatInput] in its Obsidian
/// styling, an `@`/`$`/`/` autocomplete overlay above it, and the
/// below-composer control row (model, thinking, Plan|Act, autonomy).
///
/// The composer owns the text controller (passed into [ChatInput])
/// so the overlay can observe the draft and rewrite the active
/// token on selection. The text field itself is the plain
/// [TextField] inside [ChatInput] — no input formatter is attached
/// anywhere in the chat feature, so pasted text keeps its
/// underscores and blank lines untouched.
class CodeChatComposer extends ConsumerStatefulWidget {
  final bool isLoading;
  final Function(String, {List<PlatformFile>? attachments}) onSend;
  final String? errorText;
  final VoidCallback? onDismissError;
  final TokenUsageSummary? usageSummary;
  final TokenUsageIndicatorStyle? tokenUsageStyle;
  final ValueChanged<TokenUsageIndicatorStyle>? onTokenUsageStyleChanged;
  final AutoCompactMode? autoCompactMode;
  final ValueChanged<AutoCompactMode>? onAutoCompactModeChanged;
  final VoidCallback? onCompactPressed;

  /// Handles slash commands that need pane-level actions
  /// (`/compact`, `/clear`, `/security`). `/plan` and `/act` are
  /// handled internally against [codeExecutionModeProvider].
  final ValueChanged<String>? onSlashCommand;

  const CodeChatComposer({
    super.key,
    required this.isLoading,
    required this.onSend,
    this.errorText,
    this.onDismissError,
    this.usageSummary,
    this.tokenUsageStyle,
    this.onTokenUsageStyleChanged,
    this.autoCompactMode,
    this.onAutoCompactModeChanged,
    this.onCompactPressed,
    this.onSlashCommand,
  });

  @override
  ConsumerState<CodeChatComposer> createState() => _CodeChatComposerState();
}

class _CodeChatComposerState extends ConsumerState<CodeChatComposer> {
  final TextEditingController _controller = TextEditingController();
  _ComposerTrigger? _trigger;
  String _debouncedFileQuery = '';
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleDraftChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.removeListener(_handleDraftChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleDraftChanged() {
    final next = _parseTrigger();
    if (next?.sigil == '@' && next?.query != _trigger?.query) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 250), () {
        if (mounted) {
          setState(() => _debouncedFileQuery = next!.query);
        }
      });
    } else if (next?.sigil != '@') {
      _debounceTimer?.cancel();
    }
    if (next?.sigil != _trigger?.sigil ||
        next?.query != _trigger?.query ||
        next?.tokenStart != _trigger?.tokenStart) {
      setState(() => _trigger = next);
    }
  }

  _ComposerTrigger? _parseTrigger() {
    final selection = _controller.selection;
    if (!selection.isValid || selection.start != selection.end) return null;
    final cursor = selection.start;
    if (cursor < 0 || cursor > _controller.text.length) return null;
    final text = _controller.text.substring(0, cursor);
    // Slash commands only open at the very start of the draft.
    if (text.startsWith('/') && !text.contains(' ') && !text.contains('\n')) {
      return _ComposerTrigger(
        sigil: '/',
        query: text.substring(1),
        tokenStart: 0,
      );
    }
    var i = text.length - 1;
    while (i >= 0 && text[i] != ' ' && text[i] != '\n' && text[i] != '\t') {
      i--;
    }
    final token = text.substring(i + 1);
    if (token.startsWith('@')) {
      return _ComposerTrigger(
        sigil: '@',
        query: token.substring(1),
        tokenStart: i + 1,
      );
    }
    if (token.startsWith(r'$')) {
      return _ComposerTrigger(
        sigil: r'$',
        query: token.substring(1),
        tokenStart: i + 1,
      );
    }
    return null;
  }

  void _replaceToken(String replacement) {
    final trigger = _trigger;
    if (trigger == null) return;
    final cursor = _controller.selection.start;
    final newText = _controller.text.replaceRange(
      trigger.tokenStart,
      cursor,
      replacement,
    );
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: trigger.tokenStart + replacement.length,
      ),
    );
    setState(() => _trigger = null);
  }

  void _runSlashCommand(String command) {
    _controller.clear();
    setState(() => _trigger = null);
    switch (command) {
      case '/plan':
        ref.read(codeExecutionModeProvider.notifier).state =
            CodeExecutionMode.plan;
      case '/act':
        ref.read(codeExecutionModeProvider.notifier).state =
            CodeExecutionMode.act;
      default:
        widget.onSlashCommand?.call(command);
    }
  }

  void _handleComposerSend(String text, {List<PlatformFile>? attachments}) {
    final trimmed = text.trim();
    if ((attachments == null || attachments.isEmpty) &&
        codeSlashCommands.any((c) => c.command == trimmed)) {
      _runSlashCommand(trimmed);
      return;
    }
    widget.onSend(text, attachments: attachments);
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel = ref.watch(modelSelectionProvider).selectedModel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_trigger != null) ...[
          _buildAutocompleteOverlay(_trigger!),
          const SizedBox(height: 8),
        ],
        ChatInput(
          controller: _controller,
          isLoading: widget.isLoading,
          onSend: _handleComposerSend,
          errorText: widget.errorText,
          onDismissError: widget.onDismissError,
          model: selectedModel == 'Select a model' ? null : selectedModel,
          usageSummary: widget.usageSummary,
          tokenUsageStyle: widget.tokenUsageStyle,
          onTokenUsageStyleChanged: widget.onTokenUsageStyleChanged,
          autoCompactMode: widget.autoCompactMode,
          onAutoCompactModeChanged: widget.onAutoCompactModeChanged,
          onCompactPressed: widget.onCompactPressed,
          hintText: 'Ask anything. @ files, \$ skills, / commands',
          trailingSlot: const CodeSourcesPill(),
        ),
        const SizedBox(height: 8),
        _buildBelowComposerRow(),
      ],
    );
  }

  Widget _buildAutocompleteOverlay(_ComposerTrigger trigger) {
    switch (trigger.sigil) {
      case '@':
        return _buildFileOverlay(trigger);
      case r'$':
        return _buildSkillOverlay(trigger);
      case '/':
        return _buildCommandOverlay(trigger);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _overlayShell({required Widget child}) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Container(
      constraints: const BoxConstraints(maxHeight: 264),
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ext.borderColorStrong),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: child,
      ),
    );
  }

  Widget _buildFileOverlay(_ComposerTrigger trigger) {
    final repoKey = ref.watch(selectedIndexedRepoProvider);
    final asyncFiles = ref.watch(
      codeFileSearchProvider((repoKey: repoKey, query: _debouncedFileQuery)),
    );
    return _overlayShell(
      child: asyncFiles.when(
        data: (files) {
          if (files.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'No indexed files match.',
                style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12.5),
              ),
            );
          }
          return ListView.builder(
            shrinkWrap: true,
            itemCount: files.length,
            itemBuilder: (context, index) {
              final file = files[index];
              return InkWell(
                onTap: () => _replaceToken('@${file.path} '),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Row(
                    children: [
                      LanguageFileIcon(fileName: file.path, size: 15),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          file.path,
                          style: const TextStyle(
                            color: Color(0xFFE4E4E7),
                            fontSize: 12.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (file.repoKey != null)
                        Text(
                          file.repoKey!,
                          style: const TextStyle(
                            color: Color(0xFF6E6E6E),
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
        loading: () => const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Searching indexed files…',
            style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12.5),
          ),
        ),
        error: (_, __) => const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'File search unavailable.',
            style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12.5),
          ),
        ),
      ),
    );
  }

  Widget _buildSkillOverlay(_ComposerTrigger trigger) {
    final asyncSkills = ref.watch(agentSkillsProvider);
    return _overlayShell(
      child: asyncSkills.when(
        data: (skills) {
          final query = trigger.query.toLowerCase();
          final visible = skills
              .where((skill) => skill.name.toLowerCase().contains(query))
              .toList();
          if (visible.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'No skills configured.',
                style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12.5),
              ),
            );
          }
          return ListView.builder(
            shrinkWrap: true,
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final skill = visible[index];
              return InkWell(
                onTap: () => _replaceToken('\$${skill.name} '),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.extension_outlined,
                        size: 15,
                        color: Color(0xFFA1A1AA),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              skill.name,
                              style: const TextStyle(
                                color: Color(0xFFE4E4E7),
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (skill.description.isNotEmpty)
                              Text(
                                skill.description,
                                style: const TextStyle(
                                  color: Color(0xFF6E6E6E),
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
        loading: () => const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Loading skills…',
            style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12.5),
          ),
        ),
        error: (_, __) => const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Skills unavailable.',
            style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12.5),
          ),
        ),
      ),
    );
  }

  Widget _buildCommandOverlay(_ComposerTrigger trigger) {
    final query = trigger.query.toLowerCase();
    final visible = codeSlashCommands
        .where((command) => command.command.substring(1).startsWith(query))
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return _overlayShell(
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final command = visible[index];
          return InkWell(
            onTap: () => _runSlashCommand(command.command),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                children: [
                  const Icon(
                    Icons.terminal,
                    size: 15,
                    color: Color(0xFFA1A1AA),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    command.command,
                    style: const TextStyle(
                      color: Color(0xFFE4E4E7),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      command.description,
                      style: const TextStyle(
                        color: Color(0xFF6E6E6E),
                        fontSize: 11.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBelowComposerRow() {
    final modelSelection = ref.watch(modelSelectionProvider);
    final thinkingLevel = ref.watch(codeThinkingLevelProvider);
    final executionMode = ref.watch(codeExecutionModeProvider);
    final sandboxEnabled = ref.watch(sandboxToggleViewModelProvider).enabled;
    final autonomyMode = ref.watch(codeAutonomyModeProvider);

    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ModelSelectorMenu(
          selectedModel: modelSelection.selectedModel,
          pinnedModels: modelSelection.pinnedModels.toList(),
          onModelSelected: (model) =>
              ref.read(modelSelectionProvider.notifier).selectModel(model),
          onModelPinned: (model) =>
              ref.read(modelSelectionProvider.notifier).pinModel(model),
          onModelUnpinned: (model) =>
              ref.read(modelSelectionProvider.notifier).unpinModel(model),
          child: _belowRowPill(
            icon: Icons.psychology_outlined,
            label: modelSelection.selectedModel,
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Thinking level',
          color: ext.cardBackground,
          onSelected: (level) =>
              ref.read(codeThinkingLevelProvider.notifier).setLevel(level),
          itemBuilder: (context) => [
            for (final level in CodeThinkingLevelNotifier.levels)
              PopupMenuItem<String>(
                value: level,
                child: Row(
                  children: [
                    Icon(
                      level == thinkingLevel ? Icons.check : null,
                      size: 15,
                      color: theme.colorScheme.onSurface,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      level,
                      style: TextStyle(
                          color: theme.colorScheme.onSurface, fontSize: 13),
                    ),
                  ],
                ),
              ),
          ],
          child: _belowRowPill(
            icon: Icons.lightbulb_outline,
            label: 'Thinking: $thinkingLevel',
          ),
        ),
        _buildPlanActToggle(executionMode),
        if (sandboxEnabled)
          PopupMenuButton<String>(
            tooltip: 'Sandbox autonomy',
            color: ext.cardBackground,
            onSelected: (value) =>
                ref.read(codeAutonomyModeProvider.notifier).state = value,
            itemBuilder: (context) => [
              for (final (value, label) in codeAutonomyTiers)
                PopupMenuItem<String>(
                  value: value,
                  child: Row(
                    children: [
                      Icon(
                        value == autonomyMode ? Icons.check : null,
                        size: 15,
                        color: theme.colorScheme.onSurface,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(
                            color: theme.colorScheme.onSurface, fontSize: 13),
                      ),
                    ],
                  ),
                ),
            ],
            child: _belowRowPill(
              icon: Icons.shield_outlined,
              label: codeAutonomyLabel(autonomyMode),
            ),
          ),
      ],
    );
  }

  Widget _belowRowPill({required IconData icon, required String label}) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ext.borderColorStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: ext.iconColor),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              label,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.keyboard_arrow_down,
            size: 14,
            color: ext.iconColor,
          ),
        ],
      ),
    );
  }

  Widget _buildPlanActToggle(CodeExecutionMode mode) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    return Container(
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ext.borderColorStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in CodeExecutionMode.values)
            InkWell(
              onTap: () =>
                  ref.read(codeExecutionModeProvider.notifier).state = value,
              borderRadius: BorderRadius.circular(7),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: mode == value
                      ? ext.surfaceHighlight
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  value == CodeExecutionMode.plan ? 'Plan' : 'Act',
                  style: TextStyle(
                    color: mode == value
                        ? theme.colorScheme.onSurface
                        : ext.textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
