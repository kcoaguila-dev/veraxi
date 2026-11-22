import 'dart:convert';

/// Parses an HTTP `text/event-stream` byte stream into decoded JSON maps,
/// stopping when the server emits `data: [DONE]`.
Stream<Map<String, dynamic>> parseSseJsonStream(
  Stream<List<int>> byteStream,
) async* {
  await for (final chunk
      in byteStream.transform(utf8.decoder).transform(const LineSplitter())) {
    if (chunk.isEmpty) continue;
    if (chunk.startsWith('data: ')) {
      final data = chunk.substring(6);
      if (data == '[DONE]') {
        break;
      }
      try {
        final parsed = jsonDecode(data);
        if (parsed is Map) {
          yield Map<String, dynamic>.from(parsed);
        }
      } catch (_) {
        // Ignore malformed SSE payload lines.
        continue;
      }
    }
  }
}
