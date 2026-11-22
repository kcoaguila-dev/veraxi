import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_download.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/corpus_insights_view_model.dart';

enum CorpusBriefingSectionFilter { all, briefingOnly, dbtLineageOnly }

/// Corpus Briefing & dbt Lineage panel (Knowledge Hub).
///
/// Design contract: docs/design/corpus_briefing_panel.svg.
/// Shows the deterministic corpus briefing (counts, top communities,
/// newest entities, heuristic contradiction flags) with Copy /
/// Download Markdown, plus a dbt manifest.json upload card and
/// dataset/column search with one-hop lineage.
class CorpusBriefingPanel extends ConsumerStatefulWidget {
  final CorpusBriefingSectionFilter sectionFilter;

  const CorpusBriefingPanel({
    super.key,
    this.sectionFilter = CorpusBriefingSectionFilter.all,
  });

  @override
  ConsumerState<CorpusBriefingPanel> createState() =>
      _CorpusBriefingPanelState();
}

class _CorpusBriefingPanelState extends ConsumerState<CorpusBriefingPanel> {
  final TextEditingController _datasetController = TextEditingController();
  bool _copied = false;

  @override
  void dispose() {
    _datasetController.dispose();
    super.dispose();
  }

  Future<void> _pickManifest() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (!result.isNotEmpty) return;
      final bytes = await result.first.readAsBytes();
      await ref
          .read(corpusInsightsViewModelProvider.notifier)
          .ingestManifestBytes(bytes);
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
    }
  }

  Future<void> _copyMarkdown(String markdown) async {
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>()!;
    final state = ref.watch(corpusInsightsViewModelProvider);
    final viewModel = ref.read(corpusInsightsViewModelProvider.notifier);

    final showBriefing =
        widget.sectionFilter != CorpusBriefingSectionFilter.dbtLineageOnly;
    final showDbt =
        widget.sectionFilter != CorpusBriefingSectionFilter.briefingOnly;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.sectionFilter == CorpusBriefingSectionFilter.all) ...[
          Text('Corpus Insights',
              style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20)),
          const SizedBox(height: 8),
          Text(
            'A deterministic briefing of your knowledge graph, and dbt lineage for your data pipeline.',
            style: TextStyle(color: ext.iconColor, fontSize: 14),
          ),
          const SizedBox(height: 16),
        ],
        if (showBriefing)
          Container(
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
                Row(
                  children: [
                    const Icon(Icons.menu_book_outlined,
                        size: 20, color: Colors.white),
                    const SizedBox(width: 10),
                    const Text('Corpus Briefing',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (state.briefing != null) ...[
                      TextButton.icon(
                        onPressed: () =>
                            _copyMarkdown(state.briefing!.markdown),
                        icon: Icon(_copied ? Icons.check : Icons.copy_outlined,
                            size: 16),
                        label: Text(_copied ? 'Copied' : 'Copy MD'),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () => downloadArtifactFile(
                          fileName: 'corpus_briefing.md',
                          content: state.briefing!.markdown,
                        ),
                        icon: const Icon(Icons.download_outlined, size: 16),
                        label: const Text('Download'),
                      ),
                    ],
                    IconButton(
                      tooltip: 'Refresh briefing',
                      onPressed:
                          state.loadingBriefing ? null : viewModel.loadBriefing,
                      icon: const Icon(Icons.refresh, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: _briefingBody(state),
                ),
              ],
            ),
          ),
        if (showBriefing && showDbt) const SizedBox(height: 24),
        if (showDbt)
          Container(
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
                const Text('dbt Lineage',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: state.ingestingManifest ? null : _pickManifest,
                      icon: const Icon(Icons.upload_file_outlined, size: 16),
                      label: Text(state.ingestingManifest
                          ? 'Ingesting…'
                          : 'Upload manifest.json'),
                    ),
                    if (state.manifestStatus != null)
                      Text(state.manifestStatus!,
                          style: const TextStyle(
                              color: Color(0xFF22C55E), fontSize: 13)),
                    if (state.manifestError != null)
                      Text(state.manifestError!,
                          style: const TextStyle(
                              color: Color(0xFFF59E0B), fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _datasetController,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Search datasets or columns…',
                          hintStyle: TextStyle(color: ext.textTertiary),
                          filled: true,
                          fillColor: ext.cardBackground,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: viewModel.searchDatasets,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: state.searchingDatasets
                          ? null
                          : () =>
                              viewModel.searchDatasets(_datasetController.text),
                      child: const Text('Search'),
                    ),
                  ],
                ),
                if (state.datasetError != null) ...[
                  const SizedBox(height: 8),
                  Text(state.datasetError!,
                      style: const TextStyle(
                          color: Color(0xFFF59E0B), fontSize: 13)),
                ],
                const SizedBox(height: 12),
                ...state.datasetMatches.map((match) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${match.name} (${match.label} · matched by ${match.matchedBy.join(', ')})',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                          if (match.upstream.isNotEmpty)
                            Text('Upstream: ${match.upstream.join(', ')}',
                                style: TextStyle(
                                    color: ext.iconColor, fontSize: 12)),
                          if (match.downstream.isNotEmpty)
                            Text('Downstream: ${match.downstream.join(', ')}',
                                style: TextStyle(
                                    color: ext.iconColor, fontSize: 12)),
                        ],
                      ),
                    )),
              ],
            ),
          ),
      ],
    );
  }

  Widget _briefingBody(CorpusInsightsState state) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    if (state.loadingBriefing && state.briefing == null) {
      return const Padding(
        key: ValueKey('briefing-loading'),
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('Loading briefing…',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
      );
    }
    if (state.briefingError != null && state.briefing == null) {
      return Padding(
        key: const ValueKey('briefing-error'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(state.briefingError!,
            style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 13)),
      );
    }
    final briefing = state.briefing;
    if (briefing == null) {
      return Padding(
        key: const ValueKey('briefing-empty'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No briefing loaded yet. Use the refresh button to build one from the current graph.',
          style: TextStyle(color: ext.iconColor, fontSize: 13),
        ),
      );
    }
    return Column(
      key: const ValueKey('briefing-content'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _countTile('Nodes', briefing.totalNodes),
            _countTile('Relationships', briefing.totalRelationships),
            _countTile('Communities', briefing.communityCount),
          ],
        ),
        if (briefing.topCommunities.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('Top communities',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...briefing.topCommunities.map((community) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Community ${community.id} (size ${community.size}) — '
                  '${community.topEntities.map((e) => e.name).join(', ')}',
                  style: TextStyle(color: ext.iconColor, fontSize: 12),
                ),
              )),
        ],
        if (briefing.newestEntities.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('Newest entities',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...briefing.newestEntities.map((entity) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${entity.name}${entity.type != null ? ' · ${entity.type}' : ''}'
                  '${entity.firstSeen != null ? ' · first seen ${entity.firstSeen}' : ''}',
                  style: TextStyle(color: ext.iconColor, fontSize: 12),
                ),
              )),
        ],
        if (briefing.contradictionFlags.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('Contradiction flags (heuristic — worth a human look)',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...briefing.contradictionFlags.map((flag) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${flag.entity} — ${flag.relation} → ${flag.targets.length} distinct targets',
                  style:
                      const TextStyle(color: Color(0xFFF59E0B), fontSize: 12),
                ),
              )),
        ],
      ],
    );
  }

  Widget _countTile(String label, int value) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ext.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          Text(label, style: TextStyle(color: ext.iconColor, fontSize: 11)),
        ],
      ),
    );
  }
}
