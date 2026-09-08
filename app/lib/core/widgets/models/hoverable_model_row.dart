import 'package:flutter/material.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class HoverableModelRow extends StatefulWidget {
  final String model;
  final bool isSelected;
  final bool isPinned;
  final VoidCallback onTap;
  final VoidCallback onPinToggle;

  const HoverableModelRow({
    super.key,
    required this.model,
    required this.isSelected,
    required this.isPinned,
    required this.onTap,
    required this.onPinToggle,
  });

  @override
  State<HoverableModelRow> createState() => _HoverableModelRowState();
}

class _HoverableModelRowState extends State<HoverableModelRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 36,
          margin: EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: _isHovered ? Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              if (widget.isSelected)
                Positioned(
                  left: 0,
                  top: 8,
                  bottom: 8,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ),
              Row(
                children: [
                  SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      widget.model,
                      style: TextStyle(
                        color: widget.isSelected || _isHovered
                            ? Colors.white
                            : const Color(0xFFD1D1D1),
                        fontSize: 13,
                        fontWeight: widget.isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: widget.onPinToggle,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      child: Icon(
                        widget.isPinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        size: 14,
                        color: widget.isPinned
                            ? Colors.white
                            : (_isHovered
                                ? Theme.of(context).extension<AppThemeExtension>()!.textTertiary
                                : Colors.transparent),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
