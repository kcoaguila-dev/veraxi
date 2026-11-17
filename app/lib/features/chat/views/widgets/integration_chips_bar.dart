import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/integration_chips_view_model.dart';

/// Connected integration toggles rendered inside the Tools (`Icons.tune`) menu.
///
/// Selecting items attaches only those integrations to the current
/// thread (persisted as `tool_settings['enabled_integration_ids']`);
/// when the user has never toggled, every integration is attached.
/// Renders nothing when the tenant has no integrations or no [ProviderScope]
/// is present (e.g., isolated widget tests).
class ToolsMenuIntegrations extends StatefulWidget {
  const ToolsMenuIntegrations({super.key});

  @override
  State<ToolsMenuIntegrations> createState() => _ToolsMenuIntegrationsState();
}

class _ToolsMenuIntegrationsState extends State<ToolsMenuIntegrations> {
  ProviderContainer? _container;
  ProviderSubscription<IntegrationChipsState>? _subscription;

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
    _subscription = _container!.listen<IntegrationChipsState>(
      integrationChipsViewModelProvider,
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
    final state = container.read(integrationChipsViewModelProvider);
    if (!state.loaded || state.integrations.isEmpty) {
      return const SizedBox.shrink();
    }
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 8, color: ext.borderColor),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            'Connected Apps',
            style: TextStyle(
              color: ext.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...state.integrations.map((item) {
          final selected = state.isSelected(item);
          return MenuItemButton(
            closeOnActivate: false,
            onPressed: () => container
                .read(integrationChipsViewModelProvider.notifier)
                .toggle(item),
            leadingIcon: Icon(
              Icons.extension_outlined,
              size: 16,
              color: selected ? Colors.white : ext.textTertiary,
            ),
            trailingIcon: Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
              size: 16,
              color: selected ? Colors.white : ext.textTertiary,
            ),
            child: Text(
              item.displayName,
              style: TextStyle(
                color: selected ? Colors.white : ext.textTertiary,
                fontSize: 13,
              ),
            ),
          );
        }),
      ],
    );
  }
}
