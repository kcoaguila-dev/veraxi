import 'package:veraxi_app/features/chat/views/widgets/markdown_citation_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:go_router/go_router.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/chat_thread_provider.dart';
import 'package:veraxi_app/core/widgets/profile_menu_button.dart';

/// Does not require BuildContext unlike the full CodeElementBuilder in chat_screen.dart.
class _CodeBuilder extends MarkdownElementBuilder {
  final ThemeData theme;
  final AppThemeExtension ext;

  _CodeBuilder(this.theme, this.ext);
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final isBlock = element.textContent.contains('\n') ||
        element.attributes.keys.any((k) => k.startsWith('class'));
    if (!isBlock) return null;
    return Container(
      width: double.infinity,
      margin: EdgeInsets.symmetric(vertical: 4),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ext.borderColor),
      ),
      child: Text(
        element.textContent,
        style: TextStyle(
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

  List<ChatMessage> _mapHistory(List<Map<String, dynamic>> history) {
    return history.map((m) {
      return ChatMessage(
        role: m['role'] as String,
        content: m['content'] as String,
        modelName: m['model'] as String?,
        toolEvents: [], // Simplified for V1
      );
    }).toList();
  }

  Widget _buildChatMessage(
      ChatMessage msg, ThemeData theme, AppThemeExtension ext) {
    final isUser = msg.role == 'user';
    final name =
        isUser ? resolveDisplayName() : (msg.modelName ?? 'AI Assistant');
    final avatar = isUser
        ? Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(6)),
            child: Icon(Icons.person, color: Colors.white, size: 18),
          )
        : Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.transparent),
            child: Icon(Icons.auto_awesome,
                color: ext.primaryGradientStart, size: 20),
          );

    return Center(
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  avatar,
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Colors.white)),
                        SizedBox(height: 8),
                        if (isUser)
                          Text(msg.content,
                              style: theme.textTheme.bodyLarge
                                  ?.copyWith(height: 1.5))
                        else
                          MarkdownBody(
                            data: msg.content,
                            selectable: true,
                            extensionSet: md.ExtensionSet(
                              md.ExtensionSet.gitHubFlavored.blockSyntaxes,
                              [
                                CitationSyntax(),
                                ...md
                                    .ExtensionSet.gitHubFlavored.inlineSyntaxes,
                              ],
                            ),
                            builders: {
                              'code': _CodeBuilder(theme, ext),
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
                              code: TextStyle(
                                  fontFamily: 'monospace',
                                  backgroundColor: ext.borderColor,
                                  color: Color(0xFFE5E7EB)),
                              codeblockDecoration: BoxDecoration(
                                color: ext.borderColor,
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
    final historyAsync = ref.watch(sharedThreadHistoryProvider(widget.shareId));

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title:
            Text('Shared Conversation', style: TextStyle(fontSize: 14)),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.home_outlined),
          onPressed: () => context.go('/'),
        ),
      ),
      body: historyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
            child: Text('Failed to load shared conversation: $e',
                style: TextStyle(color: Colors.red))),
        data: (history) {
          final messages = _mapHistory(history);
          return ListView.builder(
            padding: EdgeInsets.only(bottom: 120),
            itemCount: messages.length,
            itemBuilder: (context, index) {
              return _buildChatMessage(messages[index], theme, ext!);
            },
          );
        },
      ),
    );
  }
}
