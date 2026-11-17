import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/sandbox_toggle_view_model.dart';

/// Sandbox entry for the composer Tools (`Icons.tune`) menu and the
/// active-tools chip row.
///
/// `ChatInput` is a plain [StatefulWidget] (not a ConsumerWidget), so —
/// exactly like [ToolsMenuIntegrations] — this widget reaches the
/// Riverpod container through [ProviderScope.containerOf] and renders
/// nothing when no scope is present (e.g. isolated widget tests).
/// Toggling is bound to [sandboxToggleViewModelProvider], which
/// persists `tool_settings['sandbox_enabled']`.
class ToolsMenuSandbox extends StatefulWidget {
  const ToolsMenuSandbox({super.key});

  @override
  State<ToolsMenuSandbox> createState() => _ToolsMenuSandboxState();
}

class _ToolsMenuSandboxState extends State<ToolsMenuSandbox> {
  ProviderContainer? _container;
  ProviderSubscription<SandboxToggleState>? _subscription;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_container != null) return;
    try {
      _container = ProviderScope.containerOf(context);
    } catch (_) {
      _container = null;
      return;
    }
    _subscription = _container!.listen<SandboxToggleState>(
      sandboxToggleViewModelProvider,
      (_, __) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _subscription?.close();
    super.dispose();
  }

  SandboxToggleState? get _state =>
      _container?.read(sandboxToggleViewModelProvider);

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state == null || !state.loaded) return const SizedBox.shrink();
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final isActive = state.enabled;
    return MenuItemButton(
      style: const ButtonStyle(
          padding:
              WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10))),
      onPressed: () =>
          _container!.read(sandboxToggleViewModelProvider.notifier).toggle(),
      child: Container(
        width: 155,
        height: 38,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(Icons.terminal,
                color: isActive
                    ? Theme.of(context).colorScheme.secondary
                    : ext.iconColor,
                size: 14),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Sandbox',
                  style: TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            GestureDetector(
              onTap: () => _container!
                  .read(sandboxToggleViewModelProvider.notifier)
                  .toggle(),
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Icon(isActive ? LucideIcons.pinOff : LucideIcons.pin,
                    color: isActive
                        ? Theme.of(context).colorScheme.secondary
                        : const Color(0xFF6E6E6E),
                    size: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Sandbox" chip for the composer's active-tools row, shown while the
/// sandbox is enabled; tapping it deactivates the sandbox for the chat.
class SandboxActiveChip extends StatefulWidget {
  const SandboxActiveChip({super.key});

  @override
  State<SandboxActiveChip> createState() => _SandboxActiveChipState();
}

class _SandboxActiveChipState extends State<SandboxActiveChip> {
  ProviderContainer? _container;
  ProviderSubscription<SandboxToggleState>? _subscription;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_container != null) return;
    try {
      _container = ProviderScope.containerOf(context);
    } catch (_) {
      _container = null;
      return;
    }
    _subscription = _container!.listen<SandboxToggleState>(
      sandboxToggleViewModelProvider,
      (_, __) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _subscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final container = _container;
    if (container == null) return const SizedBox.shrink();
    final state = container.read(sandboxToggleViewModelProvider);
    if (!state.loaded || !state.enabled) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () =>
          container.read(sandboxToggleViewModelProvider.notifier).toggle(),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .secondary
                  .withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal,
                color: Theme.of(context).colorScheme.secondary, size: 12),
            const SizedBox(width: 6),
            Text('Sandbox',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
