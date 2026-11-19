import 'dart:convert';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/citation_chip.dart';

/// Builds inline [CitationChip] widgets for markdown `<cite>` and `<a>` nodes.
class CitationElementBuilder extends MarkdownElementBuilder {
  final ChatMessage message;

  CitationElementBuilder({required this.message});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    if (element.tag == 'a') {
      final text = element.textContent;
      final href = element.attributes['href'];
      return CitationChip(
        text: text,
        url: href ?? '',
        message: message,
      );
    } else if (element.tag == 'cite') {
      final citations = _decodeCitations(element.attributes['citations']);
      final firstText = (citations != null && citations.isNotEmpty)
          ? citations.first.text
          : element.textContent;
      final firstUrl = (citations != null && citations.isNotEmpty)
          ? citations.first.url
          : (element.attributes['href'] ?? '');
      return CitationChip(
        text: firstText,
        url: firstUrl,
        citations: citations,
        message: message,
      );
    }
    return null;
  }

  List<CitationEntry>? _decodeCitations(String? rawJson) {
    if (rawJson == null || rawJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((item) => CitationEntry(
                text: item['text']?.toString() ?? '',
                url: item['url']?.toString() ?? '',
              ))
          .where((entry) => entry.text.isNotEmpty)
          .toList();
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      return null;
    }
  }
}

/// Parses one or more consecutive inline citations into a single `<cite>` node.
///
/// Adjacent citations separated by optional whitespace, commas, or semicolons
/// (e.g. `[Source A] [Source B]`, `[Source A](urlA) [Source B](urlB)`, or
/// `[Source A], [Source B], [Source C]`) are grouped into one `<cite>` element
/// while preserving every citation label and URL.
class CitationSyntax extends md.InlineSyntax {
  static const String _urlPattern =
      r'(?:https?|file):\/\/(?:[^\s\(\)]|\([^\s\(\)]*\))+';
  static const String _singleCitationPattern =
      r'\[([^\]\n]+)\](?:\s*\(\s*(?:-\s*)?(' + _urlPattern + r')\s*\))?';
  static final RegExp _singleCitationRegex = RegExp(_singleCitationPattern);
  static const String _groupPattern =
      r'\[[^\]\n]+\](?:\s*\(\s*(?:-\s*)?' +
      _urlPattern +
      r'\s*\))?(?:\s*[,;]?\s*\[[^\]\n]+\](?:\s*\(\s*(?:-\s*)?' +
      _urlPattern +
      r'\s*\))?)*(?:[ \t]*[.,;:])?';

  CitationSyntax() : super(_groupPattern);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final raw = match[0];
    if (raw == null) return false;

    final entries = <Map<String, String>>[];
    for (final item in _singleCitationRegex.allMatches(raw)) {
      final text = (item.group(1) ?? '').trim();
      final url = (item.group(2) ?? '').trim();
      if (text.isNotEmpty) {
        entries.add({'text': text, 'url': url});
      }
    }
    if (entries.isEmpty) return false;

    final first = entries.first;
    final element = md.Element.text('cite', first['text']!);
    if (first['url']!.isNotEmpty) {
      element.attributes['href'] = first['url']!;
    }
    element.attributes['citations'] = jsonEncode(entries);
    parser.addNode(element);
    return true;
  }
}
