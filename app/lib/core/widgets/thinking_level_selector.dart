import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/models/model_thinking_capability.dart';
import 'package:veraxi_app/core/providers/thinking_level_provider.dart';
import 'package:veraxi_app/core/theme_extension.dart';

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
    final ext = theme.extension<AppThemeExtension>();
    final bg = backgroundColor ?? const Color(0xFF1E1E1E);
    final border = borderColor ?? const Color(0xFF2A2A2A);
    final menuBg = ext?.sidebarBackground ?? const Color(0xFF1C1C1F);
    final menuBorder = ext?.borderColorStrong ?? const Color(0xFF34343A);

    return PopupMenuButton<String>(
      key: ValueKey('thinking-$selectedModel-$effective'),
      tooltip: 'Thinking level',
      color: menuBg,
      elevation: 10,
      offset: openUpward ? const Offset(0, -10) : const Offset(0, 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: menuBorder),
      ),
      position: openUpward ? PopupMenuPosition.over : PopupMenuPosition.under,
      onSelected: (level) async {
        await ref
            .read(thinkingLevelByModelProvider.notifier)
            .setLevelForModel(selectedModel, level);
        onChanged?.call(level);
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'THINKING LEVEL',
            style: TextStyle(
              color: ext?.textTertiary ?? const Color(0xFF80808A),
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.7,
            ),
          ),
        ),
        for (final level in capability.levels)
          _buildLevelMenuItem(
            level: level,
            isSelected: level == effective,
            theme: theme,
            ext: ext,
          ),
      ],
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Thinking: ${_displayLabel(effective)}',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 3),
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

  PopupMenuItem<String> _buildLevelMenuItem({
    required String level,
    required bool isSelected,
    required ThemeData theme,
    required AppThemeExtension? ext,
  }) {
    return PopupMenuItem<String>(
      value: level,
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Container(
        width: 196,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? (ext?.surfaceHighlight ?? const Color(0xFF2A2A30))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _displayLabel(level),
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontSize: 13,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  Text(
                    _subtitleFor(level),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ext?.textTertiary ?? const Color(0xFF8C8C96),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check,
                size: 15,
                color: Color(0xFF60A5FA),
              ),
          ],
        ),
      ),
    );
  }
}
