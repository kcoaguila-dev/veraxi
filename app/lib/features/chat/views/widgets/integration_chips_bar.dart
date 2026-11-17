import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/integration_chips_view_model.dart';

/// Toggle chips above the chat input, one per enabled integration.
///
/// Selecting chips attaches only those integrations to the current
/// thread (persisted as `tool_settings['enabled_integration_ids']`);
/// when the user has never toggled, every integration is attached.
/// Renders nothing when the tenant has no integrations.
///
/// This is a plain StatefulWidget (not a ConsumerWidget) because
/// ChatInput is also pumped without a ProviderScope in some contexts
/// (widget tests, embeds): without a scope the bar simply stays empty
/// instead of throwing.
class IntegrationChipsBar extends StatefulWidget {
  const IntegrationChipsBar({super.key});

  @override
  State<IntegrationChipsBar> createState() => _IntegrationChipsBarState();
}

class _IntegrationChipsBarState extends State<IntegrationChipsBar> {
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: state.integrations.map((item) {
          final selected = state.isSelected(item);
          return FilterChip(
            label: Text(
              item.displayName,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontSize: 12,
              ),
            ),
            selected: selected,
            onSelected: (_) => container
                .read(integrationChipsViewModelProvider.notifier)
                .toggle(item),
            backgroundColor: ext.borderColorStrong,
            selectedColor: Colors.white,
            checkmarkColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide.none,
            ),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: EdgeInsets.zero,
          );
        }).toList(),
      ),
    );
  }
}
