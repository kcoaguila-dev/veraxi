import 'package:flutter/material.dart';
import 'package:veraxi_app/core/api_key_storage.dart';

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
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Bring Your Own Infrastructure',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Veraxi requires zero cloud hosting if you supply your own API keys and database credentials.',
            style: TextStyle(color: Color(0xFF878787), fontSize: 14),
          ),
          const SizedBox(height: 48),

          // --- Section A: Intelligence Providers ---
          const Text(
            'Intelligence Providers (BYOK)',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Provide API keys for the language models you wish to use.',
            style: TextStyle(color: Color(0xFF878787), fontSize: 13),
          ),
          const SizedBox(height: 24),
          _buildKeyInput('OpenAI API Key', 'sk-...', 'openai'),
          _buildKeyInput('Anthropic API Key', 'sk-ant-...', 'anthropic'),
          _buildKeyInput('Google Gemini API Key', 'AIza...', 'gemini'),
          _buildKeyInput('Groq API Key', 'gsk_...', 'groq'),

          const SizedBox(height: 48),
          const Divider(color: Color(0xFF2A2A2A)),
          const SizedBox(height: 48),

          // --- Section B: Database Infrastructure ---
          const Text(
            'Database Infrastructure (BYOD)',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Configure your hybrid GraphRAG databases. You can run these locally via Docker, or use free cloud tiers (Neo4j Aura & Qdrant Cloud).',
            style: TextStyle(color: Color(0xFF878787), fontSize: 13),
          ),
          const SizedBox(height: 32),

          // Neo4j Config
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF131313),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.share_outlined,
                        color: Colors.blueAccent, size: 24),
                    const SizedBox(width: 12),
                    const Text('Neo4j Knowledge Graph',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 24),
                _buildTextInput(
                    'Neo4j URI', 'bolt://localhost:7687 or neo4j+s://...',
                    controller: _neo4jUriController),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                        child: _buildTextInput('Username', 'neo4j',
                            controller: _neo4jUserController)),
                    const SizedBox(width: 16),
                    Expanded(
                        child: _buildKeyInput(
                            'Password', '••••••••', 'neo4j_pass',
                            controller: _neo4jPassController)),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Qdrant Config
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF131313),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.scatter_plot_outlined,
                        color: Colors.redAccent, size: 24),
                    const SizedBox(width: 12),
                    const Text('Qdrant Vector Database',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 24),
                _buildTextInput(
                    'Qdrant REST URL', 'http://localhost:6333 or https://...',
                    controller: _qdrantUrlController),
                const SizedBox(height: 16),
                _buildKeyInput('Qdrant API Key (Optional)',
                    'Leave empty if running locally without auth', 'qdrant_key',
                    controller: _qdrantKeyController),
              ],
            ),
          ),

          const SizedBox(height: 48),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10A37F),
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
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
              child: const Text('Save Configuration',
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
            style: const TextStyle(
                color: Color(0xFFB4B4B4),
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF4A4A4A)),
            filled: true,
            fillColor: const Color(0xFF1E1E1E),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyInput(String label, String hint, String obscureKey,
      {TextEditingController? controller}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Color(0xFFB4B4B4),
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            obscureText: _obscuredFields[obscureKey] ?? true,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            cursorColor: Colors.white,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: Color(0xFF4A4A4A)),
              filled: true,
              fillColor: const Color(0xFF1E1E1E),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscuredFields[obscureKey] == true
                      ? Icons.visibility_off
                      : Icons.visibility,
                  color: const Color(0xFF878787),
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
}
