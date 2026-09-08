import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_highlighter/flutter_highlighter.dart';
import 'package:flutter_highlighter/themes/atom-one-dark.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class InteractiveCodeBlock extends StatefulWidget {
  final String language;
  final String code;

  const InteractiveCodeBlock(
      {super.key, required this.language, required this.code});

  @override
  State<InteractiveCodeBlock> createState() => _InteractiveCodeBlockState();
}

class _InteractiveCodeBlockState extends State<InteractiveCodeBlock> {
  bool _isRunning = false;
  bool _hasError = false;

  void _runCode() async {
    if (_isRunning || _hasError) return;
    setState(() {
      _isRunning = true;
    });

    // Simulate code execution delay
    await Future.delayed(const Duration(seconds: 1));

    if (mounted) {
      setState(() {
        _isRunning = false;
        _hasError = true;
      });

      // Show red error snackbar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text('There was an error running the code',
                  style: TextStyle(color: Colors.white)),
            ],
          ),
          backgroundColor: const Color(0xFFDC2626), // Red background
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            bottom: MediaQuery.of(context).size.height - 150,
            left: MediaQuery.of(context).size.width / 2 - 150,
            right: MediaQuery.of(context).size.width / 2 - 150,
          ),
          duration: const Duration(seconds: 3),
        ),
      );

      // Revert the error state after the snackbar duration
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _hasError = false;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(vertical: 8),
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
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(widget.language,
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontFamily: 'monospace')),
                Row(
                  children: [
                    InkWell(
                      onTap: _runCode,
                      child: Row(
                        children: [
                          if (_hasError)
                            Icon(Icons.close,
                                color: Color(0xFFDC2626), size: 14)
                          else if (_isRunning)
                            SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white70))
                          else
                            Icon(Icons.play_arrow_outlined,
                                color: Colors.white70, size: 14),
                          SizedBox(width: 4),
                          Text(
                            _hasError ? 'Failed' : 'Run Code',
                            style: TextStyle(
                              color: _hasError
                                  ? const Color(0xFFDC2626)
                                  : Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 16),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: widget.code));
                      },
                      child: Row(
                        children: [
                          Icon(Icons.copy_outlined,
                              color: Colors.white70, size: 14),
                          SizedBox(width: 4),
                          Text('Copy code',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12)),
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
              padding: EdgeInsets.all(16),
              textStyle: GoogleFonts.firaCode(fontSize: 13, height: 1.5),
            ),
          ),
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.all(8),
            color: Colors.blue.withValues(alpha: 0.1),
            child: Row(
              children: [
                Icon(Icons.brush, size: 16, color: Colors.blue),
                SizedBox(width: 8),
                Text('HTML Artifact (Preview coming soon)',
                    style: TextStyle(
                        color: Colors.blue, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          InteractiveCodeBlock(language: 'html', code: code),
        ],
      );
    }

    if (languageClass == 'language-mermaid') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.all(8),
            color: Colors.purple.withValues(alpha: 0.1),
            child: Row(
              children: [
                Icon(Icons.schema, size: 16, color: Colors.purple),
                SizedBox(width: 8),
                Text('Mermaid Diagram Artifact (Preview coming soon)',
                    style: TextStyle(
                        color: Colors.purple, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          InteractiveCodeBlock(language: 'mermaid', code: code),
        ],
      );
    }

    return InteractiveCodeBlock(language: language, code: code);
  }
}
