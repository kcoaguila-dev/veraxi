import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class ObservabilityView extends StatefulWidget {
  const ObservabilityView({super.key});

  @override
  State<ObservabilityView> createState() => _ObservabilityViewState();
}

class _ObservabilityViewState extends State<ObservabilityView> {
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
    if (settingsJson != null) {
      try {
        final settings = jsonDecode(settingsJson) as Map<String, dynamic>;
        if (settings['observability'] != null) {
          final obs = settings['observability'] as Map<String, dynamic>;
          _langsmithEnabled = (obs['langsmith_enabled'] as bool?) ?? false;
          _langsmithKeyController.text =
              (obs['langsmith_api_key'] as String?) ?? '';
        }
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
      }
    }
    if (mounted) setState(() {});
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
    settings['observability'] = {
      'langsmith_enabled': _langsmithEnabled,
      'langsmith_api_key': _langsmithKeyController.text,
    };
    await prefs.setString('tool_settings', jsonEncode(settings));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Security & Observability',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(
          'Connect external platforms for deep tracing, auditing, and observability of your AI agents.',
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
        ),
        SizedBox(height: 40),
        Container(
          padding: EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
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
                          color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.analytics_outlined,
                            color: Theme.of(context).colorScheme.primary),
                      ),
                      SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('LangSmith Tracing',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600)),
                          SizedBox(height: 4),
                          Text(
                              'Record LLM inputs, tool calls, and latencies via LangChain.',
                              style: TextStyle(
                                  color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
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
                    activeTrackColor: Theme.of(context).colorScheme.primary,
                    inactiveThumbColor: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                    inactiveTrackColor: const Color(0xFF424242),
                  ),
                ],
              ),
              if (_langsmithEnabled) ...[
                SizedBox(height: 24),
                TextField(
                  controller: _langsmithKeyController,
                  obscureText: true,
                  style: TextStyle(color: Colors.white),
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
}
