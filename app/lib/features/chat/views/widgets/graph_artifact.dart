import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:veraxi_app/core/theme.dart';
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
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.surface)
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
    // The JavaScript function renderGraph expects a stringified JSON array
    // Safely encode the JSON string for injection to prevent syntax errors
    final safeJson = jsonEncode(widget.jsonElements);
    _controller.runJavaScript("renderGraph($safeJson);");
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 300,
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.surfaceHighlight, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)))
              : WebViewWidget(controller: _controller),
    );
  }
}
