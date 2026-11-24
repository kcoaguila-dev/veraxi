import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_intel_panel.dart';

/// Right-hand Master-Detail inspector for a selected [VulnFinding].
///
/// Uses flat hairline-divided sections (`ObsidianTokens.hairline`) with no
/// nested cards, matching `docs/design/veraxi_security_workbench.svg`.
class VulnInspectorPane extends StatelessWidget {
  final VulnFinding finding;
  final void Function(VulnFinding finding, VulnCallSite? site)?
      onInspectCallSite;
  final ValueChanged<VulnFinding>? onAskFixInCodeThread;
  final void Function(VulnFinding finding, String reason)? onIgnoreFinding;
  final VoidCallback? onClose;

  const VulnInspectorPane({
    super.key,
    required this.finding,
    this.onInspectCallSite,
    this.onAskFixInCodeThread,
    this.onIgnoreFinding,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ObsidianTokens.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ObsidianTokens.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(),
          const Divider(color: ObsidianTokens.hairline, height: 1),
          _buildWhyPrioritySection(),
          const Divider(color: ObsidianTokens.hairline, height: 1),
          _buildRemediationSection(),
          const Divider(color: ObsidianTokens.hairline, height: 1),
          _buildReachabilityChainSection(),
          const Divider(color: ObsidianTokens.hairline, height: 1),
          _buildCallSitesSection(),
          const Divider(color: ObsidianTokens.hairline, height: 1),
          _buildFooterActions(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final sevColor = severityColor(finding.severity);
    final scoreColor = finding.compositeScore >= 70
        ? const Color(0xFFEF4444)
        : finding.compositeScore >= 40
            ? const Color(0xFFF59E0B)
            : const Color(0xFF34D399);

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (sevColor != null && finding.severity != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: sevColor,
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
              Expanded(
                child: Text(
                  finding.cveId,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scoreColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: scoreColor.withValues(alpha: 0.45),
                  ),
                ),
                child: Text(
                  'Score ${finding.compositeScore}',
                  style: TextStyle(
                    color: scoreColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onClose != null) ...[
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Close inspector',
                  icon: const Icon(Icons.close, size: 16),
                  color: const Color(0xFF9CA3AF),
                  onPressed: onClose,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${finding.package}${finding.version != null ? ' @ ${finding.version}' : ''}'
            '${finding.introducedVia != null ? ' · via ${finding.introducedVia}' : ''}',
            style: const TextStyle(
              color: Color(0xFF9CA3AF),
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWhyPrioritySection() {
    final reasons = finding.priorityReasons.isNotEmpty
        ? finding.priorityReasons
        : [
            if (finding.kev) 'Active in CISA KEV',
            if (finding.epssScore != null)
              'EPSS ${(finding.epssScore! * 100).toStringAsFixed(1)}%',
            if (finding.severity != null)
              '${finding.severity!.toUpperCase()} severity',
            if (!finding.isReachable) 'No reachable call sites detected yet',
          ];

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'WHY THIS PRIORITY',
            style: TextStyle(
              color: Color(0xFF71717A),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          for (final reason in reasons)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '• ',
                    style: TextStyle(color: Color(0xFF60A5FA), fontSize: 12),
                  ),
                  Expanded(
                    child: Text(
                      reason,
                      style: const TextStyle(
                        color: Color(0xFFE4E4E7),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRemediationSection() {
    final scopeLabel = finding.dependencyScope == 'direct'
        ? 'Direct dependency'
        : finding.dependencyScope == 'transitive'
            ? 'Transitive via ${finding.introducedVia ?? 'lockfile'}'
            : 'Manifest dependency';

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'REMEDIATION PATH',
            style: TextStyle(
              color: Color(0xFF71717A),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF064E3B),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'No break',
                  style: TextStyle(
                    color: Color(0xFF6EE7B7),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                finding.fixedVersion != null && finding.fixedVersion!.isNotEmpty
                    ? '→ Upgrade to ${finding.package} >= ${finding.fixedVersion}'
                    : 'Upgrade ${finding.package} to patched release',
                style: const TextStyle(
                  color: Color(0xFF34D399),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            scopeLabel,
            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildReachabilityChainSection() {
    final sites = finding.callSites;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'NEO4J REACHABILITY & ATTACK PATH',
            style: TextStyle(
              color: Color(0xFF71717A),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          if (sites.isEmpty)
            const Text(
              'No call chain found in Repo X-Ray graph.',
              style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
            )
          else
            _buildVerticalChain(sites.first),
        ],
      ),
    );
  }

  Widget _buildVerticalChain(VulnCallSite site) {
    final nodes = <String>[
      if (site.symbol.isNotEmpty) site.symbol,
      ...site.chain,
      finding.package,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < nodes.length; i++) ...[
          Row(
            children: [
              Icon(
                i == nodes.length - 1
                    ? Icons.bug_report_outlined
                    : Icons.circle,
                size: i == nodes.length - 1 ? 14 : 7,
                color: i == nodes.length - 1
                    ? const Color(0xFFF87171)
                    : const Color(0xFF60A5FA),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  nodes[i],
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: i == nodes.length - 1
                        ? const Color(0xFFFCA5A5)
                        : const Color(0xFFE4E4E7),
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          if (i < nodes.length - 1)
            const Padding(
              padding: EdgeInsets.only(left: 3, top: 2, bottom: 2),
              child: SizedBox(
                height: 10,
                child: VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: ObsidianTokens.borderStrong,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildCallSitesSection() {
    final sites = finding.callSites;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ALL CALL SITES (${sites.length})',
            style: const TextStyle(
              color: Color(0xFF71717A),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          if (sites.isEmpty)
            const Text(
              'Enable Repo X-Ray reachability to inspect call sites.',
              style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
            )
          else
            for (final site in sites.take(6))
              InkWell(
                onTap: onInspectCallSite == null
                    ? null
                    : () => onInspectCallSite!(finding, site),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.code,
                        size: 13,
                        color: Color(0xFF60A5FA),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${site.file}${site.line != null ? ':${site.line}' : ''}'
                          '${site.symbol.isNotEmpty ? ' · ${site.symbol}' : ''}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF93C5FD),
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.open_in_new,
                        size: 12,
                        color: Color(0xFF71717A),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildFooterActions() {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PopupMenuButton<String>(
            tooltip: 'Ignore or snooze finding',
            onSelected: onIgnoreFinding == null
                ? null
                : (reason) => onIgnoreFinding!(finding, reason),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'false_positive',
                child: Text('Ignore · False positive'),
              ),
              PopupMenuItem(
                value: 'not_reachable',
                child: Text('Ignore · Not reachable'),
              ),
              PopupMenuItem(
                value: 'snooze_30d',
                child: Text('Snooze 30 days'),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1C22),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: ObsidianTokens.borderStrong),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Ignore / Snooze',
                    style: TextStyle(
                      color: Color(0xFFD4D4D8),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(width: 4),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 16,
                    color: Color(0xFF9CA3AF),
                  ),
                ],
              ),
            ),
          ),
          ElevatedButton(
            style: workbenchPrimaryButtonStyle(),
            onPressed: onAskFixInCodeThread == null
                ? null
                : () => onAskFixInCodeThread!(finding),
            child: const Text('Ask Veraxi to Fix in Code Thread →'),
          ),
        ],
      ),
    );
  }
}
