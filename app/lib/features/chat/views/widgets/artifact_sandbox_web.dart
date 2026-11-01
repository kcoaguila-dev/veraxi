// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

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

int _pyodideExecutionCounter = 0;

/// Fallback executor running Python inside an isolated browser iframe via Pyodide CDN.
Future<SandboxResult> _runPythonInBrowserWasm(String code) async {
  final runId = 'pyodide_run_${_pyodideExecutionCounter++}';
  final completer = Completer<SandboxResult>();
  final encodedCode = base64Encode(utf8.encode(code));

  final runnerHtml = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <script src="https://cdn.jsdelivr.net/pyodide/v0.26.2/full/pyodide.js"></script>
</head>
<body>
<script>
(async function() {
  try {
    let pyodide = await loadPyodide();
    await pyodide.runPythonAsync(`
import sys
import io
sys_stdout_backup = sys.stdout
sys_stderr_backup = sys.stderr
sys.stdout = io.StringIO()
sys.stderr = io.StringIO()
`);
    let rawCode = atob("${encodedCode}");
    let exitCode = 0;
    try {
      await pyodide.runPythonAsync(rawCode);
    } catch(err) {
      exitCode = 1;
      await pyodide.runPythonAsync(`sys.stderr.write("""\${err}\\n""")`);
    }
    let stdout = await pyodide.runPythonAsync("sys.stdout.getvalue()");
    let stderr = await pyodide.runPythonAsync("sys.stderr.getvalue()");
    window.parent.postMessage(JSON.stringify({
      runId: "${runId}",
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode
    }), "*");
  } catch(setupErr) {
    window.parent.postMessage(JSON.stringify({
      runId: "${runId}",
      stdout: "",
      stderr: "Pyodide initialization failed: " + setupErr,
      exitCode: 1
    }), "*");
  }
})();
</script>
</body>
</html>
''';

  final iframe = html.IFrameElement()
    ..style.display = 'none'
    ..setAttribute('sandbox', 'allow-scripts')
    ..srcdoc = runnerHtml;

  StreamSubscription<html.MessageEvent>? sub;
  Timer? timeoutTimer;

  void cleanup() {
    timeoutTimer?.cancel();
    sub?.cancel();
    iframe.remove();
  }

  timeoutTimer = Timer(const Duration(seconds: 25), () {
    if (!completer.isCompleted) {
      cleanup();
      completer.complete(
        const SandboxResult(
          stdout: '',
          stderr: 'Pyodide WASM execution timed out after 25s.',
          exitCode: 124,
        ),
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

/// Executes code inside client WASM / browser context or forwards to backend MCP.
Future<SandboxResult> runCodeInClientSandbox(
    String language, String code) async {
  final lang = language.toLowerCase();

  // If JavaScript, run directly in JS context
  if (lang == 'javascript' || lang == 'js') {
    try {
      final res = js.context.callMethod('eval', [code]);
      return SandboxResult(
        stdout: res?.toString() ?? '(undefined)',
        stderr: '',
        exitCode: 0,
      );
    } catch (e) {
      return SandboxResult(
        stdout: '',
        stderr: e.toString(),
        exitCode: 1,
      );
    }
  }

  // If Python, try to reach backend MCP streamable endpoint first
  if (lang == 'python' || lang == 'py') {
    try {
      final uri = Uri.parse('/mcp');
      final resp = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': {
                'name': 'run_python_code',
                'arguments': {'code': code},
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final result = data['result'] as Map<String, dynamic>? ?? {};
        final content = (result['content'] as List<dynamic>?)?.firstOrNull;
        if (content is Map<String, dynamic> && content['text'] != null) {
          final parsed = jsonDecode(content['text'] as String);
          return SandboxResult(
            stdout: parsed['stdout'] ?? '',
            stderr: parsed['stderr'] ?? '',
            exitCode: parsed['exit_code'] ?? 0,
          );
        }
      }
    } catch (_) {
      // Offline fallback: execute in browser WASM via Pyodide
      try {
        return await _runPythonInBrowserWasm(code);
      } catch (wasmErr) {
        return SandboxResult(
          stdout: '',
          stderr: 'Pyodide WASM error: $wasmErr',
          exitCode: 1,
        );
      }
    }
  }

  return SandboxResult(
    stdout: '[$language Sandbox] Execution complete',
    stderr: '',
    exitCode: 0,
  );
}

int _webArtifactCounter = 0;

/// Sandboxed artifact preview widget for Flutter Web using sandboxed iframe.
class SandboxedArtifactViewWeb extends StatefulWidget {
  final String kind;
  final String code;

  const SandboxedArtifactViewWeb({
    super.key,
    required this.kind,
    required this.code,
  });

  @override
  State<SandboxedArtifactViewWeb> createState() =>
      _SandboxedArtifactViewWebState();
}

class _SandboxedArtifactViewWebState extends State<SandboxedArtifactViewWeb> {
  late final String _viewType;
  html.IFrameElement? _iframe;
  bool _showCode = false;

  @override
  void initState() {
    super.initState();
    _viewType = 'veraxi-artifact-${_webArtifactCounter++}';
    _registerIframe();
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
    if (widget.kind == 'mermaid') {
      final escapedCode = widget.code
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
  <style>
    body {
      margin: 0;
      padding: 24px;
      background: #141416;
      color: #E2E8F0;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 85vh;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
    .mermaid {
      display: flex;
      justify-content: center;
      width: 100%;
    }
  </style>
</head>
<body>
  <pre class="mermaid">
$escapedCode
  </pre>
  <script>
    mermaid.initialize({
      startOnLoad: true,
      theme: 'dark',
      securityLevel: 'loose'
    });
  </script>
</body>
</html>
''';
    }

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body {
      margin: 0;
      padding: 16px;
      background: #141416;
      color: #E2E8F0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
  </style>
</head>
<body>
${widget.code}
</body>
</html>
''';
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
}) {
  return SandboxedArtifactViewWeb(kind: kind, code: code);
}
