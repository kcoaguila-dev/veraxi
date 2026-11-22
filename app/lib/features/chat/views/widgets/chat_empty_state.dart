import 'package:material_ui/material_ui.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_input.dart';

class HybridStarterChipsRow extends StatelessWidget {
  static const List<({String keyName, String label, IconData icon})>
      starterPrompts = [
    (
      keyName: 'starter-chip-graph',
      label: 'Trace multi-hop connections in Knowledge Graph',
      icon: Icons.hub_outlined,
    ),
    (
      keyName: 'starter-chip-code',
      label: 'Analyze symbol blast radius with Code X-Ray',
      icon: Icons.account_tree_outlined,
    ),
    (
      keyName: 'starter-chip-hybrid',
      label: 'Search live web & corpus with inline citations',
      icon: Icons.travel_explore_outlined,
    ),
  ];

  final bool isLoading;
  final ValueChanged<String> onSelectPrompt;

  const HybridStarterChipsRow({
    super.key,
    required this.isLoading,
    required this.onSelectPrompt,
  });

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in starterPrompts)
          _StarterChip(
            key: Key(item.keyName),
            label: item.label,
            icon: item.icon,
            ext: ext,
            onTap: isLoading ? null : () => onSelectPrompt(item.label),
          ),
      ],
    );
  }
}

class _StarterChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final AppThemeExtension ext;
  final VoidCallback? onTap;

  const _StarterChip({
    super.key,
    required this.label,
    required this.icon,
    required this.ext,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: ext.surfaceHighlight,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ext.borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: ext.iconColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFFB4B4B4),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatEmptyState extends StatelessWidget {
  final ChatState state;
  final ChatViewModel viewModel;
  final String selectedModel;
  final String? activeProjectName;
  final String Function() resolveDisplayName;

  const ChatEmptyState({
    super.key,
    required this.state,
    required this.viewModel,
    required this.selectedModel,
    this.activeProjectName,
    required this.resolveDisplayName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Good afternoon, ${resolveDisplayName()}',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ).animate().fade(duration: 800.ms).slideY(begin: 0.1, end: 0),
          SizedBox(height: 32),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ChatInput(
              model: selectedModel,
              projectName: activeProjectName,
              isLoading: state.isLoading,
              onSend: (text, {attachments}) => viewModel.sendMessage(text,
                  model: selectedModel, attachments: attachments),
              errorText: state.error,
            ),
          )
              .animate()
              .fade(duration: 800.ms, delay: 100.ms)
              .slideY(begin: 0.1, end: 0),
          const SizedBox(height: 16),
          HybridStarterChipsRow(
            isLoading: state.isLoading,
            onSelectPrompt: (prompt) => viewModel.sendMessage(
              prompt,
              model: selectedModel == 'Select a model' ? null : selectedModel,
            ),
          ),
        ],
      ),
    );
  }
}
