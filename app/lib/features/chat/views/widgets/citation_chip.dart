import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/view_models/code_file_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_citation_viewer.dart';
import 'package:veraxi_app/features/chat/views/widgets/sources_sidebar.dart';

const Set<String> _citationNoiseTokens = {
  'http',
  'https',
  'www',
  'com',
  'org',
  'net',
  'edu',
  'gov',
  'io',
  'co',
  'html',
  'htm',
  'php',
  'the',
  'and',
  'for',
  'from',
  'with',
};

const Set<String> _genericHostLabels = {
  'www',
  'com',
  'org',
  'net',
  'edu',
  'gov',
  'io',
  'co',
  'uk',
  'jp',
  'ai',
  'app',
  'news',
  'blog',
  'docs',
};

final RegExp _nonWordUnicodeRegex = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _bareDomainRegex = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+(?:/\S*)?$',
  caseSensitive: false,
);
final RegExp _pageRefSuffixRegex = RegExp(
  r',\s*(?:pp?\.|page|ch\.|chap\.|sec\.|fig\.)',
  caseSensitive: false,
);
final RegExp _lineAnchorFragmentRegex = RegExp(r'^L\d+(?:-L\d+)?$');

/// Normalize [value] into lowercase space-separated alphanumeric tokens.
String normalizeCitationMatchText(String value) {
  return value.toLowerCase().replaceAll(_nonWordUnicodeRegex, ' ').trim();
}

/// Extract meaningful lowercase tokens from [value] for citation matching.
List<String> extractCitationTokens(String value) {
  final normalized = normalizeCitationMatchText(value);
  if (normalized.isEmpty) return const [];
  final raw = normalized.split(' ').where((t) => t.length >= 2).toList();
  final filtered = raw.where((t) => !_citationNoiseTokens.contains(t)).toList();
  return filtered.isNotEmpty ? filtered : raw;
}

/// Check whether a citation label/URL corresponds to a retrieved source item.
bool citationMatchesSourceItem({
  required String citation,
  String citationUrl = '',
  required String title,
  required String url,
  String snippet = '',
}) {
  if (citationUrl.isNotEmpty &&
      url.isNotEmpty &&
      _urlsMatch(citationUrl, url)) {
    return true;
  }

  final search = citation.toLowerCase().trim();
  if (search.isEmpty) return false;

  if (_containsRawSubstring(search, title, url)) return true;
  if (_matchesNormalizedPhrase(citation, title, url)) return true;

  final tokens = extractCitationTokens(citation);
  if (tokens.isEmpty) return false;

  if (_allTokensPresent(tokens, '$title $url')) return true;
  if (snippet.isNotEmpty && _allTokensPresent(tokens, '$title $url $snippet')) {
    return true;
  }

  return _hasMatchingHostDomain(tokens, url);
}

/// Resolve the URL handed to the platform launcher when a `file://`
/// citation is tapped.
///
/// A line anchor (`#L<start>` / `#L<start>-L<end>`, as emitted for code
/// citations) is preserved so the receiving editor or viewer can
/// position at the cited line. Any other fragment (e.g. `#page=158`)
/// keeps the historical behavior of launching the bare file path.
String fileCitationLaunchUrl(String url) {
  final hashIndex = url.indexOf('#');
  if (hashIndex < 0) return url;
  final fragment = url.substring(hashIndex + 1);
  if (_lineAnchorFragmentRegex.hasMatch(fragment)) return url;
  return url.substring(0, hashIndex);
}

bool _urlsMatch(String a, String b) {
  final la = a.toLowerCase().trim();
  final lb = b.toLowerCase().trim();
  if (la.contains(lb) || lb.contains(la)) return true;
  final uriA = Uri.tryParse(la);
  final uriB = Uri.tryParse(lb);
  if (uriA == null || uriB == null) return false;
  final hostA = uriA.host.replaceFirst('www.', '');
  final hostB = uriB.host.replaceFirst('www.', '');
  return hostA.isNotEmpty && hostA == hostB && uriA.path == uriB.path;
}

bool _containsRawSubstring(String search, String title, String url) {
  return (url.isNotEmpty && url.toLowerCase().contains(search)) ||
      (title.isNotEmpty && title.toLowerCase().contains(search));
}

bool _matchesNormalizedPhrase(String citation, String title, String url) {
  final normQ = normalizeCitationMatchText(citation);
  if (normQ.length < 3) return false;
  final normUrl = normalizeCitationMatchText(url);
  final normTitle = normalizeCitationMatchText(title);
  if (normUrl.contains(normQ) || normTitle.contains(normQ)) return true;

  final spacelessQ = normQ.replaceAll(' ', '');
  if (spacelessQ.length < 4) return false;
  return normUrl.replaceAll(' ', '').contains(spacelessQ) ||
      normTitle.replaceAll(' ', '').contains(spacelessQ);
}

bool _allTokensPresent(List<String> tokens, String haystack) {
  final haystackSet = extractCitationTokens(haystack).toSet();
  if (haystackSet.isEmpty) return false;
  return tokens.every(haystackSet.contains);
}

bool _hasMatchingHostDomain(List<String> searchTokens, String itemUrl) {
  if (!itemUrl.startsWith('http')) return false;
  final uri = Uri.tryParse(itemUrl);
  if (uri == null || uri.host.isEmpty) return false;
  final parts = uri.host
      .toLowerCase()
      .replaceFirst('www.', '')
      .split('.')
      .where((p) => p.length >= 2 && !_genericHostLabels.contains(p))
      .toSet();
  if (parts.isEmpty) return false;
  return searchTokens.any(parts.contains);
}

const Set<String> _claimStopwords = {
  'an',
  'as',
  'at',
  'be',
  'by',
  'do',
  'go',
  'he',
  'if',
  'in',
  'is',
  'it',
  'me',
  'my',
  'no',
  'of',
  'on',
  'or',
  'so',
  'to',
  'up',
  'us',
  'we',
  'the',
  'and',
  'for',
  'are',
  'but',
  'not',
  'you',
  'all',
  'can',
  'had',
  'her',
  'was',
  'one',
  'our',
  'out',
  'has',
  'his',
  'how',
  'its',
  'may',
  'new',
  'now',
  'old',
  'see',
  'two',
  'way',
  'who',
  'did',
  'get',
  'let',
  'put',
  'say',
  'she',
  'too',
  'use',
  'that',
  'this',
  'with',
  'have',
  'from',
  'they',
  'been',
  'were',
  'what',
  'when',
  'will',
  'more',
  'also',
  'into',
  'than',
  'then',
  'them',
  'some',
  'such',
  'only',
  'over',
  'very',
  'just',
  'about',
  'after',
  'being',
  'could',
  'other',
  'since',
  'their',
  'there',
  'these',
  'those',
  'under',
  'where',
  'which',
  'while',
  'would',
  'according',
  'reported',
  'shows',
};

final RegExp _wordTokenRegex = RegExp(r'[\p{L}\p{N}]+', unicode: true);
final RegExp _digitRegex = RegExp(r'\d');
final RegExp _sentenceSplitRegex = RegExp(r'(?<=[.!?])\s+|\n+');
final RegExp _alphaThreeRegex = RegExp(r'[a-zA-Z]{3,}');
final RegExp _tocTrailingDigitRegex = RegExp(r'\d+$');

/// Select the verbatim sentence(s) from [fullText] that best support [claim].
///
/// Falls back to [fallbackSnippet] or the opening sentence of [fullText] when
/// [claim] has no meaningful overlap with any sentence in [fullText].
String extractRelevantSourceExcerpt({
  required String claim,
  required String fullText,
  required String fallbackSnippet,
}) {
  final primarySentences = _splitSourceSentences(fullText);
  final fallbackSentences = _splitSourceSentences(fallbackSnippet);
  final candidates = <String>[
    ...primarySentences,
    for (final s in fallbackSentences)
      if (!primarySentences.contains(s)) s,
  ];

  if (candidates.isEmpty) {
    final cleanFallback = fallbackSnippet.trim();
    return cleanFallback.isNotEmpty ? cleanFallback : fullText.trim();
  }

  final weights = _weightedClaimTokens(claim);
  if (weights.isEmpty) {
    final cleanFallback = fallbackSnippet.trim();
    return cleanFallback.isNotEmpty ? cleanFallback : candidates.first;
  }

  var bestIdx = -1;
  var bestScore = 0.0;
  for (var i = 0; i < candidates.length; i++) {
    final score = _scoreSentenceAgainstClaim(candidates[i], weights);
    if (score > bestScore) {
      bestScore = score;
      bestIdx = i;
    }
  }

  if (bestIdx < 0 || bestScore <= 0) {
    final cleanFallback = fallbackSnippet.trim();
    return cleanFallback.isNotEmpty ? cleanFallback : candidates.first;
  }

  var excerpt = candidates[bestIdx];
  if (excerpt.length < 180 && bestIdx + 1 < candidates.length) {
    final next = candidates[bestIdx + 1];
    final combinedLen = excerpt.length + 1 + next.length;
    if (combinedLen <= 280 &&
        _scoreSentenceAgainstClaim(next, weights) >= bestScore * 0.45) {
      excerpt = '$excerpt $next';
    }
  }
  return excerpt;
}

List<String> _splitSourceSentences(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];

  final raw = trimmed
      .split(_sentenceSplitRegex)
      .map((s) => s.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (raw.isEmpty) return const [];

  final filtered = <String>[];
  for (final s in raw) {
    if (s.split(' ').length < 4) continue;
    if (_isBoilerplateLine(s)) continue;
    filtered.add(s);
  }
  return filtered.isNotEmpty ? filtered : raw;
}

bool _isBoilerplateLine(String line) {
  final pipeCount = '|'.allMatches(line).length;
  if (pipeCount >= 2 && _alphaThreeRegex.allMatches(line).length < 6) {
    return true;
  }
  if ((line.contains('...') || line.contains('.....')) &&
      _tocTrailingDigitRegex.hasMatch(line)) {
    return true;
  }
  return false;
}

Map<String, double> _weightedClaimTokens(String claim) {
  final weights = <String, double>{};
  for (final match in _wordTokenRegex.allMatches(claim)) {
    final raw = match.group(0) ?? '';
    final lower = raw.toLowerCase();
    final hasDigit = _digitRegex.hasMatch(raw);
    if (!hasDigit && (lower.length < 2 || _claimStopwords.contains(lower))) {
      continue;
    }
    var weight = 1.0;
    if (hasDigit) {
      weight = 3.0;
    } else if (raw != lower && raw.length >= 2) {
      weight = 2.0;
    } else if (lower.length >= 6) {
      weight = 1.5;
    }
    final existing = weights[lower] ?? 0.0;
    if (weight > existing) weights[lower] = weight;
  }
  return weights;
}

double _scoreSentenceAgainstClaim(
  String sentence,
  Map<String, double> claimWeights,
) {
  final sentenceWords = _wordTokenRegex
      .allMatches(sentence.toLowerCase())
      .map((m) => m.group(0)!)
      .toSet();
  if (sentenceWords.isEmpty) return 0.0;

  var overlap = 0.0;
  for (final entry in claimWeights.entries) {
    final token = entry.key;
    if (sentenceWords.contains(token)) {
      overlap += entry.value;
    } else if (token.length >= 5) {
      final prefix = token.substring(0, 5);
      if (sentenceWords.any((w) => w.length >= 5 && w.startsWith(prefix))) {
        overlap += entry.value * 0.75;
      }
    }
  }
  if (overlap <= 0) return 0.0;
  return overlap / (math.sqrt(sentenceWords.length) + 1.0);
}

/// A single citation label and optional target URL parsed from markdown.
class CitationEntry {
  final String text;
  final String url;

  const CitationEntry({
    required this.text,
    this.url = '',
  });
}

class _ResolvedSource {
  final String rawText;
  final String rawUrl;
  final Map<String, dynamic>? sourceData;
  final String effectiveUrl;

  const _ResolvedSource({
    required this.rawText,
    required this.rawUrl,
    required this.sourceData,
    required this.effectiveUrl,
  });
}

/// Inline citation pill supporting grouped multi-source citations and hover
/// preview cards with source pagination.
class CitationChip extends StatefulWidget {
  final String text;
  final String url;
  final List<CitationEntry>? citations;
  final String claimText;
  final ChatMessage message;
  final VoidCallback? onInspectSources;

  const CitationChip({
    super.key,
    required this.text,
    required this.url,
    this.citations,
    this.claimText = '',
    required this.message,
    this.onInspectSources,
  });

  @override
  State<CitationChip> createState() => _CitationChipState();
}

class _CitationChipState extends State<CitationChip> {
  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _link = LayerLink();

  List<_ResolvedSource> _sources = const [];
  int _currentIndex = 0;

  bool _isHoveringChip = false;
  bool _isHoveringCard = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _resolveAllSources();
  }

  @override
  void didUpdateWidget(covariant CitationChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.url != widget.url ||
        oldWidget.claimText != widget.claimText ||
        !_sameCitations(oldWidget.citations, widget.citations) ||
        oldWidget.message != widget.message) {
      _resolveAllSources();
    }
  }

  @override
  void dispose() {
    _cancelHideTimer();
    super.dispose();
  }

  bool _sameCitations(List<CitationEntry>? a, List<CitationEntry>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].text != b[i].text || a[i].url != b[i].url) return false;
    }
    return true;
  }

  void _cancelHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _checkHide() {
    _cancelHideTimer();
    _hideTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted && !_isHoveringChip && !_isHoveringCard) {
        _overlayController.hide();
      }
    });
  }

  void _openUrl(String url) {
    if (url.isEmpty) return;
    if (url.startsWith('file://')) {
      // Line-anchored code citations open in the in-app viewer at
      // the cited lines; every other file citation (documents with
      // #page= anchors, plain file:// paths) keeps the historical
      // external launch.
      final target = CodeCitationTarget.tryParse(url);
      if (target != null) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CodeCitationViewer(target: target),
          ),
        );
        return;
      }
      launchUrlString(fileCitationLaunchUrl(url));
      return;
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      launchUrlString(url);
    }
  }

  void _resolveAllSources() {
    final items = _extractAllSourceItems();
    final expanded = _expandCitationEntries(items);
    final resolved = <_ResolvedSource>[];
    final seenKeys = <String>{};

    for (final entry in expanded) {
      final source = _resolveSingleEntry(entry, items);
      final dedupKey = source.effectiveUrl.isNotEmpty
          ? source.effectiveUrl.toLowerCase()
          : source.rawText.toLowerCase().trim();
      if (dedupKey.isNotEmpty && !seenKeys.add(dedupKey)) {
        continue;
      }
      resolved.add(source);
    }

    if (resolved.isEmpty) {
      resolved.add(
        _resolveSingleEntry(
          CitationEntry(text: widget.text, url: widget.url),
          items,
        ),
      );
    }

    _sources = resolved;
    if (_currentIndex >= _sources.length) {
      _currentIndex = _sources.length - 1;
    }
    if (_currentIndex < 0) {
      _currentIndex = 0;
    }
  }

  List<CitationEntry> _expandCitationEntries(List<Map<String, dynamic>> items) {
    final base = (widget.citations != null && widget.citations!.isNotEmpty)
        ? widget.citations!
        : [CitationEntry(text: widget.text, url: widget.url)];

    final expanded = <CitationEntry>[];
    for (final entry in base) {
      if (entry.url.isNotEmpty) {
        expanded.add(entry);
      } else {
        expanded.addAll(_tryExpandInlineList(entry.text, items));
      }
    }
    return expanded;
  }

  List<CitationEntry> _tryExpandInlineList(
    String rawText,
    List<Map<String, dynamic>> items,
  ) {
    if (!rawText.contains(',') && !rawText.contains(';')) {
      return [CitationEntry(text: rawText)];
    }
    if (_pageRefSuffixRegex.hasMatch(rawText)) {
      return [CitationEntry(text: rawText)];
    }
    if (_matchSourceItem(rawText, '', items) != null) {
      return [CitationEntry(text: rawText)];
    }

    final parts = rawText
        .split(RegExp(r'\s*[,;]\s*'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length < 2) {
      return [CitationEntry(text: rawText)];
    }

    final allNumeric = parts.every((p) => int.tryParse(p) != null);
    if (allNumeric) {
      return parts.map((p) => CitationEntry(text: p)).toList();
    }

    final allResolvable = parts.every((p) =>
        int.tryParse(p) != null ||
        _bareDomainRegex.hasMatch(p) ||
        _matchSourceItem(p, '', items) != null);
    if (allResolvable) {
      return parts.map((p) => CitationEntry(text: p)).toList();
    }

    return [CitationEntry(text: rawText)];
  }

  _ResolvedSource _resolveSingleEntry(
    CitationEntry entry,
    List<Map<String, dynamic>> items,
  ) {
    final matched = _matchSourceItem(entry.text, entry.url, items);
    var effectiveUrl = entry.url;
    if (effectiveUrl.isEmpty && matched != null) {
      effectiveUrl = _extractItemUrl(matched);
    }
    if (effectiveUrl.isEmpty && _bareDomainRegex.hasMatch(entry.text.trim())) {
      effectiveUrl = 'https://${entry.text.trim()}';
    }
    return _ResolvedSource(
      rawText: entry.text,
      rawUrl: entry.url,
      sourceData: matched,
      effectiveUrl: effectiveUrl,
    );
  }

  static bool _isSourceEvent(ToolEvent event) {
    if (event.result == null) return false;
    final n = event.name.toLowerCase();
    return n.contains('web_search') ||
        n.contains('merge_rank') ||
        n.contains('search_vectors') ||
        n.contains('query_graph') ||
        n.contains('build_lazy_dossier') ||
        n.contains('ephemeral_web_rag') ||
        n.contains('agentic_debate') ||
        n.contains('dynamic_web_graph') ||
        n.contains('code_symbol') ||
        n.contains('code_impact') ||
        n.contains('code_overview');
  }

  List<Map<String, dynamic>> _extractAllSourceItems() {
    final items = <Map<String, dynamic>>[];
    for (final event in widget.message.toolEvents) {
      if (!_isSourceEvent(event)) continue;
      items.addAll(_parseEventItems(event.result));
    }
    return items;
  }

  List<Map<String, dynamic>> _parseEventItems(dynamic result) {
    dynamic decoded = result;
    if (result is String) {
      final trimmed = result.trimLeft();
      if (!trimmed.startsWith('[') && !trimmed.startsWith('{')) {
        return const [];
      }
      try {
        decoded = jsonDecode(trimmed);
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
        return const [];
      }
    }

    List<dynamic> rawList = const [];
    if (decoded is List) {
      rawList = decoded;
    } else if (decoded is Map) {
      if (decoded['chunks'] is List) {
        rawList = decoded['chunks'] as List;
      } else if (decoded['sources'] is List) {
        rawList = decoded['sources'] as List;
      }
    }

    return rawList
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Map<String, dynamic>? _matchSourceItem(
    String rawText,
    String rawUrl,
    List<Map<String, dynamic>> items,
  ) {
    if (items.isEmpty) return null;

    if (rawUrl.isNotEmpty) {
      final byUrl = _findFirstMatch(items, (item) {
        final itemUrl = _extractItemUrl(item);
        return itemUrl.isNotEmpty && _urlsMatch(rawUrl, itemUrl);
      });
      if (byUrl != null) return byUrl;
    }

    final search = rawText.trim();
    if (search.isEmpty) return null;

    final numIndex = int.tryParse(search);
    if (numIndex != null && numIndex > 0 && numIndex <= items.length) {
      return items[numIndex - 1];
    }

    final lowerSearch = search.toLowerCase();
    return _findFirstMatch(items, (item) {
          return _containsRawSubstring(
            lowerSearch,
            _extractItemTitle(item),
            _extractItemUrl(item),
          );
        }) ??
        _findFirstMatch(items, (item) {
          return _matchesNormalizedPhrase(
            search,
            _extractItemTitle(item),
            _extractItemUrl(item),
          );
        }) ??
        _findBestTokenMatch(search, items);
  }

  Map<String, dynamic>? _findFirstMatch(
    List<Map<String, dynamic>> items,
    bool Function(Map<String, dynamic> item) predicate,
  ) {
    for (final item in items) {
      if (predicate(item)) return item;
    }
    return null;
  }

  Map<String, dynamic>? _findBestTokenMatch(
    String search,
    List<Map<String, dynamic>> items,
  ) {
    final tokens = extractCitationTokens(search);
    if (tokens.isEmpty) return null;

    final byTitleAndUrl = _findFirstMatch(items, (item) {
      return _allTokensPresent(
        tokens,
        '${_extractItemTitle(item)} ${_extractItemUrl(item)}',
      );
    });
    if (byTitleAndUrl != null) return byTitleAndUrl;

    final bySnippet = _findFirstMatch(items, (item) {
      return _allTokensPresent(
        tokens,
        '${_extractItemTitle(item)} ${_extractItemUrl(item)} ${_extractItemSnippet(item)}',
      );
    });
    if (bySnippet != null) return bySnippet;

    return _findFirstMatch(items, (item) {
      return _hasMatchingHostDomain(tokens, _extractItemUrl(item));
    });
  }

  String _extractItemUrl(Map item) {
    final directUrl = item['url']?.toString().trim() ?? '';
    if (_isSupportedUrl(directUrl)) return directUrl;

    if (item['payload'] is Map) {
      final payload = item['payload'] as Map;
      for (final key in ['url', 'link', 'source']) {
        final candidate = payload[key]?.toString().trim() ?? '';
        if (_isSupportedUrl(candidate)) return candidate;
      }
    }

    if (item['sources'] is List) {
      for (final s in item['sources'] as List) {
        final candidate = s.toString().trim();
        if (candidate.startsWith('http://') ||
            candidate.startsWith('https://')) {
          return candidate;
        }
      }
    }

    final link = item['link']?.toString().trim() ?? '';
    if (_isSupportedUrl(link)) return link;
    return '';
  }

  bool _isSupportedUrl(String value) {
    return value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('file://');
  }

  String _extractItemTitle(Map item) {
    final direct = item['title']?.toString() ?? '';
    if (direct.isNotEmpty) return direct;

    if (item['payload'] is Map) {
      final payload = item['payload'] as Map;
      final payloadTitle = payload['title']?.toString() ?? '';
      if (payloadTitle.isNotEmpty) return payloadTitle;
      final docName = payload['document_name']?.toString() ?? '';
      if (docName.isNotEmpty) return docName;
    }

    for (final key in ['document_name', 'entity', 'source']) {
      final val = item[key]?.toString() ?? '';
      if (val.isNotEmpty) return val;
    }
    return '';
  }

  String _extractItemFullText(Map item) {
    if (item['payload'] is Map) {
      final payload = item['payload'] as Map;
      for (final key in ['text', 'content']) {
        final val = payload[key]?.toString() ?? '';
        if (val.isNotEmpty) return val;
      }
    }
    for (final key in ['content', 'text']) {
      final val = item[key]?.toString() ?? '';
      if (val.isNotEmpty) return val;
    }
    return '';
  }

  String _extractItemFallbackSnippet(Map item) {
    if (item['payload'] is Map) {
      final payload = item['payload'] as Map;
      final val = payload['snippet']?.toString() ?? '';
      if (val.isNotEmpty) return val;
    }
    final direct = item['snippet']?.toString() ?? '';
    if (direct.isNotEmpty) return direct;
    return _extractItemFullText(item);
  }

  String _extractItemSnippet(Map item) {
    final full = _extractItemFullText(item);
    return full.isNotEmpty ? full : _extractItemFallbackSnippet(item);
  }

  String _displayTextFor(_ResolvedSource source) {
    var text = source.rawText;
    if (int.tryParse(text) != null) {
      if (source.effectiveUrl.startsWith('http')) {
        text = _domainLabelFor(source);
      } else {
        final title = _resolveTitleFor(source);
        if (title.isNotEmpty) {
          text = title.length > 20 ? '${title.substring(0, 18)}…' : title;
        }
      }
    }
    if (text.isNotEmpty && text == text.toLowerCase()) {
      text = text[0].toUpperCase() + text.substring(1);
    }
    return text;
  }

  String _domainLabelFor(_ResolvedSource source) {
    final url = source.effectiveUrl;
    if (!url.startsWith('http')) {
      if (source.sourceData != null) {
        final title = _resolveTitleFor(source);
        return title.isNotEmpty ? title : 'Knowledge Base';
      }
      return _displayTextFor(source);
    }
    try {
      final host = Uri.parse(url).host.replaceFirst('www.', '');
      final parts = host.split('.');
      return parts.length > 1 ? parts[parts.length - 2] : host;
    } catch (_) {
      return url;
    }
  }

  String _faviconUrlFor(_ResolvedSource source) {
    final url = source.effectiveUrl;
    if (!url.startsWith('http')) return '';
    try {
      final host = Uri.parse(url).host;
      if (host.isNotEmpty) return 'https://icon.horse/icon/$host';
    } catch (_) {}
    return '';
  }

  String _resolveTitleFor(_ResolvedSource source) {
    final data = source.sourceData;
    if (data != null) {
      return _extractItemTitle(data);
    }
    if (source.effectiveUrl.isNotEmpty) {
      return _displayTextFor(source);
    }
    return '';
  }

  String _resolveSnippetFor(_ResolvedSource source) {
    final data = source.sourceData;
    if (data == null) return '';
    final effectiveClaim = widget.claimText.trim().isNotEmpty
        ? widget.claimText.trim()
        : widget.message.content;
    return extractRelevantSourceExcerpt(
      claim: effectiveClaim,
      fullText: _extractItemFullText(data),
      fallbackSnippet: _extractItemFallbackSnippet(data),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primarySource = _sources.first;
    final extraCount = _sources.length - 1;
    final faviconUrl = _faviconUrlFor(primarySource);

    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) {
          _cancelHideTimer();
          _isHoveringChip = true;
          _overlayController.show();
        },
        onExit: (_) {
          _isHoveringChip = false;
          _checkHide();
        },
        child: OverlayPortal(
          controller: _overlayController,
          overlayChildBuilder: (context) {
            return Positioned(
              width: 320,
              child: CompositedTransformFollower(
                link: _link,
                targetAnchor: Alignment.topCenter,
                followerAnchor: Alignment.bottomCenter,
                offset: const Offset(0, -8),
                child: MouseRegion(
                  onEnter: (_) {
                    _cancelHideTimer();
                    _isHoveringCard = true;
                  },
                  onExit: (_) {
                    _isHoveringCard = false;
                    _checkHide();
                  },
                  child: _buildHoverCard(),
                ),
              ),
            );
          },
          child: InkWell(
            onTap: () => _openUrl(primarySource.effectiveUrl),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF272727),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF3D3D3D)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (faviconUrl.isNotEmpty) ...[
                    ClipOval(
                      child: Image.network(
                        faviconUrl,
                        width: 11,
                        height: 11,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.language,
                          size: 11,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      _displayTextFor(primarySource),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFCCCCCC),
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (extraCount > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      '+$extraCount',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF9E9E9E),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHoverCard() {
    final ext = Theme.of(context).extension<AppThemeExtension>();
    final cardBg = ext?.cardBackground ?? const Color(0xFF1F1F1F);
    final activeSource = _sources[_currentIndex];

    return Material(
      color: Colors.transparent,
      elevation: 12,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2E2E2E)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_sources.length > 1) ...[
              _buildMultiSourceHeader(cardBg),
              const Divider(height: 1, color: Color(0xFF2E2E2E)),
            ],
            _buildActiveSourceBody(activeSource),
          ],
        ),
      ),
    );
  }

  Widget _buildMultiSourceHeader(Color cardBg) {
    final canPrev = _currentIndex > 0;
    final canNext = _currentIndex < _sources.length - 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          _buildNavButton(
            icon: Icons.chevron_left,
            enabled: canPrev,
            onTap: () {
              if (!canPrev) return;
              _cancelHideTimer();
              setState(() => _currentIndex--);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${_currentIndex + 1}/${_sources.length}',
              style: const TextStyle(
                color: Color(0xFFA0A0A0),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          _buildNavButton(
            icon: Icons.chevron_right,
            enabled: canNext,
            onTap: () {
              if (!canNext) return;
              _cancelHideTimer();
              setState(() => _currentIndex++);
            },
          ),
          const Spacer(),
          _buildOverlappingFavicons(cardBg),
          const SizedBox(width: 6),
          Text(
            '${_sources.length} sources',
            style: const TextStyle(
              color: Color(0xFFCCCCCC),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          icon,
          size: 16,
          color: enabled ? const Color(0xFFCCCCCC) : const Color(0xFF555555),
        ),
      ),
    );
  }

  Widget _buildOverlappingFavicons(Color cardBg) {
    final preview = _sources.take(3).toList();
    return SizedBox(
      width: 15.0 + (preview.length - 1) * 9.0,
      height: 15,
      child: Stack(
        children: List.generate(preview.length, (index) {
          final renderIndex = preview.length - 1 - index;
          final favUrl = _faviconUrlFor(preview[renderIndex]);
          return Positioned(
            left: renderIndex * 9.0,
            child: Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF2E2E2E),
                border: Border.all(color: cardBg, width: 1.5),
              ),
              child: ClipOval(
                child: favUrl.isNotEmpty
                    ? Image.network(
                        favUrl,
                        width: 12,
                        height: 12,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.language,
                          size: 9,
                          color: Colors.white54,
                        ),
                      )
                    : const Icon(
                        Icons.language,
                        size: 9,
                        color: Colors.white54,
                      ),
              ),
            ),
          );
        }),
      ),
    );
  }

  double? _extractFusedScore(_ResolvedSource source) {
    final data = source.sourceData;
    if (data == null) return null;
    final provenance = data['provenance'];
    final raw =
        provenance is Map ? provenance['fused_score'] : data['fused_score'];
    return raw is num ? raw.toDouble() : null;
  }

  List<String> _extractProvenanceLegs(_ResolvedSource source) {
    final provenance = source.sourceData?['provenance'];
    if (provenance is! Map || provenance['legs'] is! List) return const [];
    return [
      for (final leg in provenance['legs'] as List)
        if (leg is String) leg,
    ];
  }

  bool _hasGraphPath(_ResolvedSource source) {
    final provenance = source.sourceData?['provenance'];
    return provenance is Map &&
        provenance['graph_path'] is List &&
        (provenance['graph_path'] as List).length >= 2;
  }

  Widget _buildCompactBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildActiveSourceBody(_ResolvedSource source) {
    final title = _resolveTitleFor(source);
    final snippet = _resolveSnippetFor(source);
    final domain = _domainLabelFor(source);
    final faviconUrl = _faviconUrlFor(source);
    final isInternalKb =
        source.sourceData != null && source.effectiveUrl.isEmpty;
    final fusedScore = _extractFusedScore(source);
    final legs = _extractProvenanceLegs(source);
    final hasProvenance = fusedScore != null || legs.isNotEmpty;
    final showFooter =
        source.sourceData != null || widget.onInspectSources != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => _openUrl(source.effectiveUrl),
          borderRadius: showFooter
              ? (_sources.length > 1
                  ? BorderRadius.zero
                  : const BorderRadius.vertical(top: Radius.circular(12)))
              : (_sources.length > 1
                  ? const BorderRadius.vertical(bottom: Radius.circular(12))
                  : BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (faviconUrl.isNotEmpty) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: Image.network(
                          faviconUrl,
                          width: 14,
                          height: 14,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.language,
                            size: 14,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ] else if (isInternalKb) ...[
                      Icon(
                        Icons.auto_stories_outlined,
                        size: 14,
                        color: Colors.blueAccent.shade100,
                      ),
                      const SizedBox(width: 6),
                    ] else ...[
                      const Icon(
                        Icons.language,
                        size: 14,
                        color: Colors.white54,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        domain.isNotEmpty ? domain : _displayTextFor(source),
                        style: const TextStyle(
                          color: Color(0xFFA0A0A0),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (legs.contains('graph')) ...[
                      const SizedBox(width: 6),
                      _buildCompactBadge('Graph', const Color(0xFFD98A2B)),
                    ],
                    if (fusedScore != null) ...[
                      const SizedBox(width: 6),
                      _buildCompactBadge(
                        matchTierForScore(fusedScore),
                        matchTierColor(fusedScore),
                      ),
                    ],
                  ],
                ),
                if (title.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xFFE8E8E8),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (snippet.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.only(left: 8),
                    decoration: const BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: Color(0xFF4F8EF7),
                          width: 2,
                        ),
                      ),
                    ),
                    child: Text(
                      snippet,
                      style: const TextStyle(
                        color: Color(0xFFB8B8B8),
                        fontSize: 12,
                        height: 1.4,
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (showFooter) ...[
          const Divider(height: 1, color: Color(0xFF2E2E2E)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (hasProvenance)
                  Expanded(
                    child: Text(
                      _hasGraphPath(source)
                          ? 'Graph path available'
                          : 'Provenance & context',
                      style: const TextStyle(
                        color: Color(0xFF878787),
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  const Spacer(),
                InkWell(
                  key: const Key('view-in-sources-button'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    _overlayController.hide();
                    widget.onInspectSources?.call();
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      'View in Sources →',
                      style: TextStyle(
                        color: Color(0xFF4F8EF7),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
