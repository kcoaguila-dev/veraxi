import 'package:flutter/material.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class PinnedModelsWidget extends StatefulWidget {
  final List<String> pinnedModels;
  final String selectedModel;
  final Function(String model, String? provider) onModelSelected;
  final Function(String) onModelUnpinned;

  const PinnedModelsWidget({
    super.key,
    required this.pinnedModels,
    required this.selectedModel,
    required this.onModelSelected,
    required this.onModelUnpinned,
  });

  @override
  State<PinnedModelsWidget> createState() => _PinnedModelsWidgetState();
}

class _PinnedModelsWidgetState extends State<PinnedModelsWidget> {
  String? _hoveredModel;

  Color _providerDotColorFor(String modelName) {
    if (modelName.startsWith('gemini')) {
      return const Color(0xFF4285F4);
    } else if (modelName.startsWith('gpt')) {
      return Theme.of(context).colorScheme.secondary;
    } else if (modelName.startsWith('claude')) {
      return const Color(0xFFD97757);
    } else if (modelName.startsWith('llama') ||
        modelName.startsWith('mixtral')) {
      return const Color(0xFFF55036);
    } else {
      return Colors.grey;
    }
  }

  Widget _providerDotFor(String modelName) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _providerDotColorFor(modelName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pinnedModels.isEmpty) return SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...widget.pinnedModels.map((model) {
          final isActive = model == widget.selectedModel;
          final isHovered = _hoveredModel == 'sidebar_$model';

          return MouseRegion(
            onEnter: (_) => setState(() => _hoveredModel = 'sidebar_$model'),
            onExit: (_) {
              if (isHovered) {
                setState(() => _hoveredModel = null);
              }
            },
            child: GestureDetector(
              onTap: () {
                widget.onModelSelected(model, null);
              },
              child: Container(
                height: 30,
                margin: EdgeInsets.only(bottom: 2),
                padding: EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: isActive ? Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    _providerDotFor(model),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        model,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: isActive
                                ? Colors.white
                                : Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                      ),
                    ),
                    if (isHovered)
                      GestureDetector(
                        onTap: () {
                          widget.onModelUnpinned(model);
                        },
                        child: Tooltip(
                          message: 'Unpin',
                          child: Icon(Icons.push_pin,
                              color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        }),
        SizedBox(height: 12),
      ],
    );
  }
}
