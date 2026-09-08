import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class ApiKeysView extends StatefulWidget {
  const ApiKeysView({Key? key}) : super(key: key);

  @override
  State<ApiKeysView> createState() => _ApiKeysViewState();
}

class _ApiKeysViewState extends State<ApiKeysView> {
  final _apiKeyStorage = ApiKeyStorage();

  // Controllers for BYOD
  final _neo4jUriController = TextEditingController();
  final _neo4jUserController = TextEditingController();
  final _neo4jPassController = TextEditingController();
  final _qdrantUrlController = TextEditingController();
  final _qdrantKeyController = TextEditingController();

  // We'll manage local visibility state for passwords/keys here.
  final Map<String, bool> _obscuredFields = {
    'openai': true,
    'anthropic': true,
    'gemini': true,
    'groq': true,
    'neo4j_pass': true,
    'qdrant_key': true,
  };

  @override
  void initState() {
    super.initState();
    _loadByodSettings();
  }

  Future<void> _loadByodSettings() async {
    final config = await _apiKeyStorage.getByodConfig();
    setState(() {
      _neo4jUriController.text = config['neo4j_uri'] ?? '';
      _neo4jUserController.text = config['neo4j_user'] ?? '';
      _neo4jPassController.text = config['neo4j_pass'] ?? '';
      _qdrantUrlController.text = config['qdrant_url'] ?? '';
      _qdrantKeyController.text = config['qdrant_key'] ?? '';
    });
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

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Bring Your Own Infrastructure',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Veraxi requires zero cloud hosting if you supply your own API keys and database credentials.',
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 14),
          ),
          SizedBox(height: 48),

          // --- Section A: Intelligence Providers ---
          Text(
            'Intelligence Providers (BYOK)',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'Provide API keys for the language models you wish to use.',
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13),
          ),
          SizedBox(height: 24),
          _buildKeyInput('OpenAI API Key', 'sk-...', 'openai'),
          _buildKeyInput('Anthropic API Key', 'sk-ant-...', 'anthropic'),
          _buildKeyInput('Google Gemini API Key', 'AIza...', 'gemini'),
          _buildKeyInput('Groq API Key', 'gsk_...', 'groq'),

          SizedBox(height: 48),
          Divider(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
          SizedBox(height: 48),

          // --- Section B: Database Infrastructure ---
          Text(
            'Database Infrastructure (BYOD)',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'Configure your hybrid GraphRAG databases. You can run these locally via Docker, or use free cloud tiers (Neo4j Aura & Qdrant Cloud).',
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13),
          ),
          SizedBox(height: 32),

          // Neo4j Config
          Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.share_outlined,
                        color: Colors.blueAccent, size: 24),
                    SizedBox(width: 12),
                    Text('Neo4j Knowledge Graph',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                SizedBox(height: 24),
                _buildTextInput(
                    'Neo4j URI', 'bolt://localhost:7687 or neo4j+s://...',
                    controller: _neo4jUriController),
                SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                        child: _buildTextInput('Username', 'neo4j',
                            controller: _neo4jUserController)),
                    SizedBox(width: 16),
                    Expanded(
                        child: _buildKeyInput(
                            'Password', '••••••••', 'neo4j_pass',
                            controller: _neo4jPassController)),
                  ],
                ),
              ],
            ),
          ),

          SizedBox(height: 24),

          // Qdrant Config
          Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.scatter_plot_outlined,
                        color: Colors.redAccent, size: 24),
                    SizedBox(width: 12),
                    Text('Qdrant Vector Database',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                SizedBox(height: 24),
                _buildTextInput(
                    'Qdrant REST URL', 'http://localhost:6333 or https://...',
                    controller: _qdrantUrlController),
                SizedBox(height: 16),
                _buildKeyInput('Qdrant API Key (Optional)',
                    'Leave empty if running locally without auth', 'qdrant_key',
                    controller: _qdrantKeyController),
              ],
            ),
          ),

          SizedBox(height: 48),
          Divider(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
          SizedBox(height: 48),

          // --- Section C: Model Context Protocol (BYOS) ---
          Text(
            'Model Context Protocol (BYOS)',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'Bring Your Own Subscription (BYOS) allows you to bypass cloud API costs by using your existing local AI subscriptions (e.g., Claude Desktop, Cursor) to act as the extraction engine.',
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13),
          ),
          SizedBox(height: 32),
          _buildMcpConfigCard(),

          SizedBox(height: 48),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                padding:
                    EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
              onPressed: () async {
                await _apiKeyStorage.saveByodConfig(
                  neo4jUri: _neo4jUriController.text,
                  neo4jUser: _neo4jUserController.text,
                  neo4jPass: _neo4jPassController.text,
                  qdrantUrl: _qdrantUrlController.text,
                  qdrantKey: _qdrantKeyController.text,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content:
                            Text('Infrastructure settings saved locally.')),
                  );
                }
              },
              child: Text('Save Configuration',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextInput(String label, String hint,
      {TextEditingController? controller}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        SizedBox(height: 8),
        TextField(
          controller: controller,
          style: TextStyle(color: Colors.white, fontSize: 14),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: (Theme.of(context).extension<AppThemeExtension>()?.textTertiary.withValues(alpha: 0.5) ?? Colors.grey)),
            filled: true,
            fillColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none),
            contentPadding:
                EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyInput(String label, String hint, String obscureKey,
      {TextEditingController? controller}) {
    return Padding(
      padding: EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          SizedBox(height: 8),
          TextField(
            controller: controller,
            obscureText: _obscuredFields[obscureKey] ?? true,
            style: TextStyle(color: Colors.white, fontSize: 14),
            cursorColor: Colors.white,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: (Theme.of(context).extension<AppThemeExtension>()?.textTertiary.withValues(alpha: 0.5) ?? Colors.grey)),
              filled: true,
              fillColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscuredFields[obscureKey] == true
                      ? Icons.visibility_off
                      : Icons.visibility,
                  color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    _obscuredFields[obscureKey] =
                        !(_obscuredFields[obscureKey] ?? true);
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMcpConfigCard() {
    const configString = '''{
  "mcpServers": {
    "veraxi": {
      "command": "uv",
      "args": ["run", "backend/mcp_server.py"]
    }
  }
}''';

    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_outlined,
                  color: Colors.purpleAccent, size: 24),
              SizedBox(width: 12),
              Text('Connect your AI Assistant',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          SizedBox(height: 16),
          Text(
            'Copy the configuration below and paste it into your Claude Desktop configuration (claude_desktop_config.json) or your Cursor MCP settings.',
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 14),
          ),
          SizedBox(height: 24),
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
            ),
            child: Stack(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    configString,
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Positioned(
                  top: -8,
                  right: -8,
                  child: IconButton(
                    icon: Icon(Icons.copy,
                        color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 18),
                    onPressed: () {
                      Clipboard.setData(
                          const ClipboardData(text: configString));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied to clipboard!')),
                        );
                      }
                    },
                    tooltip: 'Copy to Clipboard',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
