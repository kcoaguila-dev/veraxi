import 'package:flutter/material.dart';
import 'model_provider_styles.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class HoverableProviderRow extends StatefulWidget {
  final String provider;
  final bool isHovered;
  final ValueChanged<LayerLink> onEnter;
  final ValueChanged<LayerLink> onTap;
  final VoidCallback onSettingsTap;

  const HoverableProviderRow({
    super.key,
    required this.provider,
    required this.isHovered,
    required this.onEnter,
    required this.onTap,
    required this.onSettingsTap,
  });

  @override
  State<HoverableProviderRow> createState() => _HoverableProviderRowState();
}

class _HoverableProviderRowState extends State<HoverableProviderRow> {
  bool _isLocalHover = false;
  bool _isSettingsHovered = false;
  final LayerLink _layerLink = LayerLink();

  @override
  Widget build(BuildContext context) {
    final active = widget.isHovered || _isLocalHover;

    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _isLocalHover = true);
          widget.onEnter(_layerLink);
        },
        onExit: (_) => setState(() => _isLocalHover = false),
        child: GestureDetector(
          onTap: () => widget.onTap(_layerLink),
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 38,
            margin: EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: active ? Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                SizedBox(width: 12),
                ModelProviderStyles.getProviderCircle(widget.provider),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.provider,
                    style: TextStyle(
                      color: active ? Colors.white : const Color(0xFFD1D1D1),
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                ),
                MouseRegion(
                  onEnter: (_) => setState(() => _isSettingsHovered = true),
                  onExit: (_) => setState(() => _isSettingsHovered = false),
                  child: GestureDetector(
                    onTap: widget.onSettingsTap,
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      decoration: BoxDecoration(
                        color: _isSettingsHovered
                            ? const Color(0xFF444444)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.settings_outlined,
                              size: 15,
                              color: active
                                  ? (_isSettingsHovered
                                      ? Colors.white
                                      : Theme.of(context).extension<AppThemeExtension>()!.iconColor)
                                  : Colors.transparent),
                          if (_isSettingsHovered) ...[
                            SizedBox(width: 4),
                            Text('Set API Key',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 11)),
                          ]
                        ],
                      ),
                    ),
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 16,
                    color: active ? Colors.white : Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
