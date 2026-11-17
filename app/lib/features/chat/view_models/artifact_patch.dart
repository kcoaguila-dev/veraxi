/// Targeted search-and-replace patches for artifact quick actions.
///
/// Instead of forcing the model to regenerate an entire file, a
/// rewrite reply may carry one or more deterministic blocks:
///
/// ```text
/// <<<<<<< SEARCH
/// exact text to find
/// =======
/// replacement text
/// >>>>>>> REPLACE
/// ```
///
/// Blocks may appear bare or inside a fenced ```diff / ```patch
/// block, and several blocks may appear in sequence. Application is
/// fail-closed: a SEARCH text must match the current code exactly
/// once (after line-ending normalization) or the whole patch is
/// rejected with diagnostics — there is no fuzzy matching, because a
/// patch applied to the wrong place silently corrupts the file.
///
/// When the reply contains no patch blocks but does contain a normal
/// fenced code block, the result is a full-file fallback carrying
/// that block's code, so the existing accept/reject flow still works.
library;

/// One patch block that could not be applied.
class ArtifactPatchFailure {
  /// Zero-based index of the block within the reply.
  final int blockIndex;

  /// The SEARCH text that failed (truncated for display).
  final String searchExcerpt;

  /// Human-readable reason: not found, ambiguous, empty, or malformed.
  final String reason;

  const ArtifactPatchFailure({
    required this.blockIndex,
    required this.searchExcerpt,
    required this.reason,
  });

  @override
  String toString() => 'Block ${blockIndex + 1}: $reason';
}

/// The outcome of applying a reply to an artifact's current code.
class ArtifactPatchResult {
  /// The patched (or fallback) code. Null when nothing could be
  /// applied cleanly.
  final String? patchedCode;

  /// How many SEARCH/REPLACE blocks applied cleanly.
  final int appliedCount;

  /// Blocks that failed, with diagnostics. Non-empty means the patch
  /// as a whole was rejected (patchedCode is null) — partial patches
  /// are never returned, so the user never sees a half-applied edit.
  final List<ArtifactPatchFailure> failedBlocks;

  /// True when the reply was a normal full fenced block rather than
  /// patch blocks, and [patchedCode] is that block's content.
  final bool isFullFileFallback;

  const ArtifactPatchResult({
    required this.patchedCode,
    required this.appliedCount,
    required this.failedBlocks,
    required this.isFullFileFallback,
  });

  bool get isSuccess => patchedCode != null && failedBlocks.isEmpty;
}

String _normalizeLineEndings(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String _excerpt(String text) {
  final oneLine = text.replaceAll('\n', r'\n');
  return oneLine.length <= 80 ? oneLine : '${oneLine.substring(0, 80)}…';
}

class _PatchBlock {
  final String search;
  final String replace;
  const _PatchBlock(this.search, this.replace);
}

/// Extracts SEARCH/REPLACE blocks from [response]. Markers must sit
/// on their own lines. An unterminated block is reported as a
/// failure rather than silently dropped.
({List<_PatchBlock> blocks, List<ArtifactPatchFailure> malformed})
    _extractBlocks(String response) {
  final lines = _normalizeLineEndings(response).split('\n');
  final blocks = <_PatchBlock>[];
  final malformed = <ArtifactPatchFailure>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].trim() != '<<<<<<< SEARCH') {
      i++;
      continue;
    }
    final blockIndex = blocks.length + malformed.length;
    final searchLines = <String>[];
    i++;
    var foundSeparator = false;
    while (i < lines.length) {
      if (lines[i].trim() == '=======') {
        foundSeparator = true;
        i++;
        break;
      }
      if (lines[i].trim() == '<<<<<<< SEARCH' ||
          lines[i].trim() == '>>>>>>> REPLACE') {
        break;
      }
      searchLines.add(lines[i]);
      i++;
    }
    if (!foundSeparator) {
      malformed.add(ArtifactPatchFailure(
        blockIndex: blockIndex,
        searchExcerpt: _excerpt(searchLines.join('\n')),
        reason: 'malformed patch block: missing ======= separator',
      ));
      continue;
    }
    final replaceLines = <String>[];
    var foundEnd = false;
    while (i < lines.length) {
      if (lines[i].trim() == '>>>>>>> REPLACE') {
        foundEnd = true;
        i++;
        break;
      }
      replaceLines.add(lines[i]);
      i++;
    }
    if (!foundEnd) {
      malformed.add(ArtifactPatchFailure(
        blockIndex: blockIndex,
        searchExcerpt: _excerpt(searchLines.join('\n')),
        reason: 'malformed patch block: missing >>>>>>> REPLACE terminator',
      ));
      continue;
    }
    blocks.add(_PatchBlock(searchLines.join('\n'), replaceLines.join('\n')));
  }
  return (blocks: blocks, malformed: malformed);
}

final RegExp _fencedBlockPattern =
    RegExp(r'```([A-Za-z0-9#+._-]*)\s*\n([\s\S]*?)(?:\n```|```)');

/// The first fenced block in [response] that is not a diff/patch
/// block, used for the full-file fallback.
String? _fullFileFallbackCode(String response) {
  for (final match in _fencedBlockPattern.allMatches(response)) {
    final language = (match.group(1) ?? '').toLowerCase();
    if (language == 'diff' || language == 'patch') continue;
    return (match.group(2) ?? '').trimRight();
  }
  return null;
}

/// Applies the SEARCH/REPLACE patch blocks in [assistantResponse]
/// to [originalCode], or falls back to a full fenced block.
///
/// Fail-closed: if any block is missing, ambiguous, empty, or
/// malformed, no patched code is returned and every failure is
/// reported in [ArtifactPatchResult.failedBlocks].
ArtifactPatchResult applyArtifactPatches(
  String originalCode,
  String assistantResponse,
) {
  final extracted = _extractBlocks(assistantResponse);
  if (extracted.blocks.isEmpty && extracted.malformed.isEmpty) {
    final fallback = _fullFileFallbackCode(assistantResponse);
    if (fallback != null) {
      return ArtifactPatchResult(
        patchedCode: fallback,
        appliedCount: 0,
        failedBlocks: const [],
        isFullFileFallback: true,
      );
    }
    return const ArtifactPatchResult(
      patchedCode: null,
      appliedCount: 0,
      failedBlocks: [
        ArtifactPatchFailure(
          blockIndex: 0,
          searchExcerpt: '',
          reason: 'reply contained no SEARCH/REPLACE blocks and no '
              'fenced code block',
        ),
      ],
      isFullFileFallback: false,
    );
  }

  final failures = <ArtifactPatchFailure>[...extracted.malformed];
  var current = _normalizeLineEndings(originalCode);
  var applied = 0;
  for (var b = 0; b < extracted.blocks.length; b++) {
    final block = extracted.blocks[b];
    if (block.search.isEmpty) {
      failures.add(ArtifactPatchFailure(
        blockIndex: b,
        searchExcerpt: '',
        reason: 'SEARCH block is empty',
      ));
      continue;
    }
    final first = current.indexOf(block.search);
    if (first < 0) {
      failures.add(ArtifactPatchFailure(
        blockIndex: b,
        searchExcerpt: _excerpt(block.search),
        reason: 'SEARCH text not found in the current code',
      ));
      continue;
    }
    if (current.indexOf(block.search, first + 1) >= 0) {
      failures.add(ArtifactPatchFailure(
        blockIndex: b,
        searchExcerpt: _excerpt(block.search),
        reason: 'SEARCH text matches more than once (ambiguous)',
      ));
      continue;
    }
    current = current.replaceRange(
      first,
      first + block.search.length,
      block.replace,
    );
    applied++;
  }

  if (failures.isNotEmpty) {
    return ArtifactPatchResult(
      patchedCode: null,
      appliedCount: applied,
      failedBlocks: failures,
      isFullFileFallback: false,
    );
  }
  return ArtifactPatchResult(
    patchedCode: current,
    appliedCount: applied,
    failedBlocks: const [],
    isFullFileFallback: false,
  );
}

/// True when [response] contains at least one SEARCH marker — used
/// to decide whether a reply should be treated as a patch attempt
/// (and its failure surfaced) rather than a plain artifact reply.
bool containsArtifactPatchBlocks(String response) =>
    _normalizeLineEndings(response).contains('<<<<<<< SEARCH');
