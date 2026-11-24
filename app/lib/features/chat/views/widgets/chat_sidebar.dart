import 'package:flutter/services.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:veraxi_app/features/chat/view_models/chat_history_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/sidebar_provider.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/core/providers/model_selection_provider.dart';
import 'package:veraxi_app/core/providers/project_view_model.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_list_item.dart';
import 'package:veraxi_app/features/chat/views/widgets/connect_repo_dialog.dart';
import 'package:veraxi_app/features/chat/views/widgets/pinned_models_widget.dart';

import 'package:veraxi_app/core/widgets/profile_menu_button.dart';

/// A consecutive sequence of sidebar threads sharing the same title and pin state.
class SidebarThreadGroup {
  final String groupKey;
  final String title;
  final List<Map<String, dynamic>> threads;

  const SidebarThreadGroup({
    required this.groupKey,
    required this.title,
    required this.threads,
  });
}

/// Resolves the display title for a sidebar thread entry.
String resolveSidebarThreadTitle(Map<String, dynamic> threadData) {
  final threadId = threadData['thread_id'] as String? ?? '';
  return threadData['title'] as String? ??
      (threadId.length > 8 ? '${threadId.substring(0, 8)}...' : threadId);
}

/// Groups consecutive sidebar threads that share the exact same resolved title
/// and pinned status without altering thread order or injecting suffixes.
List<SidebarThreadGroup> groupConsecutiveSidebarThreads(
  List<Map<String, dynamic>> threads,
) {
  final groups = <SidebarThreadGroup>[];
  for (final thread in threads) {
    final title = resolveSidebarThreadTitle(thread);
    final isPinned = thread['is_pinned'] == true;
    if (groups.isNotEmpty &&
        groups.last.title == title &&
        (groups.last.threads.first['is_pinned'] == true) == isPinned) {
      groups.last.threads.add(thread);
    } else {
      final threadId =
          thread['thread_id'] as String? ?? 'group_${groups.length}';
      groups.add(
        SidebarThreadGroup(
          groupKey: threadId,
          title: title,
          threads: [thread],
        ),
      );
    }
  }
  return groups;
}

class ChatSidebar extends ConsumerStatefulWidget {
  final bool isSidebarOpen;
  final bool isMobile;
  final bool isKnowledgeHubRoute;

  const ChatSidebar({
    super.key,
    required this.isSidebarOpen,
    required this.isMobile,
    this.isKnowledgeHubRoute = false,
  });

  @override
  ConsumerState<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends ConsumerState<ChatSidebar> {
  bool _chatsExpanded = true;
  bool _codeProjectsFilterActive = false;
  final Set<String> _expandedDuplicateGroups = {};

  static const String _sidebarToggleSvg = '''
<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <path fill-rule="evenodd" clip-rule="evenodd" d="M8.85719 3H15.1428C16.2266 2.99999 17.1007 2.99998 17.8086 3.05782C18.5375 3.11737 19.1777 3.24318 19.77 3.54497C20.7108 4.02433 21.4757 4.78924 21.955 5.73005C22.2568 6.32234 22.3826 6.96253 22.4422 7.69138C22.5 8.39925 22.5 9.27339 22.5 10.3572V13.6428C22.5 14.7266 22.5 15.6008 22.4422 16.3086C22.3826 17.0375 22.2568 17.6777 21.955 18.27C21.4757 19.2108 20.7108 19.9757 19.77 20.455C19.1777 20.7568 18.5375 20.8826 17.8086 20.9422C17.1008 21 16.2266 21 15.1428 21H8.85717C7.77339 21 6.89925 21 6.19138 20.9422C5.46253 20.8826 4.82234 20.7568 4.23005 20.455C3.28924 19.9757 2.52433 19.2108 2.04497 18.27C1.74318 17.6777 1.61737 17.0375 1.55782 16.3086C1.49998 15.6007 1.49999 14.7266 1.5 13.6428V10.3572C1.49999 9.27341 1.49998 8.39926 1.55782 7.69138C1.61737 6.96253 1.74318 6.32234 2.04497 5.73005C2.52433 4.78924 3.28924 4.02433 4.23005 3.54497C4.82234 3.24318 5.46253 3.11737 6.19138 3.05782C6.89926 2.99998 7.77341 2.99999 8.85719 3ZM6.35424 5.05118C5.74907 5.10062 5.40138 5.19279 5.13803 5.32698C4.57354 5.6146 4.1146 6.07354 3.82698 6.63803C3.69279 6.90138 3.60062 7.24907 3.55118 7.85424C3.50078 8.47108 3.5 9.26339 3.5 10.4V13.6C3.5 14.7366 3.50078 15.5289 3.55118 16.1458C3.60062 16.7509 3.69279 17.0986 3.82698 17.362C4.1146 17.9265 4.57354 18.3854 5.13803 18.673C5.40138 18.8072 5.74907 18.8994 6.35424 18.9488C6.97108 18.9992 7.76339 19 8.9 19H9.5V5H8.9C7.76339 5 6.97108 5.00078 6.35424 5.05118ZM11.5 5V19H15.1C16.2366 19 17.0289 18.9992 17.6458 18.9488C18.2509 18.8994 18.5986 18.8072 18.862 18.673C19.4265 18.3854 19.8854 17.9265 20.173 17.362C20.3072 17.0986 20.3994 16.7509 20.4488 16.1458C20.4992 15.5289 20.5 14.7366 20.5 13.6V10.4C20.5 9.26339 20.4992 8.47108 20.4488 7.85424C20.3994 7.24907 20.3072 6.90138 20.173 6.63803C19.8854 6.07354 19.4265 5.6146 18.862 5.32698C18.5986 5.19279 18.2509 5.10062 17.6458 5.05118C17.0289 5.00078 16.2366 5 15.1 5H11.5ZM5 8.5C5 7.94772 5.44772 7.5 6 7.5H7C7.55229 7.5 8 7.94772 8 8.5C8 9.05229 7.55229 9.5 7 9.5H6C5.44772 9.5 5 9.05229 5 8.5ZM5 12C5 11.4477 5.44772 11 6 11H7C7.55229 11 8 11.4477 8 12C8 12.5523 7.55229 13 7 13H6C5.44772 13 5 12.5523 5 12Z" fill="currentColor"/>
</svg>
''';

  Widget _buildSidebarToggleIcon() {
    return SvgPicture.string(
      _sidebarToggleSvg,
      width: 18,
      height: 18,
      fit: BoxFit.contain,
      colorFilter: ColorFilter.mode(
          Theme.of(context).extension<AppThemeExtension>()!.iconColor,
          BlendMode.srcIn),
    );
  }

  Widget _buildNarrowUI(BuildContext context, ChatViewModel viewModel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 20),
        Tooltip(
          message: 'Open sidebar',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                ref.read(sidebarStateProvider.notifier).state = true;
              },
              child: SizedBox(
                width: 36,
                height: 36,
                child: Center(
                  child: _buildSidebarToggleIcon(),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Tooltip(
          message: 'Projects',
          child: IconButton(
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minHeight: 34, minWidth: 34),
            icon: Icon(Icons.folder_outlined,
                color:
                    Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 18),
            onPressed: () {
              ref
                  .read(chatViewModelProvider.notifier)
                  .openAllProjectsDashboard();
              context.go('/chat');
            },
          ),
        ),
        const SizedBox(height: 12),
        Tooltip(
          message: 'New chat',
          child: IconButton(
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minHeight: 34, minWidth: 34),
            icon: Icon(Icons.edit_square,
                color:
                    Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 18),
            onPressed: () {
              if (ref.read(workspaceModeProvider) == WorkspaceMode.code) {
                ref.read(codeSubViewProvider.notifier).state =
                    CodeSubView.codeChat;
              }
              viewModel.startNewChat();
              context.go('/chat');
            },
          ),
        ),
        const SizedBox(height: 4),
        Tooltip(
          message: 'Knowledge Hub',
          child: IconButton(
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minHeight: 34, minWidth: 34),
            icon: Icon(Icons.library_books_outlined,
                color:
                    Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 18),
            onPressed: () {
              context.go('/knowledge-hub');
            },
          ),
        ),
        const Spacer(),
        ProfileMenuButton(
          onDeleteAllChats: () => viewModel.deleteAllChats(),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  PopupMenuItem<String> _buildPopupMenuItem(String title, IconData icon,
      {bool isDestructive = false}) {
    return PopupMenuItem<String>(
      value: title,
      child: Row(
        children: [
          Icon(icon,
              color: isDestructive
                  ? Colors.red
                  : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
              size: 16),
          SizedBox(width: 12),
          Text(title,
              style: TextStyle(
                  color: isDestructive ? Colors.red : const Color(0xFFE0E0E0),
                  fontSize: 13)),
        ],
      ),
    );
  }

  List<({String label, IconData icon, bool destructive})> _threadActions(
      Map<String, dynamic> threadData) {
    final isPinned = threadData['is_pinned'] == true;
    final isArchived = threadData['is_archived'] == true;
    return [
      (label: 'Share', icon: Icons.share, destructive: false),
      (
        label: isPinned ? 'Unpin' : 'Pin',
        icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
        destructive: false
      ),
      (label: 'Rename', icon: Icons.edit_outlined, destructive: false),
      (label: 'Duplicate', icon: Icons.copy_outlined, destructive: false),
      (
        label: 'Change project',
        icon: Icons.folder_outlined,
        destructive: false
      ),
      (
        label: isArchived ? 'Unarchive' : 'Archive',
        icon: isArchived ? Icons.unarchive : Icons.archive_outlined,
        destructive: false
      ),
      (label: 'Delete', icon: Icons.delete_outline, destructive: true),
    ];
  }

  List<PopupMenuEntry<String>> _threadMenuItems(
      Map<String, dynamic> threadData) {
    return _threadActions(threadData)
        .map((action) => _buildPopupMenuItem(action.label, action.icon,
            isDestructive: action.destructive))
        .toList();
  }

  Future<void> _handleThreadMenuSelection(
      BuildContext context, String value, String threadId, String title) async {
    final isCodeMode = ref.read(workspaceModeProvider) == WorkspaceMode.code;
    final viewModel = ref.read(
      (isCodeMode ? codeChatViewModelProvider : chatViewModelProvider).notifier,
    );
    if (value == 'Share') {
      _showShareDialog(context, viewModel, threadId);
    } else if (value == 'Pin' || value == 'Unpin') {
      await viewModel.togglePinThread(threadId);
    } else if (value == 'Rename') {
      _showRenameDialog(context, viewModel, threadId, title);
    } else if (value == 'Duplicate') {
      await viewModel.duplicateThread(threadId);
    } else if (value == 'Change project') {
      _showChangeProjectDialog(context, viewModel, threadId);
    } else if (value == 'Archive' || value == 'Unarchive') {
      await viewModel.toggleArchiveThread(threadId);
    } else if (value == 'Delete') {
      await viewModel.deleteThread(threadId);
    }
  }

  Future<void> _showThreadMenu(BuildContext context,
      Map<String, dynamic> threadData, String threadId, String title) async {
    if (widget.isMobile) {
      final value = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        backgroundColor:
            Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (sheetContext) {
          final actions = _threadActions(threadData);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: actions
                    .map(
                      (action) => ListTile(
                        leading: Icon(
                          action.icon,
                          color: action.destructive
                              ? Colors.red
                              : Theme.of(sheetContext)
                                  .extension<AppThemeExtension>()!
                                  .iconColor,
                        ),
                        title: Text(
                          action.label,
                          style: TextStyle(
                            color:
                                action.destructive ? Colors.red : Colors.white,
                          ),
                        ),
                        onTap: () => Navigator.of(sheetContext).pop(
                          action.label,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          );
        },
      );
      if (value != null && context.mounted) {
        await _handleThreadMenuSelection(context, value, threadId, title);
      }
      return;
    }

    final box = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight =
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      items: _threadMenuItems(threadData),
    );
    if (value != null && context.mounted) {
      await _handleThreadMenuSelection(context, value, threadId, title);
    }
  }

  void _showShareDialog(
      BuildContext context, ChatViewModel viewModel, String threadId) async {
    final shareId = await viewModel.shareThread(threadId);
    if (!context.mounted) return;

    if (shareId != null) {
      // Use standard Dart web library for host if possible, or fallback to current host pattern
      // For cross-platform support without dart:html, we can just use the current flutter web url base
      // But since we can't easily access the base URL without router config, we'll hardcode it to the
      // current app domain or localhost for now, but provide a copy button.
      // Better: Use Uri.base from dart:core
      final baseUrl = Uri.base.origin;
      final url = '$baseUrl/#/share/$shareId';

      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: Theme.of(context)
                .extension<AppThemeExtension>()!
                .cardBackground,
            title: Text('Share Link',
                style: TextStyle(color: Colors.white, fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Anyone with this link can view the shared conversation.',
                    style: TextStyle(
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .iconColor,
                        fontSize: 13)),
                SizedBox(height: 16),
                Container(
                  padding:
                      EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .borderColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          url,
                          style: TextStyle(color: Colors.white, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.copy,
                            size: 18,
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .iconColor),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: url));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Link copied to clipboard',
                                  style: TextStyle(color: Colors.white)),
                              backgroundColor: Color(0xFF4CAF50),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Close',
                    style: TextStyle(
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .iconColor)),
              ),
            ],
          );
        },
      );
    }
  }

  void _showRenameDialog(BuildContext context, ChatViewModel viewModel,
      String threadId, String currentTitle) {
    final controller = TextEditingController(text: currentTitle);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor:
              Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          title: Text('Rename Chat',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: TextField(
            controller: controller,
            style: TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter new title',
              hintStyle: TextStyle(color: Color(0xFF6E6E6E)),
              enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                      color: Theme.of(context)
                          .extension<AppThemeExtension>()!
                          .borderColor)),
              focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF3A3A3A))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context)
                          .extension<AppThemeExtension>()!
                          .iconColor)),
            ),
            TextButton(
              onPressed: () async {
                final newTitle = controller.text.trim();
                if (newTitle.isNotEmpty) {
                  await viewModel.renameThread(threadId, newTitle);
                }
                if (context.mounted) Navigator.pop(context);
              },
              child: Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showChangeProjectDialog(
      BuildContext context, ChatViewModel viewModel, String threadId) async {
    final projectState = ref.read(projectViewModelProvider);
    final projects = projectState.projects;
    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor:
              Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          title: Text('Assign Project',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: SizedBox(
            width: 300,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: projects.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return ListTile(
                    title: Text('No Project',
                        style: TextStyle(color: Colors.white)),
                    onTap: () async {
                      await ref
                          .read(chatHistoryProvider.notifier)
                          .assignThreadToProject(threadId, null);
                      if (context.mounted) Navigator.pop(context);
                    },
                  );
                }
                final project = projects[index - 1];
                return ListTile(
                  title: Text(project['name'] as String,
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    await ref
                        .read(chatHistoryProvider.notifier)
                        .assignThreadToProject(
                            threadId, project['id'] as String);
                    if (context.mounted) Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Close',
                  style: TextStyle(
                      color: Theme.of(context)
                          .extension<AppThemeExtension>()!
                          .iconColor)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildThreadGroup(
    BuildContext context,
    SidebarThreadGroup group,
    ChatState state,
    ChatViewModel viewModel,
  ) {
    if (group.threads.length == 1) {
      return _buildThreadRow(context, group.threads.first, state, viewModel);
    }
    final hasSelectedChild = group.threads
        .skip(1)
        .any((t) => (t['thread_id'] as String? ?? '') == state.threadId);
    final isExpanded =
        _expandedDuplicateGroups.contains(group.groupKey) || hasSelectedChild;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildThreadRow(
          context,
          group.threads.first,
          state,
          viewModel,
          duplicateCount: group.threads.length,
          isGroupExpanded: isExpanded,
          groupKey: group.groupKey,
          onToggleGroup: () => setState(() {
            if (_expandedDuplicateGroups.contains(group.groupKey)) {
              _expandedDuplicateGroups.remove(group.groupKey);
            } else {
              _expandedDuplicateGroups.add(group.groupKey);
            }
          }),
        ),
        if (isExpanded)
          for (final childThread in group.threads.skip(1))
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: _buildThreadRow(context, childThread, state, viewModel),
            ),
      ],
    );
  }

  Widget _buildThreadRow(
    BuildContext context,
    Map<String, dynamic> threadData,
    ChatState state,
    ChatViewModel viewModel, {
    int? duplicateCount,
    bool isGroupExpanded = false,
    String? groupKey,
    VoidCallback? onToggleGroup,
  }) {
    final threadId = threadData['thread_id'] as String? ?? '';
    final title = resolveSidebarThreadTitle(threadData);
    final isPinned = threadData['is_pinned'] == true;
    final isSelected = state.threadId == threadId;
    var isHovered = false;

    return StatefulBuilder(
      builder: (context, setRowState) {
        final ext = Theme.of(context).extension<AppThemeExtension>()!;
        return MouseRegion(
          onEnter: (_) => setRowState(() => isHovered = true),
          onExit: (_) => setRowState(() => isHovered = false),
          child: InkWell(
            onTap: () {
              viewModel.selectThread(threadId);
              context.go('/chat');
              if (widget.isMobile && context.mounted) {
                Navigator.of(context).pop();
              }
            },
            onLongPress: widget.isMobile
                ? () => _showThreadMenu(context, threadData, threadId, title)
                : null,
            child: Container(
              decoration: BoxDecoration(
                color: isSelected ? ext.borderColor : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              padding:
                  const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
              child: Row(
                children: [
                  if (isPinned)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.push_pin,
                        size: 12,
                        color: ext.iconColor,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: isSelected ? Colors.white : ext.iconColor,
                        fontSize: 13,
                        fontWeight:
                            isSelected ? FontWeight.w500 : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (duplicateCount != null && duplicateCount > 1) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: isGroupExpanded
                          ? 'Collapse duplicate threads'
                          : 'Show $duplicateCount threads',
                      child: GestureDetector(
                        key: Key('duplicate-group-toggle-$groupKey'),
                        onTap: onToggleGroup,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF262626),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '×$duplicateCount',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF9E9E9E),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  Visibility(
                    visible: !widget.isMobile && (isHovered || isSelected),
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        hoverColor: Colors.transparent,
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                      ),
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_horiz,
                            color: isSelected ? Colors.white : ext.iconColor,
                            size: 16,
                          ),
                          color: ext.borderColor,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          padding: EdgeInsets.zero,
                          itemBuilder: (_) => _threadMenuItems(threadData),
                          onSelected: (value) => _handleThreadMenuSelection(
                            context,
                            value,
                            threadId,
                            title,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget build(BuildContext context) {
    // We override references to variables that used to be class members

    // In original code, these methods might be defined before _buildSidebarContent, but we moved them to this class.
    return _buildSidebarContentActual(context);
  }

  void _goSafe(BuildContext context, String location) {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go(location);
    }
  }

  Widget _buildModeSwitcher(
    BuildContext context,
    WorkspaceMode mode,
    int kevCount,
  ) {
    final isChat = mode == WorkspaceMode.chat;
    final isCode = mode == WorkspaceMode.code;
    // Code Mode rail (§3.2) uses the slim 26px switcher with a 22px
    // active pill; Chat Mode keeps its existing 34px switcher.
    final slim = isCode;

    return Container(
      height: slim ? 26 : 34,
      padding: EdgeInsets.all(slim ? 2 : 3),
      decoration: BoxDecoration(
        color: const Color(0xFF111113),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFF2B2B2E)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _modeSegment(
              label: 'Chat',
              icon: Icons.chat_bubble_outline,
              active: isChat,
              slim: slim,
              showDot: false,
              onTap: () {
                ref.read(workspaceModeProvider.notifier).state =
                    WorkspaceMode.chat;
                if (widget.isKnowledgeHubRoute) {
                  _goSafe(context, '/chat');
                }
              },
            ),
          ),
          Expanded(
            child: _modeSegment(
              label: 'Code',
              icon: Icons.code,
              active: isCode,
              slim: slim,
              showDot: kevCount > 0 && !isCode,
              onTap: () {
                ref.read(workspaceModeProvider.notifier).state =
                    WorkspaceMode.code;
                ref.read(codeSubViewProvider.notifier).state =
                    CodeSubView.codeChat;
                if (widget.isKnowledgeHubRoute) {
                  _goSafe(context, '/chat');
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeSegment({
    required String label,
    required IconData icon,
    required bool active,
    required bool showDot,
    required VoidCallback onTap,
    bool slim = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: slim ? 22 : null,
          decoration: BoxDecoration(
            color: active ? const Color(0xFF27272B) : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: active
                ? Border.all(color: const Color(0xFF3A3A40), width: 0.8)
                : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 14,
                    color: active ? Colors.white : const Color(0xFF9CA3AF),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: active ? Colors.white : const Color(0xFFA1A1AA),
                      fontSize: slim ? 11.5 : 12.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
              if (showDot)
                Positioned(
                  right: 10,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFFEF4444),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 16x13 collapse glyph used by the Code Mode rail (§3.2): a small
  /// rounded panel outline with a left rail divider, matching the SVG
  /// contract instead of the 18px Chat toggle.
  Widget _buildCodeCollapseIcon() {
    return SizedBox(
      width: 16,
      height: 13,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF71717A), width: 1.2),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const Positioned(
            left: 5,
            top: 0,
            bottom: 0,
            child: SizedBox(
              width: 1.2,
              child: ColoredBox(color: Color(0xFF71717A)),
            ),
          ),
        ],
      ),
    );
  }

  /// Nav row used by the Code Mode rail, matching Chat Mode row thickness.
  Widget _buildCodeNavRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool selected = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF26262A) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected
                    ? Colors.white
                    : Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .iconColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? Colors.white : const Color(0xFFE0E0E0),
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Code threads (from the shared thread list) scoped to [repoKey].
  List<Map<String, dynamic>> _codeThreadsForRepo(
    ChatState state,
    String repoKey,
  ) {
    return state.pastThreads
        .where((t) =>
            t['workspace_mode'] == 'code' &&
            t['repo_key'] == repoKey &&
            t['is_archived'] != true)
        .toList();
  }

  /// Code threads without a matching indexed repo (Scratchpad threads).
  List<Map<String, dynamic>> _scratchpadCodeThreads(
    ChatState state,
    List<IndexedRepoItem> indexedRepos,
  ) {
    final indexedKeys = {for (final r in indexedRepos) r.repoKey};
    return state.pastThreads
        .where((t) =>
            t['workspace_mode'] == 'code' &&
            t['is_archived'] != true &&
            (t['repo_key'] == null || !indexedKeys.contains(t['repo_key'])))
        .toList();
  }

  void _startScratchpadCodeThread() {
    final viewModel = ref.read(codeChatViewModelProvider.notifier);
    ref.read(selectedIndexedRepoProvider.notifier).state = null;
    final sources = ref.read(codeSelectedSourcesProvider);
    ref.read(codeSelectedSourcesProvider.notifier).state =
        sources.copyWith(repoKeys: const {});
    ref.read(workspaceModeProvider.notifier).state = WorkspaceMode.code;
    ref.read(codeSubViewProvider.notifier).state = CodeSubView.codeChat;
    viewModel.startNewChat();
    _goSafe(context, '/chat');
  }

  void _startCodeThreadForRepo(IndexedRepoItem repo) {
    final viewModel = ref.read(codeChatViewModelProvider.notifier);
    ref.read(selectedIndexedRepoProvider.notifier).state = repo.repoKey;
    ref.read(codeSelectedSourcesProvider.notifier).state =
        CodeSelectedSources(repoKeys: {repo.repoKey});
    ref.read(workspaceModeProvider.notifier).state = WorkspaceMode.code;
    ref.read(codeSubViewProvider.notifier).state = CodeSubView.codeChat;
    viewModel.startNewChat();
    _goSafe(context, '/chat');
  }

  void _handleRepoMenuAction(String action, IndexedRepoItem repo) {
    if (action == 'Re-index') {
      // No repo-level re-index action is reachable from the chat
      // feature (import_lint forbids the knowledge_hub view model);
      // Repo X-Ray owns the live Re-index button, so route there with
      // this repo selected.
      ref.read(selectedIndexedRepoProvider.notifier).state = repo.repoKey;
      ref.read(codeSubViewProvider.notifier).state = CodeSubView.repoXray;
      _goSafe(context, '/chat');
    } else if (action == 'Open in Knowledge Hub') {
      ref.read(selectedIndexedRepoProvider.notifier).state = repo.repoKey;
      _goSafe(context, '/knowledge-hub');
    } else if (action == 'Remove') {
      // Local removal from the sidebar list only — there is no
      // un-index endpoint wired into this surface yet.
      ref.read(indexedReposProvider.notifier).state = ref
          .read(indexedReposProvider)
          .where((r) => r.repoKey != repo.repoKey)
          .toList();
      if (ref.read(selectedIndexedRepoProvider) == repo.repoKey) {
        ref.read(selectedIndexedRepoProvider.notifier).state = null;
      }
    }
  }

  Widget _buildCodeSidebarSection(
    BuildContext context,
    ChatState state,
    ChatViewModel viewModel,
  ) {
    final indexedRepos = ref.watch(indexedReposProvider);
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);
    final scratchpadThreads = _scratchpadCodeThreads(state, indexedRepos);

    final visibleRepos = _codeProjectsFilterActive
        ? indexedRepos
            .where((r) => _codeThreadsForRepo(state, r.repoKey).isNotEmpty)
            .toList()
        : indexedRepos;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              'Projects',
              style: TextStyle(
                color: Color(0xFF71717A),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            const Spacer(),
            Tooltip(
              message: _codeProjectsFilterActive
                  ? 'Show all repos'
                  : 'Show only repos with Code threads',
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: () => setState(() =>
                    _codeProjectsFilterActive = !_codeProjectsFilterActive),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    Icons.filter_list,
                    size: 14,
                    color: _codeProjectsFilterActive
                        ? Colors.white
                        : const Color(0xFF71717A),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Add Repo',
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: () {
                  ref.read(codeSubViewProvider.notifier).state =
                      CodeSubView.repoXray;
                  _goSafe(context, '/chat');
                },
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(
                    Icons.create_new_folder_outlined,
                    size: 14,
                    color: Color(0xFF71717A),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              if (visibleRepos.isEmpty)
                Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(7),
                      onTap: () => showConnectRepoDialog(context),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'No repos indexed yet',
                              style: TextStyle(
                                  color: Color(0xFF71717A), fontSize: 12),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '+ Connect a repo →',
                              style: TextStyle(
                                  color: Color(0xFF34D399), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              else
                for (final repo in visibleRepos) ...[
                  _RepoGroupRow(
                    key: ValueKey(repo.repoKey),
                    repo: repo,
                    threads: _codeThreadsForRepo(state, repo.repoKey),
                    selected: selectedRepo == repo.repoKey,
                    initiallyExpanded: selectedRepo == repo.repoKey ||
                        (visibleRepos.length == 1 && scratchpadThreads.isEmpty),
                    selectedThreadId: state.threadId,
                    onSelectRepo: () {
                      ref.read(selectedIndexedRepoProvider.notifier).state =
                          repo.repoKey;
                      ref.read(codeSubViewProvider.notifier).state =
                          CodeSubView.codeChat;
                      _goSafe(context, '/chat');
                    },
                    onNewThread: () => _startCodeThreadForRepo(repo),
                    onMenuAction: (action) =>
                        _handleRepoMenuAction(action, repo),
                    onSelectThread: (threadId) {
                      ref.read(selectedIndexedRepoProvider.notifier).state =
                          repo.repoKey;
                      ref.read(codeSubViewProvider.notifier).state =
                          CodeSubView.codeChat;
                      viewModel.selectThread(threadId);
                      _goSafe(context, '/chat');
                      if (widget.isMobile) {
                        Navigator.of(context).pop();
                      }
                    },
                  ),
                  const SizedBox(height: 6),
                ],
              const SizedBox(height: 12),
              _buildCodeConversationsSection(
                context: context,
                threads: scratchpadThreads,
                selectedThreadId: state.threadId,
                viewModel: viewModel,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCodeConversationsSection({
    required BuildContext context,
    required List<Map<String, dynamic>> threads,
    required String? selectedThreadId,
    required ChatViewModel viewModel,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Conversations',
                  style: TextStyle(
                    color: Color(0xFF8E8E93),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                key: const Key('code-conversations-new-button'),
                tooltip: 'New conversation',
                icon: const Icon(Icons.add, size: 15),
                color: const Color(0xFF8E8E93),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: _startScratchpadCodeThread,
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        if (threads.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(
              'No conversations yet',
              style: TextStyle(color: Color(0xFF71717A), fontSize: 11.5),
            ),
          )
        else
          for (final thread in threads)
            _buildCodeConversationRow(
              context: context,
              thread: thread,
              isSelected: selectedThreadId != null &&
                  selectedThreadId == thread['thread_id'],
              onTap: () {
                final threadId = thread['thread_id'] as String?;
                if (threadId == null || threadId.isEmpty) return;
                ref.read(selectedIndexedRepoProvider.notifier).state = null;
                ref.read(codeSubViewProvider.notifier).state =
                    CodeSubView.codeChat;
                viewModel.selectThread(threadId);
                _goSafe(context, '/chat');
                if (widget.isMobile) {
                  Navigator.of(context).pop();
                }
              },
            ),
      ],
    );
  }

  Widget _buildCodeConversationRow({
    required BuildContext context,
    required Map<String, dynamic> thread,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final title = (thread['title'] as String?)?.trim();
    final label = (title == null || title.isEmpty) ? 'New conversation' : title;
    final age = _formatThreadAge(thread['updated_at'] ?? thread['created_at']);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1C1F26) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected
                      ? const Color(0xFFF4F4F5)
                      : const Color(0xFFD4D4D8),
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ),
            if (age.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                age,
                style: const TextStyle(
                  color: Color(0xFF71717A),
                  fontSize: 10.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatThreadAge(dynamic rawTimestamp) {
    if (rawTimestamp is! String || rawTimestamp.isEmpty) return '';
    final parsed = DateTime.tryParse(rawTimestamp);
    if (parsed == null) return '';
    final diff = DateTime.now().difference(parsed.toLocal());
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  Widget _buildIngestionQueueSidebarSection(List<IngestionQueueItem> queue) {
    final item = queue.first;
    final pct = (item.progress * 100).clamp(0, 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'INGESTION QUEUE',
          style: TextStyle(
            color: Color(0xFF8E8E93),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF1F1F23),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF2E2E34)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.source,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFF4F4F5),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                pct > 0 ? '${item.stage} · $pct%' : item.stage,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF34D399),
                  fontSize: 10.5,
                ),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: item.progress > 0 ? item.progress : null,
                  minHeight: 4,
                  backgroundColor: const Color(0xFF2A2A2F),
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Color(0xFF10B981)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Divider(color: Color(0xFF262629), height: 1),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildSidebarContentActual(BuildContext context) {
    final workspaceMode = ref.watch(workspaceModeProvider);
    final isCodeRail = workspaceMode == WorkspaceMode.code;
    final activeChatProvider =
        isCodeRail ? codeChatViewModelProvider : chatViewModelProvider;
    final state = ref.watch(activeChatProvider);
    final viewModel = ref.read(activeChatProvider.notifier);
    final modelSelection = ref.watch(modelSelectionProvider);
    final kevCount = ref.watch(activeKevCountProvider);
    final ingestionQueue = ref.watch(ingestionQueueProvider);
    final isSidebarOpen = widget.isSidebarOpen;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      width: isSidebarOpen ? (widget.isMobile ? double.infinity : 260) : 64,
      color:
          Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              width: 64,
              child: AnimatedOpacity(
                opacity: isSidebarOpen ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 150),
                child: IgnorePointer(
                  ignoring: isSidebarOpen,
                  child: _buildNarrowUI(context, viewModel),
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              right: widget.isMobile ? 0 : null,
              width: widget.isMobile ? null : 260,
              child: AnimatedOpacity(
                opacity: isSidebarOpen ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: IgnorePointer(
                  ignoring: !isSidebarOpen,
                  child: Container(
                    width: widget.isMobile ? double.infinity : 260,
                    padding: EdgeInsets.only(
                        top: widget.isMobile ? 48 : 20,
                        bottom: 20,
                        left: 20,
                        right: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 28,
                          width: double.infinity,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text(
                                'Veraxi',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Tooltip(
                                message: 'Close sidebar',
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () {
                                      if (widget.isMobile) {
                                        Navigator.of(context).pop();
                                      } else {
                                        ref
                                            .read(sidebarStateProvider.notifier)
                                            .state = false;
                                      }
                                    },
                                    child: SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: Center(
                                          child: widget.isMobile
                                              ? const Icon(Icons.close,
                                                  color: Color(0xFFB4B4B4),
                                                  size: 20)
                                              : isCodeRail
                                                  ? _buildCodeCollapseIcon()
                                                  : _buildSidebarToggleIcon()),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildModeSwitcher(context, workspaceMode, kevCount),
                        const SizedBox(height: 14),
                        if (isCodeRail) ...[
                          _buildCodeNavRow(
                            icon: Icons.library_books_outlined,
                            label: 'Knowledge Hub',
                            selected: widget.isKnowledgeHubRoute,
                            onTap: () => _goSafe(context, '/knowledge-hub'),
                          ),
                          const SizedBox(height: 4),
                          _buildCodeNavRow(
                            icon: Icons.shield_outlined,
                            label: 'Security',
                            selected: !widget.isKnowledgeHubRoute &&
                                ref.watch(codeSubViewProvider) ==
                                    CodeSubView.vulnIntel,
                            onTap: () {
                              ref.read(codeSubViewProvider.notifier).state =
                                  CodeSubView.vulnIntel;
                              _goSafe(context, '/chat');
                            },
                          ),
                          if (widget.isKnowledgeHubRoute &&
                              ingestionQueue.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildIngestionQueueSidebarSection(ingestionQueue),
                          ],
                          const SizedBox(height: 10),
                          Divider(
                              color: Theme.of(context)
                                  .extension<AppThemeExtension>()!
                                  .borderColor,
                              height: 1),
                          const SizedBox(height: 12),
                        ],
                        if (workspaceMode == WorkspaceMode.chat &&
                            !widget.isKnowledgeHubRoute)
                          PinnedModelsWidget(
                            pinnedModels: modelSelection.pinnedModels.toList(),
                            selectedModel: modelSelection.selectedModel,
                            onModelSelected: (model, provider) {
                              ref
                                  .read(modelSelectionProvider.notifier)
                                  .selectModel(model, provider: provider);
                            },
                            onModelUnpinned: (model) {
                              ref
                                  .read(modelSelectionProvider.notifier)
                                  .unpinModel(model);
                            },
                          ),
                        if (!isCodeRail)
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                ref.read(workspaceModeProvider.notifier).state =
                                    WorkspaceMode.chat;
                                viewModel.openAllProjectsDashboard();
                                _goSafe(context, '/chat');
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(Icons.folder_outlined,
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .iconColor,
                                        size: 18),
                                    const SizedBox(width: 12),
                                    const Expanded(
                                      child: Text(
                                        'Projects',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Color(0xFFE0E0E0),
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (workspaceMode == WorkspaceMode.chat &&
                            !widget.isKnowledgeHubRoute) ...[
                          const SizedBox(height: 4),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                viewModel.startNewChat();
                                _goSafe(context, '/chat');
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(Icons.edit_square,
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .iconColor,
                                        size: 18),
                                    const SizedBox(width: 12),
                                    const Expanded(
                                      child: Text(
                                        'New chat',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Color(0xFFE0E0E0),
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        if (!isCodeRail)
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                _goSafe(context, '/knowledge-hub');
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: widget.isKnowledgeHubRoute
                                      ? const Color(0xFF26262A)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(Icons.library_books_outlined,
                                        color: widget.isKnowledgeHubRoute
                                            ? Colors.white
                                            : Theme.of(context)
                                                .extension<AppThemeExtension>()!
                                                .iconColor,
                                        size: 18),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        'Knowledge Hub',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: widget.isKnowledgeHubRoute
                                              ? Colors.white
                                              : const Color(0xFFE0E0E0),
                                          fontSize: 14,
                                          fontWeight: widget.isKnowledgeHubRoute
                                              ? FontWeight.w600
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        if (isCodeRail) ...[
                          Expanded(
                            child: _buildCodeSidebarSection(
                                context, state, viewModel),
                          ),
                        ] else ...[
                          if (widget.isKnowledgeHubRoute &&
                              ingestionQueue.isNotEmpty)
                            _buildIngestionQueueSidebarSection(ingestionQueue),
                          InkWell(
                            onTap: () => setState(
                                () => _chatsExpanded = !_chatsExpanded),
                            child: Row(
                              children: [
                                Text('Chats',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .extension<AppThemeExtension>()!
                                            .textTertiary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(width: 4),
                                Icon(
                                    _chatsExpanded
                                        ? Icons.keyboard_arrow_down
                                        : Icons.keyboard_arrow_right,
                                    color: Theme.of(context)
                                        .extension<AppThemeExtension>()!
                                        .textTertiary,
                                    size: 16),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: !_chatsExpanded
                                ? const SizedBox.shrink()
                                : Builder(
                                    builder: (context) {
                                      if (state.isLoadingThreads) {
                                        return Center(
                                          child: Padding(
                                            padding: EdgeInsets.only(top: 24.0),
                                            child: CupertinoActivityIndicator(
                                                radius: 10),
                                          ),
                                        );
                                      }

                                      final timelineChats = state.pastThreads
                                          .where((t) =>
                                              t['is_archived'] != true &&
                                              t['workspace_mode'] != 'code')
                                          .toList();
                                      if (timelineChats.isEmpty) {
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                              left: 8.0, top: 4.0),
                                          child: Text(
                                            'No conversations yet',
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .extension<
                                                      AppThemeExtension>()!
                                                  .textTertiary,
                                              fontSize: 12,
                                            ),
                                          ),
                                        );
                                      }

                                      final groups =
                                          groupConsecutiveSidebarThreads(
                                        timelineChats,
                                      );
                                      return ListView.builder(
                                        itemCount: groups.length,
                                        itemBuilder: (context, index) =>
                                            _buildThreadGroup(
                                          context,
                                          groups[index],
                                          state,
                                          viewModel,
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            ProfileMenuButton(
                              onDeleteAllChats: () =>
                                  viewModel.deleteAllChats(),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                resolveDisplayName(),
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Parses a Code thread's activity time from the thread list entry.
/// The list payload has carried several key spellings over time
/// (`updated_at`, `timestamp`, `created_at`), as ISO strings or epoch
/// numbers; anything unrecognised yields null and the row simply
/// shows no time label rather than a fabricated one.
DateTime? parseCodeThreadTime(Map<String, dynamic> thread) {
  for (final key in ['updated_at', 'timestamp', 'created_at', '_timestamp']) {
    final raw = thread[key];
    if (raw is num && raw > 0) {
      final ms = raw > 1e12 ? raw.toInt() : (raw * 1000).toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (raw is String && raw.isNotEmpty) {
      final epoch = num.tryParse(raw);
      if (epoch != null && epoch > 0) {
        final ms = epoch > 1e12 ? epoch.toInt() : (epoch * 1000).toInt();
        return DateTime.fromMillisecondsSinceEpoch(ms);
      }
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

/// Compact relative label (`2m`, `1h`, `1d`) for a Code thread row,
/// reusing [formatRelativeTimestamp] without its ` ago` suffix.
String codeThreadTimeLabel(Map<String, dynamic> thread) {
  final time = parseCodeThreadTime(thread);
  if (time == null) return '';
  return formatRelativeTimestamp(time).replaceAll(' ago', '');
}

/// Collapsible repo group in the Code Mode rail (§3.2): a folder row
/// for one [IndexedRepoItem] with hover-revealed `⋮` / `+` actions,
/// and its slim single-line Code threads underneath.
class _RepoGroupRow extends StatefulWidget {
  final IndexedRepoItem repo;
  final List<Map<String, dynamic>> threads;
  final bool selected;
  final bool initiallyExpanded;
  final String? selectedThreadId;
  final VoidCallback onSelectRepo;
  final VoidCallback onNewThread;
  final ValueChanged<String>? onMenuAction;
  final ValueChanged<String> onSelectThread;

  const _RepoGroupRow({
    super.key,
    required this.repo,
    required this.threads,
    required this.selected,
    this.initiallyExpanded = false,
    required this.selectedThreadId,
    required this.onSelectRepo,
    required this.onNewThread,
    this.onMenuAction,
    required this.onSelectThread,
  });

  @override
  State<_RepoGroupRow> createState() => _RepoGroupRowState();
}

class _RepoGroupRowState extends State<_RepoGroupRow> {
  late bool _expanded;
  bool _showAll = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  Widget _buildThreadRow(Map<String, dynamic> thread) {
    final threadId = thread['thread_id'] as String? ?? '';
    final isSelected = widget.selectedThreadId == threadId;
    final timeLabel = codeThreadTimeLabel(thread);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => widget.onSelectThread(threadId),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1C1F26) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                resolveSidebarThreadTitle(thread),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected
                      ? const Color(0xFFF4F4F5)
                      : const Color(0xFFD4D4D8),
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ),
            if (timeLabel.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                timeLabel,
                style:
                    const TextStyle(color: Color(0xFF71717A), fontSize: 10.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleThreads =
        _showAll ? widget.threads : widget.threads.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              widget.onSelectRepo();
              setState(() => _expanded = !_expanded);
            },
            child: Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: _hovered || widget.selected
                    ? const Color(0xFF16181D)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 13,
                    color: widget.selected
                        ? const Color(0xFFE4E4E7)
                        : const Color(0xFFA1A1AA),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      widget.repo.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.selected
                            ? const Color(0xFFE4E4E7)
                            : const Color(0xFFA1A1AA),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (_hovered || widget.selected) ...[
                    if (widget.onMenuAction != null)
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: PopupMenuButton<String>(
                          icon: const Icon(
                            Icons.more_vert,
                            size: 14,
                            color: Color(0xFFA1A1AA),
                          ),
                          color: Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .cardBackground,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: EdgeInsets.zero,
                          itemBuilder: (_) => const [
                            PopupMenuItem<String>(
                              value: 'Re-index',
                              child: Text('Re-index',
                                  style: TextStyle(
                                      color: Color(0xFFE4E4E7), fontSize: 13)),
                            ),
                            PopupMenuItem<String>(
                              value: 'Open in Knowledge Hub',
                              child: Text('Open in Knowledge Hub',
                                  style: TextStyle(
                                      color: Color(0xFFE4E4E7), fontSize: 13)),
                            ),
                            PopupMenuItem<String>(
                              value: 'Remove',
                              child: Text('Remove',
                                  style: TextStyle(
                                      color: Colors.red, fontSize: 13)),
                            ),
                          ],
                          onSelected: widget.onMenuAction!,
                        ),
                      ),
                    Tooltip(
                      message: 'New Code thread in this repo',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: widget.onNewThread,
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(
                            Icons.add,
                            size: 14,
                            color: Color(0xFFE4E4E7),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          for (final thread in visibleThreads)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _buildThreadRow(thread),
            ),
          if (widget.threads.length > 5 && !_showAll)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => _showAll = true),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Text(
                  'See all (${widget.threads.length})',
                  style:
                      const TextStyle(color: Color(0xFF71717A), fontSize: 11.5),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
