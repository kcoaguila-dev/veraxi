import 'dart:async';

import 'package:veraxi_app/features/chat/view_models/audio_player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:veraxi_app/core/models/model_provider_mapper.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_metrics.dart';
import 'package:veraxi_app/features/chat/views/widgets/tool_event_card.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_activity_disclosure.dart';
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
    return _buildChatMessageActual(msg, theme, ext,
        showTelemetry: showTelemetry, context: context, ref: ref);
  }

  // We change the signature to pass context since it was previously available in the State.
  Widget _buildChatMessageActual(
      ChatMessage msg, ThemeData theme, AppThemeExtension ext,
      {bool showTelemetry = false,
      required BuildContext context,
      required WidgetRef ref}) {
    final isUser = msg.role == 'user';
    final responseAt = _responseAt(msg);
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
                              // 1. Step & Active Tool Indicator (Claude / AnythingLLM Parity)
                              if (msg.isStreaming &&
                                  (msg.content.isEmpty ||
                                      msg.activeTool != null))
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: ext.primaryGradientStart
                                          .withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: ext.primaryGradientStart
                                            .withValues(alpha: 0.25),
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 1.5,
                                              color: ext.primaryGradientStart),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          msg.activeTool ??
                                              'Thinking & formulating plan...',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                  color:
                                                      ext.primaryGradientStart,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  )
                                      .animate(
                                          onPlay: (controller) =>
                                              controller.repeat())
                                      .shimmer(
                                          duration: 1.seconds,
                                          color: Colors.white30),
                                ),

                              if (msg.activity.isNotEmpty ||
                                  (msg.reasoning?.isNotEmpty ?? false))
                                ChatActivityDisclosure(
                                  activity: msg.activity,
                                  isStreaming: msg.isStreaming,
                                  reasoning: msg.reasoning,
                                  reasoningDurationSeconds:
                                      msg.reasoningDurationSeconds,
                                )
                              else if (msg.toolEvents.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16.0),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: msg.toolEvents
                                        .map((te) => ToolEventCard(event: te))
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
                                          child: Icon(Icons.volume_up_outlined,
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
                                      if (responseAt != null) ...[
                                        const SizedBox(width: 16),
                                        _RelativeTimeLabel(
                                          timestamp: responseAt,
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: 0.55),
                                        ),
                                      ],
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
                                            Scaffold.of(context)
                                                .openEndDrawer();
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

  DateTime? _responseAt(ChatMessage msg) {
    final value = msg.metrics?['response_at'];
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        (value * 1000).round(),
        isUtc: true,
      );
    }
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  Widget _providerDotFor(String model, {double size = 14}) {
    // Resolve via the shared mapper so provider-prefixed ids such as
    // `openai/gpt-oss-20b` (served by Groq) get the right icon.
    final provider = model.endsWith('.gguf')
        ? 'local'
        : (model.toLowerCase().startsWith('mistral') ||
                model.toLowerCase().startsWith('mixtral'))
            ? 'mistral'
            : ModelProviderMapper.resolve(model);

    final String? assetPath = switch (provider) {
      'local' => 'assets/icons/local.svg',
      'google' => 'assets/icons/google.svg',
      'openai' => 'assets/icons/openai.svg',
      'anthropic' => 'assets/icons/anthropic.svg',
      'deepseek' => 'assets/icons/deepseek.svg',
      'groq' => 'assets/icons/groq.svg',
      'mistral' => 'assets/icons/mistral.svg',
      'kimi' => 'assets/icons/kimi.svg',
      _ => null,
    };
    if (assetPath == null) return SizedBox(width: size);

    final Color iconColor = switch (provider) {
      'anthropic' => const Color(0xFFd97757),
      'groq' => const Color(0xFFf55036),
      'mistral' => const Color(0xFFFF9800),
      _ => Colors.white,
    };

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
}

class _RelativeTimeLabel extends StatefulWidget {
  const _RelativeTimeLabel({
    required this.timestamp,
    required this.color,
  });

  final DateTime timestamp;
  final Color color;

  @override
  State<_RelativeTimeLabel> createState() => _RelativeTimeLabelState();
}

class _RelativeTimeLabelState extends State<_RelativeTimeLabel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scheduleNextUpdate();
  }

  @override
  void didUpdateWidget(_RelativeTimeLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timestamp != widget.timestamp) _scheduleNextUpdate();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleNextUpdate() {
    _timer?.cancel();
    final age = DateTime.now().difference(widget.timestamp);
    final delay = age.inMinutes < 1
        ? const Duration(seconds: 1)
        : age.inHours < 1
            ? Duration(seconds: 60 - age.inSeconds % 60)
            : age.inDays < 1
                ? Duration(seconds: 3600 - age.inSeconds % 3600)
                : Duration(seconds: 86400 - age.inSeconds % 86400);
    _timer = Timer(delay, () {
      if (!mounted) return;
      setState(() {});
      _scheduleNextUpdate();
    });
  }

  @override
  Widget build(BuildContext context) {
    final age = DateTime.now().difference(widget.timestamp);
    final label = age.inSeconds < 10
        ? 'just now'
        : age.inMinutes < 1
            ? '${age.inSeconds}s ago'
            : age.inHours < 1
                ? '${age.inMinutes}m ago'
                : age.inDays < 1
                    ? '${age.inHours}h ago'
                    : age.inDays < 7
                        ? '${age.inDays}d ago'
                        : '${widget.timestamp.month}/${widget.timestamp.day}/${widget.timestamp.year}';
    return Tooltip(
      message: widget.timestamp.toLocal().toString(),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: widget.color),
      ),
    );
  }
}
