import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_workbench_table.dart';

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
  final bool workbenchMode;
  final String? selectedCveId;
  final ValueChanged<VulnFinding>? onAskFinding;
  final ValueChanged<VulnFinding>? onInspectPath;
  final VoidCallback? onOpenRepoXray;

  const VulnIntelPanel({
    super.key,
    required this.repoPathController,
    this.workbenchMode = false,
    this.selectedCveId,
    this.onAskFinding,
    this.onInspectPath,
    this.onOpenRepoXray,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final state = ref.watch(codeIntelViewModelProvider);
    final viewModel = ref.read(codeIntelViewModelProvider.notifier);
    final report = state.vulnReport;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          if (!workbenchMode) ...[
            const Text('Vulnerability Intel',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
          ],
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: repoPathController,
            builder: (context, repoValue, _) {
              final hasScanTarget =
                  repoValue.text.trim().isNotEmpty || state.sbomJson != null;
              final scanDisabled = state.scanningVuln ||
                  (workbenchMode && !hasScanTarget && report == null);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        style: workbenchMode
                            ? _workbenchSecondaryButtonStyle()
                            : null,
                        onPressed:
                            state.syncingVuln ? null : viewModel.syncVulnIntel,
                        icon: const Icon(Icons.sync, size: 15),
                        label: Text(
                            state.syncingVuln ? 'Syncing…' : 'Sync NVD & KEV'),
                      ),
                      ElevatedButton.icon(
                        style: workbenchMode
                            ? _workbenchPrimaryButtonStyle()
                            : null,
                        onPressed: scanDisabled
                            ? null
                            : () =>
                                viewModel.runVulnScan(repoPathController.text),
                        icon: const Icon(Icons.shield_outlined, size: 15),
                        label: Text(state.scanningVuln
                            ? 'Scanning…'
                            : 'Run Vulnerability Scan'),
                      ),
                      if (state.syncStatus != null)
                        Text(state.syncStatus!,
                            style:
                                TextStyle(color: ext.iconColor, fontSize: 13)),
                    ],
                  ),
                  if (workbenchMode && !hasScanTarget && report == null) ...[
                    const SizedBox(height: 8),
                    _buildEmptyScanHint(ext),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ElevatedButton.icon(
                style: workbenchMode ? _workbenchSecondaryButtonStyle() : null,
                onPressed: state.scanningVuln
                    ? null
                    : () async {
                        final picked = await FilePicker.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['json'],
                        );
                        if (picked.isEmpty) return;
                        final file = picked.first;
                        final bytes = await file.readAsBytes();
                        viewModel.setSbomFromText(
                          utf8.decode(bytes, allowMalformed: true),
                          fileName: file.name,
                        );
                      },
                icon: const Icon(Icons.upload_file_outlined, size: 15),
                label: const Text('Upload SBOM (CycloneDX/SPDX)'),
              ),
              if (!workbenchMode || report == null)
                _buildReachabilityToggle(state, viewModel),
              if (state.sbomFileName != null)
                Chip(
                  label: Text('SBOM: ${state.sbomFileName}'),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  onDeleted: viewModel.clearSbom,
                ),
            ],
          ),
          if (state.vulnError != null) ...[
            const SizedBox(height: 8),
            Text(state.vulnError!,
                style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 13)),
          ],
          if (report != null) ...[
            const SizedBox(height: 16),
            if (workbenchMode)
              _buildTriageFunnelStrip(report, state, viewModel)
            else
              Text(
                '${report.dependenciesChecked} dependencies checked · '
                '${report.matchedCount} matched · ${report.unknownCount} unknown · '
                '${report.kevCount} in CISA KEV',
                style: TextStyle(color: ext.iconColor, fontSize: 13),
              ),
            const SizedBox(height: 12),
            if (workbenchMode)
              _buildWorkbenchFilterPills(report, state, viewModel)
            else
              _buildLegacyFilterPills(state, viewModel),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, constraints) {
              final findings = _effectiveFindings(state);
              final useDesktopTable =
                  workbenchMode && constraints.maxWidth >= 640;
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: useDesktopTable
                    ? VulnWorkbenchTable(
                        key: ValueKey(
                          '${state.severityFilter}-${state.vulnQuickFilter}-${state.matchedOnly}-${findings.length}-table',
                        ),
                        findings: findings,
                        selectedCveId: selectedCveId,
                        onAskFinding: onAskFinding,
                        onInspectPath: onInspectPath,
                      )
                    : Column(
                        key: ValueKey(
                          '${state.severityFilter}-${state.vulnQuickFilter}-${state.matchedOnly}-${findings.length}-$workbenchMode-stacked',
                        ),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (findings.isEmpty)
                            Text('No findings match the current filters.',
                                style: TextStyle(
                                    color: ext.iconColor, fontSize: 12))
                          else
                            ...findings.map(
                                (finding) => _findingTile(context, finding)),
                        ],
                      ),
              );
            }),
          ],
        ],
      );

    if (workbenchMode) {
      return SizedBox(
        width: double.infinity,
        child: content,
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: ext.surfaceHighlight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ext.borderColorStrong),
      ),
      child: content,
    );
  }

  Widget _buildEmptyScanHint(AppThemeExtension ext) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(Icons.info_outline, size: 14, color: ext.iconColor),
        Text(
          'Select an indexed repo or upload an SBOM to scan',
          style: TextStyle(color: ext.iconColor, fontSize: 12),
        ),
        if (onOpenRepoXray != null)
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onOpenRepoXray,
            child: const Text(
              'Open Repo X-Ray',
              style: TextStyle(fontSize: 12, color: Color(0xFF34D399)),
            ),
          ),
      ],
    );
  }

  List<VulnFinding> _effectiveFindings(CodeIntelState state) {
    if (!workbenchMode || state.vulnQuickFilter != VulnQuickFilter.highEpss) {
      return state.filteredFindings;
    }
    final report = state.vulnReport;
    if (report == null) return const [];
    return report.findings.where((f) {
      if (state.severityFilter != 'ALL' &&
          (f.severity ?? '').toUpperCase() != state.severityFilter) {
        return false;
      }
      if (state.kevOnly && !f.kev) return false;
      if (state.matchedOnly && !f.isMatched) return false;
      return (f.epssScore ?? 0) >= 0.7;
    }).toList();
  }

  Widget _buildTriageFunnelStrip(
    VulnReport report,
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    final reachableCount = report.findings.where((f) => f.isReachable).length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2D2D32)),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'TRIAGE FUNNEL',
                style: TextStyle(
                  color: Color(0xFFA1A1AA),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 4),
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    color: Color(0xFFF4F4F5),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                  children: [
                    TextSpan(
                        text:
                            '${report.dependenciesChecked} dependencies  →  ${report.findings.length} known CVEs  →  ${report.kevCount} CISA KEV  →  '),
                    TextSpan(
                      text: '$reachableCount statically reachable',
                      style: const TextStyle(color: Color(0xFFFCA5A5)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${report.matchedCount} matched · ${report.unknownCount} unknown',
                style:
                    const TextStyle(color: Color(0xFF71717A), fontSize: 11.5),
              ),
            ],
          ),
          _buildReachabilityToggle(state, viewModel),
        ],
      ),
    );
  }

  ButtonStyle _workbenchSecondaryButtonStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF27272B),
      foregroundColor: const Color(0xFFE4E4E7),
      disabledBackgroundColor: const Color(0xFF1E1E22),
      disabledForegroundColor: const Color(0xFF71717A),
      elevation: 0,
      shadowColor: Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: const Size(0, 30),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(7),
        side: const BorderSide(color: Color(0xFF3A3A40), width: 0.8),
      ),
    ).copyWith(
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) {
          return const Color(0x14FFFFFF);
        }
        if (states.contains(WidgetState.pressed)) {
          return const Color(0x20FFFFFF);
        }
        return null;
      }),
    );
  }

  ButtonStyle _workbenchPrimaryButtonStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF1D4ED8),
      foregroundColor: Colors.white,
      disabledBackgroundColor: const Color(0xFF202229),
      disabledForegroundColor: const Color(0xFF71717A),
      elevation: 0,
      shadowColor: Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      minimumSize: const Size(0, 30),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(7),
      ),
    ).copyWith(
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return const BorderSide(color: Color(0xFF2E2F36), width: 0.8);
        }
        return BorderSide.none;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) {
          return const Color(0x1AFFFFFF);
        }
        if (states.contains(WidgetState.pressed)) {
          return const Color(0x28FFFFFF);
        }
        return null;
      }),
    );
  }

  Widget _buildReachabilityToggle(
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    if (!workbenchMode) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: state.includeReachability,
            onChanged: viewModel.setIncludeReachability,
          ),
          const Text('Include reachability',
              style: TextStyle(color: Colors.white, fontSize: 13)),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Include reachability',
          style: TextStyle(
            color: Color(0xFFD4D4D8),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 4),
        Transform.scale(
          scale: 0.78,
          child: Switch(
            value: state.includeReachability,
            onChanged: viewModel.setIncludeReachability,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            thumbColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? const Color(0xFF0B0F0E)
                    : const Color(0xFFA1A1AA)),
            trackColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? const Color(0xFF10B981)
                    : const Color(0xFF27272B)),
            trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? Colors.transparent
                    : const Color(0xFF3A3A40)),
          ),
        ),
      ],
    );
  }

  Widget _buildWorkbenchFilterPills(
    VulnReport report,
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    final reachableCount = report.findings.where((f) => f.isReachable).length;
    final highEpssCount =
        report.findings.where((f) => (f.epssScore ?? 0) >= 0.7).length;

    Widget pill({
      required String label,
      required String value,
      bool isKevPill = false,
    }) {
      final selected = state.vulnQuickFilter == value;
      final bg = isKevPill
          ? (selected ? const Color(0xFF522325) : const Color(0xFF3B1D1E))
          : (selected ? const Color(0xFF2A2A2F) : const Color(0xFF18181B));
      final border = isKevPill
          ? const Color(0xFF7F1D1D)
          : (selected ? const Color(0xFF52525B) : const Color(0xFF2F2F35));
      final textColor = isKevPill
          ? const Color(0xFFFCA5A5)
          : (selected ? Colors.white : const Color(0xFFA1A1AA));

      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => viewModel.setVulnQuickFilter(value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        pill(
          label: 'All Findings (${report.findings.length})',
          value: VulnQuickFilter.all,
        ),
        pill(
          label: 'CISA KEV (${report.kevCount})',
          value: VulnQuickFilter.kevOnly,
          isKevPill: true,
        ),
        pill(
          label: 'Reachable ($reachableCount)',
          value: VulnQuickFilter.reachable,
        ),
        pill(
          label: 'EPSS ≥ 0.7 ($highEpssCount)',
          value: VulnQuickFilter.highEpss,
        ),
      ],
    );
  }

  Widget _buildLegacyFilterPills(
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Filter:',
            style: TextStyle(color: Colors.white, fontSize: 12)),
        for (final quick in const [
          (VulnQuickFilter.all, 'All'),
          (VulnQuickFilter.kevOnly, 'KEV Only'),
          (VulnQuickFilter.highEpss, 'High EPSS ≥ 0.5'),
          (VulnQuickFilter.reachable, 'Reachable in Code'),
        ])
          ChoiceChip(
            label: Text(quick.$2),
            selected: state.vulnQuickFilter == quick.$1,
            onSelected: (_) => viewModel.setVulnQuickFilter(quick.$1),
          ),
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
          label: const Text('Matched only'),
          selected: state.matchedOnly,
          onSelected: viewModel.setMatchedOnly,
        ),
      ],
    );
  }

  Widget _findingTile(BuildContext context, VulnFinding finding) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final color = severityColor(finding.severity);
    final matched = finding.isMatched;
    final isSelected = selectedCveId != null && selectedCveId == finding.cveId;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF23252B) : ext.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? const Color(0xFF3F3F46)
              : (matched ? ext.borderColor : const Color(0xFFF59E0B)),
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
              if (finding.epssScore != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6D28D9),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    'EPSS ${(finding.epssScore! * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              if (finding.isReachable)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF164E63),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    'Reachable in Code · ${finding.reachableFileCount} '
                    '${finding.reachableFileCount == 1 ? 'file' : 'files'}',
                    style: const TextStyle(
                        color: Color(0xFFA5F3FC),
                        fontSize: 11,
                        fontWeight: FontWeight.w700),
                  ),
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
              if (onAskFinding != null || onInspectPath != null) ...[
                const SizedBox(width: 8),
                if (onAskFinding != null)
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onAskFinding!(finding),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF10B981)
                            : const Color(0xFF27272A),
                        borderRadius: BorderRadius.circular(6),
                        border: isSelected
                            ? null
                            : Border.all(
                                color: const Color(0xFF3F3F46), width: 0.8),
                      ),
                      child: Text(
                        'Ask',
                        style: TextStyle(
                          color: isSelected
                              ? const Color(0xFF0B0F0E)
                              : const Color(0xFFD4D4D8),
                          fontSize: 11.5,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                if (onInspectPath != null &&
                    (finding.isReachable || finding.reachableInCode.isNotEmpty))
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onInspectPath!(finding),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2E),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: const Color(0xFF3F3F46), width: 0.8),
                      ),
                      child: const Text(
                        'Path',
                        style: TextStyle(
                          color: Color(0xFFD4D4D8),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
              ],
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
          if (finding.reachableInCode.isNotEmpty) ...[
            const SizedBox(height: 6),
            Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Reachable from',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
                children: finding.reachableInCode
                    .map((hit) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            hit.path ?? hit.qualifiedName,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12),
                          ),
                          subtitle: Text(
                            hit.qualifiedName,
                            style: TextStyle(
                                color: ext.textTertiary, fontSize: 11),
                          ),
                        ))
                    .toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
