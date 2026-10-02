import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';

/// Displays a single agent tool invocation inline in the chat stream.
///
/// Shows a spinner while running, a success/error icon on completion,
/// and expands to reveal the full output when tapped.
class ToolEventCard extends StatefulWidget {
  const ToolEventCard({super.key, required this.event});

  final ToolEvent event;

  @override
  State<ToolEventCard> createState() => _ToolEventCardState();
}

class _ToolEventCardState extends State<ToolEventCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _rotateController;

  @override
  void initState() {
    super.initState();
    _rotateController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void dispose() {
    _rotateController.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _rotateController.forward();
    } else {
      _rotateController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final isComplete = event.isComplete;
    final result = event.result;

    // Friendly name shown in the pill
    final label = _friendlyLabel(event.name);

    // Determine icon / colour from result content
    final isError = result is String && result.startsWith('Error:');
    final Color accentColor = isError
        ? Colors.redAccent
        : isComplete
            ? Colors.greenAccent.shade400
            : Colors.blueAccent;

    final Widget statusIcon = isComplete
        ? Icon(
            isError
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 14,
            color: accentColor,
          )
        : SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation(accentColor),
            ),
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row (always visible) ───────────────────────────────
              InkWell(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                onTap: isComplete && result != null ? _toggle : null,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(
                    children: [
                      statusIcon,
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.85),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (isComplete && result != null)
                        RotationTransition(
                          turns: Tween(begin: 0.0, end: 0.5)
                              .animate(_rotateController),
                          child: Icon(
                            Icons.expand_more_rounded,
                            size: 16,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // ── Expanded result ───────────────────────────────────────────
              if (_expanded && result != null)
                _ResultPanel(result: result.toString()),
            ],
          ),
        ),
      ),
    );
  }

  static String _friendlyLabel(String toolName) {
    switch (toolName) {
      case 'read_file':
        return '📄 Reading file…';
      case 'write_file':
        return '💾 Writing file…';
      case 'list_files':
        return '📂 Listing files…';
      case 'run_shell':
        return '⚡ Running shell command…';
      case 'open_app':
        return '📱 Opening app…';
      case 'web_search':
        return '🌐 Searching the web…';
      default:
        return '🔧 $toolName…';
    }
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.result});
  final String result;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Copy button
          Align(
            alignment: Alignment.topRight,
            child: GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: result));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy_rounded,
                        size: 12, color: Colors.white.withValues(alpha: 0.5)),
                    const SizedBox(width: 4),
                    Text(
                      'Copy',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.5)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Result content
          SelectableText(
            result,
            style: const TextStyle(
              fontSize: 11.5,
              fontFamily: 'monospace',
              color: Colors.white70,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
