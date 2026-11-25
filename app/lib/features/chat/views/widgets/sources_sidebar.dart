import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/core/widgets/language_file_icon.dart';
import 'package:veraxi_app/features/chat/view_models/code_file_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/citation_chip.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_citation_viewer.dart';

/// Maps a fused retrieval score (RRF k=60 with optional cross-encoder boost,
/// or cosine similarity) into a human-readable match tier.
String matchTierForScore(double score) {
  if (score >= 0.025) return 'High match';
  if (score >= 0.015) return 'Medium match';
  return 'Low match';
}

/// Returns the semantic badge color for [score]'s match tier.
Color matchTierColor(double score) {
  if (score >= 0.025) return const Color(0xFF22C55E);
  if (score >= 0.015) return const Color(0xFF4F8EF7);
  return const Color(0xFFF59E0B);
}

/// Formats a source title with its cited line range (`file:start-end` or
/// `file:line`) when [lineTarget] carries line numbers.
String formatSourceDisplayTitle(String title, CodeCitationTarget? lineTarget) {
  if (lineTarget == null) return title;
  final endLine = lineTarget.endLine;
  final lineSuffix = (endLine != null && endLine > lineTarget.startLine)
      ? '${lineTarget.startLine}-$endLine'
      : '${lineTarget.startLine}';
  if (title.endsWith(':$lineSuffix')) return title;
  return '$title:$lineSuffix';
}

CodeCitationTarget? _plainRepoFileTarget(String url) {
  final trimmed = url.trim();
  if (!trimmed.startsWith('file://') ||
      trimmed.startsWith('file:///') ||
      trimmed.contains('#')) {
    return null;
  }
  final path = trimmed.substring('file://'.length).trim();
  if (path.isEmpty) return null;
  return CodeCitationTarget(path: path, startLine: 1);
}

String _extractHttpDomain(String url) {
  if (url.isEmpty || url == 'Internal Database' || url.startsWith('file://')) {
    return '';
  }
  final uri = Uri.tryParse(url.startsWith('http') ? url : 'http://$url');
  final domain = uri?.host.replaceFirst('www.', '') ?? '';
  return domain.contains('.') ? domain : '';
}

String _resolveDisplayDomain(String domain, CodeCitationTarget? repoTarget) {
  if (domain.isNotEmpty) return domain;
  if (repoTarget != null) {
    final slash = repoTarget.path.lastIndexOf('/');
    return slash > 0 ? repoTarget.path.substring(0, slash) : 'Repository File';
  }
  return 'Internal Database';
}

ProviderContainer? _ambientContainer(BuildContext context) {
  try {
    return ProviderScope.containerOf(context, listen: false);
  } catch (_) {
    return null;
  }
}

void _openSource(
  BuildContext context, {
  required String url,
  required String displayTitle,
  required String displayDomain,
  required String snippet,
  CodeCitationTarget? repoTarget,
}) {
  if (repoTarget != null) {
    final container = _ambientContainer(context);
    if (container != null &&
        container.read(workspaceModeProvider) == WorkspaceMode.code) {
      container.read(activeReviewSessionProvider.notifier).state =
          CodeReviewState(
        sessionId: '',
        turnId: '',
        focusedPath: repoTarget.path,
        focusedStartLine: repoTarget.startLine,
        focusedEndLine: repoTarget.effectiveEndLine,
      );
      Navigator.of(context).maybePop();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CodeCitationViewer(target: repoTarget),
      ),
    );
    return;
  }

  if (url.startsWith('file://')) {
    launchUrlString(fileCitationLaunchUrl(url));
    return;
  }

  if (url.startsWith('http://') || url.startsWith('https://')) {
    launchUrlString(url);
    return;
  }

  if (snippet.isNotEmpty || displayTitle.isNotEmpty) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _SourceSnippetDialog(
        title: displayTitle,
        domain: displayDomain,
        snippet: snippet,
      ),
    );
  }
}

class SourcesSidebar extends StatelessWidget {
  final List<Map<String, dynamic>> sources;
  final bool showTelemetry;

  const SourcesSidebar({
    super.key,
    required this.sources,
    this.showTelemetry = true,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor:
          Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
      width: 350,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Icon(Icons.menu_book_outlined, color: Colors.white, size: 20),
                  SizedBox(width: 12),
                  Text(
                    'Sources',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, color: Colors.white70, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(
                color: Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .borderColor,
                height: 1),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.all(20),
                itemCount: sources.length,
                separatorBuilder: (context, index) => SizedBox(height: 16),
                itemBuilder: (context, index) {
                  final source = sources[index];
                  final rawTitle = source['title']?.toString() ?? 'Web Source';
                  final url = source['url']?.toString() ?? '';
                  final snippet = source['snippet']?.toString() ?? '';
                  final lineTarget = CodeCitationTarget.tryParse(url);
                  final repoTarget = lineTarget ?? _plainRepoFileTarget(url);
                  final domain = _extractHttpDomain(url);
                  final hasValidDomain = domain.isNotEmpty;
                  final displayDomain =
                      _resolveDisplayDomain(domain, repoTarget);
                  final displayTitle =
                      formatSourceDisplayTitle(rawTitle, lineTarget);

                  return InkWell(
                    onTap: () => _openSource(
                      context,
                      url: url,
                      displayTitle: displayTitle,
                      displayDomain: displayDomain,
                      snippet: snippet,
                      repoTarget: repoTarget,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .cardBackground,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .borderColor,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              SizedBox(width: 12),
                              if (repoTarget != null)
                                LanguageFileIcon(
                                  fileName: repoTarget.path,
                                  size: 16,
                                )
                              else if (hasValidDomain)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.network(
                                    'https://icon.horse/icon/$domain',
                                    width: 16,
                                    height: 16,
                                    errorBuilder:
                                        (context, error, stackTrace) => Icon(
                                            Icons.language,
                                            size: 16,
                                            color: Theme.of(context)
                                                .extension<AppThemeExtension>()!
                                                .textTertiary),
                                  ),
                                )
                              else
                                Icon(Icons.language,
                                    size: 16,
                                    color: Theme.of(context)
                                        .extension<AppThemeExtension>()!
                                        .textTertiary),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  displayDomain,
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .extension<AppThemeExtension>()!
                                        .textTertiary,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 12),
                          Text(
                            displayTitle,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                            ),
                          ),
                          if (snippet.isNotEmpty) ...[
                            SizedBox(height: 8),
                            Text(
                              snippet,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .extension<AppThemeExtension>()!
                                    .iconColor,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ],
                          if (source['provenance'] is Map &&
                              (source['provenance'] as Map).isNotEmpty) ...[
                            SizedBox(height: 12),
                            _ProvenanceSection(
                              provenance: Map<String, dynamic>.from(
                                  source['provenance'] as Map),
                              showTelemetry: showTelemetry,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Provenance ("show me the path") section for one source card.
///
/// Rendering only: [provenance] is the parsed map produced by
/// SourcesButton.extractSources — {legs, fused_score, graph_path}.
/// Badges render only for legs actually present; the graph path
/// renders only when a captured traversal path was sent.
class _ProvenanceSection extends StatelessWidget {
  final Map<String, dynamic> provenance;
  final bool showTelemetry;

  const _ProvenanceSection({
    required this.provenance,
    this.showTelemetry = true,
  });

  static const _legLabels = {
    'vector': 'Vector',
    'sparse': 'Sparse',
    'graph': 'Graph',
  };

  static const _legColors = {
    'vector': Color(0xFF4F8EF7),
    'sparse': Color(0xFF3FB68B),
    'graph': Color(0xFFD98A2B),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).extension<AppThemeExtension>()!;
    final legs = (provenance['legs'] as List?)?.cast<String>() ?? const [];
    final fusedScore = (provenance['fused_score'] as num?)?.toDouble();
    final rawPath = provenance['graph_path'];
    final graphPath = rawPath is List
        ? rawPath
            .whereType<Map>()
            .map((s) => Map<String, dynamic>.from(s))
            .toList()
        : const <Map<String, dynamic>>[];

    return Column(
      key: ValueKey('provenance-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: theme.borderColor, height: 1),
        SizedBox(height: 10),
        Text(
          'PROVENANCE',
          style: TextStyle(
            color: theme.textTertiary,
            fontSize: 11,
            letterSpacing: 1,
          ),
        ),
        if (legs.isNotEmpty || fusedScore != null) ...[
          SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final leg in legs)
                _ProvenanceBadge(
                  label: _legLabels[leg] ?? leg,
                  color: _legColors[leg] ?? theme.borderColor,
                ),
              if (fusedScore != null)
                _ProvenanceBadge(
                  label: matchTierForScore(fusedScore),
                  color: matchTierColor(fusedScore),
                ),
            ],
          ),
        ],
        if (showTelemetry && fusedScore != null) ...[
          SizedBox(height: 8),
          Row(
            children: [
              Text(
                'Fused score',
                style: TextStyle(color: theme.textTertiary, fontSize: 12),
              ),
              SizedBox(width: 8),
              Text(
                fusedScore.toStringAsFixed(3),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
        if (graphPath.length >= 2) ...[
          SizedBox(height: 10),
          for (var i = 0; i < graphPath.length; i++) ...[
            Padding(
              padding: EdgeInsets.only(left: i * 16.0),
              child: Text(
                graphPath[i]['node']?.toString() ?? '',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
            if (graphPath[i]['relation'] != null)
              Padding(
                padding: EdgeInsets.only(left: (i + 1) * 16.0),
                child: Text(
                  '— ${graphPath[i]['relation']} →',
                  style: TextStyle(
                    color: theme.textTertiary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ],
      ],
    );
  }
}

class _ProvenanceBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _ProvenanceBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _SourceSnippetDialog extends StatelessWidget {
  final String title;
  final String domain;
  final String snippet;

  const _SourceSnippetDialog({
    required this.title,
    required this.domain,
    required this.snippet,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).extension<AppThemeExtension>()!;
    return AlertDialog(
      backgroundColor: theme.dialogBackground,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            domain,
            style: TextStyle(color: theme.textTertiary, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 420),
        child: SingleChildScrollView(
          child: SelectableText(
            snippet.isNotEmpty ? snippet : 'No preview text available.',
            style: TextStyle(
              color: theme.iconColor,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
