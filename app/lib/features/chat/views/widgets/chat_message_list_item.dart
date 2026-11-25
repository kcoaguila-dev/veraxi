import 'dart:async';
import 'dart:convert';

import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/chat/view_models/audio_player_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:veraxi_app/core/models/model_provider_mapper.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_message_metrics.dart';
import 'package:veraxi_app/features/chat/views/widgets/compaction_divider.dart';
import 'package:veraxi_app/features/chat/views/widgets/tool_event_card.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_activity_disclosure.dart';
import 'package:veraxi_app/features/chat/views/widgets/markdown_citation_builder.dart';
import 'package:veraxi_app/features/chat/views/widgets/markdown_code_builder.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_artifact_card.dart';
import 'package:veraxi_app/features/chat/views/widgets/files_changed_card.dart';
import 'package:veraxi_app/features/chat/view_models/tool_confirmation_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/tool_confirmation_card.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';
import 'package:veraxi_app/core/providers/active_sources_provider.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
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
    if (CompactionDivider.isCompactionMessage(msg)) {
      return CompactionDivider(message: msg);
    }
    return _buildChatMessageActual(msg, theme, ext,
        showTelemetry: showTelemetry, context: context, ref: ref);
  }

  Widget _buildUserMessage(
      ChatMessage msg, ThemeData theme, AppThemeExtension ext) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: ext.surfaceHighlight,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: ext.borderColor),
                    ),
                    child: Text(
                      msg.content,
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8, right: 4),
                    child: Tooltip(
                      message: 'Copy message',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () =>
                            Clipboard.setData(ClipboardData(text: msg.content)),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.copy_outlined,
                            size: 16,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // We change the signature to pass context since it was previously available in the State.
  Widget _buildChatMessageActual(
      ChatMessage msg, ThemeData theme, AppThemeExtension ext,
      {bool showTelemetry = false,
      required BuildContext context,
      required WidgetRef ref}) {
    final isUser = msg.role == 'user';
    if (isUser) {
      return _buildUserMessage(msg, theme, ext);
    }

    final responseAt = _responseAt(msg);
    final name = (msg.modelName != null && msg.modelName!.isNotEmpty)
        ? msg.modelName!
        : 'AI Assistant';
    final avatar = Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: Colors.transparent),
      child: msg.modelName != null && msg.modelName!.isNotEmpty
          ? _providerDotFor(msg.modelName!, size: 16)
          : Icon(Icons.auto_awesome, color: ext.primaryGradientStart, size: 20),
    );

    // Claude-style artifact cards: fenced code blocks are pulled out of
    // the prose and their cards are collected at the end of the message,
    // instead of interrupting the text where the block was written.
    final artifacts = extractCodeArtifacts(msg.content);
    final openArtifact = ref.watch(openCodeArtifactProvider);
    final coverageNotice = evaluateRetrievalCoverage(msg);

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
                        if (msg.isError)
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

                              if (coverageNotice != null)
                                _RetrievalCoverageBanner(
                                    notice: coverageNotice),

                              if (msg.content.isNotEmpty)
                                MarkdownBody(
                                  // With artifacts present the prose is
                                  // rendered without the fenced blocks;
                                  // their cards follow the body instead.
                                  // Anything the extractor leaves behind
                                  // (a still-streaming unclosed fence, an
                                  // indented block) keeps the legacy
                                  // inline rendering via the builder.
                                  data: artifacts.isEmpty
                                      ? msg.content
                                      : stripCodeArtifacts(msg.content),
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
                                    'a': CitationElementBuilder(
                                      message: msg,
                                      onInspectSources: () {
                                        ref
                                                .read(activeSourcesProvider
                                                    .notifier)
                                                .state =
                                            SourcesButton.extractSources(msg);
                                        Scaffold.maybeOf(context)
                                            ?.openEndDrawer();
                                      },
                                    ),
                                    'cite': CitationElementBuilder(
                                      message: msg,
                                      onInspectSources: () {
                                        ref
                                                .read(activeSourcesProvider
                                                    .notifier)
                                                .state =
                                            SourcesButton.extractSources(msg);
                                        Scaffold.maybeOf(context)
                                            ?.openEndDrawer();
                                      },
                                    ),
                                  },
                                  styleSheet: MarkdownStyleSheet(
                                    p: theme.textTheme.bodyLarge
                                        ?.copyWith(height: 1.5),
                                    // Headings must carry an explicit
                                    // light foreground: the theme's
                                    // title styles resolve dark on this
                                    // dark surface (dark-on-dark bug),
                                    // matching code_artifact_panel.dart.
                                    h1: theme.textTheme.headlineSmall?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    h2: theme.textTheme.titleLarge?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    h3: theme.textTheme.titleMedium?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    h4: theme.textTheme.titleSmall?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    h5: theme.textTheme.bodyLarge?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    h6: theme.textTheme.bodyMedium?.copyWith(
                                      color: const Color(0xFFE2E8F0),
                                      fontWeight: FontWeight.w600,
                                    ),
                                    listBullet:
                                        theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.brightness == Brightness.dark
                                          ? const Color(0xFFE2E8F0)
                                          : theme.colorScheme.onSurface,
                                    ),
                                    blockquote:
                                        theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.brightness == Brightness.dark
                                          ? const Color(0xFFA1A1AA)
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                                    img: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.brightness == Brightness.dark
                                          ? const Color(0xFFE2E8F0)
                                          : theme.colorScheme.onSurface,
                                    ),
                                    checkbox:
                                        theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.primary,
                                    ),
                                    tableHead:
                                        theme.textTheme.bodyMedium?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    tableBody:
                                        theme.textTheme.bodyMedium?.copyWith(
                                      color: const Color(0xFFE2E8F0),
                                      height: 1.4,
                                    ),
                                    tableBorder: TableBorder.all(
                                      color: const Color(0xFF3F3F3F),
                                      width: 1,
                                    ),
                                    tableCellsPadding:
                                        const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    horizontalRuleDecoration:
                                        const BoxDecoration(
                                      border: Border(
                                        top: BorderSide(
                                          color: Color(0xFF3F3F3F),
                                          width: 1,
                                        ),
                                      ),
                                    ),
                                    // Inline code spans: borderless,
                                    // subtle Obsidian chip in dark
                                    // theme; light theme uses surface
                                    // container so contrast stays high.
                                    code: GoogleFonts.firaCode(
                                        backgroundColor:
                                            theme.brightness == Brightness.dark
                                                ? ObsidianTokens.codeSpanBg
                                                : theme.colorScheme
                                                    .surfaceContainerHighest,
                                        color:
                                            theme.brightness == Brightness.dark
                                                ? ObsidianTokens.codeSpanText
                                                : theme.colorScheme.onSurface),
                                    codeblockPadding: EdgeInsets.zero,
                                    codeblockDecoration:
                                        BoxDecoration(), // Handled by builder
                                  ),
                                ),
                              // Write-action confirmation card: when
                              // the backend gate refused a mutating
                              // external tool call, its
                              // tool_confirmation_required payload in
                              // this message renders an Approve/Reject
                              // card (POST /api/chat/confirm-tool).
                              if (!msg.isStreaming &&
                                  extractToolConfirmation(msg.content) != null)
                                ToolConfirmationCard(
                                  request:
                                      extractToolConfirmation(msg.content)!,
                                ),
                              // Artifact cards, collected at the end of
                              // the message like Claude's created-file
                              // cards, in document order.
                              for (var i = 0; i < artifacts.length; i++)
                                CodeArtifactCard(
                                  artifact: artifacts[i],
                                  isOpen:
                                      openArtifact?.artifact == artifacts[i],
                                  onTap: () {
                                    // Record where this artifact lives
                                    // (thread, message position, block
                                    // position) so the panel can follow
                                    // its live content while the message
                                    // is still streaming.
                                    final chatState =
                                        ref.read(chatViewModelProvider);
                                    final messageIndex =
                                        chatState.messages.indexOf(msg);
                                    ref
                                        .read(openCodeArtifactProvider.notifier)
                                        .state = OpenCodeArtifact(
                                      artifact: artifacts[i],
                                      threadId: chatState.threadId,
                                      messageIndex: messageIndex >= 0
                                          ? messageIndex
                                          : null,
                                      artifactIndex: i,
                                    );
                                  },
                                ),
                              // Phase 5: FilesChangedCard sits
                              // directly above the action row for
                              // turns carrying a files_changed
                              // summary (Code Mode sandbox turns).
                              if (!msg.isError &&
                                  msg.filesChanged != null &&
                                  !msg.filesChanged!.isEmpty)
                                FilesChangedCard(summary: msg.filesChanged!),
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
                                      _CopyMessageButton(
                                        text: msg.content,
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.5),
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
                                      if (msg.toolEvents.any(
                                          SourcesButton.isSourceEvent)) ...[
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
                              if (showTelemetry &&
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

/// Formats [timestamp] as a low-noise relative label (`just now` for the first
/// minute, then `Xm ago`, `Xh ago`, `Xd ago`) and switches to a short date
/// once the message is at least 7 days old.
String formatRelativeTimestamp(DateTime timestamp, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final age = current.difference(timestamp);
  if (age.isNegative || age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  if (age.inDays < 7) return '${age.inDays}d ago';
  final local = timestamp.toLocal();
  final localNow = current.toLocal();
  return local.year == localNow.year
      ? DateFormat.MMMd().format(local)
      : DateFormat.yMMMd().format(local);
}

/// Returns how long to wait before [formatRelativeTimestamp] will change, or
/// `null` once the label has settled onto a static calendar date (`>= 7d`).
Duration? nextRelativeTimestampDelay(DateTime timestamp, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final age = current.difference(timestamp);
  if (age.isNegative) return const Duration(minutes: 1);
  if (age.inMinutes < 1) return Duration(seconds: 60 - age.inSeconds);
  if (age.inHours < 1) return Duration(seconds: 60 - age.inSeconds % 60);
  if (age.inDays < 1) return Duration(seconds: 3600 - age.inSeconds % 3600);
  if (age.inDays < 7) return Duration(seconds: 86400 - age.inSeconds % 86400);
  return null;
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
    final delay = nextRelativeTimestampDelay(widget.timestamp);
    if (delay == null) return;
    _timer = Timer(delay, () {
      if (!mounted) return;
      setState(() {});
      _scheduleNextUpdate();
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = formatRelativeTimestamp(widget.timestamp);
    final exact =
        DateFormat.yMMMd().add_jm().format(widget.timestamp.toLocal());
    return Tooltip(
      message: exact,
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: widget.color),
      ),
    );
  }
}

class _CopyMessageButton extends StatefulWidget {
  final String text;
  final Color color;

  const _CopyMessageButton({
    required this.text,
    required this.color,
  });

  @override
  State<_CopyMessageButton> createState() => _CopyMessageButtonState();
}

class _CopyMessageButtonState extends State<_CopyMessageButton> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _handleCopy() {
    Clipboard.setData(ClipboardData(text: widget.text));
    _resetTimer?.cancel();
    setState(() => _copied = true);
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _copied ? 'Copied' : 'Copy',
      child: InkWell(
        onTap: _handleCopy,
        borderRadius: BorderRadius.circular(4),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: animation,
            child: child,
          ),
          child: _copied
              ? const Icon(
                  Icons.check,
                  key: ValueKey('copied'),
                  size: 16,
                  color: Color(0xFF10A37F),
                )
              : Icon(
                  Icons.copy_outlined,
                  key: const ValueKey('copy'),
                  size: 16,
                  color: widget.color,
                ),
        ),
      ),
    );
  }
}

/// Classification for retrieval coverage notices rendered above an assistant response.
enum RetrievalCoverageKind { noSolidEvidence, lowConfidence }

/// User-facing notice shown when retrieval returns empty or low-confidence hits.
class RetrievalCoverageNotice {
  final RetrievalCoverageKind kind;
  final String keyName;
  final String title;
  final String subtitle;

  const RetrievalCoverageNotice({
    required this.kind,
    required this.keyName,
    required this.title,
    required this.subtitle,
  });

  static const noSolidEvidence = RetrievalCoverageNotice(
    kind: RetrievalCoverageKind.noSolidEvidence,
    keyName: 'no-solid-evidence-banner',
    title: 'No solid evidence found in indexed sources',
    subtitle:
        'Retrieval returned 0 matching chunks — answer relies on model knowledge.',
  );

  static const lowConfidence = RetrievalCoverageNotice(
    kind: RetrievalCoverageKind.lowConfidence,
    keyName: 'low-evidence-banner',
    title: 'Low-confidence retrieval match — verify cited lines',
    subtitle:
        'All retrieved passages scored below the medium-match RRF threshold.',
  );
}

const Set<String> _retrievalToolNames = {
  'search_vectors',
  'query_graph',
  'merge_rank',
  'build_lazy_dossier',
  'web_search',
  'ephemeral_web_rag',
  'code_symbol',
  'code_impact',
  'code_overview',
};

List<ToolEvent> _collectMessageToolEvents(ChatMessage msg) {
  if (msg.toolEvents.isNotEmpty) return msg.toolEvents;
  return [
    for (final step in msg.activity) ...step.toolEvents,
  ];
}

bool _isRetrievalToolName(String rawName) {
  final normalized =
      rawName.startsWith('mcp_') ? rawName.substring(4) : rawName;
  return _retrievalToolNames.contains(normalized);
}

bool _isCompletedRetrievalEvent(ToolEvent event) {
  if (!event.isComplete || event.result == null) return false;
  if (!_isRetrievalToolName(event.name)) return false;
  final raw = event.result;
  if (raw is String) {
    final trimmed = raw.trimLeft();
    if (trimmed.isEmpty || trimmed.startsWith('Error:')) return false;
    return trimmed.startsWith('[') || trimmed.startsWith('{');
  }
  return raw is List || raw is Map;
}

dynamic _decodeResultPayload(dynamic rawResult) {
  if (rawResult is! String) return rawResult;
  try {
    return jsonDecode(rawResult.trimLeft());
  } on FormatException catch (e, st) {
    Sentry.captureException(e, stackTrace: st);
    return null;
  }
}

List<Map<String, dynamic>> _extractHitMapsFromPayload(dynamic payload) {
  if (payload is List) {
    return [
      for (final item in payload)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }
  if (payload is! Map) return const <Map<String, dynamic>>[];
  const listKeys = ['chunks', 'matches', 'impacted', 'results', 'items'];
  for (final key in listKeys) {
    final value = payload[key];
    if (value is List) {
      return [
        for (final item in value)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    }
  }
  final totalNodes = payload['total_nodes'];
  if (totalNodes is num && totalNodes > 0) {
    return [Map<String, dynamic>.from(payload)];
  }
  return const <Map<String, dynamic>>[];
}

List<double> _extractFusedScores(List<Map<String, dynamic>> hits) {
  final scores = <double>[];
  for (final hit in hits) {
    final prov = hit['provenance'];
    if (prov is Map && prov['fused_score'] is num) {
      scores.add((prov['fused_score'] as num).toDouble());
    }
  }
  return scores;
}

/// Evaluates completed retrieval tool results on [msg] to surface empty or
/// low-confidence retrieval coverage notices.
RetrievalCoverageNotice? evaluateRetrievalCoverage(ChatMessage msg) {
  if (msg.role == 'user' ||
      msg.isStreaming ||
      msg.isError ||
      msg.content.isEmpty) {
    return null;
  }
  final events =
      _collectMessageToolEvents(msg).where(_isCompletedRetrievalEvent).toList();
  if (events.isEmpty) return null;

  var validEventsCount = 0;
  final hits = <Map<String, dynamic>>[];
  for (final event in events) {
    final payload = _decodeResultPayload(event.result);
    if (payload == null) continue;
    validEventsCount++;
    hits.addAll(_extractHitMapsFromPayload(payload));
  }
  if (validEventsCount == 0) return null;
  if (hits.isEmpty) return RetrievalCoverageNotice.noSolidEvidence;

  final scores = _extractFusedScores(hits);
  if (scores.length == hits.length && scores.every((s) => s < 0.015)) {
    return RetrievalCoverageNotice.lowConfidence;
  }
  return null;
}

class _RetrievalCoverageBanner extends StatelessWidget {
  final RetrievalCoverageNotice notice;

  const _RetrievalCoverageBanner({required this.notice});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(notice.keyName),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.info_outline,
              size: 15,
              color: Color(0xFFFBBF24),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notice.title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFDE68A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  notice.subtitle,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFD4D4D8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
