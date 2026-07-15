import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:convert';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:veraxi_app/features/chat/views/widgets/graph_artifact.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        padding: const EdgeInsets.all(16.0),
        decoration: BoxDecoration(
          color: message.isUser ? AppTheme.primary : AppTheme.surfaceHighlight.withAlpha(128),
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: message.isUser ? const Radius.circular(0) : const Radius.circular(16),
            bottomLeft: !message.isUser ? const Radius.circular(0) : const Radius.circular(16),
          ),
          border: message.isUser
              ? null
              : Border.all(color: AppTheme.surfaceHighlight, width: 1),
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
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded['type'] == 'graph') {
        final elements = jsonEncode(decoded['elements'] ?? []);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_graph, color: AppTheme.primary, size: 18),
                SizedBox(width: 8),
                Text('Graph Visualization Artifact', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
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
        p: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        code: const TextStyle(
          backgroundColor: AppTheme.surface,
          fontFamily: 'monospace',
        ),
        codeblockDecoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
