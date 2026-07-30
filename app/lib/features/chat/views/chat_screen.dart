import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/views/widgets/api_key_dialog.dart';
import 'package:veraxi_app/features/settings/views/widgets/settings_dialog.dart';

import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_highlighter/flutter_highlighter.dart';
import 'package:flutter_highlighter/themes/atom-one-dark.dart';
import 'package:veraxi_app/core/widgets/profile_menu_button.dart';

class InteractiveCodeBlock extends StatefulWidget {
  final String language;
  final String code;

  const InteractiveCodeBlock({super.key, required this.language, required this.code});

  @override
  State<InteractiveCodeBlock> createState() => _InteractiveCodeBlockState();
}

class _InteractiveCodeBlockState extends State<InteractiveCodeBlock> {
  bool _isRunning = false;
  bool _hasError = false;

  void _runCode() async {
    if (_isRunning || _hasError) return;
    setState(() {
      _isRunning = true;
    });

    // Simulate code execution delay
    await Future.delayed(const Duration(seconds: 1));

    if (mounted) {
      setState(() {
        _isRunning = false;
        _hasError = true;
      });

      // Show red error snackbar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text('There was an error running the code', style: TextStyle(color: Colors.white)),
            ],
          ),
          backgroundColor: const Color(0xFFDC2626), // Red background
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            bottom: MediaQuery.of(context).size.height - 150,
            left: MediaQuery.of(context).size.width / 2 - 150,
            right: MediaQuery.of(context).size.width / 2 - 150,
          ),
          duration: const Duration(seconds: 3),
        ),
      );

      // Revert the error state after the snackbar duration
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _hasError = false;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F), // Dark background for code
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF2A2A2A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(widget.language, style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace')),
                Row(
                  children: [
                    InkWell(
                      onTap: _runCode,
                      child: Row(
                        children: [
                          if (_hasError)
                            const Icon(Icons.close, color: Color(0xFFDC2626), size: 14)
                          else if (_isRunning)
                            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
                          else
                            const Icon(Icons.play_arrow_outlined, color: Colors.white70, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            _hasError ? 'Failed' : 'Run Code',
                            style: TextStyle(
                              color: _hasError ? const Color(0xFFDC2626) : Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    InkWell(
                      onTap: () {
                         Clipboard.setData(ClipboardData(text: widget.code));
                      },
                      child: const Row(
                        children: [
                          Icon(Icons.copy_outlined, color: Colors.white70, size: 14),
                          SizedBox(width: 4),
                          Text('Copy code', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Code content
          SizedBox(
            width: double.infinity,
            child: HighlightView(
              widget.code,
              language: widget.language == 'text' ? 'plaintext' : widget.language,
              theme: atomOneDarkTheme,
              padding: const EdgeInsets.all(16),
              textStyle: GoogleFonts.firaCode(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class CodeElementBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  CodeElementBuilder(this.context);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // If it doesn't have a language class or newlines, it's probably inline code.
    final hasLanguage = element.attributes.keys.any((k) => k.startsWith('class'));
    final languageClass = element.attributes['class'];
    final isBlock = element.textContent.contains('\n') || hasLanguage;

    if (!isBlock) {
       // Let flutter_markdown handle inline code
       return null; 
    }

    String language = 'plaintext';
    if (languageClass != null && languageClass.startsWith('language-')) {
      language = languageClass.substring(9).toLowerCase();
      // Normalize common language aliases for highlight.js
      if (language == 'python3' || language == 'py') language = 'python';
      if (language == 'js' || language == 'node') language = 'javascript';
      if (language == 'ts') language = 'typescript';
      if (language == 'sh' || language == 'zsh') language = 'bash';
      if (language == 'c++' || language == 'cc') language = 'cpp';
      if (language == 'c#') language = 'cs';
      if (language == 'html') language = 'xml'; // highglight.js treats html as xml
      if (language == 'text') language = 'plaintext';
    }

    final code = element.textContent;

    return InteractiveCodeBlock(language: language, code: code);
  }
}


// Resolved at compile time via --dart-define=IS_SELF_HOSTED=true (set in Dockerfile)
const bool _isSelfHosted = bool.fromEnvironment('IS_SELF_HOSTED', defaultValue: false);



class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  PopupMenuItem<String> _buildPopupMenuItem(String title, IconData icon, {bool isDestructive = false}) {
    return PopupMenuItem<String>(
      value: title,
      child: Row(
        children: [
          Icon(icon, color: isDestructive ? Colors.red : const Color(0xFFB4B4B4), size: 16),
          const SizedBox(width: 12),
          Text(title, style: TextStyle(color: isDestructive ? Colors.red : const Color(0xFFE0E0E0), fontSize: 13)),
        ],
      ),
    );
  }

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _modelSelectorKey = GlobalKey();
  bool _isModelSelectorOpen = false;
  String? _hoveredProvider;
  String? _hoveredGearProvider;
  String _selectedModel = 'Select a model';
  String? _selectedProvider;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  String _globalSearchQuery = '';
  final TextEditingController _globalSearchController = TextEditingController();
  String? _hoveredModel;
  final Set<String> _pinnedModels = {};

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _globalSearchController.dispose();
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatViewModelProvider);
    final viewModel = ref.read(chatViewModelProvider.notifier);
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;

    // Auto-scroll when messages change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: null,
      body: Row(
        children: [
          // Inner Navigation Sidebar (Projects / Chats)
          Container(
            width: 220,
            color: const Color(0xFF171717),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Pinned Models (above Projects)
                if (_pinnedModels.isNotEmpty) ...[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _pinnedModels.map((model) {
                      final isActive = model == _selectedModel;
                      return MouseRegion(
                        onEnter: (_) => setState(() => _hoveredModel = 'sidebar_$model'),
                        onExit: (_) => setState(() {
                          if (_hoveredModel == 'sidebar_$model') _hoveredModel = null;
                        }),
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedModel = model;
                              // Infer provider from model name
                              if (model.startsWith('gemini')) _selectedProvider = 'Google';
                              else if (model.startsWith('gpt')) _selectedProvider = 'OpenAI';
                              else if (model.startsWith('claude')) _selectedProvider = 'Anthropic';
                            });
                          },
                          child: Container(
                            height: 30,
                            margin: const EdgeInsets.only(bottom: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: isActive ? const Color(0xFF2F2F2F) : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                _providerDotFor(model),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    model,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 12, color: isActive ? Colors.white : const Color(0xFF878787)),
                                  ),
                                ),
                                if (_hoveredModel == 'sidebar_$model')
                                  GestureDetector(
                                    onTap: () => setState(() => _pinnedModels.remove(model)),
                                    child: const Tooltip(
                                      message: 'Unpin',
                                      child: Icon(Icons.push_pin, color: Color(0xFF878787), size: 12),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text('Projects', style: TextStyle(color: const Color(0xFF878787), fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        Icon(Icons.keyboard_arrow_down, color: const Color(0xFF878787), size: 16),
                      ],
                    ),
                    Icon(Icons.copy_all, color: const Color(0xFFB4B4B4), size: 16),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text('Chats', style: TextStyle(color: const Color(0xFF878787), fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        Icon(Icons.keyboard_arrow_down, color: const Color(0xFF878787), size: 16),
                      ],
                    ),
                    Icon(Icons.edit_square, color: const Color(0xFFB4B4B4), size: 16),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: state.pastThreads.isEmpty
                      ? const Text('No threads found.', style: TextStyle(color: Colors.red, fontSize: 12))
                      : ListView.builder(
                          itemCount: state.pastThreads.length,
                          itemBuilder: (context, index) {
                            final threadData = state.pastThreads[index];
                            final threadId = threadData['thread_id'] as String? ?? '';
                            final title = threadData['title'] as String? ?? (threadId.length > 8 ? threadId.substring(0, 8) + '...' : threadId);
                            final isSelected = state.threadId == threadId;
                            bool isHovered = false;

                            return StatefulBuilder(
                              builder: (context, setState) {
                                return MouseRegion(
                                  onEnter: (_) => setState(() => isHovered = true),
                                  onExit: (_) => setState(() => isHovered = false),
                                  child: InkWell(
                                    onTap: () {
                                      viewModel.selectThread(threadId);
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: isSelected ? const Color(0xFF2A2A2A) : Colors.transparent,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              title,
                                              style: TextStyle(
                                                color: isSelected ? Colors.white : const Color(0xFFB4B4B4), 
                                                fontSize: 13,
                                                fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
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
                                                  icon: Icon(Icons.more_horiz, color: isSelected ? Colors.white : const Color(0xFFB4B4B4), size: 16),
                                                  color: const Color(0xFF2A2A2A),
                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                  padding: EdgeInsets.zero,
                                                  itemBuilder: (context) => [
                                                    _buildPopupMenuItem('Share', Icons.share),
                                                    _buildPopupMenuItem('Pin', Icons.push_pin_outlined),
                                                    _buildPopupMenuItem('Rename', Icons.edit_outlined),
                                                    _buildPopupMenuItem('Duplicate', Icons.copy_outlined),
                                                    _buildPopupMenuItem('Change project', Icons.folder_outlined),
                                                    _buildPopupMenuItem('Archive', Icons.archive_outlined),
                                                    _buildPopupMenuItem('Delete', Icons.delete_outline, isDestructive: true),
                                                  ],
                                                  onSelected: (value) {
                                                    // TODO: Implement actions
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
                              }
                            );
                          },
                        ),
                ),
              ],
            ),
          ),

          // Main Chat Area
          Expanded(
            child: SafeArea(
              child: Stack(
                children: [
                  // Main Content
                  Column(
                    children: [
                      Expanded(
                        child: state.isLoadingHistory 
                          ? Center(child: CircularProgressIndicator(color: theme.colorScheme.primary))
                          : state.messages.isEmpty
                              ? _buildEmptyState(theme, ext, state, viewModel)
                              : ListView.builder(
                                  controller: _scrollController,
                                  padding: const EdgeInsets.only(left: 16, right: 16, top: 80, bottom: 120),
                                  itemCount: state.messages.length,
                                  itemBuilder: (context, index) {
                                    final msg = state.messages[index];
                                    return _buildChatMessage(msg, theme, ext);
                                  },
                                ),
                      ),
                    ],
                  ),
                  
                  // Full-screen tap catcher to dismiss popup
                  if (_isModelSelectorOpen)
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                             _isModelSelectorOpen = false;
                             _hoveredProvider = null;
                             _hoveredGearProvider = null;
                             _searchQuery = '';
                             _searchController.clear();
                             _globalSearchQuery = '';
                             _globalSearchController.clear();
                             _hoveredModel = null;
                           });
                        },
                        child: Container(color: Colors.transparent),
                      ),
                    ),
                  

                  // Top Bar: Model Selector (like LibreChat)
                  Positioned(
                    top: 12,
                    left: 16,
                    child: GestureDetector(
                      key: _modelSelectorKey,
                      onTap: () {
                        setState(() {
                          _isModelSelectorOpen = !_isModelSelectorOpen;
                          if (_isModelSelectorOpen) {
                            _hoveredProvider = _selectedProvider;
                          } else {
                            _hoveredProvider = null;
                            _hoveredGearProvider = null;
                          }
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF2A2A2A)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_selectedModel != 'Select a model') ...[
                              const Text('G', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                              const SizedBox(width: 6),
                            ],
                            Text(_selectedModel, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                            const SizedBox(width: 4),
                            const Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.white),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Temporary Chat Toggle
                  Positioned(
                    top: 16,
                    right: 16,
                    child: Tooltip(
                      message: state.isTemporary ? 'Temporary Chat (Enabled)' : 'Temporary Chat',
                      child: IconButton(
                        icon: Icon(
                          Icons.data_usage, 
                          color: state.isTemporary ? ext.primaryGradientStart : const Color(0xFF878787),
                          size: 20,
                        ),
                        onPressed: () => viewModel.toggleTemporaryChat(),
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
                            isLoading: state.isLoading,
                            onSend: (text) => viewModel.sendMessage(text, model: _selectedModel == 'Select a model' ? null : _selectedModel),
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
                        style: TextStyle(color: const Color(0xFF878787), fontSize: 12),
                      ),
                    ),
                  ),

                  // The actual popup menu - opens downward from the top bar button
                  if (_isModelSelectorOpen)
                    Positioned(
                      top: 56,
                      left: 16,
                      child: _buildModelSelectorPopup(context).animate().fade(duration: 200.ms),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, AppThemeExtension ext, ChatState state, ChatViewModel viewModel) {
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
              isLoading: state.isLoading,
              onSend: (text) => viewModel.sendMessage(text, model: _selectedModel),
              errorText: state.error,
            ),
          ).animate().fade(duration: 800.ms, delay: 100.ms).slideY(begin: 0.1, end: 0),
        ],
      ),
    );
  }

  Widget _buildDrawer(ChatState state, ChatViewModel viewModel, ThemeData theme, AppThemeExtension ext) {
    return Drawer(
      backgroundColor: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.colorScheme.onSurface.withValues(alpha: 0.1))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(Icons.history, color: ext.primaryGradientStart, size: 32),
                const SizedBox(height: 12),
                Text('Chat History', style: theme.textTheme.titleLarge),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: state.pastThreads.length,
              itemBuilder: (context, index) {
                final threadData = state.pastThreads[index];
                final threadId = threadData['thread_id'] as String? ?? '';
                final title = threadData['title'] as String? ?? (threadId.length > 8 ? threadId.substring(0, 8) + '...' : threadId);
                return ListTile(
                  leading: Icon(Icons.chat_bubble_outline, color: theme.colorScheme.onSurface.withValues(alpha: 0.5), size: 20),
                  title: Text(title, style: theme.textTheme.bodyMedium),
                  onTap: () {
                    Navigator.pop(context); // Close drawer
                    viewModel.selectThread(threadId);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatMessage(ChatMessage msg, ThemeData theme, AppThemeExtension ext) {
    final isUser = msg.role == 'user';
    final name = isUser ? 'Local User' : (msg.modelName != null && msg.modelName!.isNotEmpty ? msg.modelName! : 'AI Assistant');
    final avatar = isUser
        ? Container(
            width: 28, height: 28,
            decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(6)),
            child: const Icon(Icons.person, color: Colors.white, size: 18),
          )
        : Container(
            width: 28, height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.transparent),
            child: msg.modelName != null && msg.modelName!.isNotEmpty
                ? _providerDotFor(msg.modelName!)
                : Icon(Icons.auto_awesome, color: ext.primaryGradientStart, size: 20),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: Colors.white)),
                const SizedBox(height: 8),
                if (isUser)
                  Text(
                    msg.content,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                  )
                else if (msg.isError)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3F1515), // Dark red background
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFB91C1C)), // Red border
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.refresh, color: Color(0xFFFCA5A5), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            msg.content,
                            style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 14), // Light red text
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarkdownBody(
                        data: msg.content.isEmpty && msg.isStreaming ? '...' : msg.content,
                        builders: {'code': CodeElementBuilder(context)},
                        styleSheet: MarkdownStyleSheet(
                          p: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                          code: GoogleFonts.firaCode(backgroundColor: Colors.transparent, color: ext.primaryGradientStart),
                          codeblockPadding: EdgeInsets.zero,
                          codeblockDecoration: const BoxDecoration(), // Handled by builder
                        ),
                      ),
                      if (msg.activeTool != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 2, color: ext.primaryGradientStart),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                msg.activeTool!,
                                style: theme.textTheme.bodyMedium?.copyWith(color: ext.primaryGradientStart, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ).animate(onPlay: (controller) => controller.repeat()).shimmer(duration: 1.seconds, color: Colors.white30),
                        ),
                      if (!msg.isStreaming && !msg.isError && msg.content.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Tooltip(
                                message: 'Read aloud',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(4),
                                  onTap: () => ref.read(chatViewModelProvider.notifier).playAudio(msg.content, messageId: msg.id ?? msg.hashCode.toString()),
                                  child: Icon(
                                    ref.watch(chatViewModelProvider).currentlyPlayingMessageId == (msg.id ?? msg.hashCode.toString())
                                        ? Icons.stop_circle_outlined
                                        : Icons.volume_up_outlined,
                                    size: 16,
                                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5)
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              InkWell(
                                onTap: () => Clipboard.setData(ClipboardData(text: msg.content)),
                                child: Icon(Icons.copy_outlined, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                              ),
                              const SizedBox(width: 16),
                              InkWell(
                                onTap: () {
                                  // In a real app, open an edit dialog here
                                },
                                child: Icon(Icons.edit_outlined, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                              ),
                              const SizedBox(width: 16),
                              InkWell(
                                onTap: () {
                                  if (msg.id != null) {
                                    ref.read(chatViewModelProvider.notifier).submitFeedback(msg.id!, msg.feedback == 1 ? 0 : 1);
                                  }
                                },
                                child: Icon(
                                  msg.feedback == 1 ? Icons.thumb_up : Icons.thumb_up_outlined, 
                                  size: 16, 
                                  color: msg.feedback == 1 ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.5)
                                ),
                              ),
                              const SizedBox(width: 16),
                              InkWell(
                                onTap: () {
                                  if (msg.id != null) {
                                    ref.read(chatViewModelProvider.notifier).submitFeedback(msg.id!, msg.feedback == -1 ? 0 : -1);
                                  }
                                },
                                child: Icon(
                                  msg.feedback == -1 ? Icons.thumb_down : Icons.thumb_down_outlined, 
                                  size: 16, 
                                  color: msg.feedback == -1 ? theme.colorScheme.error : theme.colorScheme.onSurface.withValues(alpha: 0.5)
                                ),
                              ),
                              const SizedBox(width: 16),
                              InkWell(
                                onTap: () => ref.read(chatViewModelProvider.notifier).regenerateResponse(),
                                child: Icon(Icons.refresh_outlined, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  

  /// All providers and their models for global search.
  static const Map<String, List<String>> _allProviderModels = {
    'Google': ['gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-3.5-flash-lite', 'gemini-3.1-pro-preview', 'gemini-3.1-pro-preview-customtools', 'gemini-3.1-flash-lite-preview', 'gemini-3-pro-preview', 'gemini-3-flash-preview', 'gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.5-flash-lite'],
    'OpenAI': ['gpt-4o', 'gpt-4-turbo', 'gpt-3.5-turbo'],
    'Anthropic': ['claude-3-opus-20240229', 'claude-3-sonnet-20240229', 'claude-3-haiku-20240307'],
    'Mistral': ['mistral-large', 'mistral-medium', 'mistral-small'],
    'DeepSeek': ['deepseek-chat', 'deepseek-coder'],
    'groq': ['llama3-70b-8192', 'llama3-8b-8192', 'mixtral-8x7b-32768'],
  };

  Widget _buildModelSelectorPopup(BuildContext context) {
    final isSearching = _globalSearchQuery.isNotEmpty;

    // Build flat search results grouped by provider
    Widget buildSearchResults() {
      final results = <Widget>[];
      _allProviderModels.forEach((provider, models) {
        final matched = models.where((m) => m.toLowerCase().contains(_globalSearchQuery)).toList();
        if (matched.isEmpty) return;
        // Provider header
        results.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                _providerCircle(provider),
                const SizedBox(width: 8),
                Text(provider, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        );
        for (final model in matched) {
          results.add(_buildSubModelRow(model, isSelected: model == _selectedModel));
        }
      });
      if (results.isEmpty) {
        results.add(const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No models found', style: TextStyle(color: Color(0xFF878787), fontSize: 13)),
        ));
      }
      return ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 8), children: results);
    }

    return Material(
      color: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 360,
            constraints: const BoxConstraints(maxHeight: 650),
            decoration: BoxDecoration(
              color: const Color(0xFF171717),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF2A2A2A)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Global search field
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: TextField(
                    controller: _globalSearchController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    cursorColor: Colors.white,
                    onChanged: (val) => setState(() {
                      _globalSearchQuery = val.toLowerCase();
                      if (val.isNotEmpty) _hoveredProvider = null;
                    }),
                    decoration: InputDecoration(
                      hintText: 'Search models...',
                      hintStyle: const TextStyle(color: Color(0xFF6E6E6E), fontSize: 13),
                      prefixIcon: const Icon(Icons.search, color: Color(0xFF6E6E6E), size: 16),
                      prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      filled: true,
                      fillColor: const Color(0xFF1E1E1E),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF3A3A3A))),
                    ),
                  ),
                ),
                // Content: flat search results OR provider list
                Flexible(
                  child: isSearching
                      ? buildSearchResults()
                      : ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          children: [
                            _buildModelOptionRow(context, 'OpenAI', Colors.white, _selectedProvider == 'OpenAI'),
                            _buildModelOptionRow(context, 'Google', Colors.white, _selectedProvider == 'Google'),
                            _buildModelOptionRow(context, 'Anthropic', const Color(0xFFE5C07B), _selectedProvider == 'Anthropic'),
                            _buildModelOptionRow(context, '302AI', Colors.grey, _selectedProvider == '302AI'),
                            _buildModelOptionRow(context, 'APIpie', const Color(0xFF4CAF50), _selectedProvider == 'APIpie'),
                            _buildModelOptionRow(context, 'cohere', const Color(0xFF81C784), _selectedProvider == 'cohere'),
                            _buildModelOptionRow(context, 'DeepSeek', const Color(0xFF2196F3), _selectedProvider == 'DeepSeek'),
                            _buildModelOptionRow(context, 'Fireworks', Colors.white, _selectedProvider == 'Fireworks'),
                            _buildModelOptionRow(context, 'Github Models', Colors.white, _selectedProvider == 'Github Models'),
                            _buildModelOptionRow(context, 'glhf.chat', Colors.white, _selectedProvider == 'glhf.chat'),
                            _buildModelOptionRow(context, 'groq', const Color(0xFFF44336), _selectedProvider == 'groq'),
                            _buildModelOptionRow(context, 'HuggingFace', const Color(0xFFFFC107), _selectedProvider == 'HuggingFace'),
                            _buildModelOptionRow(context, 'Hyperbolic', const Color(0xFF673AB7), _selectedProvider == 'Hyperbolic'),
                            _buildModelOptionRow(context, 'Kluster', const Color(0xFF4CAF50), _selectedProvider == 'Kluster'),
                            _buildModelOptionRow(context, 'Mistral', const Color(0xFFFF9800), _selectedProvider == 'Mistral'),
                          ],
                        ),
                ),
              ],
            ),
          ),
          // Sub-panel: per-provider model list (only when not globally searching)
          if (!isSearching && _hoveredProvider != null) ...[
            const SizedBox(width: 4),
            Container(
              width: 320,
              constraints: const BoxConstraints(maxHeight: 650),
              decoration: BoxDecoration(
                color: const Color(0xFF171717),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF2A2A2A)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    child: TextField(
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      cursorColor: Colors.white,
                      controller: _searchController,
                      onChanged: (val) => setState(() => _searchQuery = val.toLowerCase()),
                      decoration: InputDecoration(
                        hintText: 'Search $_hoveredProvider models...',
                        hintStyle: const TextStyle(color: Color(0xFF6E6E6E), fontSize: 13),
                        prefixIcon: const Icon(Icons.search, color: Color(0xFF6E6E6E), size: 16),
                        prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF3A3A3A))),
                      ),
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      children: _getModelsForProvider(_hoveredProvider!)
                          .where((m) => _searchQuery.isEmpty || m.toLowerCase().contains(_searchQuery))
                          .map((model) {
                        final isSelected = model == _selectedModel;
                        return _buildSubModelRow(model, isSelected: isSelected);
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Small colored circle for a provider (used in search results header).
  Widget _providerCircle(String provider) {
    final colors = {
      'Google': Colors.white,
      'OpenAI': Colors.white,
      'Anthropic': const Color(0xFFE5C07B),
      'Mistral': const Color(0xFFFF9800),
      'DeepSeek': const Color(0xFF2196F3),
      'groq': const Color(0xFFF44336),
      'HuggingFace': const Color(0xFFFFC107),
      'Hyperbolic': const Color(0xFF673AB7),
      'cohere': const Color(0xFF81C784),
    };
    final color = colors[provider];
    if (color == null) return const SizedBox(width: 10);
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  List<String> _getModelsForProvider(String provider) {
    switch (provider) {
      case 'Google':
        return [
          'gemini-3.6-flash',
          'gemini-3.5-flash',
          'gemini-3.5-flash-lite',
          'gemini-3.1-pro-preview',
          'gemini-3.1-pro-preview-customtools',
          'gemini-3.1-flash-lite-preview',
          'gemini-3-pro-preview',
          'gemini-3-flash-preview',
          'gemini-2.5-pro',
          'gemini-2.5-flash',
          'gemini-2.5-flash-lite',
        ];
      case 'OpenAI':
        return ['gpt-4o', 'gpt-4-turbo', 'gpt-3.5-turbo'];
      case 'Anthropic':
        return ['claude-3-opus-20240229', 'claude-3-sonnet-20240229', 'claude-3-haiku-20240307'];
      default:
        return ['model-a', 'model-b', 'model-c'];
    }
  }

  /// Returns a small colored circle representing the AI provider,
  /// inferred from the model name. Returns empty SizedBox for unknown providers.
  Widget _providerDotFor(String model) {
    Color? color;
    if (model.startsWith('gemini')) {
      color = Colors.white; // Google
    } else if (model.startsWith('gpt') || model.startsWith('o1') || model.startsWith('o3')) {
      color = Colors.white; // OpenAI
    } else if (model.startsWith('claude')) {
      color = const Color(0xFFFF8C42); // Anthropic
    } else if (model.startsWith('mistral') || model.startsWith('mixtral')) {
      color = const Color(0xFFFF9800); // Mistral
    } else if (model.startsWith('deepseek')) {
      color = const Color(0xFF2196F3); // DeepSeek
    } else if (model.startsWith('groq') || model.contains('llama')) {
      color = const Color(0xFFF44336); // Groq
    }
    if (color == null) return const SizedBox(width: 8);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _buildSubModelRow(String name, {bool isSelected = false, bool isPinned = false}) {
    final isHovered = _hoveredModel == name;
    final actuallyPinned = _pinnedModels.contains(name);
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredModel = name),
      onExit: (_) => setState(() {
        if (_hoveredModel == name) _hoveredModel = null;
      }),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            setState(() {
              _selectedModel = name;
              if (_hoveredProvider != null) _selectedProvider = _hoveredProvider!;
              _isModelSelectorOpen = false;
              _searchQuery = '';
              _searchController.clear();
            });
          },
          hoverColor: const Color(0xFF2F2F2F),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 36,
            margin: const EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: isSelected || isHovered ? const Color(0xFF2F2F2F) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                if (isSelected)
                  Positioned(
                    left: 0,
                    top: 8,
                    child: Container(
                      width: 3,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(
                          color: isSelected ? Colors.white : const Color(0xFFB4B4B4),
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                    // Show pin icon on hover OR if already pinned
                    if (isHovered || actuallyPinned) ...[
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            if (actuallyPinned) {
                              _pinnedModels.remove(name);
                            } else {
                              _pinnedModels.add(name);
                            }
                          });
                        },
                        child: Tooltip(
                          message: actuallyPinned ? 'Unpin model' : 'Pin model',
                          child: Icon(
                            actuallyPinned ? Icons.push_pin : Icons.push_pin_outlined,
                            color: actuallyPinned ? Colors.white : const Color(0xFF6E6E6E),
                            size: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (isSelected) ...[
                      const Icon(Icons.check_circle_outline, color: Colors.white, size: 16),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModelOptionRow(BuildContext context, String name, Color circleColor, bool isSelected) {
    final isHovered = _hoveredProvider == name;
    return MouseRegion(
      onEnter: (_) {
        if (_hoveredProvider != name) {
          setState(() => _hoveredProvider = name);
        }
      },
      child: InkWell(
        onTap: () {
          setState(() {
            _isModelSelectorOpen = false;
            _hoveredProvider = null;
          });
        },
        child: Container(
          height: 36,
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: isSelected || isHovered ? const Color(0xFF2F2F2F) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              if (isSelected)
                Positioned(
                  left: 0,
                  top: 8,
                  child: Container(
                    width: 3,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ),
              Row(
                children: [
                  const SizedBox(width: 16),
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: circleColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      name,
                      style: TextStyle(
                        color: isSelected ? Colors.white : const Color(0xFFB4B4B4),
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _isModelSelectorOpen = false;
                        _hoveredProvider = null;
                        _hoveredGearProvider = null;
                      });
                      showDialog(
                        context: context,
                        builder: (context) => ApiKeyDialog(providerName: name),
                      );
                    },
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _hoveredGearProvider = name),
                      onExit: (_) => setState(() => _hoveredGearProvider = null),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.settings_outlined,
                            color: isSelected ? Colors.white : const Color(0xFF6E6E6E),
                            size: 16,
                          ),
                          if (_hoveredGearProvider == name) ...[
                            const SizedBox(width: 6),
                            const Text('Set API Key', style: TextStyle(color: Colors.white, fontSize: 12)),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (isSelected) ...[
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.check_circle_outline,
                      color: Colors.white,
                      size: 16,
                    ),
                  ],
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right,
                    color: isSelected ? Colors.white : const Color(0xFF6E6E6E),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
