import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:veraxi_app/features/control_panel/views/widgets/api_keys_view.dart';
import 'package:veraxi_app/features/control_panel/views/widgets/billing_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/core/widgets/model_selector_popup.dart';
import 'package:veraxi_app/features/control_panel/view_models/control_panel_view_model.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:veraxi_app/core/sidebar_provider.dart';
import 'widgets/schema_visual_builder.dart';

class ControlPanelScreen extends ConsumerStatefulWidget {
  const ControlPanelScreen({super.key});

  @override
  ConsumerState<ControlPanelScreen> createState() => _ControlPanelScreenState();
}

class _ControlPanelScreenState extends ConsumerState<ControlPanelScreen> {
  int _selectedIndex = 0;

  // MCP Settings
  List<Map<String, dynamic>> _mcpServers = [];
  bool _isLoading = true;
  final TextEditingController _urlController = TextEditingController();

  // Observability Settings
  bool _langsmithEnabled = false;
  final TextEditingController _langsmithKeyController = TextEditingController();

  // Ingestion Settings
  bool _fastExtractionEnabled = false;
  String _selectedLanguage = 'en';
  String _selectedModel = 'gemini-2.5-flash-lite';
  final TextEditingController _customStopWordsController =
      TextEditingController();

  // Agent Skills
  List<Map<String, dynamic>> _skills = [];

  // Schema UI
  final _schemaSampleTextController = TextEditingController();
  static const String _sidebarToggleSvg = '''
<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <path fill-rule="evenodd" clip-rule="evenodd" d="M8.85719 3H15.1428C16.2266 2.99999 17.1007 2.99998 17.8086 3.05782C18.5375 3.11737 19.1777 3.24318 19.77 3.54497C20.7108 4.02433 21.4757 4.78924 21.955 5.73005C22.2568 6.32234 22.3826 6.96253 22.4422 7.69138C22.5 8.39925 22.5 9.27339 22.5 10.3572V13.6428C22.5 14.7266 22.5 15.6008 22.4422 16.3086C22.3826 17.0375 22.2568 17.6777 21.955 18.27C21.4757 19.2108 20.7108 19.9757 19.77 20.455C19.1777 20.7568 18.5375 20.8826 17.8086 20.9422C17.1008 21 16.2266 21 15.1428 21H8.85717C7.77339 21 6.89925 21 6.19138 20.9422C5.46253 20.8826 4.82234 20.7568 4.23005 20.455C3.28924 19.9757 2.52433 19.2108 2.04497 18.27C1.74318 17.6777 1.61737 17.0375 1.55782 16.3086C1.49998 15.6007 1.49999 14.7266 1.5 13.6428V10.3572C1.49999 9.27341 1.49998 8.39926 1.55782 7.69138C1.61737 6.96253 1.74318 6.32234 2.04497 5.73005C2.52433 4.78924 3.28924 4.02433 4.23005 3.54497C4.82234 3.24318 5.46253 3.11737 6.19138 3.05782C6.89926 2.99998 7.77341 2.99999 8.85719 3ZM6.35424 5.05118C5.74907 5.10062 5.40138 5.19279 5.13803 5.32698C4.57354 5.6146 4.1146 6.07354 3.82698 6.63803C3.69279 6.90138 3.60062 7.24907 3.55118 7.85424C3.50078 8.47108 3.5 9.26339 3.5 10.4V13.6C3.5 14.7366 3.50078 15.5289 3.55118 16.1458C3.60062 16.7509 3.69279 17.0986 3.82698 17.362C4.1146 17.9265 4.57354 18.3854 5.13803 18.673C5.40138 18.8072 5.74907 18.8994 6.35424 18.9488C6.97108 18.9992 7.76339 19 8.9 19H9.5V5H8.9C7.76339 5 6.97108 5.00078 6.35424 5.05118ZM11.5 5V19H15.1C16.2366 19 17.0289 18.9992 17.6458 18.9488C18.2509 18.8994 18.5986 18.8072 18.862 18.673C19.4265 18.3854 19.8854 17.9265 20.173 17.362C20.3072 17.0986 20.3994 16.7509 20.4488 16.1458C20.4992 15.5289 20.5 14.7366 20.5 13.6V10.4C20.5 9.26339 20.4992 8.47108 20.4488 7.85424C20.3994 7.24907 20.3072 6.90138 20.173 6.63803C19.8854 6.07354 19.4265 5.6146 18.862 5.32698C18.5986 5.19279 18.2509 5.10062 17.6458 5.05118C17.0289 5.00078 16.2366 5 15.1 5H11.5ZM5 8.5C5 7.94772 5.44772 7.5 6 7.5H7C7.55229 7.5 8 7.94772 8 8.5C8 9.05229 7.55229 9.5 7 9.5H6C5.44772 9.5 5 9.05229 5 8.5ZM5 12C5 11.4477 5.44772 11 6 11H7C7.55229 11 8 11.4477 8 12C8 12.5523 7.55229 13 7 13H6C5.44772 13 5 12.5523 5 12Z" fill="currentColor"/>
</svg>
''';

  Widget _buildSidebarToggleIcon() {
    return SvgPicture.string(
      _sidebarToggleSvg,
      width: 18,
      height: 18,
      fit: BoxFit.contain,
      colorFilter: const ColorFilter.mode(Color(0xFFB4B4B4), BlendMode.srcIn),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _customStopWordsController.dispose();
    super.dispose();
  }

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
        if (settings['observability'] != null) {
          final obs = settings['observability'] as Map<String, dynamic>;
          _langsmithEnabled = (obs['langsmith_enabled'] as bool?) ?? false;
          _langsmithKeyController.text =
              (obs['langsmith_api_key'] as String?) ?? '';
        }
        if (settings['skills'] != null) {
          final skills = settings['skills'] as List<dynamic>;
          _skills = skills
              .map((e) => {
                    'id': (e['id'] as String?) ?? '',
                    'name': (e['name'] as String?) ?? '',
                    'description': (e['description'] as String?) ?? '',
                    'instructions': (e['instructions'] as String?) ?? '',
                    'enabled': (e['enabled'] as bool?) ?? true,
                  })
              .toList();
        }
      } catch (e) {
        debugPrint('Failed to load tool settings: $e');
      }
    }
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final currentSettingsJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if (currentSettingsJson != null) {
      try {
        settings = jsonDecode(currentSettingsJson) as Map<String, dynamic>;
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
      }
    }

    settings['mcp_servers'] = _mcpServers;
    settings['observability'] = {
      'langsmith_enabled': _langsmithEnabled,
      'langsmith_api_key': _langsmithKeyController.text,
    };
    settings['skills'] = _skills;

    await prefs.setString('tool_settings', jsonEncode(settings));
  }

  void _showAddServerDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Add MCP Server',
              style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
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
              const SizedBox(height: 16),
              TextField(
                controller: urlController,
                style: const TextStyle(color: Colors.white),
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
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
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
                  backgroundColor: const Color(0xFF10A37F)),
              child: const Text('Add', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _removeServer(int index) {
    setState(() {
      _mcpServers.removeAt(index);
    });
    _saveSettings();
  }

  void _toggleServer(int index, bool val) {
    setState(() {
      _mcpServers[index]['enabled'] = val;
    });
    _saveSettings();
  }

  void _removeSkill(int index) {
    setState(() {
      _skills.removeAt(index);
    });
    _saveSettings();
  }

  void _toggleSkill(int index, bool val) {
    setState(() {
      _skills[index]['enabled'] = val;
    });
    _saveSettings();
  }

  void _showAddSkillDialog() {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final instructionsController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Add Agent Skill',
              style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    labelText: 'Skill Name',
                    labelStyle: TextStyle(color: Colors.grey),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey)),
                    focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white)),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descController,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    labelStyle: TextStyle(color: Colors.grey),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey)),
                    focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white)),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: instructionsController,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Instructions (Markdown)',
                    labelStyle: TextStyle(color: Colors.grey),
                    alignLabelWithHint: true,
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey)),
                    focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.isNotEmpty &&
                    instructionsController.text.isNotEmpty) {
                  setState(() {
                    _skills.add({
                      'id': DateTime.now().millisecondsSinceEpoch.toString(),
                      'name': nameController.text,
                      'description': descController.text,
                      'instructions': instructionsController.text,
                      'enabled': true,
                    });
                  });
                  _saveSettings();
                  Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10A37F)),
              child: const Text('Add', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showUploadSkillDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title:
              const Text('Upload skill', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () async {
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['md', 'zip'],
                    );
                    if (result != null && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Skill uploaded successfully!')));
                      Navigator.pop(context);
                    }
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: const Color(0xFF404040),
                          style: BorderStyle.solid),
                      borderRadius: BorderRadius.circular(8),
                      color: const Color(0xFF171717).withValues(alpha: 0.5),
                    ),
                    child: Column(
                      children: const [
                        Icon(Icons.upload_outlined,
                            color: Color(0xFF878787), size: 32),
                        SizedBox(height: 12),
                        Text('Drag and drop or click to upload',
                            style: TextStyle(
                                color: Color(0xFFB4B4B4), fontSize: 14)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('File requirements',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12)),
                const SizedBox(height: 4),
                const Text(
                    '• .md file must contain skill name and description formatted in YAML\n• .zip or .skill file must include a SKILL.md file\n• File size must not exceed 50 MB',
                    style: TextStyle(color: Color(0xFF878787), fontSize: 12)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSidebarOpen = ref.watch(sidebarStateProvider);

    ref.listen<ControlPanelState>(controlPanelViewModelProvider,
        (previous, next) {
      if (previous?.successMessage != next.successMessage &&
          next.successMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.successMessage!),
            backgroundColor: Colors.green.shade800,
          ),
        );
      }
      if (previous?.error != next.error && next.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${next.error}'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    });
    return Scaffold(
      backgroundColor: const Color(0xFF212121),
      body: Row(
        children: [
          // Inner Navigation Sidebar
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            width: isSidebarOpen ? 260 : 0,
            child: ClipRect(
              child: Container(
                width: 260,
                color: const Color(0xFF171717),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 24,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'Control Panel',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Tooltip(
                            message: 'Close sidebar',
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () {
                                  ref
                                      .read(sidebarStateProvider.notifier)
                                      .state = false;
                                },
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child:
                                      Center(child: _buildSidebarToggleIcon()),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    _buildMenuItem('MCP Integrations', Icons.hub_outlined,
                        _selectedIndex == 0, 0),
                    const SizedBox(height: 8),
                    _buildMenuItem('Knowledge Base', Icons.dataset_outlined,
                        _selectedIndex == 1, 1),
                    const SizedBox(height: 8),
                    _buildMenuItem('Billing', Icons.credit_card_outlined,
                        _selectedIndex == 2, 2),
                    const SizedBox(height: 8),
                    _buildMenuItem('Infrastructure', Icons.dns_outlined,
                        _selectedIndex == 3, 3),
                    const SizedBox(height: 8),
                    _buildMenuItem('Security & Logs', Icons.security_outlined,
                        _selectedIndex == 4, 4),
                    const SizedBox(height: 8),
                    _buildMenuItem('Agent Skills', Icons.psychology_outlined,
                        _selectedIndex == 5, 5),
                  ],
                ),
              ),
            ),
          ),

          // Main Content
          Expanded(
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(40.0),
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : (_selectedIndex == 0
                        ? _buildMcpIntegrations(theme)
                        : _selectedIndex == 1
                            ? _buildDataPipeline(theme)
                            : _selectedIndex == 2
                                ? const BillingView()
                                : _selectedIndex == 3
                                    ? const ApiKeysView()
                                    : _selectedIndex == 4
                                        ? _buildSecurityLogs(theme)
                                        : _buildAgentSkills(theme)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuItem(
      String title, IconData icon, bool isSelected, int index) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = index;
        });
      },
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF2F2F2F) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Stack(
          children: [
            if (isSelected)
              Positioned(
                left: -4,
                top: 8,
                bottom: 8,
                child: Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ListTile(
              leading: Icon(icon,
                  color: isSelected ? Colors.white : const Color(0xFFB4B4B4),
                  size: 20),
              title: Text(title,
                  style: TextStyle(
                      color:
                          isSelected ? Colors.white : const Color(0xFFB4B4B4),
                      fontSize: 14,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              dense: true,
              onTap: () {
                setState(() {
                  _selectedIndex = index;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataPipeline(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Knowledge Base',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'Manage your custom knowledge base.',
          style: TextStyle(color: const Color(0xFFB4B4B4), fontSize: 14),
        ),
        const SizedBox(height: 32),
        _buildSchemaCard(theme),
        const SizedBox(height: 32),
        _buildIngestionCard(theme),
        const SizedBox(height: 48),
        Text('Database Monitors',
            style: theme.textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 20)),
        const SizedBox(height: 8),
        Text(
          'Launch web dashboards to inspect the raw databases.',
          style: TextStyle(color: const Color(0xFFB4B4B4), fontSize: 14),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildDatabaseMonitorCard(
                theme,
                'Qdrant',
                'Vector Database',
                const String.fromEnvironment('QDRANT_DASHBOARD_URL',
                    defaultValue: 'http://localhost:6333/dashboard'),
                Icons.data_array,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildDatabaseMonitorCard(
                theme,
                'Neo4j',
                'Knowledge Graph',
                const String.fromEnvironment('NEO4J_DASHBOARD_URL',
                    defaultValue: 'http://localhost:7474'),
                Icons.hub,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDatabaseMonitorCard(ThemeData theme, String title,
      String subtitle, String url, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F2F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF404040)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF3B82F6), size: 24),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16)),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Color(0xFF878787), fontSize: 12)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () async {
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri);
              } else {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Could not launch dashboard')));
                }
              }
            },
            icon: const Icon(Icons.open_in_new, size: 16, color: Colors.white),
            label: const Text('Open Dashboard',
                style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3B82F6),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSchemaCard(ThemeData theme) {
    final state = ref.watch(controlPanelViewModelProvider);
    final viewModel = ref.read(controlPanelViewModelProvider.notifier);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F2F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF404040)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Knowledge Graph Schema (Ontology)',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 18)),
          const SizedBox(height: 4),
          const Text(
              'Define the entities and relationships that the AI should extract during ingestion.',
              style: TextStyle(color: Color(0xFFB4B4B4), fontSize: 14)),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Auto-Generate from Sample',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _schemaSampleTextController,
                      maxLines: 7,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText:
                            'Paste a sample of your text here (e.g., an abstract or executive summary). The AI will auto-generate an appropriate schema.',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: state.isIngesting
                          ? null
                          : () {
                              if (_schemaSampleTextController.text
                                  .trim()
                                  .isNotEmpty) {
                                viewModel.autoGenerateSchema(
                                    _schemaSampleTextController.text.trim());
                              }
                            },
                      icon: state.isIngesting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('Auto-Generate'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple.shade600,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 1,
                child: SchemaVisualBuilder(
                  initialSchema: state.schema,
                  isSaving: state.isIngesting,
                  onSave: (schema) {
                    viewModel.saveSchema(schema);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildIngestionCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F2F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF404040)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Global Ingestion',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 18)),
          const SizedBox(height: 4),
          const Text(
              'Upload documents or provide a URL. This data will be available to all AI agents.',
              style: TextStyle(color: Color(0xFFB4B4B4), fontSize: 14)),
          const SizedBox(height: 24),
          const Text('Upload Files',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontSize: 14)),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              try {
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: [
                    'pdf',
                    'txt',
                    'md',
                    'csv',
                    'html',
                    'doc',
                    'docx',
                    'ppt',
                    'pptx',
                    'xls',
                    'xlsx',
                    'png',
                    'jpg',
                    'jpeg',
                    'tiff',
                    'bmp',
                  ],
                  withData: true,
                );
                if (result != null && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Uploading file...')));
                  final viewModel =
                      ref.read(controlPanelViewModelProvider.notifier);
                  final fileBytes = result.files.first.bytes;
                  final fileName = result.files.first.name;
                  if (fileBytes != null) {
                    await viewModel.ingestUpload(
                      fileBytes,
                      fileName,
                      fastExtraction: _fastExtractionEnabled,
                      language: _selectedLanguage,
                      model: _selectedModel,
                      customStopWords: _customStopWordsController.text.trim(),
                    );
                    if (mounted)
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('File queued for ingestion!')));
                  }
                }
              } catch (e) {
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Upload failed: $e')));
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 32),
              decoration: BoxDecoration(
                border: Border.all(
                    color: const Color(0xFF404040), style: BorderStyle.solid),
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xFF171717).withValues(alpha: 0.5),
              ),
              child: Column(
                children: const [
                  Icon(Icons.cloud_upload_outlined,
                      color: Color(0xFF878787), size: 32),
                  SizedBox(height: 12),
                  Text('Click to select a file',
                      style: TextStyle(color: Color(0xFFB4B4B4), fontSize: 14)),
                  SizedBox(height: 4),
                  Text('PDF, TXT, MD, CSV, DOCX, Images (PNG/JPG) (Max 50MB)',
                      style: TextStyle(color: Color(0xFF878787), fontSize: 12)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Or ingest a URL',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontSize: 14)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: InputDecoration(
                    hintText: 'https://example.com/article',
                    hintStyle: const TextStyle(color: Color(0xFF878787)),
                    filled: true,
                    fillColor: const Color(0xFF171717),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none),
                  ),
                  onSubmitted: (val) => _submitUrl(),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _submitUrl,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3B82F6),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Ingest'),
              ),
            ],
          ),
          const SizedBox(height: 32),
          // AI Model Selection
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF171717),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF333333)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Extraction Model',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text(
                    'Select the AI model used for knowledge graph extraction.',
                    style: TextStyle(color: Color(0xFFB4B4B4), fontSize: 12)),
                const SizedBox(height: 16),
                InkWell(
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => ModelSelectorPopup(
                        selectedModel: _selectedModel,
                        onModelSelected: (model) {
                          setState(() => _selectedModel = model);
                        },
                        onClose: () => Navigator.of(context).pop(),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF333333)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_selectedModel,
                            style: const TextStyle(color: Colors.white)),
                        const Icon(Icons.arrow_drop_down,
                            color: Colors.white54),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF171717),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF333333)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Fast Extraction Mode',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      const Text(
                          'Uses a hybrid 90% fast NLP and 10% AI approach. Highly recommended for large datasets.',
                          style: TextStyle(
                              color: Color(0xFFB4B4B4), fontSize: 12)),
                    ],
                  ),
                ),
                Switch(
                  value: _fastExtractionEnabled,
                  onChanged: (val) {
                    setState(() {
                      _fastExtractionEnabled = val;
                    });
                  },
                  activeTrackColor: const Color(0xFF3B82F6),
                  inactiveThumbColor: const Color(0xFFB4B4B4),
                  inactiveTrackColor: const Color(0xFF424242),
                ),
              ],
            ),
          ),
          if (_fastExtractionEnabled) ...[
            const SizedBox(height: 16),
            Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                title: const Text('Advanced Settings',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
                iconColor: const Color(0xFF878787),
                collapsedIconColor: const Color(0xFF878787),
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: const EdgeInsets.all(16),
                backgroundColor: const Color(0xFF1E1E1E),
                collapsedBackgroundColor: const Color(0xFF1E1E1E),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0xFF333333))),
                collapsedShape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0xFF333333))),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Language',
                                style: TextStyle(
                                    color: Color(0xFFB4B4B4), fontSize: 12)),
                            const SizedBox(height: 8),
                            Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF171717),
                                borderRadius: BorderRadius.circular(8),
                                border:
                                    Border.all(color: const Color(0xFF333333)),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: _selectedLanguage,
                                  isExpanded: true,
                                  dropdownColor: const Color(0xFF1E1E1E),
                                  style: const TextStyle(color: Colors.white),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'en', child: Text('English')),
                                    DropdownMenuItem(
                                        value: 'es', child: Text('Spanish')),
                                    DropdownMenuItem(
                                        value: 'fr', child: Text('French')),
                                    DropdownMenuItem(
                                        value: 'de', child: Text('German')),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) {
                                      setState(() => _selectedLanguage = val);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Custom Stop Words (comma separated)',
                                style: TextStyle(
                                    color: Color(0xFFB4B4B4), fontSize: 12)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _customStopWordsController,
                              style: const TextStyle(color: Colors.white),
                              cursorColor: Colors.white,
                              decoration: InputDecoration(
                                hintText: 'e.g. client, company, confidential',
                                hintStyle:
                                    const TextStyle(color: Color(0xFF878787)),
                                filled: true,
                                fillColor: const Color(0xFF171717),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 14),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(
                                        color: Color(0xFF333333))),
                                enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(
                                        color: Color(0xFF333333))),
                                focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(
                                        color: Color(0xFF404040))),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAgentSkills(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Agent Skills',
                    style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                    'Manage custom instructions and workflows for the AI models.',
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: const Color(0xFF878787))),
              ],
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'write') {
                  _showAddSkillDialog();
                } else if (value == 'upload') {
                  _showUploadSkillDialog();
                }
              },
              color: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFE3E3E3),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.add, size: 18, color: Color(0xFF171717)),
                    const SizedBox(width: 4),
                    const Text('Add Skill',
                        style: TextStyle(
                            color: Color(0xFF171717),
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'write',
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, size: 18, color: Colors.white),
                      SizedBox(width: 8),
                      Text('Write skill instructions',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'upload',
                  child: Row(
                    children: [
                      Icon(Icons.upload_file_outlined,
                          size: 18, color: Colors.white),
                      SizedBox(width: 8),
                      Text('Upload a skill',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 32),
        if (_skills.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Text('No skills configured.',
                  style: TextStyle(color: const Color(0xFF878787))),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _skills.length,
            itemBuilder: (context, index) {
              final skill = _skills[index];
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF171717),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF2A2A2A)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.psychology,
                          color: Color(0xFFE3E3E3)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(skill['name'] as String,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16)),
                          const SizedBox(height: 4),
                          Text(skill['description'] as String,
                              style: const TextStyle(
                                  color: Color(0xFF878787), fontSize: 14)),
                        ],
                      ),
                    ),
                    Switch(
                      value: skill['enabled'] as bool,
                      onChanged: (val) => _toggleSkill(index, val),
                      activeThumbColor: const Color(0xFF10A37F),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.redAccent),
                      onPressed: () => _removeSkill(index),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  void _submitUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    try {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Queueing URL...')));
      final viewModel = ref.read(controlPanelViewModelProvider.notifier);
      await viewModel.ingestUrl(
        url,
        fastExtraction: _fastExtractionEnabled,
        language: _selectedLanguage,
        model: _selectedModel,
        customStopWords: _customStopWordsController.text.trim(),
      );
      _urlController.clear();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('URL queued for ingestion!')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('URL Ingestion failed: $e')));
    }
  }

  Widget _buildMcpIntegrations(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('MCP Integrations',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'Manage the external tools, services, and capabilities available to the Sovereign Intelligence.',
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: const Color(0xFF878787)),
        ),
        const SizedBox(height: 40),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF171717),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF333333)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.search,
                        color: Color(0xFF878787), size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        style: const TextStyle(color: Colors.white),
                        cursorColor: Colors.white,
                        decoration: const InputDecoration(
                          hintText: 'Search integrations...',
                          hintStyle: TextStyle(color: Color(0xFF878787)),
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
            const SizedBox(width: 16),
            ElevatedButton.icon(
              onPressed: _showAddServerDialog,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF171717),
                minimumSize: const Size(140, 44),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add Server',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 40),
        if (_isLoading)
          const Center(child: CircularProgressIndicator())
        else if (_mcpServers.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text('No MCP Integrations configured.',
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: const Color(0xFF878787))),
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
                        : const Color(0xFF878787),
                    description: server['url'] ?? '',
                    icon: Icons.extension,
                    iconColor: isOn
                        ? const Color(0xFF3B82F6)
                        : const Color(0xFF878787),
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

  Widget _buildSecurityLogs(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Security & Observability',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'Connect external platforms for deep tracing, auditing, and observability of your AI agents.',
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: const Color(0xFF878787)),
        ),
        const SizedBox(height: 40),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF2F2F2F),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF333333)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: const Color(0xFF171717),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.analytics_outlined,
                            color: Color(0xFF3B82F6)),
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('LangSmith Tracing',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(
                              'Record LLM inputs, tool calls, and latencies via LangChain.',
                              style: TextStyle(
                                  color: const Color(0xFFB4B4B4),
                                  fontSize: 14)),
                        ],
                      ),
                    ],
                  ),
                  Switch(
                    value: _langsmithEnabled,
                    onChanged: (val) {
                      setState(() {
                        _langsmithEnabled = val;
                      });
                      _saveSettings();
                    },
                    activeTrackColor: const Color(0xFF3B82F6),
                    inactiveThumbColor: const Color(0xFFB4B4B4),
                    inactiveTrackColor: const Color(0xFF424242),
                  ),
                ],
              ),
              if (_langsmithEnabled) ...[
                const SizedBox(height: 24),
                TextField(
                  controller: _langsmithKeyController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  onChanged: (_) => _saveSettings(),
                  decoration: const InputDecoration(
                    labelText: 'LangSmith API Key',
                    labelStyle: TextStyle(color: Colors.grey),
                    enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey)),
                    focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white)),
                  ),
                ),
              ],
            ],
          ),
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
    Color borderColor = const Color(0xFF333333),
  }) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F2F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF171717),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: Color(0xFFEF4444), size: 20),
                      onPressed: onDelete,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 8),
                    Switch(
                      value: isOn,
                      onChanged: onToggle,
                      activeTrackColor: const Color(0xFF3B82F6),
                      inactiveThumbColor: const Color(0xFFB4B4B4),
                      inactiveTrackColor: const Color(0xFF424242),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                            color: statusColor, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(status,
                        style: TextStyle(
                            color: statusColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
                const SizedBox(height: 12),
                Text(description,
                    style: const TextStyle(
                        color: Color(0xFFB4B4B4), fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
