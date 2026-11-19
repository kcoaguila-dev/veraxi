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
    final claimText = element.attributes['claim'] ?? '';
    if (element.tag == 'a') {
      final text = element.textContent;
      final href = element.attributes['href'];
      return CitationChip(
        text: text,
        url: href ?? '',
        claimText: claimText,
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
        claimText: claimText,
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
  static const String _groupPattern = r'\[[^\]\n]+\](?:\s*\(\s*(?:-\s*)?' +
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
    final claim = _extractClaimContext(parser.source, match.start);
    if (claim.isNotEmpty) {
      element.attributes['claim'] = claim;
    }
    parser.addNode(element);
    return true;
  }

  static String _extractClaimContext(String source, int matchStart) {
    if (source.isEmpty || matchStart <= 0) return '';
    final safeEnd = matchStart.clamp(0, source.length);
    var prefix = source.substring(0, safeEnd);
    prefix = prefix.replaceAll(_singleCitationRegex, ' ');
    prefix = prefix.replaceAll(RegExp(r'[*_`#>]'), '');
    prefix = prefix.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    if (prefix.isEmpty) return '';

    final segments = prefix
        .split(RegExp(r'(?<=[.!?])\s+|\n+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return '';

    var claim = segments.last;
    if (claim.length < 20 && segments.length >= 2) {
      claim = '${segments[segments.length - 2]} $claim';
    }
    claim = claim.replaceFirst(RegExp(r'^(?:[-*•]|\d+[.)])\s+'), '');
    claim = claim.replaceFirst(RegExp(r'[,;:(\s]+$'), '').trim();
    return claim;
  }
}
