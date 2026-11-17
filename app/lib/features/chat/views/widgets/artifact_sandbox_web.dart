// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_html_documents.dart';

/// Result of executing code in client or local sandbox.
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
/// frame and returns the reply map to post back into the frame.
typedef ArtifactStorageHandler = Future<Map<String, dynamic>> Function(
    dynamic raw);

int _sandboxRunCounter = 0;

/// Runs a runner document inside a hidden sandboxed iframe and waits
/// for it to post its JSON result back. The iframe has
/// `sandbox="allow-scripts"` without `allow-same-origin`, so the code
/// executes in an opaque origin on the user's own machine — never on
/// Veraxi's servers, and never in the app's own JS context.
Future<SandboxResult> _runInSandboxedFrame(
  String document, {
  required String runId,
  required Duration timeout,
  required String timeoutMessage,
}) async {
  final completer = Completer<SandboxResult>();

  final iframe = html.IFrameElement()
    ..style.display = 'none'
    ..setAttribute('sandbox', 'allow-scripts')
    ..srcdoc = document;

  StreamSubscription<html.MessageEvent>? sub;
  Timer? timeoutTimer;

  void cleanup() {
    timeoutTimer?.cancel();
    sub?.cancel();
    iframe.remove();
  }

  timeoutTimer = Timer(timeout, () {
    if (!completer.isCompleted) {
      cleanup();
      completer.complete(
        SandboxResult(stdout: '', stderr: timeoutMessage, exitCode: 124),
      );
    }
  });

  sub = html.window.onMessage.listen((event) {
    try {
      if (event.data is String) {
        final parsed = jsonDecode(event.data as String);
        if (parsed is Map && parsed['runId'] == runId) {
          if (!completer.isCompleted) {
            cleanup();
            completer.complete(
              SandboxResult(
                stdout: parsed['stdout']?.toString() ?? '',
                stderr: parsed['stderr']?.toString() ?? '',
                exitCode: parsed['exitCode'] is int
                    ? parsed['exitCode'] as int
                    : (parsed['exitCode'] != null ? 1 : 0),
              ),
            );
          }
        }
      }
    } catch (_) {}
  });

  html.document.body?.append(iframe);
  return completer.future;
}

/// Executes code entirely in the user's browser: JavaScript in a
/// sandboxed iframe, Python in the same iframe via Pyodide (WASM).
/// Nothing is sent to a Veraxi server for execution, and a language
/// the sandbox cannot run returns an honest error instead of a
/// simulated success.
Future<SandboxResult> runCodeInClientSandbox(
    String language, String code) async {
  final lang = language.toLowerCase();
  final runId = 'sandbox_run_${_sandboxRunCounter++}';

  if (lang == 'javascript' || lang == 'js') {
    return _runInSandboxedFrame(
      buildJavaScriptRunnerDocument(
        code,
        runId: runId,
        postResultBody: postResultToParentWindow,
      ),
      runId: runId,
      timeout: const Duration(seconds: 15),
      timeoutMessage: 'JavaScript execution timed out after 15s.',
    );
  }

  if (lang == 'python' || lang == 'py') {
    return _runInSandboxedFrame(
      buildPythonRunnerDocument(
        code,
        runId: runId,
        postResultBody: postResultToParentWindow,
      ),
      runId: runId,
      // The first run also downloads the Pyodide runtime (~10 MB).
      timeout: const Duration(seconds: 60),
      timeoutMessage: 'Python execution timed out after 60s '
          '(the first run downloads the in-browser Python runtime).',
    );
  }

  return SandboxResult(
    stdout: '',
    stderr: 'Running $language is not supported in the browser sandbox. '
        'Supported languages: Python, JavaScript.',
    exitCode: 1,
  );
}

int _webArtifactCounter = 0;

/// Sandboxed artifact preview widget for Flutter Web using sandboxed iframe.
class SandboxedArtifactViewWeb extends StatefulWidget {
  final String kind;
  final String code;
  final Map<String, String> siblingFiles;
  final ArtifactStorageHandler? storageHandler;

  const SandboxedArtifactViewWeb({
    super.key,
    required this.kind,
    required this.code,
    this.siblingFiles = const {},
    this.storageHandler,
  });

  @override
  State<SandboxedArtifactViewWeb> createState() =>
      _SandboxedArtifactViewWebState();
}

class _SandboxedArtifactViewWebState extends State<SandboxedArtifactViewWeb> {
  late final String _viewType;
  html.IFrameElement? _iframe;
  bool _showCode = false;
  StreamSubscription<html.MessageEvent>? _storageSub;

  @override
  void initState() {
    super.initState();
    _viewType = 'veraxi-artifact-${_webArtifactCounter++}';
    _registerIframe();
    _storageSub = html.window.onMessage.listen(_onStorageMessage);
  }

  @override
  void dispose() {
    _storageSub?.cancel();
    super.dispose();
  }

  Future<void> _onStorageMessage(html.MessageEvent event) async {
    final data = event.data;
    if (data is! String) return;
    dynamic parsed;
    try {
      parsed = jsonDecode(data);
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
    _iframe?.contentWindow?.postMessage(jsonEncode(reply), '*');
  }

  void _registerIframe() {
    _iframe = html.IFrameElement()
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
      ..setAttribute('sandbox', 'allow-scripts')
      ..srcdoc = _generateHtmlDoc();

    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _iframe!,
    );
  }

  String _generateHtmlDoc() {
    return buildArtifactDocument(
      widget.kind,
      widget.code,
      siblingFiles: widget.siblingFiles,
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
                        _iframe?.srcdoc = _generateHtmlDoc();
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
                : HtmlElementView(viewType: _viewType),
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
}) {
  return SandboxedArtifactViewWeb(
    kind: kind,
    code: code,
    siblingFiles: siblingFiles,
    storageHandler: storageHandler,
  );
}

/// Chrome-free preview content for the artifact panel: just the
/// sandboxed frame, filling whatever space the caller gives it. The
/// iframe keeps `sandbox="allow-scripts"` without `allow-same-origin`,
/// so artifact scripts run in an opaque origin — the same isolation
/// Claude's artifact pane uses.
class ArtifactPreviewContentWeb extends StatefulWidget {
  final String kind;
  final String code;
  final Map<String, String> siblingFiles;
  final ArtifactStorageHandler? storageHandler;

  const ArtifactPreviewContentWeb({
    super.key,
    required this.kind,
    required this.code,
    this.siblingFiles = const {},
    this.storageHandler,
  });

  @override
  State<ArtifactPreviewContentWeb> createState() =>
      _ArtifactPreviewContentWebState();
}

class _ArtifactPreviewContentWebState extends State<ArtifactPreviewContentWeb> {
  late final String _viewType;
  html.IFrameElement? _iframe;
  StreamSubscription<html.MessageEvent>? _storageSub;

  @override
  void initState() {
    super.initState();
    _viewType = 'veraxi-artifact-panel-${_webArtifactCounter++}';
    _iframe = html.IFrameElement()
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
      ..setAttribute('sandbox', 'allow-scripts')
      ..srcdoc = buildArtifactDocument(
        widget.kind,
        widget.code,
        siblingFiles: widget.siblingFiles,
      );
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _iframe!,
    );
    _storageSub = html.window.onMessage.listen(_onStorageMessage);
  }

  @override
  void dispose() {
    _storageSub?.cancel();
    super.dispose();
  }

  Future<void> _onStorageMessage(html.MessageEvent event) async {
    final data = event.data;
    if (data is! String) return;
    dynamic parsed;
    try {
      parsed = jsonDecode(data);
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
    _iframe?.contentWindow?.postMessage(jsonEncode(reply), '*');
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}

Widget buildArtifactPreviewContent({
  required String kind,
  required String code,
  Map<String, String> siblingFiles = const {},
  ArtifactStorageHandler? storageHandler,
}) {
  return ArtifactPreviewContentWeb(
    kind: kind,
    code: code,
    siblingFiles: siblingFiles,
    storageHandler: storageHandler,
  );
}
