import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/view_models/acp_runtime_view_model.dart';

/// Displays interactive ACP permission approval cards (`session/request_permission`)
/// and explicit HTTP 429 / quota-exhausted fallback banners.
///
/// Design contract: docs/design/veraxi_acp_runtime_ui.svg.
class AcpPermissionBanner extends ConsumerWidget {
  const AcpPermissionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acp = ref.watch(acpRuntimeProvider);
    final notifier = ref.read(acpRuntimeProvider.notifier);

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (acp.quotaExhaustedMessage != null)
            _QuotaExhaustedCard(
              message: acp.quotaExhaustedMessage!,
              onSwitchToByok: notifier.switchToVeraxiByok,
            ),
          if (acp.pendingPermission != null)
            _PermissionGateCard(
              prompt: acp.pendingPermission!,
              onDecision: notifier.resolvePermission,
            ),
        ],
      ),
    );
  }
}

class _PermissionGateCard extends StatelessWidget {
  final AcpPermissionPrompt prompt;
  final ValueChanged<String> onDecision;

  const _PermissionGateCard({
    required this.prompt,
    required this.onDecision,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B2230),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF364158)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, size: 16, color: Color(0xFF818CF8)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Antigravity requests permission · ${prompt.toolName}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFF1F5F9),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            prompt.description,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton(
                onPressed: () => onDecision('allow_once'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF38BDF8),
                  foregroundColor: const Color(0xFF0B0E14),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                child: const Text('Allow Once', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
              ),
              OutlinedButton(
                onPressed: () => onDecision('allow_session'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFE2E8F0),
                  side: const BorderSide(color: Color(0xFF3B4763)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                child: const Text('Allow Session', style: TextStyle(fontSize: 11.5)),
              ),
              TextButton(
                onPressed: () => onDecision('deny'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFFCA5A5),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                child: const Text('Deny', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuotaExhaustedCard extends StatelessWidget {
  final String message;
  final VoidCallback onSwitchToByok;

  const _QuotaExhaustedCard({
    required this.message,
    required this.onSwitchToByok,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1E14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFB45309)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFF59E0B)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Antigravity Quota Exhausted (HTTP 429)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFDE68A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: const TextStyle(fontSize: 11, color: Color(0xFFFCD34D)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: onSwitchToByok,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: const Color(0xFF0B0E14),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text('Switch to BYOK', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
