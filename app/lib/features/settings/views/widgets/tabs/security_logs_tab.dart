import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/theme_extension.dart';

class SecurityLogsTab extends ConsumerStatefulWidget {
  const SecurityLogsTab({super.key});

  @override
  ConsumerState<SecurityLogsTab> createState() => _SecurityLogsTabState();
}

class _SecurityLogsTabState extends ConsumerState<SecurityLogsTab> {
  bool _langsmithEnabled = false;
  final TextEditingController _langsmithKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _langsmithKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('tool_settings');
    if ((settingsJson ?? '').isNotEmpty) {
      try {
        final settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
        if (settings['observability'] != null) {
          final obs = settings['observability'] as Map<String, dynamic>;
          setState(() {
            _langsmithEnabled = (obs['langsmith_enabled'] as bool?) ?? false;
            _langsmithKeyController.text =
                (obs['langsmith_api_key'] as String?) ?? '';
          });
        }
      } catch (e) {
        // ignore
      }
    }
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
    settings['observability'] = {
      'langsmith_enabled': _langsmithEnabled,
      'langsmith_api_key': _langsmithKeyController.text,
    };
    await prefs.setString('tool_settings', jsonEncode(settings));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Security & Logs settings saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Security & Logs',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(
            'Configure audit logging, trace exports, and data privacy policies.',
            style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.extension<AppThemeExtension>()!.textTertiary)),
        SizedBox(height: 40),
        Text('Observability & Tracing',
            style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        SizedBox(height: 16),
        Container(
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
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Enable LangSmith Tracing',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w500)),
                      SizedBox(height: 4),
                      Text(
                          'Export detailed execution traces for debugging and compliance.',
                          style: TextStyle(
                              color: theme
                                  .extension<AppThemeExtension>()!
                                  .textTertiary,
                              fontSize: 13)),
                    ],
                  ),
                  Switch(
                    value: _langsmithEnabled,
                    onChanged: (val) {
                      setState(() => _langsmithEnabled = val);
                      _saveSettings();
                    },
                    activeThumbColor: theme.colorScheme.primary,
                  ),
                ],
              ),
              if (_langsmithEnabled) ...[
                SizedBox(height: 24),
                TextField(
                  controller: _langsmithKeyController,
                  style: TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'LangSmith API Key',
                    labelStyle: TextStyle(
                        color:
                            theme.extension<AppThemeExtension>()!.textTertiary),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                          color: theme
                              .extension<AppThemeExtension>()!
                              .textTertiary),
                    ),
                  ),
                  onSubmitted: (_) => _saveSettings(),
                ),
                SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: _saveSettings,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text('Save Key'),
                  ),
                ),
              ]
            ],
          ),
        ),
      ],
    );
  }
}
