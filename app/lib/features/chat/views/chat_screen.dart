import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
import 'package:veraxi_app/features/chat/view_models/audio_player_service.dart';

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

  static const String _sidebarToggleSvg = '''
<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <path fill-rule="evenodd" clip-rule="evenodd" d="M8.85719 3H15.1428C16.2266 2.99999 17.1007 2.99998 17.8086 3.05782C18.5375 3.11737 19.1777 3.24318 19.77 3.54497C20.7108 4.02433 21.4757 4.78924 21.955 5.73005C22.2568 6.32234 22.3826 6.96253 22.4422 7.69138C22.5 8.39925 22.5 9.27339 22.5 10.3572V13.6428C22.5 14.7266 22.5 15.6008 22.4422 16.3086C22.3826 17.0375 22.2568 17.6777 21.955 18.27C21.4757 19.2108 20.7108 19.9757 19.77 20.455C19.1777 20.7568 18.5375 20.8826 17.8086 20.9422C17.1008 21 16.2266 21 15.1428 21H8.85717C7.77339 21 6.89925 21 6.19138 20.9422C5.46253 20.8826 4.82234 20.7568 4.23005 20.455C3.28924 19.9757 2.52433 19.2108 2.04497 18.27C1.74318 17.6777 1.61737 17.0375 1.55782 16.3086C1.49998 15.6007 1.49999 14.7266 1.5 13.6428V10.3572C1.49999 9.27341 1.49998 8.39926 1.55782 7.69138C1.61737 6.96253 1.74318 6.32234 2.04497 5.73005C2.52433 4.78924 3.28924 4.02433 4.23005 3.54497C4.82234 3.24318 5.46253 3.11737 6.19138 3.05782C6.89926 2.99998 7.77341 2.99999 8.85719 3ZM6.35424 5.05118C5.74907 5.10062 5.40138 5.19279 5.13803 5.32698C4.57354 5.6146 4.1146 6.07354 3.82698 6.63803C3.69279 6.90138 3.60062 7.24907 3.55118 7.85424C3.50078 8.47108 3.5 9.26339 3.5 10.4V13.6C3.5 14.7366 3.50078 15.5289 3.55118 16.1458C3.60062 16.7509 3.69279 17.0986 3.82698 17.362C4.1146 17.9265 4.57354 18.3854 5.13803 18.673C5.40138 18.8072 5.74907 18.8994 6.35424 18.9488C6.97108 18.9992 7.76339 19 8.9 19H9.5V5H8.9C7.76339 5 6.97108 5.00078 6.35424 5.05118ZM11.5 5V19H15.1C16.2366 19 17.0289 18.9992 17.6458 18.9488C18.2509 18.8994 18.5986 18.8072 18.862 18.673C19.4265 18.3854 19.8854 17.9265 20.173 17.362C20.3072 17.0986 20.3994 16.7509 20.4488 16.1458C20.4992 15.5289 20.5 14.7366 20.5 13.6V10.4C20.5 9.26339 20.4992 8.47108 20.4488 7.85424C20.3994 7.24907 20.3072 6.90138 20.173 6.63803C19.8854 6.07354 19.4265 5.6146 18.862 5.32698C18.5986 5.19279 18.2509 5.10062 17.6458 5.05118C17.0289 5.00078 16.2366 5 15.1 5H11.5ZM5 8.5C5 7.94772 5.44772 7.5 6 7.5H7C7.55229 7.5 8 7.94772 8 8.5C8 9.05229 7.55229 9.5 7 9.5H6C5.44772 9.5 5 9.05229 5 8.5ZM5 12C5 11.4477 5.44772 11 6 11H7C7.55229 11 8 11.4477 8 12C8 12.5523 7.55229 13 7 13H6C5.44772 13 5 12.5523 5 12Z" fill="currentColor"/>
</svg>
''';

  Widget _buildSidebarToggleIcon(BuildContext context) {
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

    ref.listen(audioPlayerServiceProvider, (previous, next) {
      if (next.errorMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.errorMessage!),
            backgroundColor: Colors.red.shade900,
            behavior: SnackBarBehavior.floating,
          ),
        );
        ref.read(audioPlayerServiceProvider.notifier).clearErrorMessage();
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
                                                    showTelemetry:
                                                        state.showTelemetry,
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
                            if (!isMobile && !isSidebarOpen) ...[
                              Tooltip(
                                message: 'Open sidebar',
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () {
                                      ref.read(sidebarStateProvider.notifier).state = true;
                                    },
                                    child: SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: Center(child: _buildSidebarToggleIcon(context)),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            ModelSelectorMenu(
                              selectedModel: _selectedModel,
                              pinnedModels: _pinnedModels.toList(),
                              onModelSelected: (model) async {
                                setState(() {
                                  _selectedModel = model;
                                });
                                final prefs =
                                    await SharedPreferences.getInstance();
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
                                      const Icon(Icons.psychology,
                                          size: 16, color: Colors.white),
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
