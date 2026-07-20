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
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Veraxi Intelligence', style: theme.textTheme.titleLarge),
        centerTitle: true,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        actions: [
          IconButton(
            icon: Icon(
              theme.brightness == Brightness.dark ? Icons.light_mode : Icons.dark_mode,
            ),
            onPressed: () {
              ref.read(themeProvider.notifier).toggle();
            },
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              viewModel.startNewChat();
            },
          )
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: state.isLoadingHistory 
                ? Center(child: CircularProgressIndicator(color: theme.colorScheme.primary))
                : state.messages.isEmpty
                    ? _buildEmptyState(theme, ext)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                        itemCount: state.messages.length,
                        itemBuilder: (context, index) {
                          final msg = state.messages[index];
                          return _buildChatMessage(msg, theme, ext);
                        },
                      ),
            ),
            _buildInputArea(viewModel, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, AppThemeExtension ext) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
            ),
            child: Icon(Icons.hub_outlined, size: 64, color: ext.primaryGradientStart),
          ).animate().fade(duration: 800.ms).scale(curve: Curves.easeOutBack),
          const SizedBox(height: 24),
          Text(
            'How can I help you today?',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 24),
          ).animate().fade(delay: 200.ms, duration: 600.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: 8),
          Text(
            'Query the knowledge graph, analyze architecture,\nor explore codebase insights.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
          ).animate().fade(delay: 400.ms, duration: 600.ms).slideY(begin: 0.2, end: 0),
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
    return Container(
      padding: const EdgeInsets.all(16).copyWith(bottom: 16 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.onSurface.withValues(alpha: 0.1))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
                  ),
                  child: TextField(
                    controller: _textController,
                    style: theme.textTheme.bodyLarge,
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (value) {
                      _sendMessage(viewModel);
                    },
                    decoration: InputDecoration(
                      hintText: 'Message Veraxi...',
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                      border: InputBorder.none,
                      filled: false,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => _sendMessage(viewModel),
            child: Container(
              height: 52,
              width: 52,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(26),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.4),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  )
                ],
              ),
              child: Icon(Icons.send_rounded, color: theme.colorScheme.onPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
