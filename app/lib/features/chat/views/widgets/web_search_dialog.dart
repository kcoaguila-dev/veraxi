import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class WebSearchDialog extends StatefulWidget {
  const WebSearchDialog({super.key});

  @override
  State<WebSearchDialog> createState() => _WebSearchDialogState();
}

class _WebSearchDialogState extends State<WebSearchDialog> {
  // Search provider credentials
  final TextEditingController _serperKeyController = TextEditingController();
  final TextEditingController _searxngUrlController = TextEditingController();
  final TextEditingController _searxngKeyController = TextEditingController();

  // Per-scraper credentials
  final TextEditingController _firecrawlUrlController = TextEditingController();
  final TextEditingController _firecrawlKeyController = TextEditingController();
  final TextEditingController _jinaKeyController = TextEditingController();
  final TextEditingController _serperScrapeKeyController =
      TextEditingController();
  final TextEditingController _tavilyKeyController = TextEditingController();

  String _selectedProvider = 'SearXNG';
  String _selectedScraper = 'None';
  double _scraperMaxPages = 5;

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
          _selectedProvider = webSearch['provider'] ?? _selectedProvider;
          _selectedScraper = webSearch['scraper'] ?? _selectedScraper;
          _scraperMaxPages =
              (webSearch['scraper_max_pages'] as num?)?.toDouble() ??
                  _scraperMaxPages;

          _serperKeyController.text = webSearch['serper_api_key'] ?? '';
          _searxngUrlController.text = webSearch['searxng_url'] ?? '';
          _searxngKeyController.text = webSearch['searxng_api_key'] ?? '';
          _firecrawlUrlController.text = webSearch['firecrawl_url'] ?? '';
          _firecrawlKeyController.text = webSearch['firecrawl_api_key'] ?? '';
          _jinaKeyController.text = webSearch['jina_api_key'] ?? '';
          _serperScrapeKeyController.text =
              webSearch['serper_scrape_key'] ?? '';
          _tavilyKeyController.text = webSearch['tavily_api_key'] ?? '';

          if (mounted) setState(() {});
        }
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
        debugPrint('Failed to load tool settings: $e');
      }
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final currentJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if (currentJson != null) {
      try {
        settings = jsonDecode(currentJson) as Map<String, dynamic>;
      } catch (_) {}
    }

    final bool isEnabled = settings['web_search'] is Map
        ? (settings['web_search']['enabled'] as bool? ?? true)
        : true;

    settings['web_search'] = {
      'enabled': isEnabled,
      'provider': _selectedProvider,
      'scraper': _selectedScraper,
      'scraper_max_pages': _scraperMaxPages.round(),
      'serper_api_key': _serperKeyController.text,
      'searxng_url': _searxngUrlController.text,
      'searxng_api_key': _searxngKeyController.text,
      'firecrawl_url': _firecrawlUrlController.text,
      'firecrawl_api_key': _firecrawlKeyController.text,
      'jina_api_key': _jinaKeyController.text,
      'serper_scrape_key': _serperScrapeKeyController.text,
      'tavily_api_key': _tavilyKeyController.text,
    };

    await prefs.setString('tool_settings', jsonEncode(settings));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _serperKeyController.dispose();
    _searxngUrlController.dispose();
    _searxngKeyController.dispose();
    _firecrawlUrlController.dispose();
    _firecrawlKeyController.dispose();
    _jinaKeyController.dispose();
    _serperScrapeKeyController.dispose();
    _tavilyKeyController.dispose();
    super.dispose();
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 480,
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 680),
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header ────────────────────────────────────────────────
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

                // ── Search Provider ───────────────────────────────────────
                _SectionLabel(label: 'Search Provider'),
                const SizedBox(height: 8),
                _DropdownRow(
                  selected: _selectedProvider,
                  options: const ['SearXNG', 'Serper API', 'Tavily API'],
                  onSelected: (v) => setState(() => _selectedProvider = v),
                ),
                const SizedBox(height: 12),
                _buildProviderFields(),

                const SizedBox(height: 28),
                const Divider(color: Color(0xFF2A2A2A)),
                const SizedBox(height: 20),

                // ── Page Content Scraper ──────────────────────────────────
                _SectionLabel(label: 'Page Content Scraper'),
                const SizedBox(height: 4),
                const Text(
                  'Fetches the full article text after search, enabling grounded citations.',
                  style: TextStyle(color: Color(0xFF6E6E6E), fontSize: 11),
                ),
                const SizedBox(height: 10),
                _DropdownRow(
                  selected: _selectedScraper,
                  options: const [
                    'None',
                    'Trafilatura (local)',
                    'Jina Reader',
                    'Firecrawl API',
                    'Serper Scrape API',
                    'Tavily Extract API',
                  ],
                  onSelected: (v) => setState(() => _selectedScraper = v),
                ),
                const SizedBox(height: 12),
                _buildScraperFields(),

                // ── Max pages slider (shown for all scrapers except None) ─
                if (_selectedScraper != 'None') ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Max pages to fetch',
                        style: TextStyle(
                          color: Color(0xFFAAAAAA),
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        '${_scraperMaxPages.round()}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF10A37F),
                      inactiveTrackColor: const Color(0xFF2F2F2F),
                      thumbColor: const Color(0xFF10A37F),
                      overlayColor: const Color(0x2210A37F),
                      trackHeight: 2,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      value: _scraperMaxPages,
                      min: 1,
                      max: 10,
                      divisions: 9,
                      onChanged: (v) => setState(() => _scraperMaxPages = v),
                    ),
                  ),
                  const Text(
                    'More pages = richer citations but higher latency (~1-3s per page).',
                    style: TextStyle(color: Color(0xFF555555), fontSize: 10),
                  ),
                ],

                const SizedBox(height: 28),

                // ── Actions ───────────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xFF2F2F2F),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6)),
                      ),
                      child: const Text('Cancel',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: _saveSettings,
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xFF10A37F),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6)),
                      ),
                      child: const Text('Save',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── provider-specific fields ───────────────────────────────────────────────

  Widget _buildProviderFields() {
    if (_selectedProvider == 'SearXNG') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InputField(
              controller: _searxngUrlController,
              hintText: 'SearXNG Instance URL'),
          const SizedBox(height: 8),
          _ApiKeyField(
              controller: _searxngKeyController,
              hintText: 'API Key (optional)'),
        ],
      );
    }
    // Serper API or Tavily API
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ApiKeyField(
            controller: _serperKeyController, hintText: 'Enter API Key'),
        const SizedBox(height: 6),
        RichText(
          text: _linkSpan(
            'Get your $_selectedProvider key',
            url: _selectedProvider == 'Serper API'
                ? 'https://serper.dev/api-keys'
                : 'https://app.tavily.com/home',
          ),
        ),
      ],
    );
  }

  // ── scraper-specific fields ────────────────────────────────────────────────

  Widget _buildScraperFields() {
    switch (_selectedScraper) {
      case 'None':
        return _InfoChip(
          icon: Icons.snippet_folder_outlined,
          text: 'Uses SearXNG search snippets only. No configuration required.',
        );

      case 'Trafilatura (local)':
        return _InfoChip(
          icon: Icons.terminal_rounded,
          text:
              'Runs locally — no API key needed. Extracts text from HTML pages. '
              'Does not render JavaScript.',
        );

      case 'Jina Reader':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ApiKeyField(
              controller: _jinaKeyController,
              hintText: 'Jina API Key (optional — increases rate limit)',
            ),
            const SizedBox(height: 6),
            RichText(
              text: _linkSpan('Get a free Jina API key',
                  url: 'https://jina.ai/reader/'),
            ),
            const SizedBox(height: 6),
            _InfoChip(
              icon: Icons.javascript_rounded,
              text: 'Handles JavaScript-rendered pages via r.jina.ai.',
            ),
          ],
        );

      case 'Firecrawl API':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InputField(
              controller: _firecrawlUrlController,
              hintText: 'Firecrawl URL (leave blank for api.firecrawl.dev)',
            ),
            const SizedBox(height: 8),
            _ApiKeyField(
              controller: _firecrawlKeyController,
              hintText: 'Firecrawl API Key',
            ),
            const SizedBox(height: 6),
            RichText(
              text: _linkSpan('Get your Firecrawl API key',
                  url: 'https://docs.firecrawl.dev/introduction#api-key'),
            ),
          ],
        );

      case 'Serper Scrape API':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ApiKeyField(
              controller: _serperScrapeKeyController,
              hintText: 'Serper API Key',
            ),
            const SizedBox(height: 6),
            RichText(
              text: _linkSpan('Get your Serper API key',
                  url: 'https://serper.dev/api-keys'),
            ),
          ],
        );

      case 'Tavily Extract API':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ApiKeyField(
              controller: _tavilyKeyController,
              hintText: 'Tavily API Key',
            ),
            const SizedBox(height: 6),
            RichText(
              text: _linkSpan('Get your Tavily API key',
                  url: 'https://app.tavily.com/home'),
            ),
          ],
        );

      default:
        return const SizedBox.shrink();
    }
  }

  // ── shared helpers ─────────────────────────────────────────────────────────

  TextSpan _linkSpan(String text, {String? url}) {
    return TextSpan(
      text: text,
      style: const TextStyle(
        color: Color(0xFF3B82F6),
        decoration: TextDecoration.underline,
        fontSize: 11,
      ),
      recognizer: TapGestureRecognizer()
        ..onTap = () async {
          if (url != null) {
            final uri = Uri.parse(url);
            if (await canLaunchUrl(uri)) await launchUrl(uri);
          }
        },
    );
  }
}

// ── Reusable sub-widgets ───────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _DropdownRow extends StatelessWidget {
  final String selected;
  final List<String> options;
  final ValueChanged<String> onSelected;

  const _DropdownRow({
    required this.selected,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      color: const Color(0xFF2F2F2F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      offset: const Offset(0, 36),
      onSelected: onSelected,
      itemBuilder: (_) => options
          .map((o) => PopupMenuItem(
                value: o,
                height: 38,
                child: Text(o,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ))
          .toList(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF2F2F2F),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF3A3A3A)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(selected,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
            const Icon(Icons.keyboard_arrow_down,
                color: Colors.white54, size: 16),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2E2E2E)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF6E6E6E)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFF6E6E6E), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _InputField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  const _InputField({required this.controller, required this.hintText});

  @override
  Widget build(BuildContext context) {
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
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }
}

class _ApiKeyField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  const _ApiKeyField({required this.controller, required this.hintText});

  @override
  State<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<_ApiKeyField> {
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;
  bool _obscureText = true;

  @override
  void initState() {
    super.initState();
    _focusNode
        .addListener(() => setState(() => _isFocused = _focusNode.hasFocus));
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
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          suffixIcon: _isFocused
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        _obscureText
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: const Color(0xFF878787),
                        size: 16,
                      ),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: () =>
                          setState(() => _obscureText = !_obscureText),
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
