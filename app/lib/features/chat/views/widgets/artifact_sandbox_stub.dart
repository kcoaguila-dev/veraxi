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

/// Handles one raw `veraxi_storage` bridge message from an artifact
/// view and returns the reply map to send back into the view.
typedef ArtifactStorageHandler = Future<Map<String, dynamic>> Function(
    dynamic raw);

/// Handles one raw `veraxi_complete` bridge message from an artifact
/// view and returns the reply map to send back into the view.
typedef ArtifactAiHandler = Future<Map<String, dynamic>> Function(dynamic raw);

/// Builds the reply for one raw `veraxi_complete` channel message:
/// the wired handler's reply, or the standard "not available" error
/// when no handler is wired (mirrors the storage bridge behavior).
Future<Map<String, dynamic>> aiBridgeReply(
  ArtifactAiHandler? handler,
  String rawMessage,
) async {
  dynamic parsed;
  try {
    parsed = jsonDecode(rawMessage);
  } catch (_) {
    return {
      'type': 'veraxi_complete_reply',
      'requestId': '',
      'ok': false,
      'text': null,
      'error': 'invalid AI request',
    };
  }
  if (parsed is! Map || parsed['type'] != 'veraxi_complete') {
    return {
      'type': 'veraxi_complete_reply',
      'requestId': '',
      'ok': false,
      'text': null,
      'error': 'invalid AI request',
    };
  }
  if (handler == null) {
    return {
      'type': 'veraxi_complete_reply',
      'requestId': parsed['requestId']?.toString() ?? '',
      'ok': false,
      'text': null,
      'error': 'AI is not available in this preview',
    };
  }
  return handler(parsed);
}

/// JavaScript that delivers an AI bridge [reply] into a WebView
/// frame through the shim's reply entry point.
String aiReplyScript(Map<String, dynamic> reply) {
  final encoded = jsonEncode(jsonEncode(reply));
  return 'window.__veraxiCompleteReply && '
      'window.__veraxiCompleteReply(JSON.parse($encoded));';
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
  final Map<String, String> siblingFiles;
  final ArtifactStorageHandler? storageHandler;
  final ArtifactAiHandler? aiHandler;

  const SandboxedArtifactView({
    super.key,
    required this.kind,
    required this.code,
    this.siblingFiles = const {},
    this.storageHandler,
    this.aiHandler,
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
      ..addJavaScriptChannel(
        'VeraxiStorage',
        onMessageReceived: (message) async {
          // Delegated through the shared helper's logic inline:
          // the controller is not yet assigned here, so replies go
          // through the late-bound _controller field.
          dynamic parsed;
          try {
            parsed = jsonDecode(message.message);
          } catch (_) {
            return;
          }
          if (parsed is! Map || parsed['type'] != 'veraxi_storage') return;
          final handler = widget.storageHandler;
          final Map<String, dynamic> reply;
          if (handler == null) {
            reply = {
              'type': 'veraxi_storage_reply',
              'requestId': parsed['requestId']?.toString() ?? '',
              'ok': false,
              'data': null,
              'error': 'storage is not available in this preview',
            };
          } else {
            reply = await handler(parsed);
          }
          final encoded = jsonEncode(jsonEncode(reply));
          await _controller.runJavaScript(
            'window.__veraxiStorageReply && '
            'window.__veraxiStorageReply(JSON.parse($encoded));',
          );
        },
      )
      ..addJavaScriptChannel(
        'VeraxiAi',
        onMessageReceived: (message) async {
          final reply = await aiBridgeReply(widget.aiHandler, message.message);
          await _controller.runJavaScript(aiReplyScript(reply));
        },
      )
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
      buildArtifactDocument(
        widget.kind,
        widget.code,
        siblingFiles: widget.siblingFiles,
      ),
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
  Map<String, String> siblingFiles = const {},
  ArtifactStorageHandler? storageHandler,
  ArtifactAiHandler? aiHandler,
}) {
  return SandboxedArtifactView(
    kind: kind,
    code: code,
    siblingFiles: siblingFiles,
    storageHandler: storageHandler,
    aiHandler: aiHandler,
  );
}

/// Chrome-free preview content for the artifact panel: just the WebView,
/// filling whatever space the caller gives it.
class ArtifactPreviewContent extends StatefulWidget {
  final String kind;
  final String code;
  final Map<String, String> siblingFiles;
  final ArtifactStorageHandler? storageHandler;
  final ArtifactAiHandler? aiHandler;

  const ArtifactPreviewContent({
    super.key,
    required this.kind,
    required this.code,
    this.siblingFiles = const {},
    this.storageHandler,
    this.aiHandler,
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
      ..setBackgroundColor(const Color(0xFF141416));
    _controller.addJavaScriptChannel(
      'VeraxiStorage',
      onMessageReceived: (message) async {
        dynamic parsed;
        try {
          parsed = jsonDecode(message.message);
        } catch (_) {
          return;
        }
        if (parsed is! Map || parsed['type'] != 'veraxi_storage') return;
        final handler = widget.storageHandler;
        final Map<String, dynamic> reply;
        if (handler == null) {
          reply = {
            'type': 'veraxi_storage_reply',
            'requestId': parsed['requestId']?.toString() ?? '',
            'ok': false,
            'data': null,
            'error': 'storage is not available in this preview',
          };
        } else {
          reply = await handler(parsed);
        }
        final encoded = jsonEncode(jsonEncode(reply));
        await _controller.runJavaScript(
          'window.__veraxiStorageReply && '
          'window.__veraxiStorageReply(JSON.parse($encoded));',
        );
      },
    );
    _controller.addJavaScriptChannel(
      'VeraxiAi',
      onMessageReceived: (message) async {
        final reply = await aiBridgeReply(widget.aiHandler, message.message);
        await _controller.runJavaScript(aiReplyScript(reply));
      },
    );
    _controller.loadHtmlString(
      buildArtifactDocument(
        widget.kind,
        widget.code,
        siblingFiles: widget.siblingFiles,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}

Widget buildArtifactPreviewContent({
  required String kind,
  required String code,
  Map<String, String> siblingFiles = const {},
  ArtifactStorageHandler? storageHandler,
  ArtifactAiHandler? aiHandler,
}) {
  return ArtifactPreviewContent(
    kind: kind,
    code: code,
    siblingFiles: siblingFiles,
    storageHandler: storageHandler,
    aiHandler: aiHandler,
  );
}
