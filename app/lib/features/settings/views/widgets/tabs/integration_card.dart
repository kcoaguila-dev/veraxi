import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/settings/view_models/integrations_view_model.dart';

/// Maps a known integration provider slug to its UI icon.
IconData integrationProviderIcon(String provider) {
  switch (provider) {
    case 'github':
      return Icons.code;
    case 'google_drive':
      return Icons.folder_open;
    case 'notion':
      return Icons.note_alt_outlined;
    case 'linear':
      return Icons.timeline;
    case 'slack':
      return Icons.chat_bubble_outline;
    default:
      return Icons.extension;
  }
}

/// Responsive grid of [IntegrationCard] items.
class IntegrationCardsGrid extends StatelessWidget {
  final List<IntegrationModel> integrations;

  const IntegrationCardsGrid({super.key, required this.integrations});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;
        return GridView.count(
          crossAxisCount: isWide ? 2 : 1,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 24,
          mainAxisSpacing: 24,
          childAspectRatio: isWide ? 2.4 : 1.9,
          children: integrations
              .map((integration) => IntegrationCard(integration: integration))
              .toList(),
        );
      },
    );
  }
}

/// Card displaying a configured integration, its live status, and actions.
class IntegrationCard extends ConsumerWidget {
  final IntegrationModel integration;

  const IntegrationCard({super.key, required this.integration});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(integrationsViewModelProvider);
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final statusColor = switch (integration.status) {
      'connected' => const Color(0xFF10B981),
      'expired' => const Color(0xFFF59E0B),
      _ => Colors.redAccent,
    };
    final statusLabel = integration.isEnabled
        ? '${integration.status[0].toUpperCase()}${integration.status.substring(1)} · ${integration.toolCount} tools'
        : 'Disabled';
    final testResult = state.testResults[integration.id];
    final syncResult = state.syncResults[integration.id];
    final isOAuth = integration.kind == 'oauth';

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
                child: Icon(
                  integration.kind == 'openapi'
                      ? Icons.api
                      : integrationProviderIcon(integration.provider),
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(integration.displayName,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: integration.isEnabled
                                  ? statusColor
                                  : ext.textTertiary,
                              shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 6),
                        Text(statusLabel,
                            style: TextStyle(
                                color: ext.textTertiary, fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
              Switch(
                value: integration.isEnabled,
                onChanged: (value) => ref
                    .read(integrationsViewModelProvider.notifier)
                    .toggleIntegration(integration, value),
                activeThumbColor: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
          const Spacer(),
          Text(
            integration.url ?? integration.provider,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ext.textTertiary, fontSize: 12),
          ),
          if (testResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(testResult,
                  style: TextStyle(color: ext.textTertiary, fontSize: 12)),
            ),
          if (syncResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(syncResult,
                  style: TextStyle(color: ext.textTertiary, fontSize: 12)),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (integration.kind == 'mcp')
                TextButton(
                  onPressed: () => ref
                      .read(integrationsViewModelProvider.notifier)
                      .testIntegration(integration),
                  child: const Text('Test Connection'),
                ),
              if (integration.provider == 'github')
                TextButton(
                  onPressed: () => _showSyncDialog(context, ref, integration),
                  child: const Text('Sync Repos'),
                ),
              TextButton.icon(
                onPressed: () => ref
                    .read(integrationsViewModelProvider.notifier)
                    .removeIntegration(integration),
                icon: Icon(
                  isOAuth ? Icons.link_off : Icons.delete_outline,
                  size: 16,
                  color: Colors.redAccent,
                ),
                label: Text(
                  isOAuth ? 'Disconnect' : 'Remove',
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showSyncDialog(
      BuildContext context, WidgetRef ref, IntegrationModel integration) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sync GitHub Repos'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Repositories (one owner/repo per line)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final repos = controller.text
                  .split(RegExp(r'[\n,]'))
                  .map((r) => r.trim())
                  .where((r) => r.isNotEmpty)
                  .toList();
              Navigator.pop(dialogContext);
              if (repos.isNotEmpty) {
                ref
                    .read(integrationsViewModelProvider.notifier)
                    .syncRepos(integration, repos: repos);
              }
            },
            child: const Text('Sync'),
          ),
        ],
      ),
    );
  }
}
