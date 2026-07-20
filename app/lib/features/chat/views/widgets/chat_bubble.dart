import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:convert';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:veraxi_app/features/chat/views/widgets/graph_artifact.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        padding: const EdgeInsets.all(16.0),
        decoration: BoxDecoration(
          color: message.isUser ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: message.isUser ? const Radius.circular(0) : const Radius.circular(16),
            bottomLeft: !message.isUser ? const Radius.circular(0) : const Radius.circular(16),
          ),
          border: message.isUser
              ? null
              : Border.all(color: theme.colorScheme.outlineVariant, width: 1),
        ),
        child: message.isUser
            ? Text(
                message.text,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              )
            : _buildBotMessage(context, message.text),
      ).animate().fade(duration: 300.ms).slideY(begin: 0.1, duration: 300.ms),
    );
  }

  Widget _buildBotMessage(BuildContext context, String text) {
    final theme = Theme.of(context);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded['type'] == 'graph') {
        final elements = jsonEncode(decoded['elements'] ?? []);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_graph, color: theme.colorScheme.primary, size: 18),
                const SizedBox(width: 8),
                Text('Graph Visualization Artifact', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            GraphArtifact(jsonElements: elements),
          ],
        );
      }
    } catch (_) {
      // Not a valid graph JSON, fall back to markdown
    }

    return MarkdownBody(
      data: text,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(color: theme.colorScheme.onSurface, fontSize: 16),
        code: TextStyle(
          backgroundColor: theme.colorScheme.surface,
          fontFamily: 'monospace',
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
