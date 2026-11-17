import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/settings/view_models/integrations_view_model.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/integration_card.dart';

/// Connected Apps settings tab for 1-click OAuth app connections.
///
/// Separates user-facing OAuth apps (GitHub, Google Drive, etc.) from
/// developer-configured MCP servers and OpenAPI specs.
class ConnectedAppsTab extends ConsumerWidget {
  const ConnectedAppsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(integrationsViewModelProvider);
    final ext = Theme.of(context).extension<AppThemeExtension>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Connected Apps',
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
            'Link your external accounts with one click. OAuth tokens are encrypted server-side and never shown here.',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: ext.textTertiary)),
        const SizedBox(height: 32),
        Text('Connected',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _buildConnectedSection(context, state),
        const SizedBox(height: 32),
        Text('Available Apps',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _buildAvailableSection(context, ref, state),
      ],
    );
  }

  Widget _buildConnectedSection(BuildContext context, IntegrationsState state) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return state.integrations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Failed to load connected apps: $e',
          style: const TextStyle(color: Colors.redAccent)),
      data: (integrations) {
        final oauthApps =
            integrations.where((i) => i.kind == 'oauth').toList();
        if (oauthApps.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('No apps connected yet.',
                style: TextStyle(color: ext.textTertiary, fontSize: 14)),
          );
        }
        return IntegrationCardsGrid(integrations: oauthApps);
      },
    );
  }

  Widget _buildAvailableSection(
      BuildContext context, WidgetRef ref, IntegrationsState state) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final connectedProviders = <String>{};
    state.integrations.whenData((list) {
      for (final integration in list) {
        if (integration.kind == 'oauth') {
          connectedProviders.add(integration.provider);
        }
      }
    });
    return state.providers.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Failed to load available apps: $e',
          style: const TextStyle(color: Colors.redAccent)),
      data: (providers) {
        final available = providers
            .where((p) => !connectedProviders.contains(p.provider))
            .toList();
        if (available.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('All available apps are connected.',
                style: TextStyle(color: ext.textTertiary, fontSize: 14)),
          );
        }
        return Wrap(
          spacing: 24,
          runSpacing: 24,
          children: available
              .map((provider) => SizedBox(
                    width: 300,
                    child: _availableCard(context, ref, provider),
                  ))
              .toList(),
        );
      },
    );
  }

  Widget _availableCard(
      BuildContext context, WidgetRef ref, OAuthProviderModel provider) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Container(
      decoration: BoxDecoration(
        color: ext.sidebarBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ext.borderColorStrong),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(integrationProviderIcon(provider.provider),
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(provider.displayName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            provider.enabled
                ? 'Not connected'
                : provider.configured
                    ? 'Coming soon'
                    : 'Not configured on the server',
            style: TextStyle(color: ext.textTertiary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: provider.enabled
                ? () async {
                    try {
                      final connectedNow = await ref
                          .read(integrationsViewModelProvider.notifier)
                          .connectOAuth(provider.provider);
                      if (connectedNow && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${provider.displayName} connected'),
                          ),
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Could not start the OAuth flow')),
                        );
                      }
                    }
                  }
                : null,
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}
