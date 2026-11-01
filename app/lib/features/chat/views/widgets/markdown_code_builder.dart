import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_highlighter/flutter_highlighter.dart';
import 'package:flutter_highlighter/themes/atom-one-dark.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'artifact_sandbox.dart';

class InteractiveCodeBlock extends StatefulWidget {
  final String language;
  final String code;

  const InteractiveCodeBlock({
    super.key,
    required this.language,
    required this.code,
  });

  @override
  State<InteractiveCodeBlock> createState() => _InteractiveCodeBlockState();
}

class _InteractiveCodeBlockState extends State<InteractiveCodeBlock> {
  bool _isRunning = false;
  SandboxResult? _sandboxResult;

  void _runCode() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
    });

    final result = await runCodeInClientSandbox(widget.language, widget.code);

    if (mounted) {
      setState(() {
        _isRunning = false;
        _sandboxResult = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasFailed = _sandboxResult != null && _sandboxResult!.exitCode != 0;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F), // Dark background for code
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color:
                  Theme.of(context).extension<AppThemeExtension>()!.borderColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  widget.language,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
                Row(
                  children: [
                    InkWell(
                      onTap: _runCode,
                      child: Row(
                        children: [
                          if (hasFailed)
                            const Icon(Icons.close,
                                color: Color(0xFFDC2626), size: 14)
                          else if (_isRunning)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white70,
                              ),
                            )
                          else
                            const Icon(Icons.play_arrow_outlined,
                                color: Colors.white70, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            _isRunning
                                ? 'Running...'
                                : (hasFailed ? 'Failed' : 'Run Code'),
                            style: TextStyle(
                              color: hasFailed
                                  ? const Color(0xFFDC2626)
                                  : Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.code));
                      },
                      child: const Row(
                        children: [
                          Icon(Icons.copy_outlined,
                              color: Colors.white70, size: 14),
                          SizedBox(width: 4),
                          Text(
                            'Copy code',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Code content
          SizedBox(
            width: double.infinity,
            child: HighlightView(
              widget.code,
              language:
                  widget.language == 'text' ? 'plaintext' : widget.language,
              theme: atomOneDarkTheme,
              padding: const EdgeInsets.all(16),
              textStyle: GoogleFonts.firaCode(fontSize: 13, height: 1.5),
            ),
          ),
          // Output Panel
          if (_sandboxResult != null) ...[
            const Divider(color: Colors.white12, height: 1),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Color(0xFF09090B),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _sandboxResult!.exitCode == 0
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                            size: 14,
                            color: _sandboxResult!.exitCode == 0
                                ? const Color(0xFF22C55E)
                                : const Color(0xFFEF4444),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _sandboxResult!.exitCode == 0
                                ? 'Sandbox Output'
                                : 'Sandbox Error (Exit ${_sandboxResult!.exitCode})',
                            style: TextStyle(
                              color: _sandboxResult!.exitCode == 0
                                  ? const Color(0xFF22C55E)
                                  : const Color(0xFFEF4444),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      InkWell(
                        onTap: () {
                          setState(() {
                            _sandboxResult = null;
                          });
                        },
                        child: const Icon(Icons.close,
                            size: 14, color: Colors.white54),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_sandboxResult!.stdout.isNotEmpty)
                    SelectableText(
                      _sandboxResult!.stdout,
                      style: GoogleFonts.firaCode(
                        fontSize: 12,
                        color: const Color(0xFFE2E8F0),
                      ),
                    ),
                  if (_sandboxResult!.stderr.isNotEmpty)
                    SelectableText(
                      _sandboxResult!.stderr,
                      style: GoogleFonts.firaCode(
                        fontSize: 12,
                        color: const Color(0xFFFCA5A5),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class CodeElementBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  CodeElementBuilder(this.context);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // If it doesn't have a language class or newlines, it's probably inline code.
    final hasLanguage =
        element.attributes.keys.any((k) => k.startsWith('class'));
    final languageClass = element.attributes['class'];
    final isBlock = element.textContent.contains('\n') || hasLanguage;

    if (!isBlock) {
      // Let flutter_markdown handle inline code
      return null;
    }

    String language = 'plaintext';
    if (languageClass != null && languageClass.startsWith('language-')) {
      language = languageClass.substring(9).toLowerCase();
      // Normalize common language aliases for highlight.js
      if (language == 'python3' || language == 'py') language = 'python';
      if (language == 'js' || language == 'node') language = 'javascript';
      if (language == 'ts') language = 'typescript';
      if (language == 'sh' || language == 'zsh') language = 'bash';
      if (language == 'c++' || language == 'cc') language = 'cpp';
      if (language == 'c#') language = 'cs';
      if (language == 'html') {
        language = 'xml'; // highglight.js treats html as xml
      }
      if (language == 'text') language = 'plaintext';
    }

    final code = element.textContent;

    if (language == 'xml' && languageClass == 'language-html') {
      return buildSandboxedArtifactPreview(kind: 'html', code: code);
    }

    if (languageClass == 'language-mermaid') {
      return buildSandboxedArtifactPreview(kind: 'mermaid', code: code);
    }

    return InteractiveCodeBlock(language: language, code: code);
  }
}
