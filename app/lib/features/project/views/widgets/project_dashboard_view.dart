import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/core/providers/project_view_model.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class ProjectDashboardView extends ConsumerWidget {
  const ProjectDashboardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatViewModelProvider);
    final viewModel = ref.read(chatViewModelProvider.notifier);
    final projectState = ref.watch(projectViewModelProvider);
    final projectViewModel = ref.read(projectViewModelProvider.notifier);
    final projectId = projectState.activeProjectId;
    final projectName = projectState.activeProjectName ?? 'Project';

    // Filter threads for this project
    final projectThreads =
        state.pastThreads.where((t) => t['project_id'] == projectId).toList();

    return Container(
      color: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding:
                EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Back to all projects
                InkWell(
                  onTap: () => projectViewModel.exitProject(),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.arrow_back,
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'All projects',
                          style: TextStyle(
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 32),

                // Project Header
                Row(
                  children: [
                    Icon(LucideIcons.folder,
                        color: Colors.white, size: 32),
                    SizedBox(width: 16),
                    Text(
                      projectName,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 32),

                // New Chat Button
                InkWell(
                  onTap: () {
                    if (projectId != null) {
                      viewModel.startNewChatInProject(projectId);
                    }
                  },
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.add, color: Colors.white, size: 20),
                        SizedBox(width: 12),
                        Text(
                          'New chat in $projectName',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 48),

                // Chats List
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Chats ${projectThreads.length}',
                      style: TextStyle(
                        color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(Icons.arrow_upward,
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 12),
                        SizedBox(width: 4),
                        Text(
                          'Updated',
                          style: TextStyle(
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                SizedBox(height: 12),

                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                    ),
                    child: projectThreads.isEmpty
                        ? Center(
                            child: Text(
                              'No chats yet',
                              style: TextStyle(
                                color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                                fontSize: 14,
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: EdgeInsets.all(8),
                            itemCount: projectThreads.length,
                            separatorBuilder: (context, index) => Divider(
                              color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                              height: 1,
                            ),
                            itemBuilder: (context, index) {
                              final thread = projectThreads[index];
                              final title = thread['title'] ?? 'New Chat';
                              final time = thread['updated_at'] ?? '';
                              String formattedTime = '';
                              if (time.isNotEmpty) {
                                try {
                                  final dt = DateTime.parse(time);
                                  formattedTime =
                                      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                                } catch (_) {}
                              }

                              return ListTile(
                                onTap: () =>
                                    viewModel.selectThread(thread['thread_id']),
                                title: Text(
                                  title,
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 14),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Text(
                                  formattedTime,
                                  style: TextStyle(
                                      color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 12),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
