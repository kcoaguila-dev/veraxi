import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/core/providers/project_view_model.dart';
import 'package:veraxi_app/features/project/views/widgets/create_project_dialog.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class AllProjectsDashboardView extends ConsumerStatefulWidget {
  const AllProjectsDashboardView({super.key});

  @override
  ConsumerState<AllProjectsDashboardView> createState() =>
      _AllProjectsDashboardViewState();
}

class _AllProjectsDashboardViewState
    extends ConsumerState<AllProjectsDashboardView> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatViewModelProvider);
    final projectState = ref.watch(projectViewModelProvider);
    final projectViewModel = ref.read(projectViewModelProvider.notifier);

    // Filter projects based on search query
    final displayedProjects = projectState.projects.where((p) {
      final name = (p['name'] as String?)?.toLowerCase() ?? '';
      return name.contains(_searchQuery.toLowerCase());
    }).toList();

    return Container(
      color: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Padding(
            padding:
                EdgeInsets.symmetric(horizontal: 32.0, vertical: 48.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Header Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Projects',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Row(
                      children: [
                        Text(
                          'Sort by',
                          style: TextStyle(
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(width: 8),
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.swap_vert,
                                  color: Colors.white, size: 16),
                              SizedBox(width: 8),
                              Text(
                                'Latest activity',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 16),
                        InkWell(
                          onTap: () {
                            showDialog(
                              context: context,
                              builder: (context) => const CreateProjectDialog(),
                            );
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(
                                  0xFF10A37F), // Green color matching LibreChat
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.add, color: Colors.white, size: 16),
                                SizedBox(width: 8),
                                Text(
                                  'New project',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                SizedBox(height: 24),

                // Search Bar
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search,
                          color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 20),
                      SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          onChanged: (val) {
                            setState(() {
                              _searchQuery = val;
                            });
                          },
                          style: TextStyle(
                              color: Colors.white, fontSize: 15),
                          decoration: InputDecoration(
                            hintText: 'Search projects',
                            hintStyle: TextStyle(
                                color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 15),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 24),

                // Tabs
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        'Your projects',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 24),

                // Grid of Projects
                Expanded(
                  child: displayedProjects.isEmpty
                      ? Center(
                          child: Text(
                            'No projects found.',
                            style: TextStyle(
                                color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 16),
                          ),
                        )
                      : GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                            childAspectRatio: 2.2, // wide rectangular cards
                          ),
                          itemCount: displayedProjects.length,
                          itemBuilder: (context, index) {
                            final project = displayedProjects[index];
                            final projectId = project['id'] as String;
                            final projectName = project['name'] as String;

                            // Calculate chats count for this project
                            final chatCount = state.pastThreads
                                .where((t) => t['project_id'] == projectId)
                                .length;

                            return _ProjectCard(
                              name: projectName,
                              chatCount: chatCount,
                              dateStr: 'Aug 6, 2026', // Placeholder for now
                              onTap: () {
                                projectViewModel.selectProject(projectId, projectName);
                              },
                            );
                          },
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

class _ProjectCard extends StatefulWidget {
  final String name;
  final int chatCount;
  final String dateStr;
  final VoidCallback onTap;

  const _ProjectCard({
    required this.name,
    required this.chatCount,
    required this.dateStr,
    required this.onTap,
  });

  @override
  State<_ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends State<_ProjectCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color:
                _isHovered ? Theme.of(context).extension<AppThemeExtension>()!.borderColor : Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isHovered
                  ? const Color(0xFF444444)
                  : Theme.of(context).extension<AppThemeExtension>()!.borderColor,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.folder, color: Colors.white, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.name,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${widget.chatCount} chats',
                    style: TextStyle(
                      color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    widget.dateStr,
                    style: TextStyle(
                      color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
