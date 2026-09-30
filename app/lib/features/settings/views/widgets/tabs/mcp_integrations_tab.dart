import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/theme_extension.dart';

class McpIntegrationsTab extends ConsumerStatefulWidget {
  const McpIntegrationsTab({super.key});

  @override
  ConsumerState<McpIntegrationsTab> createState() => _McpIntegrationsTabState();
}

class _McpIntegrationsTabState extends ConsumerState<McpIntegrationsTab> {
  List<Map<String, dynamic>> _mcpServers = [];
  bool _isLoading = true;
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('tool_settings');
    if ((settingsJson ?? '').isNotEmpty) {
      try {
        final settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
        if (settings['mcp_servers'] != null) {
          final servers = settings['mcp_servers'] as List<dynamic>;
          setState(() {
            _mcpServers = servers
                .map((e) => {
                      'name': (e['name'] as String?) ?? '',
                      'url': (e['url'] as String?) ?? '',
                      'enabled': (e['enabled'] as bool?) ?? true,
                    })
                .toList();
          });
        }
      } catch (e) {
        // ignore parsing errors
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if ((settingsJson ?? '').isNotEmpty) {
      try {
        settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
      } catch (_) {}
    }
    settings['mcp_servers'] = _mcpServers;
    await prefs.setString('tool_settings', jsonEncode(settings));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('MCP Settings saved successfully')),
      );
    }
  }

  void _showAddServerDialog() {
    _urlController.clear();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor:
            Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
        title: Text('Add MCP Server', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _urlController,
              style: TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Server URL',
                labelStyle: TextStyle(
                    color: Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .textTertiary),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(
                      color: Theme.of(context)
                          .extension<AppThemeExtension>()!
                          .textTertiary),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: TextStyle(
                    color: Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .textTertiary)),
          ),
          ElevatedButton(
            onPressed: () {
              if (_urlController.text.isNotEmpty) {
                setState(() {
                  _mcpServers.add({
                    'name': 'Custom Server',
                    'url': _urlController.text,
                    'enabled': true,
                  });
                });
                _saveSettings();
                Navigator.pop(context);
              }
            },
            child: Text('Add'),
          ),
        ],
      ),
    );
  }

  void _removeServer(int index) {
    setState(() {
      _mcpServers.removeAt(index);
    });
    _saveSettings();
  }

  void _toggleServer(int index, bool value) {
    setState(() {
      _mcpServers[index]['enabled'] = value;
    });
    _saveSettings();
  }

  Widget _buildIntegrationCard({
    required String title,
    required String status,
    required Color statusColor,
    required String description,
    required IconData icon,
    required Color iconColor,
    required bool isOn,
    required ValueChanged<bool> onToggle,
    VoidCallback? onDelete,
  }) {
    return Container(
      decoration: BoxDecoration(
        color:
            Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Theme.of(context)
                .extension<AppThemeExtension>()!
                .borderColorStrong),
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
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 24),
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
              Switch(
                value: isOn,
                onChanged: onToggle,
                activeThumbColor: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
          Spacer(),
          Text(description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .textTertiary,
                  fontSize: 13)),
          if (onDelete != null) ...[
            SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline,
                    size: 16, color: Colors.redAccent),
                label:
                    Text('Remove', style: TextStyle(color: Colors.redAccent)),
              ),
            ),
          ]
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('MCP Integrations',
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(
            'Manage the external tools, services, and capabilities available to the Sovereign Intelligence.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .textTertiary)),
        SizedBox(height: 40),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .sidebarBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: Theme.of(context)
                          .extension<AppThemeExtension>()!
                          .borderColorStrong),
                ),
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.search,
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .textTertiary,
                        size: 20),
                    SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        style: TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search integrations...',
                          hintStyle: TextStyle(
                              color: Theme.of(context)
                                  .extension<AppThemeExtension>()!
                                  .textTertiary),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: 16),
            ElevatedButton.icon(
              onPressed: _showAddServerDialog,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .sidebarBackground,
                minimumSize: const Size(140, 44),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              icon: Icon(Icons.add),
              label: Text('Add Server',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        SizedBox(height: 40),
        if (_isLoading)
          Center(child: CircularProgressIndicator())
        else if (_mcpServers.isEmpty)
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Text('No MCP Integrations configured.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context)
                          .extension<AppThemeExtension>()!
                          .textTertiary)),
            ),
          )
        else
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
                children: List.generate(_mcpServers.length, (index) {
                  final server = _mcpServers[index];
                  final isOn = server['enabled'] == true;
                  return _buildIntegrationCard(
                    title: server['name'] ?? 'Unknown Server',
                    status: isOn ? 'Live Connection Active' : 'Disconnected',
                    statusColor: isOn
                        ? const Color(0xFF10B981)
                        : Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .textTertiary,
                    description: server['url'] ?? '',
                    icon: Icons.extension,
                    iconColor: isOn
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .textTertiary,
                    isOn: isOn,
                    onToggle: (val) => _toggleServer(index, val),
                    onDelete: () => _removeServer(index),
                  );
                }),
              );
            },
          ),
      ],
    );
  }
}
