import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';

/// The compact, clickable rectangle shown in the chat flow in place of a
/// full inline code block — the Veraxi equivalent of Claude's file card.
///
/// Shows a type icon (a globe for HTML, like Claude's card), the artifact
/// title (humanized file name when the assistant named the file), and the
/// extension badge (`PY`, `DART`, …). Tapping it opens the artifact in
/// the right-side panel.
class CodeArtifactCard extends StatelessWidget {
  final CodeArtifact artifact;
  final bool isOpen;
  final VoidCallback onTap;

  const CodeArtifactCard({
    super.key,
    required this.artifact,
    required this.onTap,
    this.isOpen = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>();
    final borderColor = isOpen
        ? (ext?.primaryGradientStart ?? theme.colorScheme.primary)
        : (ext?.borderColor ?? theme.colorScheme.outlineVariant);
    final background = ext?.cardBackground ?? const Color(0xFF2F2F2F);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      constraints: const BoxConstraints(maxWidth: 420),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: Colors.white.withValues(alpha: 0.04),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: ext?.borderColor ?? const Color(0xFF3F3F3F),
                    ),
                  ),
                  child: Icon(_iconFor(artifact),
                      size: 18, color: const Color(0xFFECECEC)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        artifact.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFECECEC),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${artifact.extensionLabel} · ${artifact.lineCount} '
                        '${artifact.lineCount == 1 ? 'line' : 'lines'}',
                        style: TextStyle(
                          color: ext?.textTertiary ?? const Color(0xFF878787),
                          fontSize: 11,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  isOpen
                      ? Icons.chevron_right
                      : artifact.isPreviewable
                          ? Icons.visibility_outlined
                          : Icons.open_in_new_outlined,
                  size: 16,
                  color: ext?.textTertiary ?? const Color(0xFF878787),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Leading tile icon per artifact kind, mirroring Claude's cards
  /// (globe for a web page, image for SVG, doc for Markdown).
  IconData _iconFor(CodeArtifact artifact) {
    return switch (artifact.previewKind) {
      CodePreviewKind.html => Icons.language,
      CodePreviewKind.svg => Icons.image_outlined,
      CodePreviewKind.mermaid => Icons.account_tree_outlined,
      CodePreviewKind.markdown => Icons.description_outlined,
      CodePreviewKind.react || CodePreviewKind.none => Icons.code,
    };
  }
}
