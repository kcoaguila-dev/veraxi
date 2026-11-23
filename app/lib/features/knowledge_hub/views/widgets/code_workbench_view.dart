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
  final TextEditingController _repoPathController = TextEditingController();
  final FocusNode _sidecarComposerFocusNode = FocusNode();
  VulnFinding? _selectedFinding;
  bool _narrowSidecarOpen = false;
  String? _citationToOpen;
  int _citationOpenNonce = 0;
  int _pathHighlightNonce = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshIndexedRepos();
      }
    });
  }

  Future<void> _refreshIndexedRepos() async {
    final raw =
        await ref.read(codeIntelViewModelProvider.notifier).fetchIndexedRepos();
    if (!mounted || raw == null) return;
    final repos = raw.map(IndexedRepoItem.fromJson).toList();
    ref.read(indexedReposProvider.notifier).state = repos;

    final selectedNotifier = ref.read(selectedIndexedRepoProvider.notifier);
    if (repos.isEmpty) {
      selectedNotifier.state = null;
      return;
    }

    final current = selectedNotifier.state;
    final hasCurrent =
        current != null && repos.any((r) => r.repoKey == current);
    if (!hasCurrent) {
      final first = repos.first;
      selectedNotifier.state = first.repoKey;
      final nextPath = first.rootPath ?? first.repoKey;
      if (_repoPathController.text != nextPath) {
        _repoPathController.text = nextPath;
      }
    }
  }

  @override
  void dispose() {
    _repoPathController.dispose();
    _sidecarComposerFocusNode.dispose();
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

  void _askFinding(VulnFinding finding, {required bool isNarrow}) {
    setState(() {
      _selectedFinding = finding;
      if (isNarrow) {
        _narrowSidecarOpen = true;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _sidecarComposerFocusNode.requestFocus();
      }
    });
  }

  void _inspectPath(VulnFinding finding, {required bool isNarrow}) {
    final topPath = finding.reachableInCode.isNotEmpty
        ? finding.reachableInCode.first.path
        : null;
    setState(() {
      _selectedFinding = finding;
      if (isNarrow) {
        _narrowSidecarOpen = true;
      }
      if (topPath != null && topPath.isNotEmpty) {
        _citationToOpen = topPath;
        _citationOpenNonce++;
      } else {
        _pathHighlightNonce++;
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
      if (prev?.indexing == true && !next.indexing && next.indexError == null) {
        _refreshIndexedRepos();
      }
    });

    // Keep repo path synced when user switches indexed repo in the sidebar.
    ref.listen<String?>(selectedIndexedRepoProvider, (_, nextRepo) {
      if (nextRepo == null) {
        if (_repoPathController.text.isNotEmpty) {
          _repoPathController.text = '';
        }
        return;
      }
      final repos = ref.read(indexedReposProvider);
      IndexedRepoItem? matched;
      for (final repo in repos) {
        if (repo.repoKey == nextRepo) {
          matched = repo;
          break;
        }
      }
      final mapped = matched?.rootPath ?? matched?.repoKey ?? nextRepo;
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
                                _askFinding(f, isNarrow: !isWideDesktop),
                            onInspectPath: (f) =>
                                _inspectPath(f, isNarrow: !isWideDesktop),
                            onOpenRepoXray: () => ref
                                .read(codeSubViewProvider.notifier)
                                .state = CodeSubView.repoXray,
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
            if (isWideDesktop)
              AskVeraxiSidecar(
                finding: activeFinding,
                composerFocusNode: _sidecarComposerFocusNode,
                citationToOpen: _citationToOpen,
                citationOpenNonce: _citationOpenNonce,
                pathHighlightNonce: _pathHighlightNonce,
              ),
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
                    composerFocusNode: _sidecarComposerFocusNode,
                    citationToOpen: _citationToOpen,
                    citationOpenNonce: _citationOpenNonce,
                    pathHighlightNonce: _pathHighlightNonce,
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
    required String? repoLabel,
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showRepoPill = constraints.maxWidth >= 520 &&
              repoLabel != null &&
              repoLabel.isNotEmpty;
          return Row(
            children: [
              Expanded(
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
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (showRepoPill) ...[
                      const SizedBox(width: 12),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF27272B),
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: const Color(0xFF3A3A40),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            repoLabel,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: const TextStyle(
                              color: Color(0xFFA1A1AA),
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!isWideDesktop) ...[
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _narrowSidecarOpen = true),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2D29),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF10B981),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.auto_awesome,
                          size: 14,
                          color: Color(0xFF34D399),
                        ),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            activeFinding != null
                                ? 'Ask Veraxi · ${activeFinding.cveId}'
                                : 'Ask Veraxi',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: const TextStyle(
                              color: Color(0xFF34D399),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
