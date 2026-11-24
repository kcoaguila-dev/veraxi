import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/code_chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/connect_repo_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/sandbox_toggle_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/connect_repo_dialog.dart';
import 'package:veraxi_app/features/settings/views/widgets/settings_dialog.dart';

/// Connected top context strip inside the Code Thread composer card.
///
/// Renders the execution target (`Chat only` / `Cloud Sandbox`), repo
/// scope (`No repo (Scratchpad)` or indexed repo), and branch/worktree
/// selector (`main` / `main · new worktree`), each opening an
/// upward-anchored popover directly above its trigger.
class ComposerContextBar extends ConsumerWidget {
  final Widget? indexingStatusSlot;

  const ComposerContextBar({super.key, this.indexingStatusSlot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(indexedReposProvider);
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);
    final branch = ref.watch(codeBranchProvider);
    final newWorktree = ref.watch(codeWorktreeProvider);
    final sandboxEnabled = ref.watch(sandboxToggleViewModelProvider).enabled;
    final connectState = ref.watch(connectRepoViewModelProvider);
    final ext = Theme.of(context).extension<AppThemeExtension>()!;

    final activeRepo = repos.cast<IndexedRepoItem?>().firstWhere(
          (r) => r?.repoKey == selectedRepo,
          orElse: () => null,
        );
    final repoLabel = activeRepo?.displayName ?? 'No repo (Scratchpad)';
    final branchLabel = newWorktree ? '$branch · new worktree' : branch;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          _ExecutionTargetTrigger(sandboxEnabled: sandboxEnabled),
          const SizedBox(width: 8),
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: _RepoSelectorTrigger(
                    repoLabel: repoLabel,
                    hasSelectedRepo: activeRepo != null,
                    repos: repos,
                    selectedRepoKey: activeRepo?.repoKey,
                  ),
                ),
                if (repos.isEmpty) ...[
                  const SizedBox(width: 8),
                  if (indexingStatusSlot != null &&
                      (connectState.indexing ||
                          connectState.errorMessage != null))
                    indexingStatusSlot!
                  else
                    _ConnectRepoInlineButton(
                      onTap: () => showConnectRepoDialog(context),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _BranchWorktreeTrigger(
            repoName: activeRepo?.displayName ?? 'Scratchpad',
            branch: branch,
            newWorktree: newWorktree,
            label: branchLabel,
            ext: ext,
          ),
        ],
      ),
    );
  }
}

class _ConnectRepoInlineButton extends StatelessWidget {
  final VoidCallback onTap;

  const _ConnectRepoInlineButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          '+ Connect repo',
          style: TextStyle(
            color: Color(0xFF34D399),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Reusable upward-anchored popover using [OverlayPortal] and
/// [CompositedTransformFollower] so menus snap directly above their
/// trigger without floating arbitrarily.
class _AnchoredUpwardPopover extends StatefulWidget {
  final OverlayPortalController controller;
  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final Widget Function(VoidCallback open, VoidCallback close) triggerBuilder;
  final Widget Function(VoidCallback close) overlayBuilder;

  const _AnchoredUpwardPopover({
    required this.controller,
    this.targetAnchor = Alignment.topLeft,
    this.followerAnchor = Alignment.bottomLeft,
    required this.triggerBuilder,
    required this.overlayBuilder,
  });

  @override
  State<_AnchoredUpwardPopover> createState() => _AnchoredUpwardPopoverState();
}

class _AnchoredUpwardPopoverState extends State<_AnchoredUpwardPopover> {
  final LayerLink _layerLink = LayerLink();

  void _open() {
    if (!widget.controller.isShowing) {
      widget.controller.show();
    }
  }

  void _close() {
    if (widget.controller.isShowing) {
      widget.controller.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: OverlayPortal(
        controller: widget.controller,
        overlayChildBuilder: (overlayContext) {
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _close,
                  child: const SizedBox.expand(),
                ),
              ),
              CompositedTransformFollower(
                link: _layerLink,
                showWhenUnlinked: false,
                targetAnchor: widget.targetAnchor,
                followerAnchor: widget.followerAnchor,
                offset: const Offset(0, -10),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) {
                    return Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, (1 - t) * 5),
                        child: child,
                      ),
                    );
                  },
                  child: Material(
                    type: MaterialType.transparency,
                    child: widget.overlayBuilder(_close),
                  ),
                ),
              ),
            ],
          );
        },
        child: widget.triggerBuilder(_open, _close),
      ),
    );
  }
}

class _ContextTriggerPill extends StatefulWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final Color? labelColor;
  final VoidCallback onTap;

  const _ContextTriggerPill({
    required this.icon,
    this.iconColor,
    required this.label,
    this.labelColor,
    required this.onTap,
  });

  @override
  State<_ContextTriggerPill> createState() => _ContextTriggerPillState();
}

class _ContextTriggerPillState extends State<_ContextTriggerPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: _hovered
                ? ext.borderColor.withValues(alpha: 0.55)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: widget.iconColor ?? ext.iconColor,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: widget.labelColor ?? theme.colorScheme.onSurface,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down,
                size: 15,
                color: ext.iconColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PopoverSurface extends StatelessWidget {
  final double width;
  final Widget child;

  const _PopoverSurface({required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ext.borderColorStrong),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.48),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: child,
      ),
    );
  }
}

class _ExecutionTargetTrigger extends ConsumerStatefulWidget {
  final bool sandboxEnabled;

  const _ExecutionTargetTrigger({required this.sandboxEnabled});

  @override
  ConsumerState<_ExecutionTargetTrigger> createState() =>
      _ExecutionTargetTriggerState();
}

class _ExecutionTargetTriggerState
    extends ConsumerState<_ExecutionTargetTrigger> {
  final OverlayPortalController _controller = OverlayPortalController();
  bool _showSandboxSubmenu = false;

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return _AnchoredUpwardPopover(
      controller: _controller,
      triggerBuilder: (open, close) => _ContextTriggerPill(
        icon: widget.sandboxEnabled
            ? Icons.terminal_outlined
            : Icons.chat_bubble_outline,
        iconColor:
            widget.sandboxEnabled ? const Color(0xFF34D399) : ext.iconColor,
        label: widget.sandboxEnabled ? 'Cloud Sandbox' : 'Chat only',
        onTap: () {
          if (_controller.isShowing) {
            close();
          } else {
            setState(() => _showSandboxSubmenu = widget.sandboxEnabled);
            open();
          }
        },
      ),
      overlayBuilder: (close) => _buildMenu(context, close),
    );
  }

  Widget _buildMenu(BuildContext context, VoidCallback close) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _PopoverSurface(
          width: 224,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PopoverOptionRow(
                  icon: Icons.chat_bubble_outline,
                  title: 'Chat only',
                  subtitle: 'Runs without sandbox',
                  selected: !widget.sandboxEnabled,
                  onHover: () {
                    if (_showSandboxSubmenu) {
                      setState(() => _showSandboxSubmenu = false);
                    }
                  },
                  onTap: () {
                    ref
                        .read(sandboxToggleViewModelProvider.notifier)
                        .setEnabled(false);
                    close();
                  },
                ),
                Divider(height: 1, thickness: 1, color: ext.borderColor),
                _PopoverOptionRow(
                  icon: Icons.terminal_outlined,
                  iconColor: widget.sandboxEnabled
                      ? const Color(0xFF34D399)
                      : ext.iconColor,
                  title: 'Cloud Sandbox',
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: ext.iconColor,
                  ),
                  onHover: () {
                    if (!_showSandboxSubmenu) {
                      setState(() => _showSandboxSubmenu = true);
                    }
                  },
                  onTap: () {
                    ref
                        .read(sandboxToggleViewModelProvider.notifier)
                        .setEnabled(true);
                    close();
                  },
                ),
              ],
            ),
          ),
        ),
        if (_showSandboxSubmenu) ...[
          const SizedBox(width: 6),
          _PopoverSurface(
            width: 220,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PopoverOptionRow(
                    icon: Icons.terminal_outlined,
                    iconColor: const Color(0xFF34D399),
                    title: 'Use Cloud Sandbox',
                    subtitle: 'Isolated container',
                    selected: widget.sandboxEnabled,
                    onTap: () {
                      ref
                          .read(sandboxToggleViewModelProvider.notifier)
                          .setEnabled(true);
                      close();
                    },
                  ),
                  Divider(height: 1, thickness: 1, color: ext.borderColor),
                  _PopoverOptionRow(
                    icon: Icons.tune,
                    title: 'Configure Sandbox…',
                    titleColor: const Color(0xFF34D399),
                    onTap: () {
                      close();
                      showDialog<void>(
                        context: context,
                        builder: (_) =>
                            const SettingsDialog(initialTab: 'Code Sandboxes'),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _RepoSelectorTrigger extends ConsumerStatefulWidget {
  final String repoLabel;
  final bool hasSelectedRepo;
  final List<IndexedRepoItem> repos;
  final String? selectedRepoKey;

  const _RepoSelectorTrigger({
    required this.repoLabel,
    required this.hasSelectedRepo,
    required this.repos,
    required this.selectedRepoKey,
  });

  @override
  ConsumerState<_RepoSelectorTrigger> createState() =>
      _RepoSelectorTriggerState();
}

class _RepoSelectorTriggerState extends ConsumerState<_RepoSelectorTrigger> {
  final OverlayPortalController _controller = OverlayPortalController();
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return _AnchoredUpwardPopover(
      controller: _controller,
      triggerBuilder: (open, close) => _ContextTriggerPill(
        icon: Icons.folder_outlined,
        label: widget.repoLabel,
        labelColor: widget.hasSelectedRepo ? null : ext.textTertiary,
        onTap: () {
          if (_controller.isShowing) {
            close();
          } else {
            _searchController.clear();
            setState(() => _query = '');
            open();
          }
        },
      ),
      overlayBuilder: (close) => _buildMenu(context, close),
    );
  }

  void _selectRepo(String? repoKey, VoidCallback close) {
    final sources = ref.read(codeSelectedSourcesProvider);
    ref.read(selectedIndexedRepoProvider.notifier).state = repoKey;
    ref.read(codeSelectedSourcesProvider.notifier).state = sources.copyWith(
      repoKeys: repoKey == null ? const {} : {repoKey},
    );
    close();
  }

  Widget _buildMenu(BuildContext context, VoidCallback close) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    final q = _query.trim().toLowerCase();
    final filtered = widget.repos
        .where((r) => q.isEmpty || r.displayName.toLowerCase().contains(q))
        .toList();

    return _PopoverSurface(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Row(
              children: [
                Icon(Icons.search, size: 15, color: ext.textTertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    onChanged: (v) => setState(() => _query = v),
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontSize: 12.5,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search Projects',
                      hintStyle: TextStyle(
                        color: ext.textTertiary,
                        fontSize: 12.5,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: ext.borderColor),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: filtered.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.repos.isEmpty
                            ? 'No indexed repos yet'
                            : 'No matching projects',
                        style: TextStyle(
                          color: ext.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: filtered.length,
                    itemBuilder: (_, index) {
                      final repo = filtered[index];
                      return _PopoverOptionRow(
                        icon: Icons.folder_outlined,
                        title: repo.displayName,
                        selected: repo.repoKey == widget.selectedRepoKey,
                        onTap: () => _selectRepo(repo.repoKey, close),
                      );
                    },
                  ),
          ),
          Divider(height: 1, thickness: 1, color: ext.borderColor),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PopoverOptionRow(
                  icon: Icons.add_box_outlined,
                  iconColor: const Color(0xFF34D399),
                  title: 'Connect Repo',
                  titleColor: const Color(0xFF34D399),
                  onTap: () {
                    close();
                    showConnectRepoDialog(context);
                  },
                ),
                _PopoverOptionRow(
                  icon: Icons.folder_off_outlined,
                  title: 'No repo (Scratchpad)',
                  selected: widget.selectedRepoKey == null,
                  onTap: () => _selectRepo(null, close),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchWorktreeTrigger extends ConsumerStatefulWidget {
  final String repoName;
  final String branch;
  final bool newWorktree;
  final String label;
  final AppThemeExtension ext;

  const _BranchWorktreeTrigger({
    required this.repoName,
    required this.branch,
    required this.newWorktree,
    required this.label,
    required this.ext,
  });

  @override
  ConsumerState<_BranchWorktreeTrigger> createState() =>
      _BranchWorktreeTriggerState();
}

class _BranchWorktreeTriggerState
    extends ConsumerState<_BranchWorktreeTrigger> {
  final OverlayPortalController _controller = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    return _AnchoredUpwardPopover(
      controller: _controller,
      targetAnchor: Alignment.topRight,
      followerAnchor: Alignment.bottomRight,
      triggerBuilder: (open, close) => _ContextTriggerPill(
        icon: Icons.call_split,
        label: widget.label,
        onTap: () {
          if (_controller.isShowing) {
            close();
          } else {
            open();
          }
        },
      ),
      overlayBuilder: (close) => _buildMenu(context, close),
    );
  }

  Widget _buildMenu(BuildContext context, VoidCallback close) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    const branches = <String>['main'];

    return _PopoverSurface(
      width: 264,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined,
                      size: 14, color: ext.textTertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.repoName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ext.textTertiary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (final name in branches)
              _PopoverOptionRow(
                icon: Icons.call_split,
                title: name,
                selected: widget.branch == name && !widget.newWorktree,
                onTap: () {
                  ref.read(codeBranchProvider.notifier).state = name;
                  ref.read(codeWorktreeProvider.notifier).state = false;
                  close();
                },
              ),
            Divider(height: 8, thickness: 1, color: ext.borderColor),
            _PopoverOptionRow(
              icon: Icons.account_tree_outlined,
              title: 'Work in a New Worktree',
              subtitle: 'Keeps your checkout untouched',
              selected: widget.newWorktree,
              onTap: () {
                ref.read(codeWorktreeProvider.notifier).state = true;
                close();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PopoverOptionRow extends StatefulWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final bool selected;
  final Widget? trailing;
  final VoidCallback? onHover;
  final VoidCallback onTap;

  const _PopoverOptionRow({
    required this.icon,
    this.iconColor,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.selected = false,
    this.trailing,
    this.onHover,
    required this.onTap,
  });

  @override
  State<_PopoverOptionRow> createState() => _PopoverOptionRowState();
}

class _PopoverOptionRowState extends State<_PopoverOptionRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHover?.call();
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          color: _hovered
              ? ext.borderColor.withValues(alpha: 0.45)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 15,
                color: widget.iconColor ?? ext.iconColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.titleColor ?? theme.colorScheme.onSurface,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle!,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ext.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null)
                widget.trailing!
              else if (widget.selected)
                Icon(
                  Icons.check,
                  size: 15,
                  color: theme.colorScheme.onSurface,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Upward-anchored `Local Permissions` selector (`Request Review`,
/// `Default`, `Auto`, `Turbo`) placed in the composer's bottom-right
/// action row right beside the mic and send button.
class LocalPermissionsTrigger extends ConsumerStatefulWidget {
  const LocalPermissionsTrigger({super.key});

  @override
  ConsumerState<LocalPermissionsTrigger> createState() =>
      _LocalPermissionsTriggerState();
}

class _LocalPermissionsTriggerState
    extends ConsumerState<LocalPermissionsTrigger> {
  final OverlayPortalController _controller = OverlayPortalController();

  static const _tierMeta = <String, ({IconData icon, String subtitle})>{
    'ask_all': (
      icon: Icons.visibility_outlined,
      subtitle: 'Every command requires approval.',
    ),
    'auto_read_test': (
      icon: Icons.lock_outline,
      subtitle: 'Ask before sensitive operations.',
    ),
    'auto_workspace_writes': (
      icon: Icons.shield_outlined,
      subtitle: 'Automatically decide if commands run.',
    ),
    'autonomous': (
      icon: Icons.bolt_outlined,
      subtitle: 'Run all commands without restrictions.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final autonomyMode = ref.watch(codeAutonomyModeProvider);
    final label = codeAutonomyLabel(autonomyMode);
    final meta = _tierMeta[autonomyMode] ??
        (
          icon: Icons.shield_outlined,
          subtitle: 'Ask before sensitive operations.',
        );

    return _AnchoredUpwardPopover(
      controller: _controller,
      targetAnchor: Alignment.topRight,
      followerAnchor: Alignment.bottomRight,
      triggerBuilder: (open, close) => _ContextTriggerPill(
        icon: meta.icon,
        label: label,
        onTap: () {
          if (_controller.isShowing) {
            close();
          } else {
            open();
          }
        },
      ),
      overlayBuilder: (close) => _buildMenu(context, autonomyMode, close),
    );
  }

  Widget _buildMenu(
      BuildContext context, String autonomyMode, VoidCallback close) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return _PopoverSurface(
      width: 284,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              child: Text(
                'Local Permissions',
                style: TextStyle(
                  color: ext.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            for (final (value, label) in codeAutonomyTiers)
              _PopoverOptionRow(
                icon: _tierMeta[value]?.icon ?? Icons.shield_outlined,
                title: label,
                subtitle: _tierMeta[value]?.subtitle,
                selected: value == autonomyMode,
                onTap: () {
                  ref.read(codeAutonomyModeProvider.notifier).state = value;
                  close();
                },
              ),
          ],
        ),
      ),
    );
  }
}
