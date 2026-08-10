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

  @override
  void initState() {
    super.initState();
    _findSourceData();
  }

  void _findSourceData() {
    for (var event in widget.message.toolEvents) {
      if (event.name.contains('web_search') && event.result != null) {
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
              String itemUrl = '';
              if (item.containsKey('sources') &&
                  (item['sources'] as List).isNotEmpty) {
                itemUrl = item['sources'][0].toString();
              }
              if (itemUrl.contains(widget.url) ||
                  widget.url.contains(itemUrl)) {
                _sourceData = Map<String, dynamic>.from(item);
                break;
              }
            }
          }
        } catch (_) {}
      }
      if (_sourceData != null) break;
    }
  }

  String get _displayText {
    String text = widget.text;
    if (int.tryParse(text) != null) {
      try {
        final uri = Uri.parse(widget.url);
        String host = uri.host;
        if (host.startsWith('www.')) {
          host = host.substring(4);
        }
        final parts = host.split('.');
        if (parts.length > 1 && parts.last.length <= 4) {
          text = parts[parts.length - 2];
        } else {
          text = host;
        }
        if (text.isNotEmpty) {
          text = text[0].toUpperCase() + text.substring(1);
        }
      } catch (_) {}
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) => _overlayController.show(),
        onExit: (_) => _overlayController.hide(),
        child: OverlayPortal(
          controller: _overlayController,
          overlayChildBuilder: (context) {
            return Positioned(
              width: 300,
              child: CompositedTransformFollower(
                link: _link,
                targetAnchor: Alignment.topCenter,
                followerAnchor: Alignment.bottomCenter,
                offset: const Offset(0, -8),
                child: _buildHoverCard(),
              ),
            );
          },
          child: InkWell(
            onTap: () => launchUrlString(widget.url),
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF3A3A3A)),
              ),
              child: Text(
                _displayText,
                style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFE0E0E0),
                    fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHoverCard() {
    String title = 'Web Source';
    String desc = widget.url;

    if (_sourceData != null) {
      if (_sourceData!.containsKey('payload') &&
          _sourceData!['payload'] is Map) {
        final payload = _sourceData!['payload'] as Map;
        title = payload['title']?.toString() ??
            payload['text']?.toString() ??
            title;
        desc = payload['text']?.toString() ?? widget.url;
      }
    }

    if (title.length > 80) title = '${title.substring(0, 80)}...';
    // Remove description truncation to show exact snippets

    return Material(
      color: Colors.transparent,
      elevation: 8,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2A2A2A)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.language, size: 16, color: Colors.white70),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _displayText,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Text(
              desc,
              style: const TextStyle(color: Color(0xFFB4B4B4), fontSize: 12),
              maxLines: 15,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
