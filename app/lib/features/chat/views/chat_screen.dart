import 'package:flutter/material.dart';
import 'package:veraxi_app/core/sidebar_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_sidebar.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_list_item.dart';
import 'package:veraxi_app/features/chat/views/widgets/project_dashboard_view.dart';
import 'package:veraxi_app/features/chat/views/widgets/all_projects_dashboard_view.dart';
import 'package:veraxi_app/core/widgets/model_selector_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_sidebar.dart';
import 'package:veraxi_app/core/widgets/profile_menu_button.dart';

final activeSourcesProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => []);

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final ScrollController _scrollController = ScrollController();

  String _selectedModel = 'Select a model';
  final Set<String> _pinnedModels = {};
  bool _isScrolledUp = false;

  void _onScroll() {
    if (_scrollController.hasClients) {
      final isUp = _scrollController.position.pixels <
          _scrollController.position.maxScrollExtent - 50;
      if (isUp != _isScrolledUp) {
        setState(() {
          _isScrolledUp = isUp;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }



  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 100, // Overscroll slightly
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Widget build(BuildContext context) {
    final state = ref.watch(chatViewModelProvider);
    final isSidebarOpen = ref.watch(sidebarStateProvider);
    final viewModel = ref.read(chatViewModelProvider.notifier);
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;

    // Auto-scroll when messages change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isScrolledUp) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      key: _scaffoldKey, // Add a key to access the scaffold
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: Builder(builder: (context) {
        return Drawer(
          backgroundColor: const Color(0xFF171717),
          child: const ChatSidebar(isSidebarOpen: true, isMobile: true),
        );
      }),
      endDrawer: Consumer(
        builder: (context, ref, child) {
          final sources = ref.watch(activeSourcesProvider);
          return SourcesSidebar(sources: sources);
        },
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 800;
          return Row(
            children: [
              // Inner Navigation Sidebar (Projects / Chats)
              isMobile
                  ? const SizedBox.shrink()
                  : ChatSidebar(isSidebarOpen: isSidebarOpen, isMobile: false),
              // Main Chat Area
              Expanded(
                child: SafeArea(
                  child: Stack(
                    children: [
                      // Main Content
                      Column(
                        children: [
                          if (isMobile)
                            Container(
                              height: 56,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              decoration: const BoxDecoration(
                                border: Border(
                                    bottom:
                                        BorderSide(color: Color(0xFF2A2A2A))),
                              ),
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.menu,
                                        color: Colors.white),
                                    onPressed: () =>
                                        Scaffold.of(context).openDrawer(),
                                  ),
                                  const SizedBox(width: 8),
                                  const Text('Veraxi',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          Expanded(
                            child: state.showAllProjectsDashboard
                                ? const AllProjectsDashboardView()
                                : state.showProjectDashboard
                                    ? const ProjectDashboardView()
                                    : state.isLoadingHistory
                                        ? const Center(
                                            child: SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.0,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                            Color>(
                                                        Color(0xFF878787)),
                                              ),
                                            ),
                                          )
                                        : state.messages.isEmpty
                                            ? _buildEmptyState(
                                                theme, ext, state, viewModel)
                                            : ListView.builder(
                                                controller: _scrollController,
                                                padding: const EdgeInsets.only(
                                                    left: 16,
                                                    right: 16,
                                                    top: 80,
                                                    bottom: 300),
                                                itemCount:
                                                    state.messages.length,
                                                itemBuilder: (context, index) {
                                                  final msg =
                                                      state.messages[index];
                                                  return ChatMessageListItem(
                                                    msg: msg,
                                                    theme: theme,
                                                    ext: ext,
                                                    showTelemetry: state.showTelemetry,
                                                  );
                                                },
                                              ),
                          ),
                        ],
                      ),

                      // Top Bar Background to prevent text overlap
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 60,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                theme.scaffoldBackgroundColor,
                                theme.scaffoldBackgroundColor
                                    .withValues(alpha: 0.9),
                                theme.scaffoldBackgroundColor
                                    .withValues(alpha: 0.0),
                              ],
                              stops: const [0.6, 0.9, 1.0],
                            ),
                          ),
                        ),
                      ),

                      // Top Bar: Model Selector (like LibreChat)
                      Positioned(
                        top: 12,
                        left: 16,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            ModelSelectorMenu(
                              selectedModel: _selectedModel,
                              pinnedModels: _pinnedModels.toList(),
                              onModelSelected: (model) async {
                                setState(() {
                                  _selectedModel = model;
                                });
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setString('selected_model', model);
                              },
                              onModelPinned: (model) {
                                setState(() => _pinnedModels.add(model));
                              },
                              onModelUnpinned: (model) {
                                setState(() => _pinnedModels.remove(model));
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E1E1E),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: const Color(0xFF2A2A2A)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_selectedModel != 'Select a model') ...[
                                      const Icon(Icons.psychology, size: 16, color: Colors.white),
                                      const SizedBox(width: 8),
                                    ],
                                    Text(_selectedModel,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500)),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.keyboard_arrow_down,
                                        size: 16, color: Colors.white),
                                  ],
                                ),
                              ),
                            ),
                            // Telemetry toggle — flush next to the model pill
                            const SizedBox(width: 4),
                            Tooltip(
                              message: state.showTelemetry
                                  ? 'Response Telemetry (On)'
                                  : 'Show Response Telemetry',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () => viewModel.toggleTelemetry(),
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Icon(
                                    state.showTelemetry
                                        ? Icons.analytics
                                        : Icons.analytics_outlined,
                                    size: 18,
                                    color: state.showTelemetry
                                        ? ext.primaryGradientStart
                                        : const Color(0xFF878787),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Temporary Chat Toggle
                      Positioned(
                        top: 16,
                        right: 16,
                        child: Tooltip(
                          message: state.isTemporary
                              ? 'Temporary Chat (Enabled)'
                              : 'Temporary Chat',
                          child: IconButton(
                            icon: Icon(
                              Icons.data_usage,
                              color: state.isTemporary
                                  ? ext.primaryGradientStart
                                  : const Color(0xFF878787),
                              size: 20,
                            ),
                            onPressed: () => viewModel.toggleTemporaryChat(),
                          ),
                        ),
                      ),

                      // Solid background at bottom behind input
                      if (state.messages.isNotEmpty)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          height: 160,
                          child: Container(
                            color: theme.scaffoldBackgroundColor,
                          ),
                        ),

                      // Floating scroll to bottom button
                      if (_isScrolledUp && state.messages.isNotEmpty)
                        Positioned(
                          bottom: 120,
                          right: 32,
                          child: GestureDetector(
                            onTap: () {
                              _scrollToBottom();
                            },
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2A2A2A),
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: const Color(0xFF3F3F3F)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.2),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  )
                                ],
                              ),
                              child: const Icon(Icons.arrow_downward,
                                  color: Colors.white, size: 16),
                            ),
                          ),
                        ),

                      // Floating Input Area at Bottom (only if messages exist)
                      if (state.messages.isNotEmpty)
                        Positioned(
                          bottom: 40,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 800),
                              child: ChatInput(
                                projectName: state.activeProjectName,
                                isLoading: state.isLoading,
                                onSend: (text, {attachments}) =>
                                    viewModel.sendMessage(text,
                                        model:
                                            _selectedModel == 'Select a model'
                                                ? null
                                                : _selectedModel,
                                        attachments: attachments),
                                errorText: state.error,
                                onDismissError: () => viewModel.clearError(),
                              ),
                            ),
                          ),
                        ),

                      // Footer Legal Text
                      Positioned(
                        bottom: 12,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Text(
                            'Veraxi v0.1.0 - Sovereign Intelligence. Privacy policy | Terms of service',
                            style: TextStyle(
                                color: const Color(0xFF878787), fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, AppThemeExtension ext,
      ChatState state, ChatViewModel viewModel) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Good afternoon, ${resolveDisplayName()}',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ).animate().fade(duration: 800.ms).slideY(begin: 0.1, end: 0),
          const SizedBox(height: 32),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ChatInput(
              projectName: state.activeProjectName,
              isLoading: state.isLoading,
              onSend: (text, {attachments}) => viewModel.sendMessage(text,
                  model: _selectedModel, attachments: attachments),
              errorText: state.error,
            ),
          )
              .animate()
              .fade(duration: 800.ms, delay: 100.ms)
              .slideY(begin: 0.1, end: 0),
        ],
      ),
    );
  }

}
