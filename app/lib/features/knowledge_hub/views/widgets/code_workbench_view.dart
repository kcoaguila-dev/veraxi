import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/ask_veraxi_sidecar.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/corpus_briefing_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/repo_xray_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/security_feed_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_intel_panel.dart';

/// Unified Code Mode workbench surfacing Vuln Intel, Repo X-Ray,
/// Security Feed, Corpus Briefing, and dbt Lineage as dedicated sub-views
/// alongside the docked (desktop >= 1200px) or slide-over (< 1200px)
/// Ask Veraxi sidecar.
///
/// Design contract: docs/design/veraxi_code_workbench.svg.
class CodeWorkbenchView extends ConsumerStatefulWidget {
  final VoidCallback? onOpenMobileSidebar;

  const CodeWorkbenchView({
    super.key,
    this.onOpenMobileSidebar,
  });

  @override
  ConsumerState<CodeWorkbenchView> createState() => _CodeWorkbenchViewState();
}

class _CodeWorkbenchViewState extends ConsumerState<CodeWorkbenchView> {
  final TextEditingController _repoPathController =
      TextEditingController(text: 'backend');
  VulnFinding? _selectedFinding;
  bool _narrowSidecarOpen = false;

  @override
  void dispose() {
    _repoPathController.dispose();
    super.dispose();
  }

  String _subViewTitle(CodeSubView subView) {
    switch (subView) {
      case CodeSubView.vulnIntel:
        return 'Vulnerability Intel';
      case CodeSubView.repoXray:
        return 'Repo X-Ray';
      case CodeSubView.securityFeed:
        return 'Security Feed';
      case CodeSubView.corpusBriefing:
        return 'Corpus Briefing';
      case CodeSubView.dbtLineage:
        return 'dbt Lineage';
    }
  }

  void _selectFinding(VulnFinding finding, {required bool isNarrow}) {
    setState(() {
      _selectedFinding = finding;
      if (isNarrow) {
        _narrowSidecarOpen = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeSubView = ref.watch(codeSubViewProvider);
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);
    final codeState = ref.watch(codeIntelViewModelProvider);

    // Keep sidebar KEV badge/dot synced with the latest vulnerability report.
    ref.listen<CodeIntelState>(codeIntelViewModelProvider, (prev, next) {
      final prevKev = prev?.vulnReport?.kevCount ?? 0;
      final nextKev = next.vulnReport?.kevCount ?? 0;
      if (prevKev != nextKev) {
        ref.read(activeKevCountProvider.notifier).state = nextKev;
      }
    });

    // Keep repo path synced when user switches indexed repo in the sidebar.
    ref.listen<String>(selectedIndexedRepoProvider, (_, nextRepo) {
      final mapped = nextRepo == 'veraxi/app' ? 'app' : 'backend';
      if (_repoPathController.text != mapped) {
        _repoPathController.text = mapped;
      }
    });

    final activeFinding = _selectedFinding ??
        (codeState.vulnReport != null &&
                codeState.vulnReport!.findings.isNotEmpty
            ? codeState.vulnReport!.findings.first
            : null);

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWideDesktop = screenWidth >= 1200;

    return Stack(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  _buildHeaderBar(
                    context: context,
                    title: _subViewTitle(activeSubView),
                    repoLabel: selectedRepo,
                    isWideDesktop: isWideDesktop,
                    activeFinding: activeFinding,
                  ),
                  Expanded(
                    child: IndexedStack(
                      index: activeSubView.index,
                      children: [
                        SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: VulnIntelPanel(
                            repoPathController: _repoPathController,
                            workbenchMode: true,
                            selectedCveId: activeFinding?.cveId,
                            onAskFinding: (f) =>
                                _selectFinding(f, isNarrow: !isWideDesktop),
                            onInspectPath: (f) =>
                                _selectFinding(f, isNarrow: !isWideDesktop),
                          ),
                        ),
                        SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: RepoXrayPanel(
                            repoPathController: _repoPathController,
                          ),
                        ),
                        const SingleChildScrollView(
                          padding: EdgeInsets.all(24),
                          child: SecurityFeedPanel(),
                        ),
                        const SingleChildScrollView(
                          padding: EdgeInsets.all(24),
                          child: CorpusBriefingPanel(
                            sectionFilter:
                                CorpusBriefingSectionFilter.briefingOnly,
                          ),
                        ),
                        const SingleChildScrollView(
                          padding: EdgeInsets.all(24),
                          child: CorpusBriefingPanel(
                            sectionFilter:
                                CorpusBriefingSectionFilter.dbtLineageOnly,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (isWideDesktop) AskVeraxiSidecar(finding: activeFinding),
          ],
        ),
        if (!isWideDesktop && _narrowSidecarOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _narrowSidecarOpen = false),
              child: Container(
                color: Colors.black54,
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () {},
                  child: AskVeraxiSidecar(
                    finding: activeFinding,
                    onClose: () => setState(() => _narrowSidecarOpen = false),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeaderBar({
    required BuildContext context,
    required String title,
    required String repoLabel,
    required bool isWideDesktop,
    required VulnFinding? activeFinding,
  }) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: Color(0xFF212121),
        border: Border(
          bottom: BorderSide(color: Color(0xFF2B2B2E), width: 1),
        ),
      ),
      child: Row(
        children: [
          if (widget.onOpenMobileSidebar != null) ...[
            IconButton(
              icon: const Icon(Icons.menu, color: Color(0xFFB4B4B4)),
              onPressed: widget.onOpenMobileSidebar,
              tooltip: 'Open sidebar',
            ),
            const SizedBox(width: 4),
          ],
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF27272B),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: const Color(0xFF3A3A40), width: 0.8),
            ),
            child: Text(
              repoLabel,
              style: const TextStyle(
                color: Color(0xFFA1A1AA),
                fontSize: 11.5,
              ),
            ),
          ),
          const Spacer(),
          if (!isWideDesktop)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _narrowSidecarOpen = true),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2D29),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: const Color(0xFF10B981), width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.auto_awesome,
                        size: 14, color: Color(0xFF34D399)),
                    const SizedBox(width: 6),
                    Text(
                      activeFinding != null
                          ? 'Ask Veraxi · ${activeFinding.cveId}'
                          : 'Ask Veraxi',
                      style: const TextStyle(
                        color: Color(0xFF34D399),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
