import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_html_documents.dart';
import 'dart:async';
import 'dart:convert';

/// Result of executing code in the on-device sandbox.
class SandboxResult {
  final String stdout;
  final String stderr;
  final int exitCode;

  const SandboxResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });
}

int _nativeRunCounter = 0;

/// Executes code entirely on the user's device: the shared runner
/// documents run inside a WebView (JavaScript in its JS engine, Python
/// via Pyodide WASM) and post their result back over a JavaScript
/// channel. Nothing is sent to a Veraxi server for execution, and
/// anything that cannot really run returns an honest error instead of
/// a simulated success.
Future<SandboxResult> runCodeInClientSandbox(
    String language, String code) async {
  final lang = language.toLowerCase();
  final isPython = lang == 'python' || lang == 'py';
  final isJavaScript = lang == 'javascript' || lang == 'js';

  if (!isPython && !isJavaScript) {
    return SandboxResult(
      stdout: '',
      stderr: 'Running $language is not supported in the app sandbox. '
          'Supported languages: Python, JavaScript.',
      exitCode: 1,
    );
  }

  try {
    return await _runInDeviceWebView(isPython: isPython, code: code);
  } catch (e) {
    return SandboxResult(
      stdout: '',
      stderr: 'In-app code execution is unavailable on this device: $e',
      exitCode: 1,
    );
  }
}

Future<SandboxResult> _runInDeviceWebView({
  required bool isPython,
  required String code,
}) async {
  final runId = 'native_run_${_nativeRunCounter++}';
  final completer = Completer<SandboxResult>();
  final document = isPython
      ? buildPythonRunnerDocument(
          code,
          runId: runId,
          postResultBody: postResultToWebViewChannel,
        )
      : buildJavaScriptRunnerDocument(
          code,
          runId: runId,
          postResultBody: postResultToWebViewChannel,
        );

  final controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..addJavaScriptChannel(
      'VeraxiRunner',
      onMessageReceived: (message) {
        try {
          final parsed = jsonDecode(message.message);
          if (parsed is Map &&
              parsed['runId'] == runId &&
              !completer.isCompleted) {
            completer.complete(
              SandboxResult(
                stdout: parsed['stdout']?.toString() ?? '',
                stderr: parsed['stderr']?.toString() ?? '',
                exitCode:
                    parsed['exitCode'] is int ? parsed['exitCode'] as int : 1,
              ),
            );
          }
        } catch (_) {}
      },
    );

  // The first Python run also downloads the Pyodide runtime (~10 MB).
  final timeout = Timer(
    isPython ? const Duration(seconds: 60) : const Duration(seconds: 15),
    () {
      if (!completer.isCompleted) {
        completer.complete(
          SandboxResult(
            stdout: '',
            stderr: isPython
                ? 'Python execution timed out after 60s '
                    '(the first run downloads the in-app Python runtime).'
                : 'JavaScript execution timed out after 15s.',
            exitCode: 124,
          ),
        );
      }
    },
  );

  try {
    await controller.loadHtmlString(document);
    return await completer.future;
  } finally {
    timeout.cancel();
  }
}

/// Sandboxed artifact preview widget for mobile / desktop VM using WebView.
class SandboxedArtifactView extends StatefulWidget {
  final String kind; // 'html' or 'mermaid'
  final String code;

  const SandboxedArtifactView({
    super.key,
    required this.kind,
    required this.code,
  });

  @override
  State<SandboxedArtifactView> createState() => _SandboxedArtifactViewState();
}

class _SandboxedArtifactViewState extends State<SandboxedArtifactView> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String? _error;
  bool _showCode = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF141416))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
          },
          onWebResourceError: (e) {
            if (mounted) {
              setState(() {
                _error = e.description;
                _isLoading = false;
              });
            }
          },
        ),
      );
    _loadContent();
  }

  void _loadContent() {
    _controller.loadHtmlString(
      buildArtifactDocument(widget.kind, widget.code),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMermaid = widget.kind == 'mermaid';
    final accentColor =
        isMermaid ? const Color(0xFFC084FC) : const Color(0xFF38BDF8);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF141416),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: const Color(0xFF1A1A1E),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isMermaid ? Icons.schema_outlined : Icons.brush_outlined,
                      color: accentColor,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isMermaid
                          ? 'Mermaid Diagram (Interactive)'
                          : 'Live HTML Artifact',
                      style: TextStyle(
                        color: accentColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _showCode
                            ? Icons.visibility_outlined
                            : Icons.code_outlined,
                        size: 16,
                        color: Colors.white70,
                      ),
                      tooltip: _showCode ? 'View Preview' : 'View Code',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        setState(() => _showCode = !_showCode);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh,
                          size: 16, color: Colors.white70),
                      tooltip: 'Reload',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        setState(() => _isLoading = true);
                        _loadContent();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Content
          SizedBox(
            height: 320,
            child: _showCode
                ? Container(
                    color: const Color(0xFF0F0F0F),
                    padding: const EdgeInsets.all(12),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        widget.code,
                        style: GoogleFonts.firaCode(
                            fontSize: 12, color: Colors.white70),
                      ),
                    ),
                  )
                : Stack(
                    children: [
                      WebViewWidget(controller: _controller),
                      if (_isLoading)
                        const Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      if (_error != null)
                        Center(
                          child: Text(
                            'Error: $_error',
                            style: const TextStyle(
                                color: Colors.redAccent, fontSize: 12),
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

Widget buildSandboxedArtifactPreview({
  required String kind,
  required String code,
}) {
  return SandboxedArtifactView(kind: kind, code: code);
}

/// Chrome-free preview content for the artifact panel: just the WebView,
/// filling whatever space the caller gives it.
class ArtifactPreviewContent extends StatefulWidget {
  final String kind;
  final String code;

  const ArtifactPreviewContent({
    super.key,
    required this.kind,
    required this.code,
  });

  @override
  State<ArtifactPreviewContent> createState() => _ArtifactPreviewContentState();
}

class _ArtifactPreviewContentState extends State<ArtifactPreviewContent> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF141416))
      ..loadHtmlString(buildArtifactDocument(widget.kind, widget.code));
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}

Widget buildArtifactPreviewContent({
  required String kind,
  required String code,
}) {
  return ArtifactPreviewContent(kind: kind, code: code);
}
