import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Compact 36x19 pill switch shared across Chat (`Metrics`), Knowledge Hub
/// (`Fast Extraction`), and Code Mode (`Include reachability`).
///
/// Design contract: docs/design/veraxi_code_workbench.svg.
class VeraxiSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;
  final FocusNode? focusNode;

  const VeraxiSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.focusNode,
  });

  void _toggle() {
    if (onChanged != null) {
      onChanged!(!value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final trackColor = value
        ? (enabled ? const Color(0xFF10B981) : const Color(0xFF065F46))
        : const Color(0xFF27272B);
    final thumbColor = value
        ? const Color(0xFF0B0F0E)
        : (enabled ? const Color(0xFFA1A1AA) : const Color(0xFF52525B));

    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: FocusableActionDetector(
        enabled: enabled,
        focusNode: focusNode,
        mouseCursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? _toggle : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            width: 36,
            height: 19,
            padding: const EdgeInsets.symmetric(horizontal: 2.5),
            decoration: BoxDecoration(
              color: trackColor,
              borderRadius: BorderRadius.circular(9.5),
              border: value
                  ? null
                  : Border.all(color: const Color(0xFF3A3A40), width: 1),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: thumbColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
