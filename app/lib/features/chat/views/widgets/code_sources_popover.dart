import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:veraxi_app/core/providers/indexed_sources_provider.dart';
import 'package:veraxi_app/core/providers/workspace_mode_provider.dart';
import 'package:veraxi_app/core/theme/obsidian_tokens.dart';

/// The `N sources` pill rendered in the Code composer, with its
/// 320px anchored popover for choosing the thread's source scope.
///
/// Repos come from [indexedReposProvider] (GET /api/v1/code/repos,
/// populated by the workbench) and Knowledge Hub documents from
/// [indexedKnowledgeSourcesProvider] (GET /api/admin/sources, synced
/// into `core/` by the Knowledge Hub view model — features never
/// import another feature's view models directly). Every toggle
/// writes straight to [codeSelectedSourcesProvider], which the next
/// send stamps as `source_scope`.
class CodeSourcesPill extends StatefulWidget {
  const CodeSourcesPill({super.key});

  @override
  State<CodeSourcesPill> createState() => _CodeSourcesPillState();
}

class _CodeSourcesPillState extends State<CodeSourcesPill> {
  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _overlayController,
        overlayChildBuilder: (context) {
          return Positioned(
            width: 320,
            child: CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.bottomRight,
              offset: const Offset(0, -8),
              child: _CodeSourcesPopover(
                onClose: () => _overlayController.hide(),
              ),
            ),
          );
        },
        child: Consumer(
          builder: (context, ref, _) {
            final selected = ref.watch(codeSelectedSourcesProvider);
            final count = selected.repoKeys.length + selected.docIds.length;
            return InkWell(
              onTap: () {
                if (_overlayController.isShowing) {
                  _overlayController.hide();
                } else {
                  _overlayController.show();
                }
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: ObsidianTokens.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ObsidianTokens.borderStrong),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.library_books_outlined,
                      size: 13,
                      color: Color(0xFFA1A1AA),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      count == 0 ? 'All sources' : '$count sources',
                      style: const TextStyle(
                        color: Color(0xFFD4D4D8),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CodeSourcesPopover extends ConsumerStatefulWidget {
  final VoidCallback onClose;

  const _CodeSourcesPopover({required this.onClose});

  @override
  ConsumerState<_CodeSourcesPopover> createState() =>
      _CodeSourcesPopoverState();
}

class _CodeSourcesPopoverState extends ConsumerState<_CodeSourcesPopover> {
  String _filter = '';

  @override
  void initState() {
    super.initState();
    // Make sure the Knowledge Hub documents list is loaded even when
    // the hub screen has not been visited yet this session.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ensureIndexedKnowledgeSourcesLoaded(ref);
    });
  }

  bool _matches(String label) =>
      _filter.isEmpty || label.toLowerCase().contains(_filter.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final repos = ref.watch(indexedReposProvider);
    final docs = ref.watch(indexedKnowledgeSourcesProvider);
    final selected = ref.watch(codeSelectedSourcesProvider);
    final notifier = ref.read(codeSelectedSourcesProvider.notifier);

    final visibleRepos =
        repos.where((repo) => _matches(repo.displayName)).toList();
    final visibleDocs = docs.where((doc) => _matches(doc.name)).toList();
    final allKeys = <String>{
      for (final repo in repos) repo.repoKey,
    };
    final allDocIds = <String>{for (final doc in docs) doc.id};
    final hasAny = allKeys.isNotEmpty || allDocIds.isNotEmpty;
    final allSelected = hasAny &&
        selected.repoKeys.containsAll(allKeys) &&
        selected.docIds.containsAll(allDocIds);

    return TapRegion(
      onTapOutside: (_) => widget.onClose(),
      child: Material(
        color: Colors.transparent,
        elevation: 12,
        child: Container(
          width: 320,
          constraints: const BoxConstraints(maxHeight: 380),
          decoration: BoxDecoration(
            color: ObsidianTokens.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ObsidianTokens.borderStrong),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12.5),
                        cursorColor: Colors.white,
                        decoration: const InputDecoration(
                          hintText: 'Search sources',
                          hintStyle: TextStyle(
                              color: Color(0xFF6E6E6E), fontSize: 12.5),
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                        ),
                        onChanged: (value) => setState(() => _filter = value),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        notifier.state = allSelected
                            ? const CodeSelectedSources()
                            : CodeSelectedSources(
                                repoKeys: allKeys,
                                docIds: allDocIds,
                              );
                      },
                      child: Text(
                        allSelected ? 'Clear all' : 'Select all',
                        style: const TextStyle(
                          color: Color(0xFF4F8EF7),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: ObsidianTokens.hairline),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  children: [
                    if (visibleRepos.isNotEmpty)
                      const _SourcesSectionLabel('Indexed Repos'),
                    for (final repo in visibleRepos)
                      _SourceCheckboxRow(
                        label: repo.displayName,
                        subtitle: repo.subtitle,
                        checked: selected.repoKeys.contains(repo.repoKey),
                        onChanged: () => notifier.state =
                            selected.toggleRepoKey(repo.repoKey),
                      ),
                    if (visibleDocs.isNotEmpty)
                      const _SourcesSectionLabel('Knowledge Hub Docs'),
                    for (final doc in visibleDocs)
                      _SourceCheckboxRow(
                        label: doc.name,
                        subtitle: doc.subtitle,
                        checked: selected.docIds.contains(doc.id),
                        onChanged: () =>
                            notifier.state = selected.toggleDocId(doc.id),
                      ),
                    if (visibleRepos.isEmpty && visibleDocs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'No sources match.',
                          style:
                              TextStyle(color: Color(0xFFA1A1AA), fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1, color: ObsidianTokens.hairline),
              InkWell(
                onTap: () {
                  widget.onClose();
                  context.go('/knowledge-hub');
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Text(
                    '+ Add sources in Knowledge Hub ->',
                    style: TextStyle(
                      color: Color(0xFF4F8EF7),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourcesSectionLabel extends StatelessWidget {
  final String label;

  const _SourcesSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF6E6E6E),
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _SourceCheckboxRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool checked;
  final VoidCallback onChanged;

  const _SourceCheckboxRow({
    required this.label,
    required this.subtitle,
    required this.checked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onChanged,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          children: [
            Checkbox(
              value: checked,
              onChanged: (_) => onChanged(),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Color(0xFFE4E4E7),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF6E6E6E),
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
