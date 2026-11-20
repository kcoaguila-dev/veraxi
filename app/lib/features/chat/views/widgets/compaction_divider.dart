import 'package:material_ui/material_ui.dart';

import '../../view_models/chat_state.dart';

/// The in-thread marker for a compacted span: a divider, never a
/// chat bubble. The summary message carries a `compaction` record in
/// its metrics (messages_compacted / compacted_at / tokens_before);
/// tapping the divider opens the full summary text.
class CompactionDivider extends StatelessWidget {
  final ChatMessage message;

  const CompactionDivider({super.key, required this.message});

  static bool isCompactionMessage(ChatMessage message) {
    final metrics = message.metrics;
    return metrics != null && metrics['compaction'] is Map;
  }

  @override
  Widget build(BuildContext context) {
    final record = message.metrics?['compaction'] as Map?;
    final count = record?['messages_compacted'];
    final label = count is int
        ? 'Conversation compacted · $count messages summarized'
        : 'Conversation compacted';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: InkWell(
            onTap: () => _showSummary(context),
            borderRadius: BorderRadius.circular(999),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Expanded(child: Divider(color: Color(0xFF2E2E2E))),
                const SizedBox(width: 10),
                const Icon(Icons.compress,
                    size: 14, color: Color(0xFF8A8A8A)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style: const TextStyle(
                        color: Color(0xFF8A8A8A), fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(child: Divider(color: Color(0xFF2E2E2E))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSummary(BuildContext context) {
    // Strip the machine-facing prefix line for display.
    var text = message.content;
    const prefix = '[Conversation summary';
    if (text.startsWith(prefix)) {
      final newline = text.indexOf('\n');
      if (newline >= 0) text = text.substring(newline + 1).trim();
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Conversation summary',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                text,
                style: const TextStyle(color: Color(0xFFD6D6D6), fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
