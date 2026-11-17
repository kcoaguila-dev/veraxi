import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:veraxi_app/core/theme_extension.dart';

class SourcesSidebar extends StatelessWidget {
  final List<Map<String, dynamic>> sources;

  const SourcesSidebar({super.key, required this.sources});

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
                  String title = source['title'] ?? 'Web Source';
                  String url = source['url'] ?? '';
                  String snippet = source['snippet'] ?? '';
                  String domain = '';
                  bool hasValidDomain = false;
                  try {
                    if (url.isNotEmpty && url != 'Internal Database') {
                      final uri = Uri.tryParse(
                          url.startsWith('http') ? url : 'http://$url');
                      domain = uri?.host.replaceFirst('www.', '') ?? '';
                      if (domain.contains('.')) {
                        hasValidDomain = true;
                      }
                    }
                  } catch (_) {}

                  String displayDomain =
                      hasValidDomain ? domain : 'Internal Database';

                  return InkWell(
                    onTap: () {
                      if (url.isNotEmpty) launchUrlString(url);
                    },
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
                              if (hasValidDomain)
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
                            title,
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

  const _ProvenanceSection({required this.provenance});

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
        if (legs.isNotEmpty) ...[
          SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final leg in legs)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: (_legColors[leg] ?? theme.borderColor)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(11),
                    border:
                        Border.all(color: _legColors[leg] ?? theme.borderColor),
                  ),
                  child: Text(
                    _legLabels[leg] ?? leg,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ],
        if (fusedScore != null) ...[
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
