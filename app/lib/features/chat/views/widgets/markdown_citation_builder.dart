import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:veraxi_app/features/chat/views/widgets/citation_chip.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';

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
      return CitationChip(
        text: element.textContent,
        url: '', // the chip will resolve the URL from the message's tool events
        message: message,
      );
    }
    return null;
  }
}

class CitationSyntax extends md.InlineSyntax {
  CitationSyntax()
      : super(
            r'\[([^\]]+)\](?:\s*\(\s*(?:-\s*)?https?:\/\/[^\)]+\s*\))?\s*[.,;:]?');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final text = match[1]!;
    final element = md.Element.text('cite', text);
    parser.addNode(element);
    return true;
  }
}
