import 'package:flutter/material.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'dart:convert';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher_string.dart';

class AgenticToolLog extends StatefulWidget {
  final ToolEvent event;

  const AgenticToolLog({super.key, required this.event});

  @override
  State<AgenticToolLog> createState() => _AgenticToolLogState();
}

class _AgenticToolLogState extends State<AgenticToolLog> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isComplete = widget.event.isComplete;

    return Container(
      margin: const EdgeInsets.only(bottom: 8.0),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _expanded = !_expanded;
              });
            },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: const Color(0xFF878787),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '> ${widget.event.name}',
                    style: const TextStyle(
                      color: Color(0xFFB4B4B4),
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const Spacer(),
                  if (!isComplete)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Color(0xFF878787)),
                      ),
                    )
                        .animate(onPlay: (controller) => controller.repeat())
                        .shimmer(duration: 1.seconds, color: Colors.white30)
                  else
                    const Icon(Icons.check, size: 14, color: Color(0xFF878787)),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.event.name.contains('web_search')) ...[
                    Text('Query: "${widget.event.args['query'] ?? ''}"',
                        style: const TextStyle(
                            color: Color(0xFFB4B4B4),
                            fontSize: 13,
                            fontStyle: FontStyle.italic)),
                    const SizedBox(height: 12),
                    const Text('Sources Retrieved:',
                        style: TextStyle(
                            color: Color(0xFF878787),
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (widget.event.result != null)
                      ..._buildWebSearchResults(widget.event.result)
                    else
                      const Text('...',
                          style: TextStyle(
                              color: Color(0xFF878787), fontSize: 12)),
                  ] else ...[
                    const Text('Arguments:',
                        style: TextStyle(
                            color: Color(0xFF878787),
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      const JsonEncoder.withIndent('  ')
                          .convert(widget.event.args),
                      style: const TextStyle(
                          color: Color(0xFFB4B4B4),
                          fontSize: 12,
                          fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 12),
                    const Text('Result:',
                        style: TextStyle(
                            color: Color(0xFF878787),
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    if (widget.event.result != null)
                      Text(
                        widget.event.result is String
                            ? widget.event.result
                            : const JsonEncoder.withIndent('  ')
                                .convert(widget.event.result),
                        style: const TextStyle(
                            color: Color(0xFFB4B4B4),
                            fontSize: 12,
                            fontFamily: 'monospace'),
                        maxLines: 10,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      const Text('...',
                          style: TextStyle(
                              color: Color(0xFF878787), fontSize: 12)),
                  ]
                ],
              ),
            ).animate().fade(duration: 200.ms),
        ],
      ),
    );
  }

  List<Widget> _buildWebSearchResults(dynamic result) {
    if (result == null) return [];

    List<dynamic> items = [];
    if (result is String) {
      try {
        final decoded = jsonDecode(result);
        if (decoded is List) items = decoded;
      } catch (_) {
        // Not JSON
        return [
          Text(result.toString(),
              style: const TextStyle(color: Color(0xFFB4B4B4), fontSize: 12))
        ];
      }
    } else if (result is List) {
      items = result;
    }

    return items.take(5).map((item) {
      String url = '';
      String title = '';

      if (item is Map) {
        if (item.containsKey('sources') &&
            (item['sources'] as List).isNotEmpty) {
          url = item['sources'][0].toString();
        }
        if (item.containsKey('payload') && item['payload'] is Map) {
          final payload = item['payload'] as Map;
          title =
              payload['title']?.toString() ?? payload['text']?.toString() ?? '';
        }
      }

      if (title.length > 80) title = '${title.substring(0, 80)}...';
      if (title.isEmpty) title = url;
      if (url.isEmpty) return const SizedBox.shrink();

      return Padding(
        padding: const EdgeInsets.only(bottom: 6.0),
        child: InkWell(
          onTap: () => launchUrlString(url),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.link, size: 14, color: Colors.blueAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                      color: Colors.blueAccent,
                      fontSize: 12,
                      decoration: TextDecoration.underline),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}
