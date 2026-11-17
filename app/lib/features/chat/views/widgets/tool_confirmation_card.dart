import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/view_models/tool_confirmation_view_model.dart';

/// Card rendered when the backend gate returns
/// `tool_confirmation_required` for a mutating external tool call.
///
/// Shows the tool name and a compact args summary with Approve /
/// Reject buttons. The decision goes to POST /api/chat/confirm-tool
/// (via [toolConfirmationServiceProvider]); after a decision the card
/// collapses to a status line and cannot be acted on again.
class ToolConfirmationCard extends ConsumerStatefulWidget {
  final ToolConfirmationRequest request;

  const ToolConfirmationCard({super.key, required this.request});

  @override
  ConsumerState<ToolConfirmationCard> createState() =>
      _ToolConfirmationCardState();
}

class _ToolConfirmationCardState extends ConsumerState<ToolConfirmationCard> {
  bool _busy = false;
  String? _outcome; // 'executed' | 'rejected' | 'failed'

  Future<void> _decide(bool approve) async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(toolConfirmationServiceProvider)
          .decide(widget.request, approve: approve);
      setState(() {
        _busy = false;
        _outcome = result['status'] as String? ?? (approve ? 'executed' : 'rejected');
      });
    } catch (_) {
      setState(() {
        _busy = false;
        _outcome = 'failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final argsSummary = widget.request.args.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(' · ');
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F2F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF59E0B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: Color(0xFFF59E0B), size: 18),
              SizedBox(width: 8),
              Text('Approval needed',
                  style: TextStyle(
                      color: Color(0xFFF59E0B),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(widget.request.toolName,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          if (argsSummary.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(argsSummary,
                style: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 12)),
          ],
          const SizedBox(height: 4),
          const Text('This changes external state.',
              style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 12)),
          const SizedBox(height: 12),
          if (_outcome != null)
            Text(
              switch (_outcome) {
                'executed' => 'Executed ✓',
                'rejected' => 'Rejected',
                _ => 'Something went wrong — the action did not run.',
              },
              style: TextStyle(
                color: _outcome == 'executed'
                    ? const Color(0xFF10B981)
                    : const Color(0xFFF87171),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Row(
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : () => _decide(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Approve'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _busy ? null : () => _decide(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFF87171),
                  ),
                  child: const Text('Reject'),
                ),
                if (_busy) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
