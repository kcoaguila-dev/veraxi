
import 'package:veraxi_app/features/chat/view_models/audio_player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/agentic_tool_log.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_metrics.dart';
import 'package:veraxi_app/features/chat/views/widgets/markdown_citation_builder.dart';
import 'package:veraxi_app/features/chat/views/widgets/markdown_code_builder.dart';
import 'package:veraxi_app/core/providers/active_sources_provider.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/services.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_button.dart';
import 'package:veraxi_app/features/chat/views/widgets/global_audio_player.dart';
class ChatMessageListItem extends ConsumerWidget {
  final ChatMessage msg;
  final ThemeData theme;
  final AppThemeExtension ext;
  final bool showTelemetry;
  

  const ChatMessageListItem({
    super.key,
    required this.msg,
    required this.theme,
    required this.ext,
    required this.showTelemetry,
    
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _buildChatMessageActual(msg, theme, ext, showTelemetry: showTelemetry, context: context, ref: ref);
  }

  // We change the signature to pass context since it was previously available in the State.
  Widget _buildChatMessageActual(
      ChatMessage msg, ThemeData theme, AppThemeExtension ext,
      {bool showTelemetry = false, required BuildContext context, required WidgetRef ref}) {
    final isUser = msg.role == 'user';
    final name = isUser
        ? 'User'
        : (msg.modelName != null && msg.modelName!.isNotEmpty
            ? msg.modelName!
            : 'AI Assistant');
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
            child: msg.modelName != null && msg.modelName!.isNotEmpty
                ? _providerDotFor(msg.modelName!, size: 16)
                : Icon(Icons.auto_awesome,
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
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                msg.content,
                                style: theme.textTheme.bodyLarge
                                    ?.copyWith(height: 1.5),
                              ),
                              Padding(
                                padding: EdgeInsets.only(top: 12),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Tooltip(
                                      message: 'Copy message',
                                      child: InkWell(
                                        onTap: () => Clipboard.setData(
                                            ClipboardData(text: msg.content)),
                                        child: Icon(Icons.copy_outlined,
                                            size: 16,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        else if (msg.isError)
                          Container(
                            margin: EdgeInsets.only(top: 8),
                            padding: EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(
                                  0xFF3F1515), // Dark red background
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: const Color(0xFFB91C1C)), // Red border
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.refresh,
                                    color: Color(0xFFFCA5A5), size: 18),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    msg.content,
                                    style: TextStyle(
                                        color: Color(0xFFFCA5A5),
                                        fontSize: 14), // Light red text
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 1. Thinking / Active Tool Indicator
                              if (msg.isStreaming && msg.content.isEmpty)
                                Padding(
                                  padding: EdgeInsets.only(bottom: 16),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: ext.primaryGradientStart),
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Thinking...',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                                color: ext.primaryGradientStart,
                                                fontWeight: FontWeight.w500,
                                                fontStyle: FontStyle.italic),
                                      ),
                                    ],
                                  )
                                      .animate(
                                          onPlay: (controller) =>
                                              controller.repeat())
                                      .shimmer(
                                          duration: 1.seconds,
                                          color: Colors.white30),
                                ),

                              // 3. Completed Tool Events
                              if (msg.toolEvents.isNotEmpty)
                                Padding(
                                  padding: EdgeInsets.only(bottom: 16.0),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: msg.toolEvents
                                        .map((te) => AgenticToolLog(event: te))
                                        .toList(),
                                  ),
                                ),

                              if (msg.content.isNotEmpty)
                                MarkdownBody(
                                  data: msg.content,
                                  extensionSet: md.ExtensionSet(
                                    md.ExtensionSet.gitHubFlavored
                                        .blockSyntaxes,
                                    [
                                      CitationSyntax(),
                                      ...md.ExtensionSet.gitHubFlavored
                                          .inlineSyntaxes,
                                    ],
                                  ),
                                  builders: {
                                    'code': CodeElementBuilder(context),
                                    'a': CitationElementBuilder(message: msg),
                                    'cite':
                                        CitationElementBuilder(message: msg),
                                  },
                                  styleSheet: MarkdownStyleSheet(
                                    p: theme.textTheme.bodyLarge
                                        ?.copyWith(height: 1.5),
                                    code: GoogleFonts.firaCode(
                                        backgroundColor: Colors.transparent,
                                        color: ext.primaryGradientStart),
                                    codeblockPadding: EdgeInsets.zero,
                                    codeblockDecoration:
                                        BoxDecoration(), // Handled by builder
                                  ),
                                ),
                              if (!msg.isStreaming &&
                                  !msg.isError &&
                                  msg.content.isNotEmpty)
                                Padding(
                                  padding: EdgeInsets.only(top: 16),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Tooltip(
                                        message: 'Read aloud',
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          onTap: () {
                                            final msgId = msg.id ??
                                                msg.hashCode.toString();
                                            ref
                                                .read(audioPlayerServiceProvider
                                                    .notifier)
                                                .playMessage(
                                                    msgId, msg.content);
                                          },
                                          child: Icon(
                                              ref
                                                              .watch(
                                                                  audioPlayerServiceProvider)
                                                              .playingMessageId ==
                                                          (msg.id ??
                                                              msg.hashCode
                                                                  .toString()) &&
                                                      ref
                                                          .watch(
                                                              audioPlayerServiceProvider)
                                                          .isPlaying
                                                  ? Icons.pause_circle_outline
                                                  : Icons.volume_up_outlined,
                                              size: 16,
                                              color: theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.5)),
                                        ),
                                      ),
                                      SizedBox(width: 16),
                                      InkWell(
                                        onTap: () => Clipboard.setData(
                                            ClipboardData(text: msg.content)),
                                        child: Icon(Icons.copy_outlined,
                                            size: 16,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                      SizedBox(width: 16),
                                      InkWell(
                                        onTap: () {
                                          // In a real app, open an edit dialog here
                                        },
                                        child: Icon(Icons.edit_outlined,
                                            size: 16,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                      SizedBox(width: 16),
                                      InkWell(
                                        onTap: () {
                                          if (msg.id != null) {
                                            ref
                                                .read(chatViewModelProvider
                                                    .notifier)
                                                .submitFeedback(msg.id!,
                                                    msg.feedback == 1 ? 0 : 1);
                                          }
                                        },
                                        child: Icon(
                                            msg.feedback == 1
                                                ? Icons.thumb_up
                                                : Icons.thumb_up_outlined,
                                            size: 16,
                                            color: msg.feedback == 1
                                                ? theme.colorScheme.primary
                                                : theme.colorScheme.onSurface
                                                    .withValues(alpha: 0.5)),
                                      ),
                                      SizedBox(width: 16),
                                      InkWell(
                                        onTap: () {
                                          if (msg.id != null) {
                                            ref
                                                .read(chatViewModelProvider
                                                    .notifier)
                                                .submitFeedback(
                                                    msg.id!,
                                                    msg.feedback == -1
                                                        ? 0
                                                        : -1);
                                          }
                                        },
                                        child: Icon(
                                            msg.feedback == -1
                                                ? Icons.thumb_down
                                                : Icons.thumb_down_outlined,
                                            size: 16,
                                            color: msg.feedback == -1
                                                ? theme.colorScheme.error
                                                : theme.colorScheme.onSurface
                                                    .withValues(alpha: 0.5)),
                                      ),
                                      SizedBox(width: 16),
                                      InkWell(
                                        onTap: () => ref
                                            .read(
                                                chatViewModelProvider.notifier)
                                            .regenerateResponse(),
                                        child: Icon(Icons.refresh_outlined,
                                            size: 16,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                      SizedBox(width: 16),
                                      Tooltip(
                                        message: 'Save to Memory',
                                        child: InkWell(
                                          onTap: () {
                                            ref
                                                .read(chatViewModelProvider
                                                    .notifier)
                                                .saveToMemory(msg.content,
                                                    model: msg.modelName ??
                                                        'gpt-4o');
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text('Saved to Memory',
                                                    style: TextStyle(
                                                        color: Colors.white)),
                                                backgroundColor:
                                                    Color(0xFF4CAF50),
                                                behavior:
                                                    SnackBarBehavior.floating,
                                                duration: Duration(seconds: 2),
                                              ),
                                            );
                                          },
                                          child: Icon(Icons.psychology_outlined,
                                              size: 18,
                                              color: theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.5)),
                                        ),
                                      ),
                                      if (msg.toolEvents.any((e) =>
                                          (e.name.contains('web_search') ||
                                              e.name.contains('merge_rank')) &&
                                          e.result != null)) ...[
                                        SizedBox(width: 16),
                                        SourcesButton(
                                          message: msg,
                                          onSourceClicked: () {
                                            ref
                                                    .read(activeSourcesProvider
                                                        .notifier)
                                                    .state =
                                                SourcesButton.extractSources(
                                                    msg);
                                            Scaffold.of(context).openEndDrawer();
                                          },
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              if (ref
                                      .watch(audioPlayerServiceProvider)
                                      .playingMessageId ==
                                  (msg.id ?? msg.hashCode.toString()))
                                GlobalAudioPlayer(
                                    messageId:
                                        msg.id ?? msg.hashCode.toString()),
                              if (!isUser &&
                                  showTelemetry &&
                                  msg.metrics != null &&
                                  msg.metrics!.isNotEmpty)
                                ChatMessageMetrics(metrics: msg.metrics!),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            )));
  }

  // Removed hardcoded _allProviderModels

  Widget _providerDotFor(String model, {double size = 14}) {
    String? assetPath;
    if (model.startsWith('gemini')) {
      assetPath = 'assets/icons/google.svg';
    } else if (model.startsWith('gpt') ||
        model.startsWith('o1') ||
        model.startsWith('o3')) {
      assetPath = 'assets/icons/openai.svg';
    } else if (model.startsWith('claude')) {
      assetPath = 'assets/icons/anthropic.svg';
    } else if (model.startsWith('deepseek')) {
      assetPath = 'assets/icons/deepseek.svg';
    } else if (model.startsWith('groq') ||
        model.contains('llama') ||
        model.startsWith('qwen') ||
        model.startsWith('allam') ||
        model.startsWith('meta')) {
      assetPath = 'assets/icons/groq.svg';
    } else if (model.startsWith('mistral') || model.startsWith('mixtral')) {
      assetPath = 'assets/icons/mistral.svg';
    }

    if (assetPath != null) {
      final lowerModel = model.toLowerCase();
      Color iconColor = Colors.white;
      if (lowerModel.startsWith('claude')) {
        iconColor = const Color(0xFFd97757);
      } else if (lowerModel.startsWith('groq') ||
          lowerModel.contains('llama') ||
          lowerModel.startsWith('qwen') ||
          lowerModel.startsWith('allam') ||
          lowerModel.startsWith('meta')) {
        iconColor = const Color(0xFFf55036);
      } else if (lowerModel.startsWith('mistral') ||
          lowerModel.startsWith('mixtral')) {
        iconColor = const Color(0xFFFF9800);
      }

      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: SvgPicture.asset(
            assetPath,
            width: size,
            height: size,
            colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
          ),
        ),
      );
    }

    Color? color;
    if (model.startsWith('mistral') || model.startsWith('mixtral')) {
      color = const Color(0xFFFF9800); // Mistral
    }

    if (color == null) return SizedBox(width: size);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  

  

}