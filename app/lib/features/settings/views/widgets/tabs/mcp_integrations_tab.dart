import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/settings/view_models/integrations_view_model.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/integration_card.dart';

/// MCP & Custom APIs settings tab.
///
/// Manages developer-configured Model Context Protocol servers and
/// OpenAPI specs via [integrationsViewModelProvider]. OAuth app
/// connections live in [ConnectedAppsTab].
class McpIntegrationsTab extends ConsumerWidget {
  const McpIntegrationsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(integrationsViewModelProvider);
    final ext = Theme.of(context).extension<AppThemeExtension>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('MCP Integrations',
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
            'Connect custom Model Context Protocol servers or import OpenAPI specs. Secrets are encrypted server-side and never shown here.',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: ext.textTertiary)),
        const SizedBox(height: 32),
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
        Text('Configured Servers & APIs',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _buildCustomList(context, state),
      ],
    );
  }

  Widget _buildCustomList(BuildContext context, IntegrationsState state) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return state.integrations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Failed to load MCP integrations: $e',
          style: const TextStyle(color: Colors.redAccent)),
      data: (integrations) {
        final customIntegrations =
            integrations.where((i) => i.kind != 'oauth').toList();
        if (customIntegrations.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
                'No custom MCP servers or OpenAPI specs configured yet.',
                style: TextStyle(color: ext.textTertiary, fontSize: 14)),
          );
        }
        return IntegrationCardsGrid(integrations: customIntegrations);
      },
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
