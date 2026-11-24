/// Chunk-boundary-safe streaming parser separating `<think>` / `<thought>`
/// blocks from visible response text for on-device `fllama` models.
class ThinkParseResult {
  final List<String> reasoningDeltas;
  final List<String> contentDeltas;
  final int? reasoningEndedMs;

  const ThinkParseResult({
    required this.reasoningDeltas,
    required this.contentDeltas,
    this.reasoningEndedMs,
  });
}

class ThinkTagStreamParser {
  static const List<String> _openTags = ['<think>', '<thought>'];
  static const List<String> _closeTags = ['</think>', '</thought>'];
  static const int _maxTagLen = 10; // '</thought>'.length

  bool inThinking = false;
  DateTime? _thinkingStart;
  String _buffer = '';

  (int, String)? _findEarliestTag(String text, List<String> tags) {
    var bestIdx = -1;
    var bestTag = '';
    for (final tag in tags) {
      final idx = text.indexOf(tag);
      if (idx != -1 && (bestIdx == -1 || idx < bestIdx)) {
        bestIdx = idx;
        bestTag = tag;
      }
    }
    return bestIdx != -1 ? (bestIdx, bestTag) : null;
  }

  int _trailingPartialTagLen(String text, List<String> tags) {
    final maxCheck = text.length < _maxTagLen - 1 ? text.length : _maxTagLen - 1;
    for (var size = maxCheck; size > 0; size--) {
      final suffix = text.substring(text.length - size);
      if (tags.any((t) => t.startsWith(suffix))) {
        return size;
      }
    }
    return 0;
  }

  int _finishTimerMs() {
    if (_thinkingStart == null) return 0;
    final ms = DateTime.now().difference(_thinkingStart!).inMilliseconds;
    _thinkingStart = null;
    return ms;
  }

  ThinkParseResult feed(String text) {
    final reasoning = <String>[];
    final content = <String>[];
    int? endedMs;
    _buffer += text;

    while (_buffer.isNotEmpty) {
      if (inThinking) {
        final found = _findEarliestTag(_buffer, _closeTags);
        if (found != null) {
          final (idx, tag) = found;
          if (idx > 0) reasoning.add(_buffer.substring(0, idx));
          _buffer = _buffer.substring(idx + tag.length);
          inThinking = false;
          endedMs = _finishTimerMs();
          continue;
        }
        final hold = _trailingPartialTagLen(_buffer, _closeTags);
        final emitLen = _buffer.length - hold;
        if (emitLen > 0) {
          reasoning.add(_buffer.substring(0, emitLen));
          _buffer = _buffer.substring(emitLen);
        }
        break;
      }

      final foundOpen = _findEarliestTag(_buffer, _openTags);
      if (foundOpen != null) {
        final (idx, tag) = foundOpen;
        if (idx > 0) content.add(_buffer.substring(0, idx));
        _buffer = _buffer.substring(idx + tag.length);
        inThinking = true;
        _thinkingStart ??= DateTime.now();
        continue;
      }

      final foundDangling = _findEarliestTag(_buffer, _closeTags);
      if (foundDangling != null) {
        final (idx, tag) = foundDangling;
        if (idx > 0) content.add(_buffer.substring(0, idx));
        _buffer = _buffer.substring(idx + tag.length);
        continue;
      }

      final hold = _trailingPartialTagLen(_buffer, [..._openTags, ..._closeTags]);
      final emitLen = _buffer.length - hold;
      if (emitLen > 0) {
        content.add(_buffer.substring(0, emitLen));
        _buffer = _buffer.substring(emitLen);
      }
      break;
    }

    return ThinkParseResult(
      reasoningDeltas: reasoning,
      contentDeltas: content,
      reasoningEndedMs: endedMs,
    );
  }

  ThinkParseResult flush() {
    if (_buffer.isEmpty) {
      return const ThinkParseResult(reasoningDeltas: [], contentDeltas: []);
    }
    final leftover = _buffer;
    _buffer = '';
    if (inThinking) {
      inThinking = false;
      return ThinkParseResult(
        reasoningDeltas: [leftover],
        contentDeltas: const [],
        reasoningEndedMs: _finishTimerMs(),
      );
    }
    return ThinkParseResult(
      reasoningDeltas: const [],
      contentDeltas: [leftover],
    );
  }
}
