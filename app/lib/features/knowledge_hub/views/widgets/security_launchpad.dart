import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';

/// Sections of the unified Security workspace (Phase 6).
///
/// [cves] is the Vuln Intel workbench itself; the other four sections
/// map 1:1 onto the tabs of the embedded Security Feed panel
/// (SAST=0, Recon=1, ATT&CK=2, SOC=3).
enum SecuritySection { cves, sast, recon, attack, soc }

/// Security Feed tab index for a non-CVE [SecuritySection], or null
/// for [SecuritySection.cves] (which has no feed tab).
int? securityFeedTabForSection(SecuritySection section) {
  return switch (section) {
    SecuritySection.cves => null,
    SecuritySection.sast => 0,
    SecuritySection.recon => 1,
    SecuritySection.attack => 2,
    SecuritySection.soc => 3,
  };
}

/// Pure query filter for vulnerability findings (Phase 6).
///
/// The query is split on whitespace; every token must match (AND).
/// Supported structured tokens:
///   * `is:reachable` — only findings reachable in code
///   * `is:kev` — only CISA KEV findings
///   * `severity:critical|high|medium|low` (case-insensitive)
///   * `epss:>0.7`, `epss:>=0.7`, `epss:<0.3`, `epss:<=0.3`,
///     `epss:=0.5`, or a bare `epss:0.7` (treated as `>=`)
/// Any other token (including a malformed structured token) is free
/// text matched case-insensitively against the CVE id, package,
/// version, ecosystem, source file, severity and CWE ids.
/// An empty/blank query returns [findings] unchanged. No widget or
/// provider dependencies — unit-testable in isolation.
List<VulnFinding> filterFindingsByQuery(
  List<VulnFinding> findings,
  String query,
) {
  final tokens =
      query.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (tokens.isEmpty) return List<VulnFinding>.of(findings);
  return findings
      .where((f) => tokens.every((t) => _matchesToken(f, t)))
      .toList();
}

bool _matchesToken(VulnFinding finding, String rawToken) {
  final token = rawToken.toLowerCase();
  if (token == 'is:reachable') return finding.isReachable;
  if (token == 'is:kev') return finding.kev;
  if (token.startsWith('severity:')) {
    final wanted = token.substring('severity:'.length);
    const known = {'critical', 'high', 'medium', 'low'};
    if (known.contains(wanted)) {
      return (finding.severity ?? '').toLowerCase() == wanted;
    }
    // Unknown severity value falls through to free-text matching.
  }
  if (token.startsWith('epss:')) {
    final matched = _matchesEpss(finding, token.substring('epss:'.length));
    if (matched != null) return matched;
    // Unparseable comparison falls through to free-text matching.
  }
  return _findingHaystack(finding).contains(token);
}

/// Returns null when [expr] is not a parseable EPSS comparison, so the
/// caller can fall back to free-text matching for that token.
bool? _matchesEpss(VulnFinding finding, String expr) {
  var op = '>=';
  var rest = expr;
  for (final candidate in const ['>=', '<=', '>', '<', '=']) {
    if (rest.startsWith(candidate)) {
      op = candidate;
      rest = rest.substring(candidate.length);
      break;
    }
  }
  final threshold = double.tryParse(rest);
  if (threshold == null) return null;
  final score = finding.epssScore;
  if (score == null) return false;
  return switch (op) {
    '>' => score > threshold,
    '>=' => score >= threshold,
    '<' => score < threshold,
    '<=' => score <= threshold,
    _ => score == threshold,
  };
}

String _findingHaystack(VulnFinding finding) {
  return [
    finding.cveId,
    finding.package,
    finding.version ?? '',
    finding.ecosystem ?? '',
    finding.sourceFile ?? '',
    finding.severity ?? '',
    finding.matchStatus,
    ...finding.cweIds,
  ].join(' ').toLowerCase();
}

/// Tab strip for the unified Security workspace.
class SecuritySectionTabs extends StatelessWidget {
  final SecuritySection selected;
  final ValueChanged<SecuritySection> onChanged;

  const SecuritySectionTabs({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  static const List<(SecuritySection, String)> tabs = [
    (SecuritySection.cves, 'CVEs & Reachability'),
    (SecuritySection.sast, 'SAST · SARIF'),
    (SecuritySection.recon, 'Recon · Nuclei'),
    (SecuritySection.attack, 'ATT&CK · STIX'),
    (SecuritySection.soc, 'SOC Alerts'),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (section, label) in tabs)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onChanged(section),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: section == selected
                    ? ObsidianTokens.card
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: section == selected
                      ? ObsidianTokens.borderStrong
                      : ObsidianTokens.hairline,
                  width: 0.8,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: section == selected
                      ? Colors.white
                      : const Color(0xFFA1A1AA),
                  fontSize: 12.5,
                  fontWeight:
                      section == selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Query bar driving [filterFindingsByQuery] over the workbench table.
class SecurityQueryBar extends StatefulWidget {
  final ValueChanged<String> onChanged;
  final int? resultCount;
  final String? initialValue;

  const SecurityQueryBar({
    super.key,
    required this.onChanged,
    this.resultCount,
    this.initialValue,
  });

  @override
  State<SecurityQueryBar> createState() => _SecurityQueryBarState();
}

class _SecurityQueryBarState extends State<SecurityQueryBar> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            onChanged: widget.onChanged,
            style: const TextStyle(color: Color(0xFFF4F4F5), fontSize: 12.5),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon:
                  const Icon(Icons.search, size: 16, color: Color(0xFF71717A)),
              hintText:
                  'Filter findings — is:reachable  is:kev  severity:critical  epss:>0.7  or free text',
              hintStyle:
                  const TextStyle(color: Color(0xFF71717A), fontSize: 12),
              filled: true,
              fillColor: ObsidianTokens.card,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: ObsidianTokens.hairline),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    const BorderSide(color: ObsidianTokens.borderStrong),
              ),
            ),
          ),
        ),
        if (widget.resultCount != null) ...[
          const SizedBox(width: 10),
          Text(
            '${widget.resultCount} matching',
            style: const TextStyle(color: Color(0xFFA1A1AA), fontSize: 11.5),
          ),
        ],
      ],
    );
  }
}

/// Empty state for the unified Security workspace: no scan has run
/// yet, so instead of a dead void this offers an inline Repo Path
/// field with an Index & Scan action (wired to the existing
/// `indexRepo` + `runVulnScan` view-model actions) and a 2x2 grid of
/// quick-start cards, each opening the Security section whose real
/// ingest/sync action it describes.
class SecurityLaunchpad extends ConsumerWidget {
  final TextEditingController repoPathController;
  final ValueChanged<SecuritySection> onSelectSection;

  const SecurityLaunchpad({
    super.key,
    required this.repoPathController,
    required this.onSelectSection,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(codeIntelViewModelProvider);
    final viewModel = ref.read(codeIntelViewModelProvider.notifier);
    final busy = state.indexing || state.scanningVuln;

    Future<void> indexAndScan() async {
      final path = repoPathController.text.trim();
      if (busy || path.isEmpty) return;
      await viewModel.indexRepo(path);
      if (ref.read(codeIntelViewModelProvider).indexError == null) {
        await viewModel.runVulnScan(path);
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: ObsidianTokens.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ObsidianTokens.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Security Launchpad',
            style: TextStyle(
              color: Color(0xFFF4F4F5),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Index a repository and scan it, or jump straight to a feed ingest below.',
            style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: repoPathController,
                  style:
                      const TextStyle(color: Color(0xFFF4F4F5), fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Repo Path — /path/to/repo',
                    hintStyle: const TextStyle(
                        color: Color(0xFF71717A), fontSize: 12.5),
                    filled: true,
                    fillColor: ObsidianTokens.recessedCanvas,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: ObsidianTokens.hairline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: ObsidianTokens.borderStrong),
                    ),
                  ),
                  onSubmitted: (_) => indexAndScan(),
                ),
              ),
              const SizedBox(width: 10),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: repoPathController,
                builder: (context, value, _) {
                  final hasPath = value.text.trim().isNotEmpty;
                  return ElevatedButton.icon(
                    onPressed: (busy || !hasPath) ? null : indexAndScan,
                    icon: const Icon(Icons.shield_outlined, size: 15),
                    label: Text(busy ? 'Working…' : 'Index & Scan'),
                  );
                },
              ),
            ],
          ),
          if (state.indexError != null) ...[
            const SizedBox(height: 8),
            Text(state.indexError!,
                style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 12)),
          ],
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final cards = <Widget>[
                _quickStartCard(
                  icon: Icons.bug_report_outlined,
                  title: 'SAST · SARIF',
                  body: 'Upload a SARIF 2.1.0 report and inspect taint paths.',
                  onTap: () => onSelectSection(SecuritySection.sast),
                ),
                _quickStartCard(
                  icon: Icons.radar_outlined,
                  title: 'Recon · Nuclei',
                  body: 'Ingest Nuclei JSON/JSONL scan output.',
                  onTap: () => onSelectSection(SecuritySection.recon),
                ),
                _quickStartCard(
                  icon: Icons.hub_outlined,
                  title: 'ATT&CK · STIX',
                  body: 'Sync MITRE ATT&CK or upload a STIX bundle.',
                  onTap: () => onSelectSection(SecuritySection.attack),
                ),
                _quickStartCard(
                  icon: Icons.notifications_active_outlined,
                  title: 'SOC Alerts',
                  body: 'Ingest alerts and IOCs for triage.',
                  onTap: () => onSelectSection(SecuritySection.soc),
                ),
              ];
              if (constraints.maxWidth < 640) {
                return Column(
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(height: 10),
                      cards[i],
                    ],
                  ],
                );
              }
              return Column(
                children: [
                  Row(children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: 10),
                    Expanded(child: cards[1]),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: cards[2]),
                    const SizedBox(width: 10),
                    Expanded(child: cards[3]),
                  ]),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _quickStartCard({
    required IconData icon,
    required String title,
    required String body,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: ObsidianTokens.recessedCanvas,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ObsidianTokens.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF34D399)),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFFF4F4F5),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              body,
              style: const TextStyle(color: Color(0xFFA1A1AA), fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }
}
