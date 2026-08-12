import 'package:flutter/material.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'dart:convert';
import 'package:sentry_flutter/sentry_flutter.dart';

class SourcesButton extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback onSourceClicked;

  const SourcesButton(
      {super.key, required this.message, required this.onSourceClicked});

  @override
  Widget build(BuildContext context) {
    final sources = extractSources(message);
    if (sources.isEmpty) return const SizedBox.shrink();

    // Show up to 3 overlapping favicons
    final favicons = sources.take(3).map((s) {
      final urlStr = s['url']?.toString() ?? '';
      if (urlStr.isNotEmpty && urlStr != 'Internal Database') {
        final uri = Uri.tryParse(urlStr.startsWith('http') ? urlStr : 'http://$urlStr');
        final host = uri?.host.replaceFirst('www.', '') ?? '';
        if (host.contains('.')) {
          return host;
        }
      }
      return '';
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
                          border: Border.all(
                              color: const Color(0xFF1E1E1E), width: 1.5),
                          color: const Color(0xFF2A2A2A),
                        ),
                        child: ClipOval(
                          child: favicons[renderIndex].isNotEmpty
                              ? Image.network(
                                  'https://icon.horse/icon/${favicons[renderIndex]}',
                                  width: 13,
                                  height: 13,
                                  errorBuilder: (_, __, ___) => const Icon(
                                      Icons.language,
                                      size: 10,
                                      color: Color(0xFF878787)),
                                )
                              : const Icon(Icons.language,
                                  size: 10, color: Color(0xFF878787)),
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
      if (!_isSourceEvent(event)) continue;

      final items = _parseEventResult(event.result);
      for (var item in items) {
        if (item is! Map) continue;

        final processedItem = _processSourceItem(item);
        if (processedItem == null) continue;

        final uniqueKey = processedItem['url'].toString().isNotEmpty
            ? processedItem['url']
            : processedItem['title'];
        if (uniqueKey.isNotEmpty && !seenUrls.contains(uniqueKey)) {
          seenUrls.add(uniqueKey);
          sources.add(processedItem);
        }
      }
    }

    _filterUnreferencedSources(sources, message.content);

    for (var s in sources) {
      s.remove('_rawMatch');
    }

    return sources;
  }

  static bool _isSourceEvent(ToolEvent event) {
    if (event.result == null) return false;
    return event.name.contains('web_search') ||
        event.name.contains('merge_rank') ||
        event.name.contains('search_vectors') ||
        event.name.contains('query_graph');
  }

  static List<dynamic> _parseEventResult(dynamic result) {
    if (result is String) {
      try {
        final decoded = jsonDecode(result);
        if (decoded is List) return decoded;
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
        // Fallback to empty if json is invalid
      }
    } else if (result is List) {
      return result;
    }
    return [];
  }

  static Map<String, dynamic>? _processSourceItem(Map item) {
    final url = _extractUrl(item);
    var title = _extractTitle(item);
    final rawMatchText = _extractRawText(item);

    if (title.length > 80) {
      title = title.substring(0, 80) + '...';
    }

    if (title.isEmpty && url.isEmpty) return null;

    return {
      'title': title,
      'url': url,
      '_rawMatch': ('$rawMatchText $title $url').toLowerCase(),
    };
  }

  static String _extractUrl(Map item) {
    // Priority 1: url directly on the item
    if (item.containsKey('url') && item['url'].toString().isNotEmpty) {
      return item['url'].toString();
    }
    // Priority 2: url inside payload (where WebHit stores the real URL)
    if (item.containsKey('payload') && item['payload'] is Map) {
      final payload = item['payload'] as Map;
      if (payload.containsKey('url') && payload['url'].toString().isNotEmpty) {
        return payload['url'].toString();
      }
      if (payload.containsKey('link') && payload['link'].toString().isNotEmpty) {
        return payload['link'].toString();
      }
      if (payload.containsKey('source') && payload['source'].toString().isNotEmpty) {
        return payload['source'].toString();
      }
    }
    // Priority 3: sources array — but only if it looks like a real URL (not "vector"/"graph")
    if (item.containsKey('sources') && (item['sources'] as List).isNotEmpty) {
      final s = item['sources'][0].toString();
      if (s.startsWith('http')) return s;
    }
    if (item.containsKey('link')) {
      return item['link'].toString();
    }
    return '';
  }


  static String _extractTitle(Map item) {
    if (item.containsKey('payload') && item['payload'] is Map) {
      final payload = item['payload'] as Map;
      return payload['title']?.toString() ?? payload['text']?.toString() ?? '';
    }
    if (item.containsKey('title')) {
      return item['title'].toString();
    }
    return '';
  }

  static String _extractRawText(Map item) {
    if (item.containsKey('payload') && item['payload'] is Map) {
      final payload = item['payload'] as Map;
      return payload['text']?.toString() ?? '';
    }
    return '';
  }

  static void _filterUnreferencedSources(
      List<Map<String, dynamic>> sources, String content) {
    final citationRegex = RegExp(r'\[([^\]]+)\]');
    final citations = citationRegex
        .allMatches(content)
        .map((m) => m.group(1)?.toLowerCase() ?? '')
        .where((s) => s.isNotEmpty && s.length > 2)
        .toList();

    if (citations.isEmpty) return;

    sources.removeWhere((source) {
      final rawMatch = source['_rawMatch'] as String? ?? '';
      for (var citation in citations) {
        if (rawMatch.contains(citation))
          return false; // keep if any citation matches
      }
      return true; // remove if no citations match
    });
  }
}
