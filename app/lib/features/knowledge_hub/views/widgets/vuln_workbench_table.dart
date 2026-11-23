import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_intel_panel.dart';

/// Desktop data table for Code Mode Vulnerability Intel findings.
///
/// Design contract: docs/design/veraxi_code_workbench.svg.
class VulnWorkbenchTable extends StatelessWidget {
  final List<VulnFinding> findings;
  final String? selectedCveId;
  final ValueChanged<VulnFinding>? onAskFinding;
  final ValueChanged<VulnFinding>? onInspectPath;

  const VulnWorkbenchTable({
    super.key,
    required this.findings,
    this.selectedCveId,
    this.onAskFinding,
    this.onInspectPath,
  });

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2D2D32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTableColumnHeader(),
          if (findings.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'No findings match the current filters.',
                style: TextStyle(color: ext.iconColor, fontSize: 12),
              ),
            )
          else
            for (int i = 0; i < findings.length; i++) ...[
              if (i > 0) const Divider(color: Color(0xFF242428), height: 1),
              _buildWorkbenchTableRow(
                findings[i],
                ext,
                isSelected:
                    selectedCveId != null && selectedCveId == findings[i].cveId,
              ),
            ],
        ],
      ),
    );
  }

  Widget _buildTableColumnHeader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return const SizedBox.shrink();
        }
        const style = TextStyle(
          color: Color(0xFF71717A),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Color(0xFF2B2B30), width: 1),
            ),
          ),
          child: const Row(
            children: [
              Expanded(flex: 4, child: Text('CVE / PACKAGE', style: style)),
              SizedBox(width: 8),
              Expanded(flex: 2, child: Text('KEV / EPSS', style: style)),
              SizedBox(width: 8),
              Expanded(flex: 3, child: Text('REACHABILITY', style: style)),
              SizedBox(width: 8),
              Expanded(flex: 2, child: Text('WEAKNESS', style: style)),
              SizedBox(
                width: 104,
                child: Text('ACTIONS', style: style, textAlign: TextAlign.end),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWorkbenchTableRow(
    VulnFinding finding,
    AppThemeExtension ext, {
    required bool isSelected,
  }) {
    return InkWell(
      onTap: onAskFinding == null ? null : () => onAskFinding!(finding),
      child: Container(
        color: isSelected ? const Color(0xFF23252B) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(flex: 4, child: _buildCvePackageColumn(finding)),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: _buildKevEpssColumn(finding)),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: _buildReachabilityColumn(finding)),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: _buildWeaknessColumn(finding, ext)),
            SizedBox(
              width: 104,
              child: _buildActionsColumn(finding, isSelected: isSelected),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCvePackageColumn(VulnFinding finding) {
    final color = severityColor(finding.severity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (color != null && finding.severity != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  finding.severity!.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                finding.cveId,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${finding.package}${finding.version != null ? ' ${finding.version}' : ''}',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFFA1A1AA),
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }

  Widget _buildKevEpssColumn(VulnFinding finding) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        if (finding.kev)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF8B7CF6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'KEV',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (finding.epssScore != null) ...[
          Builder(builder: (context) {
            final epss = epssBadgeColors(finding.epssScore!);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: epss.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: epss.border, width: 0.8),
              ),
              child: Text(
                'EPSS ${(finding.epssScore! * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  color: epss.text,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            );
          }),
        ],
        if (!finding.kev && finding.epssScore == null)
          const Text(
            '—',
            style: TextStyle(color: Color(0xFF71717A), fontSize: 12),
          ),
      ],
    );
  }

  Widget _buildWeaknessColumn(VulnFinding finding, AppThemeExtension ext) {
    final matched = finding.isMatched;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (finding.cweIds.isNotEmpty)
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: finding.cweIds
                .take(2)
                .map((cwe) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: ext.borderColorStrong,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        cwe,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                      ),
                    ))
                .toList(),
          ),
        const SizedBox(height: 3),
        Text(
          matched ? 'Matched' : 'Unknown',
          style: TextStyle(
            color: matched ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildActionsColumn(
    VulnFinding finding, {
    required bool isSelected,
  }) {
    final hasReachable =
        finding.isReachable || finding.reachableInCode.isNotEmpty;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 6,
      runSpacing: 4,
      children: [
        if (onAskFinding != null)
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => onAskFinding!(finding),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF10B981)
                    : const Color(0xFF27272A),
                borderRadius: BorderRadius.circular(6),
                border: isSelected
                    ? null
                    : Border.all(color: const Color(0xFF3F3F46), width: 0.8),
              ),
              child: Text(
                'Ask',
                style: TextStyle(
                  color: isSelected
                      ? const Color(0xFF0B0F0E)
                      : const Color(0xFFD4D4D8),
                  fontSize: 11.5,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        if (onInspectPath != null && hasReachable)
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => onInspectPath!(finding),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF3F3F46), width: 0.8),
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
    );
  }

  Widget _buildReachabilityColumn(VulnFinding finding) {
    if (!finding.isReachable && finding.reachableInCode.isEmpty) {
      return const Text(
        'Not reachable',
        style: TextStyle(color: Color(0xFF71717A), fontSize: 11.5),
      );
    }

    final hops = finding.reachableInCode.isNotEmpty
        ? finding.reachableInCode.length
        : finding.reachableFileCount;
    final topHop = finding.reachableInCode.isNotEmpty
        ? '${finding.package} → ${finding.reachableInCode.first.qualifiedName}'
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF064E3B),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'Static Path ($hops ${hops == 1 ? 'hop' : 'hops'})',
            style: const TextStyle(
              color: Color(0xFF34D399),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (topHop != null) ...[
          const SizedBox(height: 3),
          Text(
            topHop,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: const TextStyle(color: Color(0xFFA1A1AA), fontSize: 11),
          ),
        ],
      ],
    );
  }
}
