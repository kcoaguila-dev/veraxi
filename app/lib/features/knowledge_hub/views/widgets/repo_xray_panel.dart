import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';

/// Repo X-Ray panel: index a repo into the code graph, inspect the
/// overview, search symbols and walk their impact tree.
///
/// Design contract: docs/design/repo_xray_panel.svg. The repo path
/// field is shared with the Vuln Intel panel via [repoPathController]
/// owned by the parent workbench section.
class RepoXrayPanel extends ConsumerStatefulWidget {
  final TextEditingController repoPathController;

  const RepoXrayPanel({super.key, required this.repoPathController});

  @override
  ConsumerState<RepoXrayPanel> createState() => _RepoXrayPanelState();
}

class _RepoXrayPanelState extends ConsumerState<RepoXrayPanel> {
  final TextEditingController _symbolController = TextEditingController();
  bool _impactExpanded = true;

  @override
  void dispose() {
    _symbolController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    final state = ref.watch(codeIntelViewModelProvider);
    final viewModel = ref.read(codeIntelViewModelProvider.notifier);
    final overview = state.overview;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: ext.surfaceHighlight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ext.borderColorStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Repo X-Ray',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.repoPathController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '/path/to/repo (inside an allowed root)',
                    hintStyle: TextStyle(color: ext.textTertiary),
                    filled: true,
                    fillColor: ext.cardBackground,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: state.indexing
                    ? null
                    : () => viewModel.indexRepo(widget.repoPathController.text),
                icon: const Icon(Icons.account_tree_outlined, size: 16),
                label: Text(state.indexing ? 'Indexing…' : 'Index Code Graph'),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh overview',
                onPressed:
                    state.loadingOverview ? null : viewModel.loadOverview,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          if (state.indexStatus != null) ...[
            const SizedBox(height: 8),
            Text(state.indexStatus!,
                style: const TextStyle(color: Color(0xFF22C55E), fontSize: 13)),
          ],
          if (state.indexError != null) ...[
            const SizedBox(height: 8),
            Text(state.indexError!,
                style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 13)),
          ],
          if (overview != null) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pill('${overview.totalNodes} nodes'),
                _pill('${overview.totalEdges} edges'),
                ...overview.nodeCounts.entries
                    .map((e) => _pill('${e.key}: ${e.value}')),
              ],
            ),
            if (overview.topConnected.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Top-connected symbols',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              ...overview.topConnected.map((symbol) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${symbol.qualifiedName} — ${symbol.degree} connections'
                      '${symbol.label != null ? ' · ${symbol.label}' : ''}'
                      '${symbol.path != null ? ' · ${symbol.path}' : ''}',
                      style: TextStyle(color: ext.iconColor, fontSize: 12),
                    ),
                  )),
            ],
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _symbolController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search a symbol…',
                    hintStyle: TextStyle(color: ext.textTertiary),
                    filled: true,
                    fillColor: ext.cardBackground,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: viewModel.searchSymbol,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => viewModel.searchSymbol(_symbolController.text),
                child: const Text('Search'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () =>
                    viewModel.analyzeImpact(_symbolController.text),
                child: const Text('Impact'),
              ),
            ],
          ),
          if (state.symbolSearched != null) ...[
            const SizedBox(height: 10),
            if (state.symbolMatches.isEmpty)
              Text('No matches for "${state.symbolSearched}"',
                  style: TextStyle(color: ext.iconColor, fontSize: 12))
            else
              ...state.symbolMatches.map((match) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${match.qualifiedName}${match.label != null ? ' · ${match.label}' : ''}'
                      '${match.path != null ? ' · ${match.path}' : ''}'
                      '${match.line != null ? ':${match.line}' : ''}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  )),
          ],
          if (state.impactSymbol != null) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: () => setState(() => _impactExpanded = !_impactExpanded),
              child: Row(
                children: [
                  Icon(
                    _impactExpanded ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text('Impact of ${state.impactSymbol}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeInOut,
              child: !_impactExpanded
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 6),
                        if (state.impacted.isEmpty)
                          Text('Nothing calls or imports this symbol.',
                              style:
                                  TextStyle(color: ext.iconColor, fontSize: 12))
                        else
                          ...state.impacted.map((node) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Row(
                                  children: [
                                    _badge('depth ${node.depth}'),
                                    const SizedBox(width: 6),
                                    if (node.viaEdge != null) ...[
                                      _badge(node.viaEdge!),
                                      const SizedBox(width: 6),
                                    ],
                                    Expanded(
                                      child: Text(
                                        node.qualifiedName,
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 12),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              )),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(String label) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: ext.borderColor),
      ),
      child: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 12)),
    );
  }

  Widget _badge(String label) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: ext.borderColorStrong,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 10)),
    );
  }
}
