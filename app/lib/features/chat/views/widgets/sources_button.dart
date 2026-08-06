import 'package:flutter/material.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'dart:convert';

class SourcesButton extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback onSourceClicked;

  const SourcesButton({super.key, required this.message, required this.onSourceClicked});

  @override
  Widget build(BuildContext context) {
    final sources = extractSources(message);
    if (sources.isEmpty) return const SizedBox.shrink();

    // Show up to 3 overlapping favicons
    final favicons = sources.take(3).map((s) {
      String domain = '';
      try {
        if (s['url'] != null && s['url'].toString().isNotEmpty) {
          final uri = Uri.parse(s['url']);
          domain = uri.host.replaceFirst('www.', '');
        }
      } catch (_) {}
      return domain;
    }).toList();

    return InkWell(
      onTap: onSourceClicked,
      borderRadius: BorderRadius.circular(100),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: const Color(0xFF2A2A2A)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (favicons.isNotEmpty)
              SizedBox(
                width: 16.0 + (favicons.length - 1) * 10.0,
                height: 16,
                child: Stack(
                  children: List.generate(favicons.length, (index) {
                    // Reverse the list in the stack so the first one is rendered last (on top)
                    final renderIndex = favicons.length - 1 - index;
                    return Positioned(
                      left: renderIndex * 10.0,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFF1E1E1E), width: 1.5),
                          color: const Color(0xFF2A2A2A),
                        ),
                        child: ClipOval(
                          child: favicons[renderIndex].isNotEmpty
                              ? Image.network(
                                  'https://www.google.com/s2/favicons?domain=${favicons[renderIndex]}&sz=64',
                                  width: 13,
                                  height: 13,
                                  errorBuilder: (_, __, ___) => const Icon(Icons.language, size: 10, color: Color(0xFF878787)),
                                )
                              : const Icon(Icons.language, size: 10, color: Color(0xFF878787)),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            if (favicons.isNotEmpty) const SizedBox(width: 8),
            Text(
              '${sources.length} source${sources.length == 1 ? '' : 's'}',
              style: const TextStyle(
                color: Color(0xFFE0E0E0),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<Map<String, dynamic>> extractSources(ChatMessage message) {
    final List<Map<String, dynamic>> sources = [];
    final Set<String> seenUrls = {};

    for (var event in message.toolEvents) {
      if ((event.name.contains('web_search') || 
           event.name.contains('merge_rank') ||
           event.name.contains('search_vectors') ||
           event.name.contains('query_graph')) && event.result != null) {
        try {
          List<dynamic> items = [];
          if (event.result is String) {
            final decoded = jsonDecode(event.result);
            if (decoded is List) items = decoded;
          } else if (event.result is List) {
            items = event.result;
          }

          for (var item in items) {
            if (item is Map) {
              String url = '';
              String title = '';
              
              if (item.containsKey('sources') && (item['sources'] as List).isNotEmpty) {
                url = item['sources'][0].toString();
              } else if (item.containsKey('url')) {
                 url = item['url'].toString();
              } else if (item.containsKey('payload') && item['payload'] is Map) {
                 final payload = item['payload'] as Map;
                 if (payload.containsKey('url')) {
                   url = payload['url'].toString();
                 } else if (payload.containsKey('source')) {
                   url = payload['source'].toString();
                 }
              }

              String rawMatchText = '';
              if (item.containsKey('payload') && item['payload'] is Map) {
                final payload = item['payload'] as Map;
                title = payload['title']?.toString() ?? payload['text']?.toString() ?? '';
                rawMatchText = payload['text']?.toString() ?? '';
              } else if (item.containsKey('title')) {
                 title = item['title'].toString();
              }

              if (title.length > 80) {
                 title = title.substring(0, 80) + '...';
              }

              final uniqueKey = url.isNotEmpty ? url : title;
              if (uniqueKey.isNotEmpty && !seenUrls.contains(uniqueKey)) {
                seenUrls.add(uniqueKey);
                sources.add({
                  'title': title,
                  'url': url,
                  '_rawMatch': (rawMatchText + ' ' + title + ' ' + url).toLowerCase(),
                });
              }
            }
          }
        } catch (_) {}
      }
    }

    // Filter out sources that are entirely unreferenced if the LLM used explicit text citations
    final citationRegex = RegExp(r'\[([^\]]+)\]');
    final citations = citationRegex.allMatches(message.content)
        .map((m) => m.group(1)?.toLowerCase() ?? '')
        .where((s) => s.isNotEmpty && s.length > 2)
        .toList();

    if (citations.isNotEmpty) {
      sources.removeWhere((source) {
        final rawMatch = source['_rawMatch'] as String? ?? '';
        bool hasMatch = false;
        for (var citation in citations) {
          if (rawMatch.contains(citation)) {
            hasMatch = true;
            break;
          }
        }
        return !hasMatch;
      });
    }

    for (var s in sources) {
      s.remove('_rawMatch');
    }

    return sources;
  }
}
