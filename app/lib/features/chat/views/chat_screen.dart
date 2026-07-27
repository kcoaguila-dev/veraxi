import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/core/theme_provider.dart';
import 'dart:ui';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 100, // Overscroll slightly
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _sendMessage(ChatViewModel viewModel) {
    if (_textController.text.isNotEmpty) {
      viewModel.sendMessage(_textController.text);
      _textController.clear();
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
      drawer: _buildDrawer(state, viewModel, theme, ext),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: state.isLoadingHistory 
                    ? Center(child: CircularProgressIndicator(color: theme.colorScheme.primary))
                    : state.messages.isEmpty
                        ? _buildEmptyState(theme, ext)
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
            
            // Top Left Model Selector (Floating)
            Positioned(
              top: 16,
              left: 16,
              child: GestureDetector(
                onTap: () => _showModelSelector(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Select AI Model', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: Colors.white)),
                      const SizedBox(width: 8),
                      const Icon(Icons.keyboard_arrow_down, size: 20, color: Colors.white),
                    ],
                  ),
                ),
              ),
            ),
            
            // Hamburger Menu for mobile (only if narrow screen, optional)
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.menu, color: Colors.white),
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
            
            // Floating Input Area at Bottom
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 660),
                  child: _buildInputArea(viewModel, theme),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, AppThemeExtension ext) {
    return Center(
      child: Text(
        'Good afternoon, Guest',
        style: theme.textTheme.headlineMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ).animate().fade(duration: 800.ms).slideY(begin: 0.1, end: 0),
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
                final threadId = state.pastThreads[index];
                return ListTile(
                  leading: Icon(Icons.chat_bubble_outline, color: theme.colorScheme.onSurface.withValues(alpha: 0.5), size: 20),
                  title: Text(threadId.substring(0, 8) + '...', style: theme.textTheme.bodyMedium),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              margin: const EdgeInsets.only(right: 12, top: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.smart_toy, color: ext.primaryGradientStart, size: 16),
            ),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser ? theme.colorScheme.primary : ext.surfaceHighlight,
                borderRadius: BorderRadius.circular(16).copyWith(
                  bottomRight: isUser ? const Radius.circular(0) : const Radius.circular(16),
                  bottomLeft: !isUser ? const Radius.circular(0) : const Radius.circular(16),
                ),
                border: isUser ? null : Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
              ),
              child: isUser 
                ? Text(
                    msg.content,
                    style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onPrimary),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarkdownBody(
                        data: msg.content.isEmpty && msg.isStreaming ? '...' : msg.content,
                        styleSheet: MarkdownStyleSheet(
                          p: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                          code: GoogleFonts.firaCode(backgroundColor: theme.colorScheme.surface, color: ext.primaryGradientStart),
                          codeblockDecoration: BoxDecoration(
                            color: theme.scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
                          ),
                        ),
                      ),
                      if (msg.activeTool != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
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
                    ],
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea(ChatViewModel viewModel, ThemeData theme) {
    final ext = theme.extension<AppThemeExtension>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F2F),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Color(0xFFB4B4B4)),
            onPressed: () {},
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: TextField(
                controller: _textController,
                style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white),
                maxLines: 5,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (value) {
                  _sendMessage(viewModel);
                },
                decoration: InputDecoration(
                  hintText: 'Message Veraxi...',
                  hintStyle: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFF878787)),
                  border: InputBorder.none,
                  filled: false,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.mic_none, color: Color(0xFFB4B4B4)),
            onPressed: () {},
          ),
          GestureDetector(
            onTap: () => _sendMessage(viewModel),
            child: Container(
              margin: const EdgeInsets.all(4),
              height: 40,
              width: 40,
              decoration: const BoxDecoration(
                color: Color(0xFF424242),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.arrow_upward, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  void _showModelSelector(BuildContext context) {
    final theme = Theme.of(context);
    
    // Instead of a bottom sheet, show a dialog positioned near the top-left
    showDialog(
      context: context,
      barrierColor: Colors.transparent, // transparent background
      builder: (context) {
        return Stack(
          children: [
            Positioned(
              top: 64, // Just below the "Select AI Model" button
              left: 16,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: 220,
                  height: 380,
                  decoration: BoxDecoration(
                    color: const Color(0xFF171717),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF333333)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // Search Bar
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Container(
                          height: 32,
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFB4B4B4)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.centerLeft,
                          child: const Text('Search models...', style: TextStyle(color: Color(0xFF878787), fontSize: 12)),
                        ),
                      ),
                      // Model List
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                          children: [
                            _buildModelOptionRow(context, 'OpenAI', Colors.white, false),
                            _buildModelOptionRow(context, 'Google', Colors.white, true),
                            _buildModelOptionRow(context, 'Anthropic', const Color(0xFFE3E3E3), false),
                            _buildModelOptionRow(context, '302AI', const Color(0xFFE3E3E3), false),
                            _buildModelOptionRow(context, 'APIpie', const Color(0xFF10B981), false),
                            _buildModelOptionRow(context, 'cohere', const Color(0xFFE3E3E3), false),
                            _buildModelOptionRow(context, 'DeepSeek', const Color(0xFF3B82F6), false),
                            _buildModelOptionRow(context, 'Fireworks', const Color(0xFFE3E3E3), false),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildModelOptionRow(BuildContext context, String name, Color circleColor, bool isSelected) {
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        height: 36,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF2F2F2F) : Colors.transparent,
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
                Icon(Icons.settings_outlined, color: isSelected ? Colors.white : const Color(0xFF878787), size: 16),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right, color: isSelected ? Colors.white : const Color(0xFF878787), size: 18),
                const SizedBox(width: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
