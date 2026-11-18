import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  const SecurityFeedPanel({super.key});

  @override
  ConsumerState<SecurityFeedPanel> createState() => _SecurityFeedPanelState();
}

class _SecurityFeedPanelState extends ConsumerState<SecurityFeedPanel> {
  int _tab = 0;

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
      ),
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

  Widget _sastTab(
    AppThemeExtension ext,
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ElevatedButton.icon(
          onPressed: state.sarifBusy
              ? null
              : () async {
                  final text = await _pickText(['json', 'sarif']);
                  if (text != null) await viewModel.ingestSarifText(text);
                },
          icon: const Icon(Icons.upload_file_outlined, size: 16),
          label: Text(state.sarifBusy ? 'Ingesting…' : 'Upload SARIF 2.1.0'),
        ),
        _statusLines(state.sarifStatus, state.sarifError, ext),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ElevatedButton.icon(
          onPressed: state.reconBusy
              ? null
              : () async {
                  final text = await _pickText(['json', 'jsonl']);
                  if (text != null) await viewModel.ingestRecon(text);
                },
          icon: const Icon(Icons.radar_outlined, size: 16),
          label:
              Text(state.reconBusy ? 'Ingesting…' : 'Upload Nuclei JSON/JSONL'),
        ),
        _statusLines(state.reconStatus, state.reconError, ext),
      ],
    );
  }

  Widget _attackTab(
    AppThemeExtension ext,
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: state.attackBusy
                  ? null
                  : () => viewModel.syncAttackIntel(),
              icon: const Icon(Icons.sync, size: 16),
              label: Text(
                  state.attackBusy ? 'Syncing…' : 'Sync MITRE ATT&CK'),
            ),
            ElevatedButton.icon(
              onPressed: state.attackBusy
                  ? null
                  : () async {
                      final text = await _pickText(['json']);
                      if (text != null) {
                        await viewModel.syncAttackIntelFromText(text);
                      }
                    },
              icon: const Icon(Icons.upload_file_outlined, size: 16),
              label: const Text('Upload STIX bundle'),
            ),
          ],
        ),
        _statusLines(state.attackStatus, state.attackError, ext),
      ],
    );
  }

  Widget _socTab(
    AppThemeExtension ext,
    CodeIntelState state,
    CodeIntelViewModel viewModel,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ElevatedButton.icon(
          onPressed: state.alertsBusy
              ? null
              : () async {
                  final text = await _pickText(['json', 'jsonl']);
                  if (text != null) await viewModel.ingestAlertsText(text);
                },
          icon: const Icon(Icons.notifications_active_outlined, size: 16),
          label:
              Text(state.alertsBusy ? 'Ingesting…' : 'Upload Alerts / IOCs'),
        ),
        _statusLines(state.alertsStatus, state.alertsError, ext),
      ],
    );
  }
}
