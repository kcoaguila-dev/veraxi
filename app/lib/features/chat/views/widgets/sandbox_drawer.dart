import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/sandbox_drawer_view_model.dart';

/// Collapsible Terminal & Diff drawer docked above the chat input.
///
/// Visible only while the Sandbox toggle is on for the chat. Streams
/// `sandbox_exec` output lines (stderr in red), renders pending
/// approval prompts with Approve / Reject buttons (decisions go
/// through [sandboxDrawerViewModelProvider] to
/// POST /api/v1/sandboxes/sessions/{id}/approve), and shows the
/// current git diff with +/- line coloring. Design contract:
/// docs/design/chat_sandbox_drawer.svg.
class SandboxDrawer extends ConsumerWidget {
  const SandboxDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sandboxDrawerViewModelProvider);
    final vm = ref.read(sandboxDrawerViewModelProvider.notifier);
    final ext = Theme.of(context).extension<AppThemeExtension>()!;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ext.borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context, state, vm),
          if (state.expanded) ...[
            Divider(height: 1, color: ext.borderColor),
            if (state.showDiff)
              _buildDiff(context, state)
            else
              _buildTerminal(context, state),
            for (final approval in state.approvals)
              _SandboxApprovalCard(approval: approval),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, SandboxDrawerState state,
      SandboxDrawerViewModel vm) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.terminal, size: 16, color: Colors.white),
          const SizedBox(width: 8),
          const Text('Sandbox',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          if (state.sessionStatus != null) ...[
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                  color: Color(0xFF10B981), shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(state.sessionStatus!,
                style: const TextStyle(color: Color(0xFF10B981), fontSize: 12)),
          ],
          const Spacer(),
          _tabButton(
            context,
            label: 'Terminal',
            selected: !state.showDiff,
            onTap: () => vm.setShowDiff(false),
          ),
          const SizedBox(width: 6),
          _tabButton(
            context,
            label: 'Diff',
            selected: state.showDiff,
            onTap: () => vm.setShowDiff(true),
          ),
          IconButton(
            icon: Icon(
              state.expanded
                  ? Icons.keyboard_arrow_down
                  : Icons.keyboard_arrow_up,
              size: 18,
              color: ext.textTertiary,
            ),
            tooltip: state.expanded
                ? 'Collapse sandbox drawer'
                : 'Expand sandbox drawer',
            onPressed: vm.toggleExpanded,
            splashRadius: 18,
          ),
        ],
      ),
    );
  }

  Widget _tabButton(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? ext.surfaceHighlight : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ext.borderColor),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? Colors.white : ext.textTertiary,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildTerminal(BuildContext context, SandboxDrawerState state) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    if (state.lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Sandbox output will stream here when the agent runs commands.',
          style: TextStyle(color: ext.textTertiary, fontSize: 12),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: state.lines.length,
        itemBuilder: (context, index) {
          final line = state.lines[index];
          return Text(
            line.text,
            style: TextStyle(
              color: line.isStderr
                  ? const Color(0xFFF87171)
                  : const Color(0xFFECECEC),
              fontSize: 12,
              fontFamily: 'monospace',
              height: 1.5,
            ),
          );
        },
      ),
    );
  }

  Widget _buildDiff(BuildContext context, SandboxDrawerState state) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    if (state.diff.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No changes yet — the sandbox working tree is clean.',
          style: TextStyle(color: ext.textTertiary, fontSize: 12),
        ),
      );
    }
    final lines = state.diff.split('\n');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 260),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final line = lines[index];
          final isHeader = line.startsWith('diff ') ||
              line.startsWith('+++') ||
              line.startsWith('---') ||
              line.startsWith('@@');
          final Color color;
          if (line.startsWith('+') && !line.startsWith('+++')) {
            color = const Color(0xFF10B981);
          } else if (line.startsWith('-') && !line.startsWith('---')) {
            color = const Color(0xFFF87171);
          } else if (isHeader) {
            color = Colors.white;
          } else {
            color = const Color(0xFF9E9E9E);
          }
          return Text(
            line.isEmpty ? ' ' : line,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: isHeader ? FontWeight.w600 : FontWeight.w400,
              height: 1.5,
            ),
          );
        },
      ),
    );
  }
}

/// Approval prompt card inside the drawer, styled after
/// ToolConfirmationCard: amber border, tool + description, and
/// Approve / Reject buttons that resolve through the drawer view model.
class _SandboxApprovalCard extends ConsumerWidget {
  final SandboxApproval approval;

  const _SandboxApprovalCard({required this.approval});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.read(sandboxDrawerViewModelProvider.notifier);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      padding: const EdgeInsets.all(14),
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
          Text(approval.toolName,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(approval.description,
              style: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 12)),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton(
                onPressed: () => vm.decide(approval, approve: true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                ),
                child: const Text('Approve'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => vm.decide(approval, approve: false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFF87171),
                ),
                child: const Text('Reject'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
