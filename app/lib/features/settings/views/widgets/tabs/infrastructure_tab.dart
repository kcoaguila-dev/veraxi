import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/theme_extension.dart';

class InfrastructureTab extends ConsumerStatefulWidget {
  const InfrastructureTab({super.key});

  @override
  ConsumerState<InfrastructureTab> createState() => _InfrastructureTabState();
}

class _InfrastructureTabState extends ConsumerState<InfrastructureTab> {
  final _storage = ApiKeyStorage();
  final _neo4jUriController = TextEditingController();
  final _neo4jUserController = TextEditingController();
  final _neo4jPassController = TextEditingController();
  final _qdrantUrlController = TextEditingController();
  final _qdrantKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadByodConfig();
  }

  @override
  void dispose() {
    _neo4jUriController.dispose();
    _neo4jUserController.dispose();
    _neo4jPassController.dispose();
    _qdrantUrlController.dispose();
    _qdrantKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadByodConfig() async {
    final config = await _storage.getByodConfig();
    if (!mounted) return;
    _neo4jUriController.text = config['neo4j_uri'] ?? '';
    _neo4jUserController.text = config['neo4j_user'] ?? '';
    _neo4jPassController.text = config['neo4j_pass'] ?? '';
    _qdrantUrlController.text = config['qdrant_url'] ?? '';
    _qdrantKeyController.text = config['qdrant_key'] ?? '';
  }

  Future<void> _saveByodConfig() async {
    await _storage.saveByodConfig(
      neo4jUri: _neo4jUriController.text.trim(),
      neo4jUser: _neo4jUserController.text.trim(),
      neo4jPass: _neo4jPassController.text,
      qdrantUrl: _qdrantUrlController.text.trim(),
      qdrantKey: _qdrantKeyController.text,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Infrastructure settings saved locally.')),
    );
  }

  Widget _buildTextField({
    required String label,
    required String hint,
    required TextEditingController controller,
    bool obscureText = false,
  }) {
    final extension = Theme.of(context).extension<AppThemeExtension>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: extension.textTertiary,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscureText,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: extension.textTertiary),
            filled: true,
            fillColor: extension.cardBackground,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildByodDatabaseCard({
    required ThemeData theme,
    required String title,
    required IconData icon,
    required List<Widget> fields,
  }) {
    final extension = theme.extension<AppThemeExtension>()!;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: extension.dialogBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: extension.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ...fields.expand((field) => [field, const SizedBox(height: 16)]),
        ],
      ),
    );
  }

  Widget _buildByodSection(ThemeData theme) {
    final extension = theme.extension<AppThemeExtension>()!;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: extension.surfaceHighlight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: extension.borderColorStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Database Infrastructure (BYOD)',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            'Connect Veraxi to your own Neo4j and Qdrant instances. Values are stored securely on this device.',
            style: TextStyle(color: extension.textTertiary, fontSize: 13),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 620;
              final neo4jCredentials = isWide
                  ? Row(
                      children: [
                        Expanded(
                            child: _buildTextField(
                                label: 'Username',
                                hint: 'neo4j',
                                controller: _neo4jUserController)),
                        const SizedBox(width: 12),
                        Expanded(
                            child: _buildTextField(
                                label: 'Password',
                                hint: 'Optional',
                                controller: _neo4jPassController,
                                obscureText: true)),
                      ],
                    )
                  : Column(
                      children: [
                        _buildTextField(
                            label: 'Username',
                            hint: 'neo4j',
                            controller: _neo4jUserController),
                        const SizedBox(height: 16),
                        _buildTextField(
                            label: 'Password',
                            hint: 'Optional',
                            controller: _neo4jPassController,
                            obscureText: true),
                      ],
                    );
              return Column(
                children: [
                  _buildByodDatabaseCard(
                    theme: theme,
                    title: 'Neo4j Knowledge Graph',
                    icon: Icons.hub_outlined,
                    fields: [
                      _buildTextField(
                          label: 'Neo4j URI',
                          hint: 'bolt://localhost:7687 or neo4j+s://...',
                          controller: _neo4jUriController),
                      neo4jCredentials,
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildByodDatabaseCard(
                    theme: theme,
                    title: 'Qdrant Vector Database',
                    icon: Icons.scatter_plot_outlined,
                    fields: [
                      _buildTextField(
                          label: 'Qdrant REST URL',
                          hint: 'http://localhost:6333 or https://...',
                          controller: _qdrantUrlController),
                      _buildTextField(
                          label: 'Qdrant API Key (Optional)',
                          hint: 'Leave empty for local instances',
                          controller: _qdrantKeyController,
                          obscureText: true),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: _saveByodConfig,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Save Configuration'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDatabaseMonitorCard(ThemeData theme, String title, String status,
      Color statusColor, IconData icon) {
    return Container(
      decoration: BoxDecoration(
        color: theme.extension<AppThemeExtension>()!.sidebarBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.extension<AppThemeExtension>()!.borderColorStrong),
      ),
      padding: EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.extension<AppThemeExtension>()!.borderColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: Colors.white, size: 24),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: statusColor, shape: BoxShape.circle)),
                        SizedBox(width: 6),
                        Text(status,
                            style: TextStyle(
                                color: statusColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          Spacer(),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {},
              icon: Icon(Icons.open_in_new,
                  size: 16, color: theme.colorScheme.primary),
              label: Text('Open Dashboard',
                  style: TextStyle(color: theme.colorScheme.primary)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        Text('Infrastructure & Self-Hosting',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(
            'Manage the underlying Neo4j and Qdrant clusters powering your Sovereign Intelligence.',
            style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.extension<AppThemeExtension>()!.textTertiary)),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 800;
            return GridView.count(
              crossAxisCount: isWide ? 2 : 1,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 24,
              mainAxisSpacing: 24,
              childAspectRatio: isWide ? 2.5 : 2.0,
              children: [
                _buildDatabaseMonitorCard(
                    theme,
                    'Neo4j Graph Database',
                    'Healthy (Managed Cloud)',
                    const Color(0xFF10B981),
                    Icons.hub_outlined),
                _buildDatabaseMonitorCard(
                    theme,
                    'Qdrant Vector Database',
                    'Healthy (Managed Cloud)',
                    const Color(0xFF10B981),
                    Icons.blur_on),
              ],
            );
          },
        ),
        const SizedBox(height: 28),
        _buildByodSection(theme),
        ],
      ),
    );
  }
}
