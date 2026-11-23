import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/core/widgets/language_file_icon.dart';
import 'package:veraxi_app/features/chat/view_models/chat_state.dart';

/// "N files changed +A -D" card rendered inside an assistant turn,
/// above its Copy/Thumbs/Timestamp action row (Phase 5).
///
/// Collapsed by default: a 32px-high, radius-8 strip with the summary
/// on the left and a [Review] button on the right. Expanding lists
/// one row per file (language icon, file name, muted relative path,
/// per-file +/-). The Review button — and clicking a file row —
/// opens the review pane by setting [activeReviewSessionProvider];
/// a file-row click additionally focuses that file.
///
/// Visual contract: docs/design/veraxi_code_review_pane.svg.
class FilesChangedCard extends ConsumerStatefulWidget {
  final FilesChangedSummary summary;

  /// Prompt of the turn this card belongs to, when the caller knows
  /// it; forwarded to the review pane's "For Turn" bar.
  final String? turnPrompt;

  const FilesChangedCard({
    super.key,
    required this.summary,
    this.turnPrompt,
  });

  @override
  ConsumerState<FilesChangedCard> createState() => _FilesChangedCardState();
}

class _FilesChangedCardState extends ConsumerState<FilesChangedCard> {
  bool _expanded = false;

  FilesChangedSummary get _summary => widget.summary;

  void _openReview({String? focusedPath}) {
    ref.read(activeReviewSessionProvider.notifier).state = CodeReviewState(
      sessionId: _summary.sessionId,
      turnId: _summary.turnId,
      focusedPath: focusedPath,
      files: [
        for (final file in _summary.files)
          CodeReviewFileSummary(
            path: file.path,
            additions: file.additions,
            deletions: file.deletions,
          ),
      ],
      turnPrompt: widget.turnPrompt,
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return Container(
      key: const Key('files-changed-card'),
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: ObsidianTokens.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ObsidianTokens.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    key: const Key('files-changed-toggle'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              '${summary.files.length} '
                              '${summary.files.length == 1 ? 'file' : 'files'} changed',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFFE4E4E7),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '+${summary.totalAdditions} -${summary.totalDeletions}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: Color(0xFF34D399),
                            ),
                          ),
                          const SizedBox(width: 4),
                          AnimatedRotation(
                            turns: _expanded ? 0.5 : 0.0,
                            duration: const Duration(milliseconds: 180),
                            child: const Icon(
                              Icons.keyboard_arrow_down,
                              size: 16,
                              color: Color(0xFF71717A),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: SizedBox(
                    height: 22,
                    child: OutlinedButton(
                      key: const Key('files-changed-review-button'),
                      onPressed: () => _openReview(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        backgroundColor: const Color(0xFF1C1F26),
                        side: const BorderSide(color: Color(0xFF2E323D)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: const Text(
                        'Review',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFFF4F4F5),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(
                        height: 1,
                        color: ObsidianTokens.hairline,
                      ),
                      for (final file in summary.files)
                        _buildFileRow(file),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildFileRow(FilesChangedFile file) {
    return InkWell(
      key: Key('files-changed-file-${file.path}'),
      onTap: () => _openReview(focusedPath: file.path),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            LanguageFileIcon(fileName: file.fileName, size: 15),
            const SizedBox(width: 8),
            Text(
              file.fileName,
              style: const TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: Color(0xFFD4D4D8),
              ),
            ),
            if (file.directory.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  file.directory,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF71717A),
                  ),
                ),
              ),
            ] else
              const Spacer(),
            Text(
              '+${file.additions} -${file.deletions}',
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Color(0xFF34D399),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
