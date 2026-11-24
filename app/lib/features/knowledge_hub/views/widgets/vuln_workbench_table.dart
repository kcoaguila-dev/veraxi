import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_intel_panel.dart';

/// Desktop data table for Code Mode Vulnerability Intel findings.
///
/// Design contract: docs/design/veraxi_code_workbench.svg.
class VulnWorkbenchTable extends StatelessWidget {
  final List<VulnFinding> findings;
  final String? selectedCveId;
  final String? selectedFindingId;
  final ValueChanged<VulnFinding>? onSelectFinding;
  final ValueChanged<VulnFinding>? onAskFinding;
  final ValueChanged<VulnFinding>? onInspectPath;
  final int hiddenUnreachableCount;
  final int totalFindingsCount;
  final VoidCallback? onShowAll;

  const VulnWorkbenchTable({
    super.key,
    required this.findings,
    this.selectedCveId,
    this.selectedFindingId,
    this.onSelectFinding,
    this.onAskFinding,
    this.onInspectPath,
    this.hiddenUnreachableCount = 0,
    this.totalFindingsCount = 0,
    this.onShowAll,
  });

  List<({String package, List<VulnFinding> items})> _groupByPackage() {
    final order = <String>[];
    final grouped = <String, List<VulnFinding>>{};
    for (final f in findings) {
      final key = f.package.isEmpty ? 'unknown' : f.package;
      if (!grouped.containsKey(key)) {
        order.add(key);
        grouped[key] = [];
      }
      grouped[key]!.add(f);
    }
    return [for (final k in order) (package: k, items: grouped[k]!)];
  }

  bool _isRowSelected(VulnFinding finding) {
    if (selectedFindingId != null) {
      return selectedFindingId == finding.findingId;
    }
    return selectedCveId != null && selectedCveId == finding.cveId;
  }

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final groups = _groupByPackage();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: ObsidianTokens.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ObsidianTokens.hairline),
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
            for (final group in groups) ...[
              _buildPackageGroupHeader(group.package, group.items),
              for (int i = 0; i < group.items.length; i++) ...[
                if (i > 0)
                  const Divider(color: ObsidianTokens.hairline, height: 1),
                _buildWorkbenchTableRow(
                  group.items[i],
                  ext,
                  isSelected: _isRowSelected(group.items[i]),
                ),
              ],
            ],
          if (hiddenUnreachableCount > 0 && onShowAll != null)
            _buildHiddenFooter(),
        ],
      ),
    );
  }

  Widget _buildPackageGroupHeader(String package, List<VulnFinding> items) {
    final first = items.first;
    final scope = first.dependencyScope;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF0E1014),
        border: Border(
          top: BorderSide(color: ObsidianTokens.hairline, width: 1),
          bottom: BorderSide(color: ObsidianTokens.hairline, width: 1),
        ),
      ),
      child: Row(
        children: [
          Text(
            package,
            style: const TextStyle(
              color: Color(0xFFE4E4E7),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
          if (first.version != null) ...[
            const SizedBox(width: 6),
            Text(
              first.version!,
              style: const TextStyle(
                color: Color(0xFF71717A),
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ],
          const SizedBox(width: 8),
          _buildScopePill(scope),
          const Spacer(),
          Text(
            '${items.length} ${items.length == 1 ? 'finding' : 'findings'}',
            style: const TextStyle(color: Color(0xFF71717A), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildScopePill(String scope) {
    final isDirect = scope == 'direct';
    final isTransitive = scope == 'transitive';
    if (!isDirect && !isTransitive) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: isDirect ? const Color(0xFF172554) : const Color(0xFF1F2028),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDirect ? const Color(0xFF1D4ED8) : const Color(0xFF323442),
          width: 0.7,
        ),
      ),
      child: Text(
        isDirect ? 'Direct' : 'Transitive',
        style: TextStyle(
          color: isDirect ? const Color(0xFF93C5FD) : const Color(0xFFA1A1AA),
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildHiddenFooter() {
    final total = totalFindingsCount > 0
        ? totalFindingsCount
        : findings.length + hiddenUnreachableCount;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: ObsidianTokens.hairline, width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$hiddenUnreachableCount unreachable transitive findings hidden',
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onShowAll,
            child: Text(
              'Show all $total →',
              style: const TextStyle(
                color: Color(0xFF60A5FA),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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
              bottom: BorderSide(color: ObsidianTokens.hairline, width: 1),
            ),
          ),
          child: const Row(
            children: [
              SizedBox(width: 82, child: Text('SEVERITY', style: style)),
              SizedBox(width: 8),
              Expanded(flex: 4, child: Text('PACKAGE / DEPENDENCY', style: style)),
              SizedBox(width: 8),
              Expanded(flex: 3, child: Text('SIGNALS', style: style)),
              SizedBox(width: 8),
              SizedBox(
                width: 96,
                child: Text('FIX', style: style, textAlign: TextAlign.end),
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
    final tapHandler = onSelectFinding ?? onAskFinding;
    return InkWell(
      onTap: tapHandler == null ? null : () => tapHandler(finding),
      child: Container(
        margin: isSelected
            ? const EdgeInsets.symmetric(horizontal: 6, vertical: 3)
            : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: isSelected ? ObsidianTokens.bubble : Colors.transparent,
          borderRadius: isSelected ? BorderRadius.circular(8) : null,
          border: isSelected
              ? Border.all(color: ObsidianTokens.borderStrong, width: 1)
              : null,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: isSelected ? 10 : 14,
          vertical: 12,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 82, child: _buildSeverityBadge(finding)),
            const SizedBox(width: 8),
            Expanded(flex: 4, child: _buildPackageDependencyColumn(finding)),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: _buildSignalsColumn(finding)),
            const SizedBox(width: 8),
            SizedBox(width: 96, child: _buildFixColumn(finding)),
          ],
        ),
      ),
    );
  }

  Widget _buildSeverityBadge(VulnFinding finding) {
    final color = severityColor(finding.severity);
    final label = !finding.isMatched
        ? 'UNKNOWN'
        : (finding.severity ?? 'UNKNOWN').toUpperCase();
    final bg = !finding.isMatched
        ? const Color(0xFF181A20)
        : (color ?? const Color(0xFF27272A));
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: !finding.isMatched
              ? Border.all(color: const Color(0xFFF59E0B), width: 0.8)
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: !finding.isMatched ? const Color(0xFFFBBF24) : Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildPackageDependencyColumn(VulnFinding finding) {
    final topSite = finding.callSites.isNotEmpty ? finding.callSites.first : null;
    final cwe = finding.cweIds.isNotEmpty ? ' · ${finding.cweIds.first}' : '';
    final via = finding.dependencyScope == 'transitive' &&
            finding.introducedVia != null
        ? ' · via ${finding.introducedVia}'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${finding.package}${finding.version != null ? ' ${finding.version}' : ''}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            _buildScopePill(finding.dependencyScope),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          '${finding.cveId}$cwe$via',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFFA1A1AA),
            fontSize: 11.5,
            fontFamily: 'monospace',
          ),
        ),
        if (topSite != null && topSite.file.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            '${topSite.file}${topSite.line != null ? ':${topSite.line}' : ''}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF71717A),
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSignalsColumn(VulnFinding finding) {
    final hops = finding.callSites.isNotEmpty
        ? finding.callSites.length
        : (finding.reachableInCode.isNotEmpty
            ? finding.reachableInCode.length
            : finding.reachableFileCount);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        if (finding.kev)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF4C1D95),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF7C3AED), width: 0.8),
            ),
            child: const Text(
              'KEV',
              style: TextStyle(
                color: Color(0xFFEDE9FE),
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: finding.isReachable
                ? const Color(0xFF083344)
                : const Color(0xFF181A20),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: finding.isReachable
                  ? const Color(0xFF0E7490)
                  : ObsidianTokens.borderStrong,
              width: 0.8,
            ),
          ),
          child: Text(
            finding.isReachable
                ? 'Reachable · $hops ${hops == 1 ? 'path' : 'paths'}'
                : 'Unreachable',
            style: TextStyle(
              color: finding.isReachable
                  ? const Color(0xFF67E8F9)
                  : const Color(0xFF71717A),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFixColumn(VulnFinding finding) {
    final fixed = finding.fixedVersion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          fixed != null && fixed.isNotEmpty ? '≥ $fixed' : 'Unpinned',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: fixed != null && fixed.isNotEmpty
                ? const Color(0xFF34D399)
                : const Color(0xFF71717A),
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'Score ${finding.compositeScore}',
          style: const TextStyle(color: Color(0xFF71717A), fontSize: 10.5),
        ),
      ],
    );
  }

}
