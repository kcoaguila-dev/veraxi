import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:veraxi_app/features/chat/view_models/chat_history_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/sidebar_provider.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/core/providers/model_selection_provider.dart';
import 'package:veraxi_app/core/providers/project_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/pinned_models_widget.dart';
import 'package:veraxi_app/features/project/views/widgets/project_list_widget.dart';


class ChatSidebar extends ConsumerStatefulWidget {
  final bool isSidebarOpen;
  final bool isMobile;

  const ChatSidebar({
    super.key,
    required this.isSidebarOpen,
    required this.isMobile,
  });

  @override
  ConsumerState<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends ConsumerState<ChatSidebar> {
  bool _chatsExpanded = true;

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
      colorFilter: ColorFilter.mode(Theme.of(context).extension<AppThemeExtension>()!.iconColor, BlendMode.srcIn),
    );
  }

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
            backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
            title: Text('Share Link',
                style: TextStyle(color: Colors.white, fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Anyone with this link can view the shared conversation.',
                    style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 13)),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.only(
                      left: 12, right: 4, top: 4, bottom: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          url,
                          style: TextStyle(
                              color: Colors.white, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.copy,
                            size: 18, color: Theme.of(context).extension<AppThemeExtension>()!.iconColor),
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
                    style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor)),
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
          backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          title: Text('Rename Chat',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: TextField(
            controller: controller,
            style: TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter new title',
              hintStyle: TextStyle(color: Color(0xFF6E6E6E)),
              enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor)),
              focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF3A3A3A))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel',
                  style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor)),
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
          backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
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
                      await ref.read(chatHistoryProvider.notifier).assignThreadToProject(threadId, null);
                      if (context.mounted) Navigator.pop(context);
                    },
                  );
                }
                final project = projects[index - 1];
                return ListTile(
                  title: Text(project['name'] as String,
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    await ref.read(chatHistoryProvider.notifier).assignThreadToProject(
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
                  style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor)),
            ),
          ],
        );
      },
    );
  }

Widget build(BuildContext context) {
    // We override references to variables that used to be class members
    
    
    
    // In original code, these methods might be defined before _buildSidebarContent, but we moved them to this class.
return _buildSidebarContentActual(context); 
} 
Widget _buildSidebarContentActual(BuildContext context) { 
final state = ref.watch(chatViewModelProvider);
final viewModel = ref.read(chatViewModelProvider.notifier);
final projectState = ref.watch(projectViewModelProvider);
final projectViewModel = ref.read(projectViewModelProvider.notifier);
final modelSelection = ref.watch(modelSelectionProvider);
final isSidebarOpen = widget.isSidebarOpen;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      width: isSidebarOpen ? 260 : 0,
      child: ClipRect(
        child: Container(
          width: 260,
          color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 24,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'Veraxi',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
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
                            ref.read(sidebarStateProvider.notifier).state =
                                false;
                          },
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: Center(child: _buildSidebarToggleIcon()),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 18),
              PinnedModelsWidget(
                pinnedModels: modelSelection.pinnedModels.toList(),
                selectedModel: modelSelection.selectedModel,
                onModelSelected: (model, provider) {
                  ref.read(modelSelectionProvider.notifier).selectModel(model, provider: provider);
                },
                onModelUnpinned: (model) {
                  ref.read(modelSelectionProvider.notifier).unpinModel(model);
                },
              ),
              ProjectListWidget(
                chatState: state,
                chatViewModel: viewModel,
                projectState: projectState,
                projectViewModel: projectViewModel,
                showShareDialog: _showShareDialog,
                showRenameDialog: _showRenameDialog,
                showChangeProjectDialog: _showChangeProjectDialog,
              ),
              SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  InkWell(
                    onTap: () =>
                        setState(() => _chatsExpanded = !_chatsExpanded),
                    child: Row(
                      children: [
                        Text('Chats',
                            style: TextStyle(
                                color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                        SizedBox(width: 4),
                        Icon(
                            _chatsExpanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                            size: 16),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      viewModel.startNewChat();
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: EdgeInsets.all(4.0),
                      child: Icon(Icons.edit_square,
                          color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, size: 16),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12),
              if (_chatsExpanded)
                Expanded(
                  child: Builder(
                    builder: (context) {
                      if (state.isLoadingThreads) {
                        return Center(
                          child: Padding(
                            padding: EdgeInsets.only(top: 24.0),
                            child: CupertinoActivityIndicator(radius: 10),
                          ),
                        );
                      }

                      final timelineChats = state.pastThreads
                          .where((t) => t['is_archived'] != true)
                          .toList();
                      if (timelineChats.isEmpty) {
                        return SizedBox.shrink();
                      }

                      final now = DateTime.now();
                      final today = DateTime(now.year, now.month, now.day);
                      final yesterday = today.subtract(const Duration(days: 1));
                      final lastWeek = today.subtract(const Duration(days: 7));

                      final todayChats = <Map<String, dynamic>>[];
                      final yesterdayChats = <Map<String, dynamic>>[];
                      final lastWeekChats = <Map<String, dynamic>>[];
                      final olderChats = <Map<String, dynamic>>[];

                      for (final chat in timelineChats) {
                        final tsRaw = chat['_timestamp'];
                        final tsSec = tsRaw is num ? tsRaw.toDouble() : 0.0;
                        final date = tsSec > 0
                            ? DateTime.fromMillisecondsSinceEpoch(
                                (tsSec * 1000).toInt())
                            : DateTime.now();
                        final justDate =
                            DateTime(date.year, date.month, date.day);

                        if (!justDate.isBefore(today)) {
                          todayChats.add(chat);
                        } else if (!justDate.isBefore(yesterday)) {
                          yesterdayChats.add(chat);
                        } else if (!justDate.isBefore(lastWeek)) {
                          lastWeekChats.add(chat);
                        } else {
                          olderChats.add(chat);
                        }
                      }

                      final flatItems = <dynamic>[];
                      if (todayChats.isNotEmpty) {
                        flatItems.add('Today');
                        flatItems.addAll(todayChats);
                      }
                      if (yesterdayChats.isNotEmpty) {
                        flatItems.add('Yesterday');
                        flatItems.addAll(yesterdayChats);
                      }
                      if (lastWeekChats.isNotEmpty) {
                        flatItems.add('Previous 7 days');
                        flatItems.addAll(lastWeekChats);
                      }
                      if (olderChats.isNotEmpty) {
                        flatItems.add('Older');
                        flatItems.addAll(olderChats);
                      }

                      return ListView.builder(
                        itemCount: flatItems.length,
                        itemBuilder: (context, index) {
                          final item = flatItems[index];
                          if (item is String) {
                            return Padding(
                              padding: EdgeInsets.only(
                                  top: 16.0, bottom: 8.0, left: 8.0),
                              child: Text(
                                item,
                                style: TextStyle(
                                  color: Color(0xFF676767),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            );
                          }

                          final threadData = item as Map<String, dynamic>;
                          final threadId =
                              threadData['thread_id'] as String? ?? '';
                          final title = threadData['title'] as String? ??
                              (threadId.length > 8
                                  ? threadId.substring(0, 8) + '...'
                                  : threadId);
                          final isSelected = state.threadId == threadId;
                          bool isHovered = false;

                          return StatefulBuilder(builder: (context, setState) {
                            return MouseRegion(
                              onEnter: (_) => setState(() => isHovered = true),
                              onExit: (_) => setState(() => isHovered = false),
                              child: InkWell(
                                onTap: () {
                                  viewModel.selectThread(threadId);
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Theme.of(context).extension<AppThemeExtension>()!.borderColor
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: EdgeInsets.symmetric(
                                      vertical: 8.0, horizontal: 8.0),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          title,
                                          style: TextStyle(
                                            color: isSelected
                                                ? Colors.white
                                                : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                                            fontSize: 13,
                                            fontWeight: isSelected
                                                ? FontWeight.w500
                                                : FontWeight.normal,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Visibility(
                                        visible: isHovered || isSelected,
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
                                                  color: isSelected
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
                                                  _buildPopupMenuItem(
                                                      'Duplicate',
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
                                                final viewModel = ref.read(
                                                    chatViewModelProvider
                                                        .notifier);
                                                if (value == 'Share') {
                                                  _showShareDialog(context,
                                                      viewModel, threadId);
                                                } else if (value == 'Pin' ||
                                                    value == 'Unpin') {
                                                  await viewModel
                                                      .togglePinThread(
                                                          threadId);
                                                } else if (value == 'Rename') {
                                                  _showRenameDialog(
                                                      context,
                                                      viewModel,
                                                      threadId,
                                                      title);
                                                } else if (value ==
                                                    'Duplicate') {
                                                  await viewModel
                                                      .duplicateThread(
                                                          threadId);
                                                } else if (value ==
                                                    'Change project') {
                                                  _showChangeProjectDialog(
                                                      context,
                                                      viewModel,
                                                      threadId);
                                                } else if (value == 'Archive' ||
                                                    value == 'Unarchive') {
                                                  await viewModel
                                                      .toggleArchiveThread(
                                                          threadId);
                                                } else if (value == 'Delete') {
                                                  await viewModel
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
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );





}}