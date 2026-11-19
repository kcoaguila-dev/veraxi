import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'dart:convert';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/views/widgets/citation_chip.dart';

class SourcesButton extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback onSourceClicked;

  const SourcesButton(
      {super.key, required this.message, required this.onSourceClicked});

  @override
  Widget build(BuildContext context) {
    final sources = extractSources(message);
    if (sources.isEmpty) return SizedBox.shrink();

    // Show up to 3 overlapping favicons
    final favicons = sources.take(3).map((s) {
      final urlStr = s['url']?.toString() ?? '';
      if (urlStr.isNotEmpty && urlStr != 'Internal Database') {
        final uri =
            Uri.tryParse(urlStr.startsWith('http') ? urlStr : 'http://$urlStr');
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
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color:
              Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
              color: Theme.of(context)
                  .extension<AppThemeExtension>()!
                  .borderColor),
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
                              color: Theme.of(context)
                                  .extension<AppThemeExtension>()!
                                  .cardBackground,
                              width: 1.5),
                          color: Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .borderColor,
                        ),
                        child: ClipOval(
                          child: favicons[renderIndex].isNotEmpty
                              ? Image.network(
                                  'https://icon.horse/icon/${favicons[renderIndex]}',
                                  width: 13,
                                  height: 13,
                                  errorBuilder: (_, __, ___) => Icon(
                                      Icons.language,
                                      size: 10,
                                      color: Theme.of(context)
                                          .extension<AppThemeExtension>()!
                                          .textTertiary),
                                )
                              : Icon(Icons.language,
                                  size: 10,
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .textTertiary),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            if (favicons.isNotEmpty) SizedBox(width: 8),
            Text(
              '${sources.length} source${sources.length == 1 ? '' : 's'}',
              style: TextStyle(
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
        event.name.contains('query_graph') ||
        event.name.contains('build_lazy_dossier');
  }

  static List<dynamic> _parseEventResult(dynamic result) {
    if (result is String) {
      try {
        final decoded = jsonDecode(result);
        if (decoded is List) return decoded;
        if (decoded is Map &&
            decoded.containsKey('chunks') &&
            decoded['chunks'] is List) {
          return decoded['chunks'] as List;
        }
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
        // Fallback to empty if json is invalid
      }
    } else if (result is List) {
      return result;
    } else if (result is Map &&
        result.containsKey('chunks') &&
        result['chunks'] is List) {
      return result['chunks'] as List;
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

    final provenance = _extractProvenance(item);

    return {
      'title': title,
      'url': url,
      'snippet': rawMatchText,
      if (provenance != null) 'provenance': provenance,
      '_rawMatch': ('$rawMatchText $title $url').toLowerCase(),
    };
  }

  /// Parse the backend `provenance` object ({legs, fused_score,
  /// graph_path}) attached to merged retrieval results and dossier
  /// chunks. Returns null when no provenance was sent, so legacy
  /// sources render exactly as before. Only legs the backend actually
  /// recorded are kept, in canonical Vector/Sparse/Graph order; a
  /// graph path is kept only when it has at least two valid node steps.
  static Map<String, dynamic>? _extractProvenance(Map item) {
    final raw = item['provenance'];
    if (raw is! Map) return null;

    const knownLegs = ['vector', 'sparse', 'graph'];
    final rawLegs = raw['legs'];
    final legs = <String>[
      if (rawLegs is List)
        for (final leg in knownLegs)
          if (rawLegs.contains(leg)) leg,
    ];

    final rawScore = raw['fused_score'];
    final fusedScore = rawScore is num ? rawScore.toDouble() : null;

    List<Map<String, dynamic>>? graphPath;
    final rawPath = raw['graph_path'];
    if (rawPath is List) {
      final steps = <Map<String, dynamic>>[];
      var valid = true;
      for (final step in rawPath) {
        if (step is! Map || step['node'] is! String) {
          valid = false;
          break;
        }
        steps.add({
          'node': step['node'] as String,
          'relation': step['relation']?.toString(),
        });
      }
      if (valid && steps.length >= 2) graphPath = steps;
    }

    if (legs.isEmpty && fusedScore == null && graphPath == null) return null;

    return {
      'legs': legs,
      'fused_score': fusedScore,
      'graph_path': graphPath,
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
      if (payload.containsKey('link') &&
          payload['link'].toString().isNotEmpty) {
        return payload['link'].toString();
      }
      if (payload.containsKey('source') &&
          payload['source'].toString().isNotEmpty) {
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
      return payload['text']?.toString() ??
          payload['snippet']?.toString() ??
          payload['content']?.toString() ??
          '';
    }
    return item['text']?.toString() ??
        item['snippet']?.toString() ??
        item['content']?.toString() ??
        '';
  }

  static final RegExp _contentCitationRegex = RegExp(
    r'\[([^\]\n]+)\](?:\s*\(\s*(?:-\s*)?((?:https?|file):\/\/(?:[^\s\(\)]|\([^\s\(\)]*\))+)\s*\))?',
  );

  static void _filterUnreferencedSources(
      List<Map<String, dynamic>> sources, String content) {
    final numericIndices = <int>{};
    final textCitations = <({String label, String url})>[];

    for (final match in _contentCitationRegex.allMatches(content)) {
      final rawLabel = (match.group(1) ?? '').trim();
      final rawUrl = (match.group(2) ?? '').trim();
      if (rawLabel.isEmpty) continue;

      final singleIndex = int.tryParse(rawLabel);
      if (singleIndex != null) {
        numericIndices.add(singleIndex);
        continue;
      }

      if (_tryAddNumericListIndices(rawLabel, numericIndices)) {
        continue;
      }

      if (rawLabel.length > 2 || rawUrl.isNotEmpty) {
        textCitations.add((label: rawLabel, url: rawUrl));
      }
    }

    if (numericIndices.isEmpty && textCitations.isEmpty) return;

    final resolvedCitations = _expandUnmatchedLists(sources, textCitations);

    final kept = <Map<String, dynamic>>[];
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      if (numericIndices.contains(i + 1) ||
          resolvedCitations.any((cite) => _matchesSingleCitation(source, cite))) {
        kept.add(source);
      }
    }
    sources
      ..clear()
      ..addAll(kept);
  }

  static List<({String label, String url})> _expandUnmatchedLists(
    List<Map<String, dynamic>> sources,
    List<({String label, String url})> textCitations,
  ) {
    final pageSuffix = RegExp(
      r',\s*(?:pp?\.|page|ch\.|chap\.|sec\.|fig\.)',
      caseSensitive: false,
    );
    final result = <({String label, String url})>[];
    for (final cite in textCitations) {
      final hasDelim = cite.label.contains(',') || cite.label.contains(';');
      if (cite.url.isEmpty &&
          hasDelim &&
          !pageSuffix.hasMatch(cite.label) &&
          !sources.any((s) => _matchesSingleCitation(s, cite))) {
        final parts = cite.label
            .split(RegExp(r'\s*[,;]\s*'))
            .map((p) => p.trim())
            .where((p) => p.length > 2)
            .toList();
        if (parts.length >= 2) {
          for (final part in parts) {
            result.add((label: part, url: ''));
          }
          continue;
        }
      }
      result.add(cite);
    }
    return result;
  }

  static bool _tryAddNumericListIndices(String rawLabel, Set<int> outIndices) {
    if (!rawLabel.contains(',') && !rawLabel.contains(';')) return false;
    final parts = rawLabel
        .split(RegExp(r'\s*[,;]\s*'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length < 2 || !parts.every((p) => int.tryParse(p) != null)) {
      return false;
    }
    for (final part in parts) {
      outIndices.add(int.parse(part));
    }
    return true;
  }

  static bool _matchesSingleCitation(
    Map<String, dynamic> source,
    ({String label, String url}) cite,
  ) {
    final rawMatch = source['_rawMatch'] as String? ?? '';
    final title = source['title']?.toString() ?? '';
    final url = source['url']?.toString() ?? '';
    final snippet = source['snippet']?.toString() ?? '';

    if (rawMatch.contains(cite.label.toLowerCase())) return true;
    return citationMatchesSourceItem(
      citation: cite.label,
      citationUrl: cite.url,
      title: title,
      url: url,
      snippet: snippet,
    );
  }
}
