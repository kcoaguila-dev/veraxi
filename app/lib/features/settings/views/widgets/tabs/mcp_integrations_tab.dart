import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/settings/view_models/integrations_view_model.dart';

/// Integrations settings tab.
///
/// Backed entirely by the backend integrations API via
/// [integrationsViewModelProvider] — no SharedPreferences persistence
/// and no hardcoded server names (the pre-migration implementation
/// stored MCP servers in `tool_settings` locally and labeled every
/// added server "Custom Server").
class McpIntegrationsTab extends ConsumerWidget {
  const McpIntegrationsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(integrationsViewModelProvider);
    final ext = Theme.of(context).extension<AppThemeExtension>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Integrations',
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
            'Connect external tools and services. Secrets are encrypted server-side and never shown here.',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: ext.textTertiary)),
        const SizedBox(height: 32),
        Text('Connected Apps',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _buildCatalog(context, ref, state),
        const SizedBox(height: 32),
        Text('Custom Integrations',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: () => _showAddMcpDialog(context, ref),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: ext.sidebarBackground,
                minimumSize: const Size(160, 44),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add MCP Server',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 16),
            OutlinedButton.icon(
              onPressed: () => showDialog(
                context: context,
                builder: (_) => const _ImportOpenApiDialog(),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                minimumSize: const Size(180, 44),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Import OpenAPI Spec',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 32),
        Text('Active Integrations',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _buildActiveList(context, ref, state),
      ],
    );
  }

  Widget _buildCatalog(
      BuildContext context, WidgetRef ref, IntegrationsState state) {
    final connectedProviders = <String>{};
    state.integrations.whenData((list) {
      for (final integration in list) {
        connectedProviders.add(integration.provider);
      }
    });
    return state.providers.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Failed to load providers: $e',
          style: const TextStyle(color: Colors.redAccent)),
      data: (providers) => Wrap(
        spacing: 24,
        runSpacing: 24,
        children: providers.map((provider) {
          final connected = connectedProviders.contains(provider.provider);
          return SizedBox(
            width: 300,
            child: _catalogCard(context, ref, provider, connected),
          );
        }).toList(),
      ),
    );
  }

  Widget _catalogCard(BuildContext context, WidgetRef ref,
      OAuthProviderModel provider, bool connected) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final canConnect = provider.enabled && !connected;
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
                child: Icon(_providerIcon(provider.provider),
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
            connected
                ? 'Connected'
                : provider.enabled
                    ? 'Not connected'
                    : provider.configured
                        ? 'Coming soon'
                        : 'Not configured on the server',
            style: TextStyle(color: ext.textTertiary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: canConnect
                ? () async {
                    try {
                      await ref
                          .read(integrationsViewModelProvider.notifier)
                          .connectOAuth(provider.provider);
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
            child: Text(connected ? 'Connected' : 'Connect'),
          ),
        ],
      ),
    );
  }

  IconData _providerIcon(String provider) {
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

  Widget _buildActiveList(
      BuildContext context, WidgetRef ref, IntegrationsState state) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return state.integrations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Failed to load integrations: $e',
          style: const TextStyle(color: Colors.redAccent)),
      data: (integrations) {
        if (integrations.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text('No integrations configured yet.',
                style: TextStyle(color: ext.textTertiary, fontSize: 14)),
          );
        }
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
                  .map((integration) =>
                      _integrationCard(context, ref, state, integration))
                  .toList(),
            );
          },
        );
      },
    );
  }

  Widget _integrationCard(BuildContext context, WidgetRef ref,
      IntegrationsState state, IntegrationModel integration) {
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
                      : _providerIcon(integration.provider),
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
                icon: const Icon(Icons.delete_outline,
                    size: 16, color: Colors.redAccent),
                label: const Text('Remove',
                    style: TextStyle(color: Colors.redAccent)),
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

  void _showAddMcpDialog(BuildContext context, WidgetRef ref) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final headerNameController = TextEditingController();
    final headerValueController = TextEditingController();
    var transport = 'auto';
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add MCP Server'),
        content: StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(labelText: 'Server URL'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: transport,
                  decoration: const InputDecoration(labelText: 'Transport'),
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('Auto')),
                    DropdownMenuItem(
                        value: 'streamable_http',
                        child: Text('Streamable HTTP')),
                    DropdownMenuItem(value: 'sse', child: Text('SSE')),
                  ],
                  onChanged: (value) =>
                      setState(() => transport = value ?? 'auto'),
                ),
                TextField(
                  controller: headerNameController,
                  decoration: const InputDecoration(
                      labelText: 'Auth header name (optional)'),
                ),
                TextField(
                  controller: headerValueController,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Auth header value (optional)'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (urlController.text.trim().isEmpty) return;
              final headers = <String, String>{};
              if (headerNameController.text.trim().isNotEmpty) {
                headers[headerNameController.text.trim()] =
                    headerValueController.text;
              }
              Navigator.pop(dialogContext);
              try {
                await ref
                    .read(integrationsViewModelProvider.notifier)
                    .addMcpServer(
                      displayName: nameController.text.trim(),
                      url: urlController.text.trim(),
                      transport: transport,
                      headers: headers.isEmpty ? null : headers,
                    );
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Could not connect to that MCP server')),
                  );
                }
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

/// OpenAPI import wizard: paste spec → preview operations → select →
/// import. Kept as its own StatefulWidget so the two-step state lives
/// in one place.
class _ImportOpenApiDialog extends ConsumerStatefulWidget {
  const _ImportOpenApiDialog();

  @override
  ConsumerState<_ImportOpenApiDialog> createState() =>
      _ImportOpenApiDialogState();
}

class _ImportOpenApiDialogState extends ConsumerState<_ImportOpenApiDialog> {
  final _specController = TextEditingController();
  final _authValueController = TextEditingController();
  List<dynamic> _operations = [];
  final Set<String> _selected = {};
  bool _previewed = false;
  String _authType = 'bearer';
  String? _error;

  @override
  void dispose() {
    _specController.dispose();
    _authValueController.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    try {
      final result = await ref
          .read(integrationsViewModelProvider.notifier)
          .previewOpenApi(specText: _specController.text);
      setState(() {
        _operations = result['operations'] as List<dynamic>? ?? [];
        _previewed = true;
        _error = null;
      });
    } catch (_) {
      setState(() => _error = 'Could not parse that spec');
    }
  }

  Future<void> _import() async {
    Navigator.pop(context);
    try {
      await ref.read(integrationsViewModelProvider.notifier).importOpenApi(
            specText: _specController.text,
            selectedOperationIds: _selected.toList(),
            authType: _authType,
            authValue: _authValueController.text.isEmpty
                ? null
                : _authValueController.text,
          );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('OpenAPI import failed')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import OpenAPI Spec'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _specController,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'OpenAPI spec (JSON or YAML)',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _authType,
              decoration: const InputDecoration(labelText: 'Auth'),
              items: const [
                DropdownMenuItem(value: 'bearer', child: Text('Bearer')),
                DropdownMenuItem(
                    value: 'api_key_header', child: Text('API key header')),
                DropdownMenuItem(
                    value: 'api_key_query', child: Text('API key query')),
              ],
              onChanged: (value) =>
                  setState(() => _authType = value ?? 'bearer'),
            ),
            TextField(
              controller: _authValueController,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'Auth value (optional)'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            if (_previewed)
              ..._operations.map((op) {
                final opMap = Map<String, dynamic>.from(op as Map);
                final id = opMap['operation_id'] as String;
                return CheckboxListTile(
                  title: Text('${opMap['method']} ${opMap['path']}',
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Text(id, style: const TextStyle(fontSize: 11)),
                  value: _selected.contains(id),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _selected.add(id);
                    } else {
                      _selected.remove(id);
                    }
                  }),
                );
              }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (!_previewed)
          ElevatedButton(onPressed: _preview, child: const Text('Preview'))
        else
          ElevatedButton(
            onPressed: _selected.isEmpty ? null : _import,
            child: const Text('Import'),
          ),
      ],
    );
  }
}
