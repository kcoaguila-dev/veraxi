import 'package:flutter/material.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'dart:convert';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:veraxi_app/core/theme_extension.dart';


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
      margin: EdgeInsets.only(bottom: 8.0),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
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
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                  ),
                  SizedBox(width: 8),
                  Text(
                    '> ${widget.event.name}',
                    style: TextStyle(
                      color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const Spacer(),
                  if (!isComplete)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                      ),
                    )
                        .animate(onPlay: (controller) => controller.repeat())
                        .shimmer(duration: 1.seconds, color: Colors.white30)
                  else
                    Icon(Icons.check, size: 14, color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.event.name.contains('web_search')) ...[
                    Text('Query: "${widget.event.args['query'] ?? ''}"',
                        style: TextStyle(
                            color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                            fontSize: 13,
                            fontStyle: FontStyle.italic)),
                    SizedBox(height: 12),
                    Text('Sources Retrieved:',
                        style: TextStyle(
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    SizedBox(height: 8),
                    if (widget.event.result != null)
                      ..._buildWebSearchResults(widget.event.result)
                    else
                      Text('...',
                          style: TextStyle(
                              color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 12)),
                  ] else ...[
                    Text('Arguments:',
                        style: TextStyle(
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    SizedBox(height: 4),
                    Text(
                      const JsonEncoder.withIndent('  ')
                          .convert(widget.event.args),
                      style: TextStyle(
                          color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                          fontSize: 12,
                          fontFamily: 'monospace'),
                    ),
                    SizedBox(height: 12),
                    Text('Result:',
                        style: TextStyle(
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    SizedBox(height: 4),
                    if (widget.event.result != null)
                      Text(
                        widget.event.result is String
                            ? widget.event.result
                            : const JsonEncoder.withIndent('  ')
                                .convert(widget.event.result),
                        style: TextStyle(
                            color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                            fontSize: 12,
                            fontFamily: 'monospace'),
                        maxLines: 10,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      Text('...',
                          style: TextStyle(
                              color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 12)),
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
              style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 12))
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
      if (url.isEmpty) return SizedBox.shrink();

      return Padding(
        padding: EdgeInsets.only(bottom: 6.0),
        child: InkWell(
          onTap: () => launchUrlString(url),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.link, size: 14, color: Colors.blueAccent),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
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
