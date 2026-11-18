import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/evals_view_model.dart';

/// Evidence Evals section for the Observability tab: paste a typed
/// dataset and recorded rankings, run the ablation, compare configs.
///
/// Design contract: docs/design/evidence_evals_panel.svg. There is
/// no saved-benchmark store in the backend, so both inputs are
/// supplied per run. Only the metrics the runner actually returns
/// are rendered: recall@k, hit rate, and grounding — grounding shows
/// "n/a" when the rankings carried none, never an invented 0.
class EvidenceEvalsPanel extends ConsumerStatefulWidget {
  const EvidenceEvalsPanel({super.key});

  @override
  ConsumerState<EvidenceEvalsPanel> createState() => _EvidenceEvalsPanelState();
}

class _EvidenceEvalsPanelState extends ConsumerState<EvidenceEvalsPanel> {
  final TextEditingController _datasetController = TextEditingController(
    text: '{\n  "cases": [\n    {"id": "lookup-1", "query_type": "lookup", '
        '"query": "What is Acme?", "relevant_doc_ids": ["doc-1"]}\n  ]\n}',
  );
  final TextEditingController _rankingsController = TextEditingController(
    text: '{\n  "vector_only": {"What is Acme?": ["doc-1"]},\n'
        '  "hybrid_no_graph": {"What is Acme?": ["doc-1"]},\n'
        '  "hybrid_with_graph": {"What is Acme?": ["doc-1"]}\n}',
  );

  @override
  void dispose() {
    _datasetController.dispose();
    _rankingsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final state = ref.watch(evalsViewModelProvider);
    final viewModel = ref.read(evalsViewModelProvider.notifier);

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
          const Text('Evidence Evals — Retrieval Ablation',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'Paste a typed dataset (cases) and recorded rankings '
            '(config → query → doc ids). Runs offline against the '
            'recorded rankings — no benchmark is stored server-side.',
            style: TextStyle(color: ext.iconColor, fontSize: 13),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final fields = [
                _jsonField('Typed dataset JSON', _datasetController),
                _jsonField('Recorded rankings JSON', _rankingsController),
              ];
              if (constraints.maxWidth < 700) {
                return Column(
                  children: [
                    fields[0],
                    const SizedBox(height: 12),
                    fields[1],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: fields[0]),
                  const SizedBox(width: 12),
                  Expanded(child: fields[1]),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: state.running
                ? null
                : () => viewModel.run(
                      datasetJson: _datasetController.text,
                      rankingsJson: _rankingsController.text,
                    ),
            icon: const Icon(Icons.play_arrow_outlined, size: 16),
            label: Text(state.running ? 'Running…' : 'Run Ablation'),
          ),
          if (state.error != null) ...[
            const SizedBox(height: 10),
            Text(state.error!,
                style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 13)),
          ],
          if (state.report != null) ...[
            const SizedBox(height: 20),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              child: _resultsTable(state.report!),
            ),
          ],
        ],
      ),
    );
  }

  Widget _jsonField(String label, TextEditingController controller) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: 7,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
          decoration: InputDecoration(
            filled: true,
            fillColor: ext.cardBackground,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }

  Widget _resultsTable(AblationReport report) {
    final sections = <String?>[null, ...report.queryTypes];
    return Column(
      key: const ValueKey('evals-results'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in sections) ...[
          Text(
            section ?? 'Overall',
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                const DataColumn(label: Text('Config')),
                DataColumn(label: Text('Recall@${report.k}')),
                const DataColumn(label: Text('Hit rate')),
                const DataColumn(label: Text('Grounding')),
                const DataColumn(label: Text('Cases')),
              ],
              rows: [
                for (final config in report.configurations)
                  _rowFor(config, section),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  DataRow _rowFor(EvalConfigResults config, String? queryType) {
    final metrics = queryType == null
        ? config.overall
        : (config.byQueryType[queryType] ??
            const EvalGroupMetrics(caseCount: 0));
    String fmt(double value) => value.toStringAsFixed(3);
    return DataRow(
      cells: [
        DataCell(Text(config.config)),
        DataCell(Text(fmt(metrics.recallAtK))),
        DataCell(Text(fmt(metrics.hitRate))),
        DataCell(Text(
          metrics.groundingScore == null ? 'n/a' : fmt(metrics.groundingScore!),
        )),
        DataCell(Text('${metrics.caseCount}')),
      ],
    );
  }
}
