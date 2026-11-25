import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_chat_pane.dart';
import 'package:veraxi_app/features/chat/views/widgets/code_review_drawer.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/code_intel_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/corpus_briefing_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/repo_xray_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/security_feed_panel.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/vuln_intel_panel.dart';

/// Unified Code Mode workbench surfacing Code Chat, Vuln Intel, Repo X-Ray,
/// Security Feed, Corpus Briefing, and dbt Lineage as dedicated sub-views.
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

  void _openCallSiteViewer(VulnFinding finding, VulnCallSite? site) {
    final targetFile = site?.file ??
        (finding.callSites.isNotEmpty ? finding.callSites.first.file : null);
    if (targetFile == null || targetFile.isEmpty) return;
    final line = site?.line ?? 1;
    ref.read(activeReviewSessionProvider.notifier).state = CodeReviewState(
      sessionId: '',
      turnId: '',
      focusedPath: targetFile,
      focusedStartLine: line,
      focusedEndLine: line,
      files: [CodeReviewFileSummary(path: targetFile)],
      turnPrompt: '${finding.cveId} · ${finding.package}',
    );
  }

  void _openFindingCodeThread(VulnFinding finding) {
    final badges = <String>[
      if (finding.severity != null) finding.severity!.toUpperCase(),
      if (finding.kev) 'CISA KEV',
      if (finding.epssScore != null)
        'EPSS ${(finding.epssScore! * 100).toStringAsFixed(1)}%',
      if (finding.compositeScore > 0) 'Score ${finding.compositeScore}',
    ].join(' · ');

    final sites = finding.callSites
        .take(5)
        .map((s) =>
            '- ${s.file}${s.line != null ? ':${s.line}' : ''} (${s.symbol})')
        .join('\n');

    final prompt = StringBuffer()
      ..writeln(
        'Fix ${finding.cveId} in `${finding.package}`'
        '${finding.version != null ? ' (${finding.version})' : ''}'
        '${badges.isNotEmpty ? ' [$badges]' : ''}.',
      )
      ..writeln()
      ..writeln(
        sites.isNotEmpty
            ? 'Neo4j reachable call sites:\n$sites'
            : 'No Neo4j call sites attached yet — check callers in the graph first.',
      )
      ..writeln()
      ..writeln(
        'Run the graph caller check and sandbox pytest verification, then propose a minimal patch in the Diff Review pane.',
      );

    ref.read(pendingSecurityThreadPromptProvider.notifier).state =
        prompt.toString();
    ref.read(codeSubViewProvider.notifier).state = CodeSubView.codeChat;
  }

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
      case CodeSubView.codeChat:
        return 'Code Chat';
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeSubView = ref.watch(codeSubViewProvider);
    final selectedRepo = ref.watch(selectedIndexedRepoProvider);

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

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWideDesktop = screenWidth >= 1200;
    // Code Chat is a 2-column layout (rail + pane) per
    // docs/design/veraxi_code_workbench.svg: the pane renders its
    // own header bar, so the workbench header must not mount while
    // it is active.
    final isCodeChat = activeSubView == CodeSubView.codeChat;

    // Phase 5 review pane host: an active review session splits in
    // on the right (~55%) on desktop and overlays as a modal sheet
    // below 1200px. Gated to Code Mode — Chat Mode's host lives in
    // ChatScreen — so the drawer never mounts twice.
    final workspaceMode = ref.watch(workspaceModeProvider);
    final activeReview = ref.watch(activeReviewSessionProvider);
    // Promoted local: guards below use `review != null`, so no
    // non-null assertions are needed at the drawer mounts.
    final review = activeReview;
    final showReview = review != null && workspaceMode == WorkspaceMode.code;

    return LayoutBuilder(
      builder: (context, workbenchConstraints) {
        final workspaceWidth = workbenchConstraints.maxWidth;
        return Stack(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      if (!isCodeChat)
                        _buildHeaderBar(
                          context: context,
                          title: _subViewTitle(activeSubView),
                          repoLabel: selectedRepo,
                          isWideDesktop: isWideDesktop,
                          activeSubView: activeSubView,
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
                                hideToolbarActions: isWideDesktop,
                                onAskFinding: _openFindingCodeThread,
                                onInspectCallSite: _openCallSiteViewer,
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
                            // CodeSubView.codeChat (index 5, the default
                            // sub-view since Phase 3): the Code Chat pane
                            // from the chat feature.
                            const CodeChatPane(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (showReview && isWideDesktop)
                  SizedBox(
                    width: computeReviewPaneWidth(
                      workspaceWidth,
                      ref.watch(reviewPaneWidthFractionProvider),
                    ),
                    child: CodeReviewDrawer(
                      key: ValueKey(
                          'review-${review.sessionId}-${review.turnId}'),
                      review: review,
                      maxSplitWidth: workspaceWidth,
                    ),
                  ),
              ],
            ),
            if (showReview && !isWideDesktop)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => ref
                      .read(activeReviewSessionProvider.notifier)
                      .state = null,
                  child: Container(
                    color: Colors.black54,
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () {},
                      child: SizedBox(
                        width: (screenWidth * 0.92).clamp(320.0, 640.0),
                        child: CodeReviewDrawer(
                          key: ValueKey(
                              'review-sheet-${review.sessionId}-${review.turnId}'),
                          review: review,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildHeaderBar({
    required BuildContext context,
    required String title,
    required String? repoLabel,
    required bool isWideDesktop,
    required CodeSubView activeSubView,
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
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back,
                        color: Color(0xFFB4B4B4),
                        size: 18,
                      ),
                      onPressed: () => ref
                          .read(codeSubViewProvider.notifier)
                          .state = CodeSubView.codeChat,
                      tooltip: 'Back to Code Chat',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const SizedBox(width: 4),
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
                    if (activeSubView == CodeSubView.vulnIntel &&
                        constraints.maxWidth >= 900) ...[
                      const SizedBox(width: 10),
                      Flexible(
                        child: FeedHealthPill(
                          repoPathController: _repoPathController,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (isWideDesktop && activeSubView == CodeSubView.vulnIntel) ...[
                const SizedBox(width: 12),
                VulnIntelToolbarActions(
                  repoPathController: _repoPathController,
                  workbenchMode: true,
                  compact: true,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
