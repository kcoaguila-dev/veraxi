import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/core/widgets/language_file_icon.dart';
import 'package:veraxi_app/features/chat/view_models/code_file_view_model.dart';

/// Hover card for a line-anchored code citation: pager header,
/// file identity, optional tool-event enrichment (`title` / `snippet`),
/// a line-numbered snippet of the cited range (fetched/cached through
/// [codeFileProvider], i.e. GET /api/v1/code/file), and the review footer.
/// Live variant: watches [codeFileProvider] and forwards the result
/// to [CodeCitationHoverCard]. Only ever built under a [ProviderScope].
class LiveCodeCitationHoverCard extends ConsumerWidget {
  final CodeCitationTarget target;
  final String? sourceTitle;
  final String? sourceSnippet;
  final int index;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onOpenReview;

  const LiveCodeCitationHoverCard({
    super.key,
    required this.target,
    this.sourceTitle,
    this.sourceSnippet,
    required this.index,
    required this.total,
    required this.onPrev,
    required this.onNext,
    required this.onOpenReview,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CodeCitationHoverCard(
      target: target,
      sourceTitle: sourceTitle,
      sourceSnippet: sourceSnippet,
      index: index,
      total: total,
      onPrev: onPrev,
      onNext: onNext,
      onOpenReview: onOpenReview,
      asyncContent: ref.watch(codeFileProvider(target)),
    );
  }
}

class CodeCitationHoverCard extends StatelessWidget {
  final CodeCitationTarget target;
  final String? sourceTitle;
  final String? sourceSnippet;
  final int index;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onOpenReview;

  /// Snippet state from [codeFileProvider], or null when no
  /// [ProviderScope] is available (bare widget tests): the card then
  /// renders its fallback body from [sourceTitle] / [sourceSnippet]
  /// and the target fields.
  final AsyncValue<CodeFileContent>? asyncContent;

  const CodeCitationHoverCard({
    super.key,
    required this.target,
    this.sourceTitle,
    this.sourceSnippet,
    required this.index,
    required this.total,
    required this.onPrev,
    required this.onNext,
    required this.onOpenReview,
    required this.asyncContent,
  });

  @override
  Widget build(BuildContext context) {
    final rangeLabel = target.endLine != null
        ? 'L${target.startLine}-L${target.endLine}'
        : 'L${target.startLine}';
    final hasTitle = sourceTitle != null && sourceTitle!.trim().isNotEmpty;
    final hasSnippet =
        sourceSnippet != null && sourceSnippet!.trim().isNotEmpty;
    return Material(
      color: Colors.transparent,
      elevation: 12,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: ObsidianTokens.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ObsidianTokens.borderStrong),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const Divider(height: 1, color: ObsidianTokens.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  LanguageFileIcon(fileName: target.path, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${target.path} · $rangeLabel',
                      style: const TextStyle(
                        color: Color(0xFFA1A1AA),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            if (hasTitle)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
                child: Text(
                  sourceTitle!.trim(),
                  style: const TextStyle(
                    color: Color(0xFFF4F4F5),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (asyncContent == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Text(
                  hasSnippet
                      ? sourceSnippet!.trim()
                      : "This file isn't available on the server.",
                  style: const TextStyle(
                    color: Color(0xFFA1A1AA),
                    fontSize: 11.5,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              asyncContent!.when(
                data: (content) => _buildSnippet(content),
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                error: (_, __) => Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: Text(
                    hasSnippet
                        ? sourceSnippet!.trim()
                        : "This file isn't available on the server.",
                    style: const TextStyle(
                      color: Color(0xFFA1A1AA),
                      fontSize: 11.5,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            const Divider(height: 1, color: ObsidianTokens.hairline),
            InkWell(
              onTap: onOpenReview,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  'Neo4j AST · Click to open in Review',
                  style: TextStyle(
                    color: Color(0xFF4F8EF7),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          InkWell(
            onTap: onPrev,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.chevron_left,
                size: 16,
                color: onPrev != null
                    ? const Color(0xFFCCCCCC)
                    : const Color(0xFF555555),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${index + 1}/$total',
              style: const TextStyle(
                color: Color(0xFFA0A0A0),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          InkWell(
            onTap: onNext,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.chevron_right,
                size: 16,
                color: onNext != null
                    ? const Color(0xFFCCCCCC)
                    : const Color(0xFF555555),
              ),
            ),
          ),
          const Spacer(),
          Text(
            total == 1 ? '1 source' : '$total sources',
            style: const TextStyle(
              color: Color(0xFFCCCCCC),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// The cited lines of [content], numbered with their real file
  /// line numbers, capped at 8 rows so the card stays a popover.
  Widget _buildSnippet(CodeFileContent content) {
    final rows = <(int, String)>[];
    for (var i = 0; i < content.lines.length && rows.length < 8; i++) {
      final lineNo = content.startLine + i;
      if (lineNo < target.startLine) continue;
      if (lineNo > target.effectiveEndLine) break;
      rows.add((lineNo, content.lines[i]));
    }
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Text(
          'Cited lines are outside the served file.',
          style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 11.5),
        ),
      );
    }
    final truncated =
        target.effectiveEndLine - target.startLine + 1 > rows.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (lineNo, text) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 30,
                    child: Text(
                      '$lineNo',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Color(0xFF6E6E6E),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text.isEmpty ? ' ' : text,
                      style: const TextStyle(
                        color: ObsidianTokens.codeSpanText,
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (truncated)
            const Padding(
              padding: EdgeInsets.only(left: 40, top: 2),
              child: Text(
                '…',
                style: TextStyle(color: Color(0xFF6E6E6E), fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}
