import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/core/providers/project_view_model.dart';
import 'package:veraxi_app/features/project/views/widgets/create_project_dialog.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class ProjectListWidget extends ConsumerStatefulWidget {
  final ChatState chatState;
  final ChatViewModel chatViewModel;
  final ProjectState projectState;
  final ProjectViewModel projectViewModel;
  final Function(BuildContext, ChatViewModel, String) showShareDialog;
  final Function(BuildContext, ChatViewModel, String, String) showRenameDialog;
  final Function(BuildContext, ChatViewModel, String) showChangeProjectDialog;

  const ProjectListWidget({
    super.key,
    required this.chatState,
    required this.chatViewModel,
    required this.projectState,
    required this.projectViewModel,
    required this.showShareDialog,
    required this.showRenameDialog,
    required this.showChangeProjectDialog,
  });

  @override
  ConsumerState<ProjectListWidget> createState() => _ProjectListWidgetState();
}

class _ProjectListWidgetState extends ConsumerState<ProjectListWidget> {
  bool _projectsListExpanded = false;
  final Set<String> _expandedProjects = {};

  PopupMenuItem<String> _buildPopupMenuItem(String title, IconData icon,
      {bool isDestructive = false}) {
    return PopupMenuItem<String>(
      value: title,
      child: Row(
        children: [
          Icon(icon,
              color: isDestructive ? Colors.red : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
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

  void _showRenameProjectDialog(BuildContext context, String projectId,
      String currentName, ProjectViewModel viewModel) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          title: Text('Rename Project',
              style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            style: TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Project Name',
              hintStyle: TextStyle(color: Colors.grey),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.grey)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  viewModel.renameProject(projectId, controller.text);
                  Navigator.pop(context);
                }
              },
              child: Text('Save', style: TextStyle(color: Colors.blue)),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteProjectDialog(BuildContext context, String projectId,
      String projectName, ProjectViewModel viewModel) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          title: Text('Delete Project',
              style: TextStyle(color: Colors.white)),
          content: Text(
              'Are you sure you want to delete the project "$projectName"? This action cannot be undone.',
              style: TextStyle(color: Colors.white)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                viewModel.deleteProject(projectId);
                Navigator.pop(context);
              },
              child: Text('Delete',
                  style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            InkWell(
              onTap: () =>
                  setState(() => _projectsListExpanded = !_projectsListExpanded),
              child: Row(
                children: [
                  Text('Projects',
                      style: TextStyle(
                          color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  SizedBox(width: 4),
                  Icon(
                      _projectsListExpanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                      size: 16),
                ],
              ),
            ),
            Row(
              children: [
                Tooltip(
                  message: 'All Projects',
                  child: InkWell(
                    onTap: () => widget.projectViewModel.openAllProjectsDashboard(),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: EdgeInsets.all(4.0),
                      child: Icon(LucideIcons.folder,
                          color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, size: 16),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Tooltip(
                  message: 'New Project',
                  child: InkWell(
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (context) => const CreateProjectDialog(),
                      );
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: EdgeInsets.all(4.0),
                      child: Icon(LucideIcons.folderPlus,
                          color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, size: 16),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        SizedBox(height: 8),
        if (widget.projectState.projects.isNotEmpty && _projectsListExpanded)
          Column(
            children: widget.projectState.projects.map((project) {
              final projectId = project['id'] as String;
              final projectName = project['name'] as String;
              final isActive = widget.projectState.activeProjectId == projectId;
              final isExpanded = _expandedProjects.contains(projectId);

              final projectThreads = widget.chatState.pastThreads
                  .where((t) =>
                      t['project_id'] == projectId &&
                      t['is_archived'] != true)
                  .toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  (() {
                    bool isHovered = false;
                    return StatefulBuilder(
                      builder: (context, setHoverState) {
                        return MouseRegion(
                          onEnter: (_) => setHoverState(() => isHovered = true),
                          onExit: (_) => setHoverState(() => isHovered = false),
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                if (isExpanded) {
                                  _expandedProjects.remove(projectId);
                                } else {
                                  _expandedProjects.add(projectId);
                                }
                              });
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 8),
                              decoration: BoxDecoration(
                                color: (isActive || isHovered)
                                    ? Theme.of(context).extension<AppThemeExtension>()!.borderColor
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                children: [
                                  Padding(
                                    padding: EdgeInsets.all(4.0),
                                    child: Icon(
                                      isExpanded
                                          ? Icons.keyboard_arrow_down
                                          : Icons.keyboard_arrow_right,
                                      color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                                      size: 16,
                                    ),
                                  ),
                                  SizedBox(width: 4),
                                  Icon(
                                    LucideIcons.folder,
                                    color: isActive
                                        ? Colors.white
                                        : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                                    size: 16,
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      projectName,
                                      style: TextStyle(
                                        color: isActive
                                            ? Colors.white
                                            : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                                        fontSize: 13,
                                        fontWeight: isActive
                                            ? FontWeight.w500
                                            : FontWeight.normal,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Visibility(
                                    visible: isHovered || isActive,
                                    maintainSize: true,
                                    maintainAnimation: true,
                                    maintainState: true,
                                    child: Row(
                                      children: [
                                        InkWell(
                                          onTap: () => widget.chatViewModel
                                              .startNewChatInProject(projectId),
                                          borderRadius: BorderRadius.circular(4),
                                          child: Padding(
                                            padding: EdgeInsets.all(4.0),
                                            child: Icon(Icons.edit_square,
                                                color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                                                size: 14),
                                          ),
                                        ),
                                        SizedBox(width: 2),
                                        Theme(
                                          data: Theme.of(context).copyWith(
                                            hoverColor: Colors.transparent,
                                            splashColor: Colors.transparent,
                                            highlightColor: Colors.transparent,
                                          ),
                                          child: PopupMenuButton<String>(
                                            padding: EdgeInsets.zero,
                                            icon: Icon(Icons.more_horiz,
                                                color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                                                size: 14),
                                            color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8)),
                                            offset: const Offset(0, 30),
                                            onSelected: (value) {
                                              if (value == 'open') {
                                                widget.projectViewModel
                                                    .selectProject(
                                                        projectId, projectName);
                                              } else if (value == 'rename') {
                                                _showRenameProjectDialog(
                                                    context,
                                                    projectId,
                                                    projectName,
                                                    widget.projectViewModel);
                                              } else if (value == 'delete') {
                                                _showDeleteProjectDialog(
                                                    context,
                                                    projectId,
                                                    projectName,
                                                    widget.projectViewModel);
                                              }
                                            },
                                            itemBuilder: (BuildContext
                                                    context) =>
                                                <PopupMenuEntry<String>>[
                                              const PopupMenuItem<String>(
                                                value: 'open',
                                                height: 36,
                                                child: Row(
                                                  children: [
                                                    Icon(LucideIcons.folder,
                                                        color: Color(0xFF6E6E6E),
                                                        size: 14),
                                                    SizedBox(width: 8),
                                                    Text('Open project',
                                                        style: TextStyle(
                                                            color: Color(
                                                                0xFFB4B4B4),
                                                            fontSize: 12)),
                                                  ],
                                                ),
                                              ),
                                              const PopupMenuItem<String>(
                                                value: 'rename',
                                                height: 36,
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.edit_outlined,
                                                        color: Color(0xFF6E6E6E),
                                                        size: 14),
                                                    SizedBox(width: 8),
                                                    Text('Rename',
                                                        style: TextStyle(
                                                            color: Color(
                                                                0xFFB4B4B4),
                                                            fontSize: 12)),
                                                  ],
                                                ),
                                              ),
                                              const PopupMenuItem<String>(
                                                value: 'delete',
                                                height: 36,
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.delete_outline,
                                                        color: Colors.redAccent,
                                                        size: 14),
                                                    SizedBox(width: 8),
                                                    Text('Delete',
                                                        style: TextStyle(
                                                            color: Colors
                                                                .redAccent,
                                                            fontSize: 12)),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  })(),
                  if (isExpanded && projectThreads.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                          left: 32.0, top: 4.0, bottom: 4.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: projectThreads.map((threadData) {
                          final threadId =
                              threadData['thread_id'] as String? ?? '';
                          final title = threadData['title'] as String? ??
                              (threadId.length > 8
                                  ? threadId.substring(0, 8) + '...'
                                  : threadId);
                          final isThreadActive =
                              widget.chatState.threadId == threadId;

                          bool isHovered = false;
                          return StatefulBuilder(
                              builder: (context, setHoverState) {
                            return MouseRegion(
                              onEnter: (_) =>
                                  setHoverState(() => isHovered = true),
                              onExit: (_) =>
                                  setHoverState(() => isHovered = false),
                              child: InkWell(
                                onTap: () => widget.chatViewModel
                                    .selectThread(threadId),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isThreadActive
                                        ? Theme.of(context).extension<AppThemeExtension>()!.borderColor
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          title,
                                          style: TextStyle(
                                            color: isThreadActive
                                                ? Colors.white
                                                : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                                            fontSize: 13,
                                            fontWeight: isThreadActive
                                                ? FontWeight.w500
                                                : FontWeight.normal,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Visibility(
                                        visible: isHovered || isThreadActive,
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
                                              icon: Icon(Icons.more_horiz,
                                                  color: isThreadActive
                                                      ? Colors.white
                                                      : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                                                  size: 16),
                                              color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8)),
                                              padding: EdgeInsets.zero,
                                              itemBuilder: (context) {
                                                final isPinned =
                                                    threadData['is_pinned'] ==
                                                        true;
                                                final isArchived =
                                                    threadData['is_archived'] ==
                                                        true;
                                                return [
                                                  _buildPopupMenuItem(
                                                      'Share', Icons.share),
                                                  _buildPopupMenuItem(
                                                      isPinned
                                                          ? 'Unpin'
                                                          : 'Pin',
                                                      isPinned
                                                          ? Icons.push_pin
                                                          : Icons
                                                              .push_pin_outlined),
                                                  _buildPopupMenuItem('Rename',
                                                      Icons.edit_outlined),
                                                  _buildPopupMenuItem('Duplicate',
                                                      Icons.copy_outlined),
                                                  _buildPopupMenuItem(
                                                      'Change project',
                                                      Icons.folder_outlined),
                                                  _buildPopupMenuItem(
                                                      isArchived
                                                          ? 'Unarchive'
                                                          : 'Archive',
                                                      isArchived
                                                          ? Icons.unarchive
                                                          : Icons
                                                              .archive_outlined),
                                                  _buildPopupMenuItem('Delete',
                                                      Icons.delete_outline,
                                                      isDestructive: true),
                                                ];
                                              },
                                              onSelected: (value) async {
                                                if (value == 'Share') {
                                                  widget.showShareDialog(
                                                      context,
                                                      widget.chatViewModel,
                                                      threadId);
                                                } else if (value == 'Pin' ||
                                                    value == 'Unpin') {
                                                  await widget.chatViewModel
                                                      .togglePinThread(threadId);
                                                } else if (value == 'Rename') {
                                                  widget.showRenameDialog(
                                                      context,
                                                      widget.chatViewModel,
                                                      threadId,
                                                      title);
                                                } else if (value == 'Duplicate') {
                                                  await widget.chatViewModel
                                                      .duplicateThread(threadId);
                                                } else if (value ==
                                                    'Change project') {
                                                  widget.showChangeProjectDialog(
                                                      context,
                                                      widget.chatViewModel,
                                                      threadId);
                                                } else if (value == 'Archive' ||
                                                    value == 'Unarchive') {
                                                  await widget.chatViewModel
                                                      .toggleArchiveThread(
                                                          threadId);
                                                } else if (value == 'Delete') {
                                                  await widget.chatViewModel
                                                      .deleteThread(threadId);
                                                }
                                              },
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          });
                        }).toList(),
                      ),
                    ),
                ],
              );
            }).toList(),
          ),
      ],
    );
  }
}
