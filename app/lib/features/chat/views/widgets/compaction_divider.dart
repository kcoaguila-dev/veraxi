import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../view_models/chat_view_model.dart';

/// The in-thread marker for a compacted span: a divider, never a
/// chat bubble. The summary message carries a `compaction` record in
/// its metrics (messages_compacted / compacted_at / tokens_before);
/// tapping the divider opens the full summary text — and, when the
/// compaction is restorable, the action that undoes it.
class CompactionDivider extends ConsumerWidget {
  final ChatMessage message;

  const CompactionDivider({super.key, required this.message});

  static bool isCompactionMessage(ChatMessage message) {
    final metrics = message.metrics;
    return metrics != null && metrics['compaction'] is Map;
  }

  /// Server compactions are restorable from checkpointer history
  /// (the backend flags the record at apply time); local ones are
  /// restorable when the summary carries its on-device backup.
  bool get _canRestore {
    final metrics = message.metrics;
    if (metrics == null) return false;
    final record = metrics['compaction'];
    if (record is Map && record['restorable'] == true) return true;
    return metrics['compaction_backup'] is Map;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            onTap: () => _showSummary(context, ref),
            borderRadius: BorderRadius.circular(999),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Expanded(child: Divider(color: Color(0xFF2E2E2E))),
                const SizedBox(width: 10),
                const Icon(Icons.compress, size: 14, color: Color(0xFF8A8A8A)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style:
                        const TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
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

  void _showSummary(BuildContext context, WidgetRef ref) {
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
              if (_canRestore) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _confirmRestore(sheetContext, ref),
                    icon: const Icon(Icons.restore, size: 16),
                    label: const Text('Restore pre-compaction context'),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Brings back the messages this summary replaced. '
                  'Anything sent after the compaction is removed.',
                  style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRestore(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore pre-compaction context?'),
        content: const Text(
          'The conversation returns to exactly how it was before this '
          'compaction. Messages sent after the compaction will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(chatViewModelProvider.notifier);
    Navigator.of(context).pop(); // close the summary sheet
    try {
      await notifier.restoreCompaction();
      messenger.showSnackBar(const SnackBar(
        content: Text('Pre-compaction context restored.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}
