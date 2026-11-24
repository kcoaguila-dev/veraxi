import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/acp_runtime_view_model.dart';

/// Composer pill switching between Veraxi Engine (BYOK/Local) and
/// External ACP Runtimes such as Google Antigravity (`agy acp`).
///
/// Design contract: docs/design/veraxi_acp_runtime_ui.svg.
class AcpRuntimePill extends ConsumerWidget {
  const AcpRuntimePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(acpRuntimeProvider.notifier);
    if (!notifier.isPlatformSupported) {
      return const SizedBox.shrink();
    }
    final acp = ref.watch(acpRuntimeProvider);
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final isAcp = acp.isAcpActive;
    final statusColor = !isAcp
        ? const Color(0xFF94A3B8)
        : (acp.status.available
            ? const Color(0xFF22C55E)
            : const Color(0xFFF59E0B));

    return PopupMenuButton<String>(
      tooltip: 'Agent Runtime (Veraxi Engine vs Antigravity ACP)',
      color: ext.cardBackground,
      onSelected: (value) {
        if (value == 'veraxi') {
          notifier.selectRuntime(AgentRuntimeType.veraxi);
        } else if (value == 'antigravity_acp') {
          notifier.selectRuntime(AgentRuntimeType.antigravityAcp);
        } else if (value == 'toggle_mcp') {
          notifier.setAttachVeraxiMcp(!acp.attachVeraxiMcp);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'veraxi',
          child: Row(
            children: [
              Icon(
                !isAcp ? Icons.check_rounded : Icons.auto_awesome_outlined,
                size: 15,
                color: !isAcp ? const Color(0xFF38BDF8) : null,
              ),
              const SizedBox(width: 8),
              const Text(
                'Veraxi Engine · BYOK / Local',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'antigravity_acp',
          child: Row(
            children: [
              Icon(
                isAcp ? Icons.check_rounded : Icons.terminal_rounded,
                size: 15,
                color: isAcp ? const Color(0xFF22C55E) : null,
              ),
              const SizedBox(width: 8),
              const Text(
                'Antigravity (Local ACP) · User Quota',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'toggle_mcp',
          child: Row(
            children: [
              Icon(
                acp.attachVeraxiMcp
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 15,
                color: const Color(0xFF38BDF8),
              ),
              const SizedBox(width: 8),
              const Text(
                'Attach Veraxi /mcp (GraphRAG + Code)',
                style: TextStyle(fontSize: 11.5),
              ),
            ],
          ),
        ),
      ],
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isAcp
              ? const Color(0xFF1D2433)
              : ext.cardBackground.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: isAcp
                ? const Color(0xFF38BDF8).withValues(alpha: 0.45)
                : ext.borderColor,
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Row(
            key: ValueKey(acp.selectedRuntime),
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                acp.selectedRuntime.displayName,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down_rounded, size: 15),
            ],
          ),
        ),
      ),
    );
  }
}
