import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';

class ProjectDashboardView extends ConsumerWidget {
  const ProjectDashboardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatViewModelProvider);
    final viewModel = ref.read(chatViewModelProvider.notifier);
    final projectId = state.activeProjectId;
    final projectName = state.activeProjectName ?? 'Project';

    // Filter threads for this project
    final projectThreads =
        state.pastThreads.where((t) => t['project_id'] == projectId).toList();

    return Container(
      color: const Color(0xFF131313),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Back to all projects
                InkWell(
                  onTap: () => viewModel.exitProject(),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.arrow_back,
                            color: Color(0xFF878787), size: 16),
                        const SizedBox(width: 8),
                        const Text(
                          'All projects',
                          style: TextStyle(
                            color: Color(0xFF878787),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),

                // Project Header
                Row(
                  children: [
                    const Icon(LucideIcons.folder,
                        color: Colors.white, size: 32),
                    const SizedBox(width: 16),
                    Text(
                      projectName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // New Chat Button
                InkWell(
                  onTap: () => viewModel.startNewChatInProject(),
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFF2A2A2A)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.add, color: Colors.white, size: 20),
                        const SizedBox(width: 12),
                        Text(
                          'New chat in $projectName',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 48),

                // Chats List
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Chats ${projectThreads.length}',
                      style: const TextStyle(
                        color: Color(0xFF878787),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Row(
                      children: [
                        Icon(Icons.arrow_upward,
                            color: Color(0xFF878787), size: 12),
                        SizedBox(width: 4),
                        Text(
                          'Updated',
                          style: TextStyle(
                            color: Color(0xFF878787),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF131313),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF2A2A2A)),
                    ),
                    child: projectThreads.isEmpty
                        ? const Center(
                            child: Text(
                              'No chats yet',
                              style: TextStyle(
                                color: Color(0xFF878787),
                                fontSize: 14,
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(8),
                            itemCount: projectThreads.length,
                            separatorBuilder: (context, index) => const Divider(
                              color: Color(0xFF2A2A2A),
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
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 14),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Text(
                                  formattedTime,
                                  style: const TextStyle(
                                      color: Color(0xFF878787), fontSize: 12),
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
