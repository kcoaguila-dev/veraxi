import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_highlighter/flutter_highlighter.dart';
import 'package:flutter_highlighter/themes/atom-one-dark.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_sandbox.dart';

/// Right-side panel that shows the full code for a [CodeArtifact] when its
/// card is tapped in the chat — the split view in Claude's UI.
///
/// Desktop: rendered as a fixed-width column beside the chat.
/// Mobile: the caller renders it as a full-screen overlay instead; this
/// widget simply fills whatever space it is given.
///
/// The header carries the title and extension badge, a Copy action, a Run
/// action for the languages the existing client sandbox actually executes
/// (Python / JavaScript), and a close button. The body is syntax
/// highlighted with a line-number gutter, scrollable in both directions.
class CodeArtifactPanel extends StatefulWidget {
  final CodeArtifact artifact;
  final VoidCallback onClose;

  const CodeArtifactPanel({
    super.key,
    required this.artifact,
    required this.onClose,
  });

  @override
  State<CodeArtifactPanel> createState() => _CodeArtifactPanelState();
}

class _CodeArtifactPanelState extends State<CodeArtifactPanel> {
  bool _copied = false;
  bool _isRunning = false;
  SandboxResult? _sandboxResult;

  bool get _canRun =>
      widget.artifact.language == 'python' ||
      widget.artifact.language == 'javascript';

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: widget.artifact.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _runCode() async {
    if (_isRunning) return;
    setState(() => _isRunning = true);
    final result = await runCodeInClientSandbox(
      widget.artifact.language,
      widget.artifact.code,
    );
    if (mounted) {
      setState(() {
        _isRunning = false;
        _sandboxResult = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>();
    final borderColor = ext?.borderColor ?? const Color(0xFF3F3F3F);
    final artifact = widget.artifact;

    return Container(
      decoration: BoxDecoration(
        color: ext?.dialogBackground ?? const Color(0xFF1E1E1E),
        border: Border(left: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(ext, borderColor),
          Expanded(child: _buildCodeBody(artifact)),
          if (_sandboxResult != null) _buildOutputStrip(),
        ],
      ),
    )
        .animate()
        .fade(duration: 200.ms)
        .slideX(begin: 0.04, end: 0, duration: 200.ms);
  }

  Widget _buildHeader(AppThemeExtension? ext, Color borderColor) {
    final artifact = widget.artifact;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          const Icon(Icons.code, size: 18, color: Color(0xFFECECEC)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  artifact.fileName ?? artifact.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFECECEC),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${artifact.extensionLabel} · '
                  '${codeLanguageDisplayName(artifact.language)}',
                  style: TextStyle(
                    color: ext?.textTertiary ?? const Color(0xFF878787),
                    fontSize: 11,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
          if (_canRun)
            _HeaderAction(
              icon: _isRunning ? null : Icons.play_arrow_outlined,
              label: _isRunning ? 'Running…' : 'Run',
              onTap: _runCode,
            ),
          const SizedBox(width: 8),
          _HeaderAction(
            icon: _copied ? Icons.check : Icons.copy_outlined,
            label: _copied ? 'Copied' : 'Copy',
            onTap: _copyCode,
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Color(0xFFB4B4B4)),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildCodeBody(CodeArtifact artifact) {
    final lineCount = artifact.lineCount;
    final gutterWidth = 16.0 + 9.0 * '$lineCount'.length;
    final textStyle = GoogleFonts.firaCode(fontSize: 13, height: 1.5);
    final gutterText = [
      for (var i = 1; i <= lineCount; i++) '$i',
    ].join('\n');

    return Container(
      color: const Color(0xFF0F0F0F),
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: gutterWidth + 16,
                padding: const EdgeInsets.fromLTRB(12, 16, 8, 16),
                alignment: Alignment.topRight,
                child: Text(
                  gutterText,
                  textAlign: TextAlign.right,
                  style: GoogleFonts.firaCode(
                    fontSize: 13,
                    height: 1.5,
                    color: const Color(0xFF5A5A5A),
                  ),
                ),
              ),
              HighlightView(
                artifact.code,
                language: artifact.language == 'plaintext'
                    ? 'plaintext'
                    : artifact.language,
                theme: atomOneDarkTheme,
                padding: const EdgeInsets.fromLTRB(4, 16, 24, 16),
                textStyle: textStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOutputStrip() {
    final result = _sandboxResult!;
    final failed = result.exitCode != 0;
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFF09090B),
        border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.check_circle_outline,
                size: 14,
                color:
                    failed ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
              ),
              const SizedBox(width: 6),
              Text(
                failed
                    ? 'Sandbox Error (Exit ${result.exitCode})'
                    : 'Sandbox Output',
                style: TextStyle(
                  color: failed
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF22C55E),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () => setState(() => _sandboxResult = null),
                child: const Icon(Icons.close, size: 14, color: Colors.white54),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (result.stdout.isNotEmpty)
                    SelectableText(
                      result.stdout,
                      style: GoogleFonts.firaCode(
                        fontSize: 12,
                        color: const Color(0xFFE2E8F0),
                      ),
                    ),
                  if (result.stderr.isNotEmpty)
                    SelectableText(
                      result.stderr,
                      style: GoogleFonts.firaCode(
                        fontSize: 12,
                        color: const Color(0xFFFCA5A5),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onTap;

  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF2F2F2F),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF3F3F3F)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: const Color(0xFFECECEC)),
                const SizedBox(width: 5),
              ] else ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFECECEC),
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFFECECEC),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
