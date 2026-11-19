import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/docs/view_models/docs_view_model.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';

/// Documentation and API/MCP reference screen matching the cool-paper
/// editorial design system.
class DocsScreen extends ConsumerStatefulWidget {
  const DocsScreen({super.key});

  @override
  ConsumerState<DocsScreen> createState() => _DocsScreenState();
}

class _DocsScreenState extends ConsumerState<DocsScreen> {
  final TextEditingController _filterController = TextEditingController();

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(docsViewModelProvider);
    final viewModel = ref.read(docsViewModelProvider.notifier);
    final wide = MediaQuery.sizeOf(context).width >= 900;

    return Scaffold(
      backgroundColor: LandingColors.paper,
      body: SelectionArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DocsHeader(
                onOverview: () => context.go('/'),
                onApiJump: () => viewModel.selectEntry('api-chat'),
                onSignIn: () => context.go('/login'),
              ),
              Container(
                height: 1,
                color: LandingColors.line.withValues(alpha: 0.7),
              ),
              LandingColumn(
                top: 32,
                bottom: 56,
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 280,
                            child: _DocsSidebar(
                              controller: _filterController,
                              state: state,
                              onFilterChanged: viewModel.setFilter,
                              onClearFilter: () {
                                _filterController.clear();
                                viewModel.clearFilter();
                              },
                              onSelect: viewModel.selectEntry,
                            ),
                          ),
                          const SizedBox(width: 40),
                          Expanded(
                            child: _DocDetailCard(
                              entry: state.selectedEntry,
                              onCopy: _copyToClipboard,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _DocsSidebar(
                            controller: _filterController,
                            state: state,
                            onFilterChanged: viewModel.setFilter,
                            onClearFilter: () {
                              _filterController.clear();
                              viewModel.clearFilter();
                            },
                            onSelect: viewModel.selectEntry,
                          ),
                          const SizedBox(height: 24),
                          _DocDetailCard(
                            entry: state.selectedEntry,
                            onCopy: _copyToClipboard,
                          ),
                        ],
                      ),
              ),
              LandingColumn(
                bottom: 40,
                child: Container(
                  padding: const EdgeInsets.only(top: 24),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: LandingColors.line)),
                  ),
                  child: Text(
                    'Veraxi · Open source under MIT · Still in development',
                    style:
                        LandingType.sans(size: 13, color: LandingColors.grey),
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

class _DocsHeader extends StatelessWidget {
  final VoidCallback onOverview;
  final VoidCallback onApiJump;
  final VoidCallback onSignIn;

  const _DocsHeader({
    required this.onOverview,
    required this.onApiJump,
    required this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return LandingColumn(
      top: 20,
      bottom: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          InkWell(
            onTap: onOverview,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.asset(
                    'assets/veraxi_logo.png',
                    width: 28,
                    height: 28,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Veraxi',
                  style: LandingType.sans(
                    size: 24,
                    weight: FontWeight.w800,
                    letterSpacing: -0.7,
                  ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (wide) ...[
                LandingTextLink(label: 'Overview', onPressed: onOverview),
                const SizedBox(width: 12),
                LandingTextLink(label: 'API', onPressed: onApiJump),
                const SizedBox(width: 12),
              ],
              LandingTextLink(
                label: 'GitHub',
                onPressed: () =>
                    openLandingUrl('https://github.com/kcoaguila-dev/veraxi'),
              ),
              const SizedBox(width: 12),
              LandingTextLink(label: 'Sign in', onPressed: onSignIn),
            ],
          ),
        ],
      ),
    );
  }
}

class _DocsSidebar extends StatelessWidget {
  final TextEditingController controller;
  final DocsState state;
  final ValueChanged<String> onFilterChanged;
  final VoidCallback onClearFilter;
  final ValueChanged<String> onSelect;

  const _DocsSidebar({
    required this.controller,
    required this.state,
    required this.onFilterChanged,
    required this.onClearFilter,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final filtered = state.filteredEntries;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          onChanged: onFilterChanged,
          style: LandingType.sans(size: 13.5, weight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: 'Filter guides & endpoints...',
            hintStyle: LandingType.sans(
              size: 13.5,
              weight: FontWeight.w500,
              color: LandingColors.grey,
            ),
            filled: true,
            fillColor: LandingColors.panel,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            suffixIcon: state.filterQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'Clear filter',
                    onPressed: onClearFilter,
                  )
                : null,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: LandingColors.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: LandingColors.cobalt, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (filtered.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: LandingColors.panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: LandingColors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No matching guides or endpoints.',
                  style: LandingType.sans(size: 13, color: LandingColors.grey),
                ),
                const SizedBox(height: 8),
                LandingTextLink(
                  label: 'Clear filter',
                  onPressed: onClearFilter,
                ),
              ],
            ),
          )
        else
          for (final category in DocCategory.values)
            ..._buildCategoryGroup(
              category,
              filtered.where((e) => e.category == category).toList(),
            ),
      ],
    );
  }

  List<Widget> _buildCategoryGroup(
    DocCategory category,
    List<DocEntry> items,
  ) {
    if (items.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Text(
          category.label,
          style: LandingType.mono(
            size: 11,
            color: LandingColors.grey,
          ),
        ),
      ),
      for (final entry in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _SidebarItem(
            entry: entry,
            selected: entry.id == state.selectedId,
            onTap: () => onSelect(entry.id),
          ),
        ),
      const SizedBox(height: 8),
    ];
  }
}

class _SidebarItem extends StatelessWidget {
  final DocEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = entry.path ?? entry.title;
    return Material(
      color: selected ? LandingColors.cobalt : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              if (entry.method != null) ...[
                _MethodBadge(method: entry.method!, onCobalt: selected),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: entry.path != null
                      ? LandingType.mono(
                          size: 12.5,
                          color: selected
                              ? LandingColors.onCobalt
                              : LandingColors.ink,
                        )
                      : LandingType.sans(
                          size: 13.5,
                          weight: selected ? FontWeight.w600 : FontWeight.w500,
                          color: selected
                              ? LandingColors.onCobalt
                              : LandingColors.ink,
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

class _MethodBadge extends StatelessWidget {
  final String method;
  final bool onCobalt;

  const _MethodBadge({required this.method, required this.onCobalt});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    if (onCobalt) {
      bg = LandingColors.cobaltDark;
      fg = LandingColors.onCobalt;
    } else if (method == 'GET') {
      bg = const Color(0xFFD1FAE5);
      fg = const Color(0xFF065F46);
    } else if (method == 'MCP') {
      bg = const Color(0xFFE2E8F0);
      fg = LandingColors.ink;
    } else {
      bg = const Color(0xFFE2E8F0);
      fg = LandingColors.cobalt;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        method,
        style: LandingType.mono(size: 10, color: fg),
      ),
    );
  }
}

class _DocDetailCard extends StatelessWidget {
  final DocEntry entry;
  final void Function(String text, String label) onCopy;

  const _DocDetailCard({required this.entry, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: LandingColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: LandingColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (entry.method != null)
                _MethodBadge(method: entry.method!, onCobalt: false),
              if (entry.path != null)
                Text(
                  entry.path!,
                  style: LandingType.mono(
                    size: 15,
                    color: LandingColors.ink,
                  ),
                ),
            ],
          ),
          if (entry.path != null) const SizedBox(height: 12),
          Text(
            entry.title,
            style: LandingType.sans(
              size: 28,
              weight: FontWeight.w800,
              letterSpacing: -0.7,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            entry.summary,
            style: LandingType.serif(
              size: 16.5,
              color: LandingColors.grey,
              height: 1.55,
            ),
          ),
          for (final paragraph in entry.paragraphs) ...[
            const SizedBox(height: 16),
            Text(
              paragraph,
              style: LandingType.serif(
                size: 15.5,
                color: LandingColors.ink,
                height: 1.65,
              ),
            ),
          ],
          if (entry.params.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              entry.method != null ? 'PARAMETERS' : 'COMMANDS',
              style: LandingType.mono(
                size: 11,
                color: LandingColors.grey,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: LandingColors.line),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < entry.params.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, color: LandingColors.paper),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 180,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.params[i].name,
                                  style: LandingType.mono(
                                    size: 12.5,
                                    color: LandingColors.cobalt,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  entry.params[i].type,
                                  style: LandingType.mono(
                                    size: 11,
                                    color: LandingColors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              entry.params[i].description,
                              style: LandingType.sans(
                                size: 13.5,
                                weight: FontWeight.w500,
                                color: LandingColors.ink,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (entry.codeSnippet != null) ...[
            const SizedBox(height: 24),
            _CodePanel(
              label: entry.codeLabel ?? 'EXAMPLE',
              code: entry.codeSnippet!,
              dark: true,
              onCopy: () =>
                  onCopy(entry.codeSnippet!, entry.codeLabel ?? 'Code'),
            ),
          ],
          if (entry.responseSnippet != null) ...[
            const SizedBox(height: 20),
            _CodePanel(
              label: entry.responseLabel ?? 'RESPONSE',
              code: entry.responseSnippet!,
              dark: false,
              onCopy: () => onCopy(
                  entry.responseSnippet!, entry.responseLabel ?? 'Response'),
            ),
          ],
        ],
      ),
    );
  }
}

class _CodePanel extends StatelessWidget {
  final String label;
  final String code;
  final bool dark;
  final VoidCallback onCopy;

  const _CodePanel({
    required this.label,
    required this.code,
    required this.dark,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: LandingType.mono(
            size: 11,
            color: LandingColors.grey,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: dark ? LandingColors.code : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: dark ? null : Border.all(color: LandingColors.line),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 64),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    code,
                    style: LandingType.mono(
                      size: 13,
                      color: dark ? LandingColors.onCobalt : LandingColors.ink,
                      height: 1.55,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: TextButton(
                  onPressed: onCopy,
                  style: TextButton.styleFrom(
                    backgroundColor:
                        dark ? LandingColors.cobaltDark : LandingColors.paper,
                    foregroundColor:
                        dark ? LandingColors.onCobalt : LandingColors.cobalt,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Copy',
                    style: LandingType.sans(
                      size: 11.5,
                      weight: FontWeight.w600,
                      color:
                          dark ? LandingColors.onCobalt : LandingColors.cobalt,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
