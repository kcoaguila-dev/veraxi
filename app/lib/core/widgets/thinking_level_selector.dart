import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/models/model_thinking_capability.dart';
import 'package:veraxi_app/core/providers/thinking_level_provider.dart';

/// Model-aware thinking level selector shared across Chat and Code composers.
///
/// Smoothly animates out when a non-reasoning model is selected, and adapts
/// between multi-tier effort menus (`Off`..`Max`) and 2-state toggles
/// (`Off` / `On`) based on [ModelThinkingCapability].
class ThinkingLevelSelector extends ConsumerWidget {
  final String selectedModel;
  final ValueChanged<String>? onChanged;
  final bool openUpward;
  final Color? backgroundColor;
  final Color? borderColor;

  const ThinkingLevelSelector({
    super.key,
    required this.selectedModel,
    this.onChanged,
    this.openUpward = false,
    this.backgroundColor,
    this.borderColor,
  });

  static String _displayLabel(String level) {
    if (level.isEmpty) return level;
    return level[0].toUpperCase() + level.substring(1);
  }

  static String _subtitleFor(String level) {
    switch (level) {
      case 'off':
        return 'Fastest · Direct answer';
      case 'minimal':
        return 'Light check';
      case 'low':
        return 'Quick reasoning';
      case 'medium':
        return 'Balanced';
      case 'high':
        return 'Deep analysis';
      case 'max':
        return 'Exhaustive';
      case 'on':
        return 'Step-by-step';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capsAsync = ref.watch(modelCapabilitiesProvider);
    final caps =
        capsAsync.valueOrNull ?? const <String, ModelThinkingCapability>{};
    final capability = resolveModelCapability(selectedModel, caps);
    final savedByModel = ref.watch(thinkingLevelByModelProvider);
    final effective = resolveEffectiveThinkingLevel(
      modelName: selectedModel,
      savedByModel: savedByModel,
      capabilities: caps,
    );

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: (!capability.supportsReasoning || effective == null)
            ? const SizedBox.shrink(key: ValueKey('thinking-hidden'))
            : _buildMenu(
                context,
                ref,
                capability,
                effective,
              ),
      ),
    );
  }

  Widget _buildMenu(
    BuildContext context,
    WidgetRef ref,
    ModelThinkingCapability capability,
    String effective,
  ) {
    final theme = Theme.of(context);
    final bg = backgroundColor ?? const Color(0xFF1E1E1E);
    final border = borderColor ?? const Color(0xFF2A2A2A);
    final isOff = effective == 'off';

    return PopupMenuButton<String>(
      key: ValueKey('thinking-$selectedModel-$effective'),
      tooltip: 'Thinking level',
      color: theme.cardColor,
      position: openUpward ? PopupMenuPosition.over : PopupMenuPosition.under,
      onSelected: (level) async {
        await ref
            .read(thinkingLevelByModelProvider.notifier)
            .setLevelForModel(selectedModel, level);
        onChanged?.call(level);
      },
      itemBuilder: (context) => [
        for (final level in capability.levels)
          PopupMenuItem<String>(
            value: level,
            child: Row(
              children: [
                Icon(
                  level == effective ? Icons.check : null,
                  size: 15,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _displayLabel(level),
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 13,
                          fontWeight: level == effective
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      Text(
                        _subtitleFor(level),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.55),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isOff
                ? border
                : theme.colorScheme.primary.withValues(alpha: 0.45),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isOff ? Icons.lightbulb_outline : Icons.auto_awesome,
              size: 14,
              color: isOff
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.65)
                  : theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              'Thinking: ${_displayLabel(effective)}',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down,
              size: 14,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}
