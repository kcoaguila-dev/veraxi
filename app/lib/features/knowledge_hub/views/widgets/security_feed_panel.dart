import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';

/// Unified Security Feed panel: SAST (SARIF), Recon (Nuclei),
/// ATT&CK (STIX sync) and SOC (alerts/IOCs) ingestion in one place,
/// instead of four siloed queues.
///
/// Design contract: docs/design/security_feed_panel.svg. Each tab has
/// one primary action, shows the real counts the backend returns, and
/// renders failures as an amber error line — never as success. The
/// SAST tab also renders taint breadcrumbs (source → sink) extracted
/// from the uploaded SARIF codeFlows.
class SecurityFeedPanel extends ConsumerStatefulWidget {
  /// When true, renders without the outer card chrome or the
  /// 'Security Feed' title — used inside the unified Security
  /// workspace (Phase 6), where the section tabs own the header.
  final bool embedded;

  /// Tab shown first (0=SAST, 1=Recon, 2=ATT&CK, 3=SOC). In embedded
  /// mode a changed value re-selects the tab, so the unified
  /// workspace can drive the panel from its section tabs.
  final int initialTab;

  final VoidCallback? onConnectRepo;

  const SecurityFeedPanel({
    super.key,
    this.embedded = false,
    this.initialTab = 0,
    this.onConnectRepo,
  });

  @override
  ConsumerState<SecurityFeedPanel> createState() => _SecurityFeedPanelState();
}

class _SecurityFeedPanelState extends ConsumerState<SecurityFeedPanel> {
  late int _tab = widget.initialTab.clamp(0, 3);

  @override
  void didUpdateWidget(covariant SecurityFeedPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab) {
      _tab = widget.initialTab.clamp(0, 3);
    }
  }

  static const _tabs = ['SAST', 'Recon', 'ATT&CK', 'SOC'];

  Future<String?> _pickText(List<String> extensions) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    if (picked.isEmpty) return null;
    final bytes = await picked.first.readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final state = ref.watch(codeIntelViewModelProvider);
    final viewModel = ref.read(codeIntelViewModelProvider.notifier);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.embedded) ...[
          const Text('Security Feed',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _tabs.length; i++)
                ChoiceChip(
                  label: Text(_tabs[i]),
                  selected: _tab == i,
                  onSelected: (_) => setState(() => _tab = i),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          child: KeyedSubtree(
            key: ValueKey(_tab),
            child: switch (_tab) {
              0 => _sastTab(ext, state, viewModel),
              1 => _reconTab(ext, state, viewModel),
              2 => _attackTab(ext, state, viewModel),
              _ => _socTab(ext, state, viewModel),
            },
          ),
        ),
      ],
    );

    if (widget.embedded) return SizedBox(width: double.infinity, child: body);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: ext.surfaceHighlight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ext.borderColorStrong),
      ),
      child: body,
    );
  }

  Widget _statusLines(String? status, String? error, AppThemeExtension ext) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status != null) ...[
          const SizedBox(height: 8),
          Text(status, style: TextStyle(color: ext.iconColor, fontSize: 13)),
        ],
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error,
              style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 13)),
        ],
      ],
    );
  }

  Widget _buildEmptyDropzone({
    required IconData icon,
    required String title,
    required String subtitle,
    required String primaryLabel,
    required VoidCallback? onPrimary,
    String? secondaryLabel,
    VoidCallback? onSecondary,
    required String cliSnippet,
    required String supportedTools,
    String? status,
    String? error,
    required AppThemeExtension ext,
  }) {
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: ObsidianTokens.borderStrong,
        radius: 12,
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: ObsidianTokens.card,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: ObsidianTokens.bubble,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: ObsidianTokens.hairline),
              ),
              child: Icon(icon, size: 20, color: const Color(0xFF60A5FA)),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF9CA3AF),
                  fontSize: 12.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1D4ED8),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  onPressed: onPrimary,
                  icon: Icon(icon, size: 15),
                  label: Text(primaryLabel),
                ),
                if (secondaryLabel != null && onSecondary != null)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE4E4E7),
                      side: const BorderSide(
                        color: ObsidianTokens.borderStrong,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                    onPressed: onSecondary,
                    child: Text(secondaryLabel),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: ObsidianTokens.recessedCanvas,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ObsidianTokens.hairline),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      cliSnippet,
                      style: const TextStyle(
                        color: Color(0xFFD4D4D8),
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Copy CLI command',
                    icon: const Icon(Icons.copy_outlined, size: 14),
                    color: const Color(0xFF9CA3AF),
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: cliSnippet));
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              supportedTools,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF71717A),
                fontSize: 11,
              ),
            ),
            _statusLines(status, error, ext),
          ],
        ),
      ),
    );
  }

  Widget _sastTab(
    AppThemeExtension ext,
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildEmptyDropzone(
          icon: Icons.upload_file_outlined,
          title: 'Drop SARIF 2.1.0 report to correlate SAST with Neo4j',
          subtitle:
              'Veraxi maps static taint flows directly onto your indexed call graph and links findings to CWEs.',
          primaryLabel:
              state.sarifBusy ? 'Ingesting…' : 'Upload SARIF 2.1.0 (.json)',
          onPrimary: state.sarifBusy
              ? null
              : () async {
                  final text = await _pickText(['json', 'sarif']);
                  if (text != null) await viewModel.ingestSarifText(text);
                },
          secondaryLabel:
              widget.onConnectRepo != null ? '+ Connect a repo' : null,
          onSecondary: widget.onConnectRepo,
          cliSnippet: 'semgrep --sarif -o results.sarif .',
          supportedTools:
              'Supports Semgrep · CodeQL · Bandit · Snyk · Trivy SARIF 2.1.0',
          status: state.sarifStatus,
          error: state.sarifError,
          ext: ext,
        ),
        if (state.sarifTaintFlows.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Taint paths (source → sink)',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...state.sarifTaintFlows.map((flow) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (var i = 0; i < flow.steps.length; i++) ...[
                      if (i > 0)
                        const Text('→',
                            style: TextStyle(color: Color(0xFFA1A1AA))),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF164E63),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(flow.steps[i],
                            style: const TextStyle(
                                color: Color(0xFFA5F3FC), fontSize: 11)),
                      ),
                    ],
                    Text(flow.ruleId,
                        style:
                            TextStyle(color: ext.textTertiary, fontSize: 11)),
                  ],
                ),
              )),
        ],
      ],
    );
  }

  Widget _reconTab(
    AppThemeExtension ext,
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    return _buildEmptyDropzone(
      icon: Icons.radar_outlined,
      title: 'Ingest Recon & DAST scan output',
      subtitle:
          'Correlate exposed endpoints, CVEs, and misconfigurations with your repository graph.',
      primaryLabel: state.reconBusy ? 'Ingesting…' : 'Upload Nuclei JSON/JSONL',
      onPrimary: state.reconBusy
          ? null
          : () async {
              final text = await _pickText(['json', 'jsonl']);
              if (text != null) await viewModel.ingestRecon(text);
            },
      secondaryLabel: widget.onConnectRepo != null ? '+ Connect a repo' : null,
      onSecondary: widget.onConnectRepo,
      cliSnippet: 'nuclei -u https://target.example.com -je recon.json',
      supportedTools:
          'Supports Nuclei JSON/JSONL · Nmap XML · Burp XML · Caido',
      status: state.reconStatus,
      error: state.reconError,
      ext: ext,
    );
  }

  Widget _attackTab(
    AppThemeExtension ext,
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    return _buildEmptyDropzone(
      icon: Icons.sync,
      title: 'Sync MITRE ATT&CK STIX 2.1 Intel',
      subtitle:
          'Link techniques, tactics, and mitigations to CVEs and runtime alerts in Neo4j.',
      primaryLabel: state.attackBusy ? 'Syncing…' : 'Sync MITRE ATT&CK',
      onPrimary: state.attackBusy ? null : () => viewModel.syncAttackIntel(),
      secondaryLabel: 'Upload STIX bundle',
      onSecondary: state.attackBusy
          ? null
          : () async {
              final text = await _pickText(['json']);
              if (text != null) {
                await viewModel.syncAttackIntelFromText(text);
              }
            },
      cliSnippet:
          'curl -sO https://raw.githubusercontent.com/mitre/cti/master/enterprise-attack/enterprise-attack.json',
      supportedTools: 'Supports MITRE ATT&CK Enterprise STIX 2.1 bundles',
      status: state.attackStatus,
      error: state.attackError,
      ext: ext,
    );
  }

  Widget _socTab(
    AppThemeExtension ext,
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    return _buildEmptyDropzone(
      icon: Icons.notifications_active_outlined,
      title: 'Ingest SOC Alerts & IOCs',
      subtitle:
          'Correlate SIEM/EDR alerts and indicators of compromise against your vulnerable packages.',
      primaryLabel:
          state.alertsBusy ? 'Ingesting…' : 'Upload Alerts / IOCs (.json)',
      onPrimary: state.alertsBusy
          ? null
          : () async {
              final text = await _pickText(['json', 'jsonl']);
              if (text != null) await viewModel.ingestAlertsText(text);
            },
      secondaryLabel: widget.onConnectRepo != null ? '+ Connect a repo' : null,
      onSecondary: widget.onConnectRepo,
      cliSnippet: 'veraxi ingest alerts --file siem-alerts.json',
      supportedTools: 'Supports ECS JSON · OCSF · Splunk/Elastic alert exports',
      status: state.alertsStatus,
      error: state.alertsError,
      ext: ext,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedBorderPainter({
    required this.color,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dashWidth = 6.0;
    const dashSpace = 4.0;
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final next = distance + dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0.0, metric.length)),
          paint,
        );
        distance = next + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
