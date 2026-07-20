import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'dart:convert';

class GraphArtifact extends StatefulWidget {
  final String jsonElements;

  const GraphArtifact({
    super.key,
    required this.jsonElements,
  });

  @override
  State<GraphArtifact> createState() => _GraphArtifactState();
}

class _GraphArtifactState extends State<GraphArtifact> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Cannot easily access theme in initState without didChangeDependencies,
    // so we set transparent background and rely on container color
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            setState(() {
              _isLoading = false;
            });
            // Inject the graph data into the webview
            _injectGraphData();
          },
          onWebResourceError: (WebResourceError error) {
            setState(() {
              _error = error.description;
              _isLoading = false;
            });
          },
        ),
      );

    _loadHtml();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-inject if theme changes
    if (!_isLoading) {
      _injectGraphData();
    }
  }

  Future<void> _loadHtml() async {
    try {
      final htmlString = await rootBundle.loadString('assets/graph.html');
      // For local assets, we can load HTML string directly
      // Base URL is required for some assets, but we load everything via CDN
      await _controller.loadHtmlString(htmlString);
    } catch (e) {
      setState(() {
        _error = "Failed to load graph artifact: \$e";
        _isLoading = false;
      });
    }
  }

  void _injectGraphData() {
    if (!mounted) return;
    final theme = Theme.of(context);
    
    // Safely encode the JSON string for injection
    final safeJson = jsonEncode(widget.jsonElements);
    
    // Create a theme payload for the JS side
    final themePayload = jsonEncode({
      'primary': '#${theme.colorScheme.primary.toARGB32().toRadixString(16).substring(2, 8)}',
      'onSurface': '#${theme.colorScheme.onSurface.toARGB32().toRadixString(16).substring(2, 8)}',
      'outline': '#${theme.colorScheme.outlineVariant.toARGB32().toRadixString(16).substring(2, 8)}',
    });

    _controller.runJavaScript("renderGraph($safeJson, $themePayload);");
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 300,
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
              : WebViewWidget(controller: _controller),
    );
  }
}
