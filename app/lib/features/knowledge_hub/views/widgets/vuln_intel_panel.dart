import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';

/// Severity badge colors. Unknown/absent severity renders no badge.
Color? severityColor(String? severity) {
  switch ((severity ?? '').toUpperCase()) {
    case 'CRITICAL':
      return const Color(0xFFDC2626);
    case 'HIGH':
      return const Color(0xFFEA580C);
    case 'MEDIUM':
      return const Color(0xFFF59E0B);
    case 'LOW':
      return const Color(0xFF71717A);
    default:
      return null;
  }
}

/// Vuln Intel panel: sync NVD & CISA KEV, scan a repo's dependencies,
/// and filter findings by severity / KEV / match status.
///
/// Design contract: docs/design/vuln_intel_panel.svg. 'matched'
/// findings (version provably in range) and 'unknown' findings
/// (version/range unparseable) are visually distinct — unknown is
/// outlined amber and never presented as confirmed vulnerable.
class VulnIntelPanel extends ConsumerWidget {
  final TextEditingController repoPathController;

  const VulnIntelPanel({super.key, required this.repoPathController});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final state = ref.watch(codeIntelViewModelProvider);
    final viewModel = ref.read(codeIntelViewModelProvider.notifier);
    final report = state.vulnReport;

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
          const Text('Vulnerability Intel',
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
                onPressed: state.syncingVuln ? null : viewModel.syncVulnIntel,
                icon: const Icon(Icons.sync, size: 16),
                label: Text(state.syncingVuln ? 'Syncing…' : 'Sync NVD & KEV'),
              ),
              ElevatedButton.icon(
                onPressed: state.scanningVuln
                    ? null
                    : () => viewModel.runVulnScan(repoPathController.text),
                icon: const Icon(Icons.shield_outlined, size: 16),
                label: Text(state.scanningVuln
                    ? 'Scanning…'
                    : 'Run Vulnerability Scan'),
              ),
              if (state.syncStatus != null)
                Text(state.syncStatus!,
                    style: TextStyle(color: ext.iconColor, fontSize: 13)),
            ],
          ),
          if (state.vulnError != null) ...[
            const SizedBox(height: 8),
            Text(state.vulnError!,
                style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 13)),
          ],
          if (report != null) ...[
            const SizedBox(height: 16),
            Text(
              '${report.dependenciesChecked} dependencies checked · '
              '${report.matchedCount} matched · ${report.unknownCount} unknown · '
              '${report.kevCount} in CISA KEV',
              style: TextStyle(color: ext.iconColor, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Filter:',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
                for (final severity in const [
                  'ALL',
                  'CRITICAL',
                  'HIGH',
                  'MEDIUM',
                  'LOW',
                ])
                  ChoiceChip(
                    label: Text(severity),
                    selected: state.severityFilter == severity,
                    onSelected: (_) => viewModel.setSeverityFilter(severity),
                  ),
                FilterChip(
                  label: const Text('KEV only'),
                  selected: state.kevOnly,
                  onSelected: viewModel.setKevOnly,
                ),
                FilterChip(
                  label: const Text('Matched only'),
                  selected: state.matchedOnly,
                  onSelected: viewModel.setMatchedOnly,
                ),
              ],
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              child: Column(
                key: ValueKey(
                  '${state.severityFilter}-${state.kevOnly}-${state.matchedOnly}-${state.filteredFindings.length}',
                ),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (state.filteredFindings.isEmpty)
                    Text('No findings match the current filters.',
                        style: TextStyle(color: ext.iconColor, fontSize: 12))
                  else
                    ...state.filteredFindings
                        .map((finding) => _findingTile(context, finding)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _findingTile(BuildContext context, VulnFinding finding) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final color = severityColor(finding.severity);
    final matched = finding.isMatched;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: matched ? ext.borderColor : const Color(0xFFF59E0B),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (color != null && finding.severity != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    finding.severity!.toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              if (finding.kev)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B7CF6),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Text('KEV',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              Text(
                '${finding.package}${finding.version != null ? ' ${finding.version}' : ''} — ${finding.cveId}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
              Text(
                matched ? 'Matched' : 'Unknown — version/range unparseable',
                style: TextStyle(
                  color: matched
                      ? const Color(0xFF22C55E)
                      : const Color(0xFFF59E0B),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (finding.cweIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: finding.cweIds
                  .map((cwe) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: ext.borderColorStrong,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(cwe,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10)),
                      ))
                  .toList(),
            ),
          ],
          if (finding.sourceFile != null) ...[
            const SizedBox(height: 6),
            Text(finding.sourceFile!,
                style: TextStyle(color: ext.textTertiary, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}
