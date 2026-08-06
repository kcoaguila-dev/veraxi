import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WebSearchDialog extends StatefulWidget {
  const WebSearchDialog({super.key});

  @override
  State<WebSearchDialog> createState() => _WebSearchDialogState();
}

class _WebSearchDialogState extends State<WebSearchDialog> {
  final TextEditingController _serperKeyController = TextEditingController();
  final TextEditingController _searxngUrlController = TextEditingController();
  final TextEditingController _searxngKeyController = TextEditingController();
  final TextEditingController _firecrawlUrlController = TextEditingController();
  final TextEditingController _firecrawlKeyController = TextEditingController();

  String _selectedProvider = 'Serper API';
  String _selectedScraper = 'Firecrawl API';
  bool _webSearchEnabled = true;

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
        final webSearch = settings['web_search'] as Map<String, dynamic>?;
        if (webSearch != null) {
          if (webSearch['enabled'] != null) _webSearchEnabled = webSearch['enabled'];
          if (webSearch['provider'] != null) _selectedProvider = webSearch['provider'];
          if (webSearch['scraper'] != null) _selectedScraper = webSearch['scraper'];
          _serperKeyController.text = webSearch['serper_api_key'] ?? '';
          _searxngUrlController.text = webSearch['searxng_url'] ?? '';
          _searxngKeyController.text = webSearch['searxng_api_key'] ?? '';
          _firecrawlUrlController.text = webSearch['firecrawl_url'] ?? '';
          _firecrawlKeyController.text = webSearch['firecrawl_api_key'] ?? '';
          if (mounted) setState(() {});
        }
      } catch (e) {
        debugPrint('Failed to load tool settings: $e');
      }
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final currentSettingsJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if (currentSettingsJson != null) {
      try {
        settings = jsonDecode(currentSettingsJson) as Map<String, dynamic>;
      } catch (_) {}
    }
    
    settings['web_search'] = {
      'enabled': _webSearchEnabled,
      'provider': _selectedProvider,
      'scraper': _selectedScraper,
      'serper_api_key': _serperKeyController.text,
      'searxng_url': _searxngUrlController.text,
      'searxng_api_key': _searxngKeyController.text,
      'firecrawl_url': _firecrawlUrlController.text,
      'firecrawl_api_key': _firecrawlKeyController.text,
    };
    
    await prefs.setString('tool_settings', jsonEncode(settings));
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _serperKeyController.dispose();
    _searxngUrlController.dispose();
    _searxngKeyController.dispose();
    _firecrawlUrlController.dispose();
    _firecrawlKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 480,
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF171717),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2A2A2A)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            const Center(
              child: Text(
                'Web Search',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 24),
            
            // Toggle removed in favor of direct click in the tools menu

            
            const SizedBox(height: 24),
            
            // Search Provider
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Search Provider', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                PopupMenuButton<String>(
                  color: const Color(0xFF2F2F2F),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  offset: const Offset(0, 30),
                  onSelected: (value) => setState(() => _selectedProvider = value),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'Serper API',
                      height: 40,
                      child: Text('Serper API', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                    const PopupMenuItem(
                      value: 'SearXNG',
                      height: 40,
                      child: Text('SearXNG', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                    const PopupMenuItem(
                      value: 'Tavily API',
                      height: 40,
                      child: Text('Tavily API', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2F2F2F),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_selectedProvider, style: const TextStyle(color: Colors.white, fontSize: 12)),
                        const SizedBox(width: 4),
                        const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 14),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_selectedProvider == 'SearXNG') ...[
              _buildInputField(_searxngUrlController, 'SearXNG Instance URL'),
              const SizedBox(height: 12),
              _ApiKeyInputField(controller: _searxngKeyController, hintText: 'Enter SearXNG API Key (optional)'),
            ] else ...[
              _ApiKeyInputField(controller: _serperKeyController, hintText: 'Enter API Key'),
              const SizedBox(height: 8),
              RichText(
                text: _linkSpan('Get your $_selectedProvider key', url: 'https://serper.dev/api-keys'),
              ),
            ],
            
            const SizedBox(height: 32),
            
            // Scraper
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Scraper', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                PopupMenuButton<String>(
                  color: const Color(0xFF2F2F2F),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  offset: const Offset(0, 30),
                  onSelected: (value) => setState(() => _selectedScraper = value),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'Firecrawl API',
                      height: 40,
                      child: Text('Firecrawl API', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                    const PopupMenuItem(
                      value: 'Serper Scrape API',
                      height: 40,
                      child: Text('Serper Scrape API', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                    const PopupMenuItem(
                      value: 'Tavily Extract API',
                      height: 40,
                      child: Text('Tavily Extract API', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2F2F2F),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_selectedScraper, style: const TextStyle(color: Colors.white, fontSize: 12)),
                        const SizedBox(width: 4),
                        const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 14),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildInputField(_firecrawlUrlController, 'Firecrawl API URL (optional)'),
            const SizedBox(height: 12),
            _ApiKeyInputField(controller: _firecrawlKeyController, hintText: 'Enter API Key'),
            const SizedBox(height: 8),
            RichText(
              text: _linkSpan('Get your Firecrawl API key', url: 'https://docs.firecrawl.dev/introduction#api-key'),
            ),
            
            const SizedBox(height: 32),
            
            // Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFF2F2F2F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  child: const Text('Cancel', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _saveSettings,
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFF10A37F), // ChatGPT Green
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  child: const Text('Save', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputField(TextEditingController controller, String hintText) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: const TextStyle(color: Color(0xFF6E6E6E), fontSize: 13),
          border: InputBorder.none,
          focusedBorder: InputBorder.none,
          enabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          filled: false,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }

  TextSpan _linkSpan(String text, {String? url}) {
    return TextSpan(
      text: text,
      style: const TextStyle(color: Color(0xFF3B82F6), decoration: TextDecoration.underline, fontSize: 11),
      recognizer: TapGestureRecognizer()..onTap = () async {
        if (url != null) {
          final uri = Uri.parse(url);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri);
          }
        }
      },
    );
  }
}

class _ApiKeyInputField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;

  const _ApiKeyInputField({required this.controller, required this.hintText});

  @override
  State<_ApiKeyInputField> createState() => _ApiKeyInputFieldState();
}

class _ApiKeyInputFieldState extends State<_ApiKeyInputField> {
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;
  bool _obscureText = true;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        obscureText: _obscureText,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          hintText: widget.hintText,
          hintStyle: const TextStyle(color: Color(0xFF6E6E6E), fontSize: 13),
          border: InputBorder.none,
          focusedBorder: InputBorder.none,
          enabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          filled: false,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          suffixIcon: _isFocused
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        _obscureText ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: const Color(0xFF878787),
                        size: 16,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: () {
                        setState(() {
                          _obscureText = !_obscureText;
                        });
                      },
                    ),
                    const SizedBox(width: 4),
                  ],
                )
              : null,
        ),
      ),
    );
  }
}
