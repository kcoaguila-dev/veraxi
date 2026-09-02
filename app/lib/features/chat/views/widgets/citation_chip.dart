import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'dart:convert';

class CitationChip extends StatefulWidget {
  final String text;
  final String url;
  final ChatMessage message;

  const CitationChip({
    super.key,
    required this.text,
    required this.url,
    required this.message,
  });

  @override
  State<CitationChip> createState() => _CitationChipState();
}

class _CitationChipState extends State<CitationChip> {
  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _link = LayerLink();

  Map<String, dynamic>? _sourceData;
  late String _effectiveUrl;

  bool _isHoveringChip = false;
  bool _isHoveringCard = false;

  void _checkHide() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted && !_isHoveringChip && !_isHoveringCard) {
        _overlayController.hide();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _findSourceData();
  }

  void _findSourceData() {
    for (final event in widget.message.toolEvents) {
      if (!event.name.contains('web_search') || event.result == null) continue;
      _effectiveUrl = widget.url;

      try {
        List<dynamic> items = [];
        if (event.result is String) {
          final decoded = jsonDecode(event.result);
          if (decoded is List) items = decoded;
        } else if (event.result is List) {
          items = event.result;
        }

        for (final item in items) {
          if (item is! Map) continue;
          final itemUrl = _extractUrl(item);
          String itemTitle = item['title']?.toString() ?? '';
          if (itemTitle.isEmpty && item['payload'] is Map) {
            itemTitle = item['payload']['title']?.toString() ?? '';
          }

          // Match by URL if we have one
          if (widget.url.isNotEmpty &&
              (itemUrl.contains(widget.url) || widget.url.contains(itemUrl))) {
            _sourceData = Map<String, dynamic>.from(item);
            break;
          }

          // Match by source name when URL is empty (e.g. [Yahoo Finance])
          if (widget.url.isEmpty && widget.text.isNotEmpty) {
            final searchText = widget.text.toLowerCase();
            if (itemUrl.toLowerCase().contains(searchText) ||
                itemTitle.toLowerCase().contains(searchText)) {
              _sourceData = Map<String, dynamic>.from(item);
              break;
            }
          }
        }
      } catch (_) {}

      if (_sourceData != null) break;
    }

    // Resolve effective URL from source data when chip has no URL
    if (widget.url.isEmpty && _sourceData != null) {
      _effectiveUrl = _extractUrl(_sourceData!);
    } else {
      _effectiveUrl = widget.url;
    }
  }

  String _extractUrl(Map item) {
    if (item.containsKey('url')) return item['url'].toString();
    if (item.containsKey('sources') && (item['sources'] as List).isNotEmpty) {
      return item['sources'][0].toString();
    }
    return '';
  }

  String get _displayText {
    String text = widget.text;
    // If text is just a number, derive name from URL
    if (int.tryParse(text) != null) {
      text = _domainLabel(_effectiveUrl);
    }
    if (text.isNotEmpty && text == text.toLowerCase()) {
      text = text[0].toUpperCase() + text.substring(1);
    }
    return text;
  }

  String _domainLabel(String url) {
    try {
      final host = Uri.parse(url).host.replaceFirst('www.', '');
      final parts = host.split('.');
      return parts.length > 1 ? parts[parts.length - 2] : host;
    } catch (_) {
      return url;
    }
  }

  String get _faviconUrl {
    try {
      final host = Uri.parse(_effectiveUrl).host;
      if (host.isNotEmpty) return 'https://icon.horse/icon/$host';
    } catch (_) {}
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) {
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
            onTap: () {
              if (_effectiveUrl.isNotEmpty) launchUrlString(_effectiveUrl);
            },
            borderRadius: BorderRadius.circular(4),
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
                  if (_faviconUrl.isNotEmpty) ...[
                    ClipOval(
                      child: Image.network(
                        _faviconUrl,
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
                  Text(
                    _displayText,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFCCCCCC),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHoverCard() {
    final title = _resolveTitle();
    final snippet = _resolveSnippet();
    final domain = _domainLabel(_effectiveUrl);

    return Material(
      color: Colors.transparent,
      elevation: 12,
      child: InkWell(
        onTap: () {
          if (_effectiveUrl.isNotEmpty) launchUrlString(_effectiveUrl);
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 320,
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
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
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header: favicon + domain ──────────────────────────────
                Row(
                  children: [
                    if (_faviconUrl.isNotEmpty) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: Image.network(
                          _faviconUrl,
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
                    ],
                    Expanded(
                      child: Text(
                        domain.isNotEmpty ? domain : _displayText,
                        style: const TextStyle(
                          color: Color(0xFFA0A0A0),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),

                // ── Article title ─────────────────────────────────────────
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

                // ── Snippet ───────────────────────────────────────────────
                if (snippet.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    snippet,
                    style: const TextStyle(
                      color: Color(0xFF9A9A9A),
                      fontSize: 12,
                      height: 1.4,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _resolveTitle() {
    if (_sourceData == null) return '';
    // Direct top-level title (what SearXNG returns)
    final direct = _sourceData!['title']?.toString() ?? '';
    if (direct.isNotEmpty) return direct;
    // Fallback: nested payload
    final payload = _sourceData!['payload'];
    if (payload is Map) {
      return payload['title']?.toString() ?? payload['text']?.toString() ?? '';
    }
    return '';
  }

  String _resolveSnippet() {
    if (_sourceData == null) return '';
    // Direct content / description from SearXNG
    final content = _sourceData!['content']?.toString() ??
        _sourceData!['snippet']?.toString() ??
        _sourceData!['text']?.toString() ??
        '';
    if (content.isNotEmpty) return content;
    // Fallback: nested payload text
    final payload = _sourceData!['payload'];
    if (payload is Map) {
      return payload['snippet']?.toString() ??
          payload['text']?.toString() ??
          payload['content']?.toString() ??
          '';
    }
    return '';
  }
}
