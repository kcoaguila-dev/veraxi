import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_highlighter/flutter_highlighter.dart';
import 'package:flutter_highlighter/themes/atom-one-dark.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_button.dart';
import 'package:veraxi_app/features/chat/views/widgets/citation_chip.dart';
import 'package:veraxi_app/features/chat/views/chat_screen.dart' show CitationSyntax, CitationElementBuilder;
import 'package:veraxi_app/core/widgets/profile_menu_button.dart';
import 'package:flutter/services.dart';

/// Lightweight code block builder for the read-only shared chat view.
/// Does not require BuildContext unlike the full CodeElementBuilder in chat_screen.dart.
class _CodeBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final isBlock = element.textContent.contains('\n') ||
        element.attributes.keys.any((k) => k.startsWith('class'));
    if (!isBlock) return null;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Text(
        element.textContent,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: Color(0xFFE5E7EB),
          height: 1.5,
        ),
      ),
    );
  }
}

class SharedChatScreen extends ConsumerStatefulWidget {
  final String shareId;
  const SharedChatScreen({super.key, required this.shareId});

  @override
  ConsumerState<SharedChatScreen> createState() => _SharedChatScreenState();
}

class _SharedChatScreenState extends ConsumerState<SharedChatScreen> {
  List<ChatMessage> _messages = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSharedHistory();
  }

  Future<void> _loadSharedHistory() async {
    try {
      final repo = ref.read(chatRepositoryProvider);
      final history = await repo.getSharedThreadHistory(widget.shareId);
      final messages = history.map((m) {
        return ChatMessage(
          role: m['role'] as String,
          content: m['content'] as String,
          modelName: m['model'] as String?,
          toolEvents: [], // Simplified for V1
        );
      }).toList();

      setState(() {
        _messages = messages;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = "Failed to load shared conversation: $e";
        _isLoading = false;
      });
    }
  }

  Widget _buildChatMessage(ChatMessage msg, ThemeData theme, AppThemeExtension ext) {
    final isUser = msg.role == 'user';
    final name = isUser ? resolveDisplayName() : (msg.modelName ?? 'AI Assistant');
    final avatar = isUser
        ? Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(6)),
            child: const Icon(Icons.person, color: Colors.white, size: 18),
          )
        : Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Colors.transparent),
            child: Icon(Icons.auto_awesome, color: ext?.primaryGradientStart ?? Colors.blueAccent, size: 20),
          );

    return Center(
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Padding(
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
                        Text(name,
                            style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Colors.white)),
                        const SizedBox(height: 8),
                        if (isUser)
                          Text(msg.content, style: theme.textTheme.bodyLarge?.copyWith(height: 1.5))
                        else
                          MarkdownBody(
                            data: msg.content,
                            selectable: true,
                            extensionSet: md.ExtensionSet(
                              md.ExtensionSet.gitHubFlavored.blockSyntaxes,
                              [
                                CitationSyntax(),
                                ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
                              ],
                            ),
                            builders: {
                              'code': _CodeBuilder(),
                              'a': CitationElementBuilder(message: msg),
                              'cite': CitationElementBuilder(message: msg),
                            },
                            styleSheet: MarkdownStyleSheet(
                              p: theme.textTheme.bodyLarge?.copyWith(
                                  height: 1.6, color: const Color(0xFFD1D5DB)),
                              h1: theme.textTheme.headlineMedium
                                  ?.copyWith(color: Colors.white),
                              h2: theme.textTheme.headlineSmall
                                  ?.copyWith(color: Colors.white),
                              h3: theme.textTheme.titleLarge
                                  ?.copyWith(color: Colors.white),
                              code: const TextStyle(
                                  fontFamily: 'monospace',
                                  backgroundColor: Color(0xFF2A2A2A),
                                  color: Color(0xFFE5E7EB)),
                              codeblockDecoration: BoxDecoration(
                                color: const Color(0xFF2A2A2A),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            )));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Shared Conversation', style: TextStyle(fontSize: 14)),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.home_outlined),
          onPressed: () => context.go('/'),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 120),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    return _buildChatMessage(_messages[index], theme, ext!);
                  },
                ),
    );
  }
}
