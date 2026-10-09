import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/views/widgets/api_key_dialog.dart';
import 'package:veraxi_app/features/settings/views/widgets/tabs/settings_shared_ui.dart';

class AiProvidersTab extends ConsumerStatefulWidget {
  const AiProvidersTab({super.key});

  @override
  ConsumerState<AiProvidersTab> createState() => _AiProvidersTabState();
}

class _AiProvidersTabState extends ConsumerState<AiProvidersTab> {
  final Map<String, String?> _providerKeys = {};
  final Map<String, String?> _providerExpirations = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    final storage = ref.read(apiKeyStorageProvider);
    for (final provider in ['openai', 'anthropic', 'google', 'groq']) {
      _providerKeys[provider] = await storage.getKey(provider);
      _providerExpirations[provider] = await storage.getKeyExpirationDate(provider);
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _openApiKeyDialog(String providerId) async {
    await showDialog(
      context: context,
      builder: (context) => ApiKeyDialog(providerName: providerId),
    );
    // Reload keys after dialog closes
    _loadKeys();
  }

  Widget _buildProviderRow(String label, String providerId) {
    final key = _providerKeys[providerId];
    final expires = _providerExpirations[providerId];
    final isConfigured = key != null && key.isNotEmpty;

    final String subtitle;
    if (isConfigured) {
      if (expires != null) {
        subtitle = 'Expires: $expires';
      } else {
        subtitle = 'Configured • No expiration';
      }
    } else {
      subtitle = 'Not configured';
    }

    return SettingsUI.buildActionRow(
      context,
      label,
      subtitle,
      isConfigured ? 'Manage' : 'Configure',
      onTap: () => _openApiKeyDialog(providerId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('AI Providers',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
            'Configure API keys for intelligence providers. These keys are stored securely on your device.',
            style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.extension<AppThemeExtension>()!.textTertiary)),
        const SizedBox(height: 28),
        SettingsUI.buildSectionHeader(context, 'INTELLIGENCE PROVIDERS'),
        SettingsUI.buildSettingsGroup(context, [
          _buildProviderRow('OpenAI', 'openai'),
          _buildProviderRow('Anthropic', 'anthropic'),
          _buildProviderRow('Google Gemini', 'google'),
          _buildProviderRow('Groq', 'groq'),
        ]),
      ],
    );
  }
}
