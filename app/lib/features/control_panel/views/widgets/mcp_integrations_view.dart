import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class McpIntegrationsView extends StatefulWidget {
  const McpIntegrationsView({super.key});

  @override
  State<McpIntegrationsView> createState() => _McpIntegrationsViewState();
}

class _McpIntegrationsViewState extends State<McpIntegrationsView> {
  List<Map<String, dynamic>> _mcpServers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('tool_settings');
    if (settingsJson != null) {
      try {
        final settings = jsonDecode(settingsJson) as Map<String, dynamic>;
        if (settings['mcp_servers'] != null) {
          final servers = settings['mcp_servers'] as List<dynamic>;
          _mcpServers = servers
              .map((e) => {
                    'name': (e['name'] as String?) ?? '',
                    'url': (e['url'] as String?) ?? '',
                    'enabled': (e['enabled'] as bool?) ?? true,
                  })
              .toList();
        }
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final currentJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if (currentJson != null) {
      try {
        settings = jsonDecode(currentJson) as Map<String, dynamic>;
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
      }
    }

    settings['mcp_servers'] = _mcpServers;
    await prefs.setString('tool_settings', jsonEncode(settings));
  }

  void _showAddServerDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          title: Text('Add MCP Server',
              style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: TextStyle(color: Colors.white),
                cursorColor: Colors.white,
                decoration: const InputDecoration(
                  labelText: 'Server Name',
                  labelStyle: TextStyle(color: Colors.grey),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.grey)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white)),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: urlController,
                style: TextStyle(color: Colors.white),
                cursorColor: Colors.white,
                decoration: const InputDecoration(
                  labelText: 'SSE URL',
                  labelStyle: TextStyle(color: Colors.grey),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.grey)),
                  focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.isNotEmpty &&
                    urlController.text.isNotEmpty) {
                  setState(() {
                    _mcpServers.add({
                      'name': nameController.text,
                      'url': urlController.text,
                      'enabled': true,
                    });
                  });
                  _saveSettings();
                  Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary),
              child: Text('Add', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _removeServer(int index) {
    setState(() => _mcpServers.removeAt(index));
    _saveSettings();
  }

  void _toggleServer(int index, bool val) {
    setState(() => _mcpServers[index]['enabled'] = val);
    _saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('MCP Integrations',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(
          'Manage the external tools, services, and capabilities available to the Sovereign Intelligence.',
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
        ),
        SizedBox(height: 40),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
                ),
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.search,
                        color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 20),
                    SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        style: TextStyle(color: Colors.white),
                        cursorColor: Colors.white,
                        decoration: InputDecoration(
                          hintText: 'Search integrations...',
                          hintStyle: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
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
                foregroundColor: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
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
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary)),
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
                        : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                    description: server['url'] ?? '',
                    icon: Icons.extension,
                    iconColor: isOn
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
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

  Widget _buildIntegrationCard({
    required String title,
    required String status,
    required Color statusColor,
    required String description,
    required IconData icon,
    required Color iconColor,
    required bool isOn,
    required ValueChanged<bool> onToggle,
    required VoidCallback onDelete,
    Color? borderColor,
  }) {
    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor ?? Theme.of(context).extension<AppThemeExtension>()!.borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(title,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline,
                          color: Color(0xFFEF4444), size: 20),
                      onPressed: onDelete,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    SizedBox(width: 8),
                    Switch(
                      value: isOn,
                      onChanged: onToggle,
                      activeTrackColor: Theme.of(context).colorScheme.primary,
                      inactiveThumbColor: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                      inactiveTrackColor: const Color(0xFF424242),
                    ),
                  ],
                ),
                SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                            color: statusColor, shape: BoxShape.circle)),
                    SizedBox(width: 8),
                    Text(status,
                        style: TextStyle(
                            color: statusColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
                SizedBox(height: 12),
                Text(description,
                    style: TextStyle(
                        color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
