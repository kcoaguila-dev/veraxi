import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/api_key_dialog.dart';

class ModelSelectorMenu extends ConsumerStatefulWidget {
  final String selectedModel;
  final ValueChanged<String> onModelSelected;
  final List<String> pinnedModels;
  final ValueChanged<String>? onModelPinned;
  final ValueChanged<String>? onModelUnpinned;
  final Widget child;

  const ModelSelectorMenu({
    super.key,
    required this.selectedModel,
    required this.onModelSelected,
    this.pinnedModels = const [],
    this.onModelPinned,
    this.onModelUnpinned,
    required this.child,
  });

  @override
  ConsumerState<ModelSelectorMenu> createState() => _ModelSelectorMenuState();
}

class _ModelSelectorMenuState extends ConsumerState<ModelSelectorMenu> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  OverlayEntry? _subMenuOverlayEntry;

  bool _isOpen = false;
  String? _hoveredProvider;
  final GlobalKey _providerListKey = GlobalKey();

  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    _closeMenu();
    super.dispose();
  }

  void _toggleMenu() {
    if (_isOpen) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    if (_isOpen) return;
    _overlayEntry = _createOverlayEntry();
    Overlay.of(context).insert(_overlayEntry!);
    setState(() {
      _isOpen = true;
      _searchQuery = '';
      _searchController.clear();
    });
  }

  void _closeMenu() {
    if (!_isOpen) return;
    _closeSubMenu();
    _overlayEntry?.remove();
    _overlayEntry = null;
    setState(() {
      _isOpen = false;
      _hoveredProvider = null;
    });
  }

  void _closeSubMenu() {
    _subMenuOverlayEntry?.remove();
    _subMenuOverlayEntry = null;
  }

  void _openSubMenu(
      String provider, List<String> models, BuildContext providerItemContext) {
    if (_hoveredProvider == provider) return;

    _closeSubMenu(); // close existing submenu

    setState(() {
      _hoveredProvider = provider;
    });

    final RenderBox renderBox =
        providerItemContext.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);

    // We position the submenu slightly overlapping or directly next to the parent menu
    _subMenuOverlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // Invisible layer to catch taps outside submenu but keep main menu open?
          // Actually, the main menu already has a huge transparent background.
          // We don't need a background here, just Positioned
          Positioned(
            left: offset.dx + renderBox.size.width + 4,
            top: offset.dy - 30, // Align roughly with the row
            child: Material(
              color: Colors.transparent,
              child: _buildSubMenuContent(provider, models),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_subMenuOverlayEntry!);
  }

  Widget _buildSubMenuContent(String provider, List<String> models) {
    final filteredModels = models
        .where((m) => m.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    return Container(
      width: 280,
      constraints: const BoxConstraints(maxHeight: 450),
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333333)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Search box inside submenu
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search $provider models...',
                  hintStyle:
                      const TextStyle(color: Color(0xFF878787), fontSize: 13),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF333333)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF333333)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF555555)),
                  ),
                ),
                onChanged: (val) {
                  // This is tricky because we are inside an overlay.
                  // We need to use a StatefulBuilder or just rebuild the submenu overlay.
                  _subMenuOverlayEntry?.markNeedsBuild();
                  _searchQuery = val;
                },
              ),
            ),
          ),
          if (filteredModels.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('No models found',
                  style: TextStyle(color: Color(0xFF878787), fontSize: 13)),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                itemCount: filteredModels.length,
                itemBuilder: (context, index) {
                  final model = filteredModels[index];
                  final isSelected = widget.selectedModel == model;
                  final isPinned = widget.pinnedModels.contains(model);
                  return _HoverableModelRow(
                    model: model,
                    isSelected: isSelected,
                    isPinned: isPinned,
                    onTap: () {
                      widget.onModelSelected(model);
                      _closeMenu();
                    },
                    onPinToggle: () {
                      if (isPinned) {
                        widget.onModelUnpinned?.call(model);
                      } else {
                        widget.onModelPinned?.call(model);
                      }
                      _subMenuOverlayEntry?.markNeedsBuild();
                      _overlayEntry?.markNeedsBuild();
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  OverlayEntry _createOverlayEntry() {
    return OverlayEntry(
      builder: (context) {
        return Consumer(
          builder: (context, ref, child) {
            final asyncModels = ref.watch(providerModelsProvider);

            return Stack(
              children: [
                // Full screen transparent detector to close the menu
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeMenu,
                    onPanStart: (_) => _closeMenu(),
                    child: Container(color: Colors.transparent),
                  ),
                ),
                CompositedTransformFollower(
                  link: _layerLink,
                  showWhenUnlinked: false,
                  offset: const Offset(
                      0, 48), // Adjust this to sit below the button
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: 240,
                      constraints: const BoxConstraints(maxHeight: 500),
                      decoration: BoxDecoration(
                        color: const Color(0xFF171717),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF333333)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: asyncModels.when(
                        data: (allProviderModels) {
                          return ListView(
                            key: _providerListKey,
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 8),
                            children: [
                              if (widget.pinnedModels.isNotEmpty) ...[
                                const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 4),
                                  child: Text('Pinned',
                                      style: TextStyle(
                                          color: Color(0xFF6E6E6E),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600)),
                                ),
                                for (final pinned in widget.pinnedModels)
                                  _HoverableModelRow(
                                    model: pinned,
                                    isSelected: widget.selectedModel == pinned,
                                    isPinned: true,
                                    onTap: () {
                                      widget.onModelSelected(pinned);
                                      _closeMenu();
                                    },
                                    onPinToggle: () {
                                      widget.onModelUnpinned?.call(pinned);
                                      _overlayEntry?.markNeedsBuild();
                                    },
                                  ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 4),
                                  child: Divider(
                                      color: Color(0xFF2A2A2A), height: 1),
                                ),
                              ],
                              const Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 4),
                                child: Text('Providers',
                                    style: TextStyle(
                                        color: Color(0xFF6E6E6E),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600)),
                              ),
                              for (final providerEntry
                                  in allProviderModels.entries)
                                Builder(builder: (itemContext) {
                                  final isHovered =
                                      _hoveredProvider == providerEntry.key;
                                  return _HoverableProviderRow(
                                    provider: providerEntry.key,
                                    isHovered: isHovered,
                                    onEnter: () {
                                      _openSubMenu(providerEntry.key,
                                          providerEntry.value, itemContext);
                                      _overlayEntry?.markNeedsBuild();
                                    },
                                    onTap: () {
                                      _openSubMenu(providerEntry.key,
                                          providerEntry.value, itemContext);
                                      _overlayEntry?.markNeedsBuild();
                                    },
                                    onSettingsTap: () {
                                      _closeMenu();
                                      showDialog(
                                        context: context,
                                        builder: (context) => ApiKeyDialog(
                                            providerName: providerEntry.key),
                                      );
                                    },
                                  );
                                })
                            ],
                          );
                        },
                        loading: () => const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                              child: CircularProgressIndicator(
                                  color: Colors.white54)),
                        ),
                        error: (e, s) => Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('Error: $e',
                              style: const TextStyle(color: Colors.red)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        onTap: _toggleMenu,
        child: widget.child,
      ),
    );
  }
}

// ---------------------------------------------------------
// Custom Hover Rows for precise styling
// ---------------------------------------------------------

class _HoverableProviderRow extends StatefulWidget {
  final String provider;
  final bool isHovered;
  final VoidCallback onEnter;
  final VoidCallback onTap;
  final VoidCallback onSettingsTap;

  const _HoverableProviderRow({
    required this.provider,
    required this.isHovered,
    required this.onEnter,
    required this.onTap,
    required this.onSettingsTap,
  });

  @override
  State<_HoverableProviderRow> createState() => _HoverableProviderRowState();
}

class _HoverableProviderRowState extends State<_HoverableProviderRow> {
  bool _isLocalHover = false;

  Widget _providerCircle(String provider) {
    String? assetPath;
    final lower = provider.toLowerCase();
    if (lower == 'google')
      assetPath = 'assets/icons/google.svg';
    else if (lower == 'openai')
      assetPath = 'assets/icons/openai.svg';
    else if (lower == 'anthropic')
      assetPath = 'assets/icons/anthropic.svg';
    else if (lower == 'deepseek')
      assetPath = 'assets/icons/deepseek.svg';
    else if (lower == 'groq')
      assetPath = 'assets/icons/groq.svg';
    else if (lower == 'mistral' || lower == 'mixtral')
      assetPath = 'assets/icons/mistral.svg';
    else if (lower == 'kimi')
      assetPath = 'assets/icons/kimi.svg';
    else if (lower == 'local') assetPath = 'assets/icons/local.svg';

    final colors = {
      'Google': Colors.white,
      'OpenAI': Colors.white,
      'Anthropic': const Color(0xFFd97757),
      'Mistral': const Color(0xFFFF9800),
      'DeepSeek': const Color(0xFF2196F3),
      'groq': const Color(0xFFf55036),
      'HuggingFace': const Color(0xFFFFC107),
      'Hyperbolic': const Color(0xFF673AB7),
      'cohere': const Color(0xFF81C784),
      'Kimi': Colors.white,
      'Local': Colors.white,
    };

    if (assetPath != null) {
      final colorKey = colors.keys
          .firstWhere((k) => k.toLowerCase() == lower, orElse: () => 'OpenAI');
      final iconColor = colors[colorKey] ?? Colors.white;
      return SizedBox(
        width: 16,
        height: 16,
        child: Center(
          child: SvgPicture.asset(
            assetPath,
            width: 16,
            height: 16,
            colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
          ),
        ),
      );
    }
    final color = colors[provider];
    if (color == null) return const SizedBox(width: 16);
    return Container(
      width: 12,
      height: 12,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.isHovered || _isLocalHover;

    return MouseRegion(
      onEnter: (_) {
        setState(() => _isLocalHover = true);
        widget.onEnter();
      },
      onExit: (_) => setState(() => _isLocalHover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 38,
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF2F2F2F) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              _providerCircle(widget.provider),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.provider,
                  style: TextStyle(
                    color: active ? Colors.white : const Color(0xFFD1D1D1),
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ),
              GestureDetector(
                onTap: widget.onSettingsTap,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Icon(Icons.settings_outlined,
                      size: 15,
                      color: active
                          ? const Color(0xFFB4B4B4)
                          : Colors.transparent),
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 16,
                  color: active ? Colors.white : const Color(0xFF878787)),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _HoverableModelRow extends StatefulWidget {
  final String model;
  final bool isSelected;
  final bool isPinned;
  final VoidCallback onTap;
  final VoidCallback onPinToggle;

  const _HoverableModelRow({
    required this.model,
    required this.isSelected,
    required this.isPinned,
    required this.onTap,
    required this.onPinToggle,
  });

  @override
  State<_HoverableModelRow> createState() => _HoverableModelRowState();
}

class _HoverableModelRowState extends State<_HoverableModelRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 36,
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: _isHovered ? const Color(0xFF2F2F2F) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              if (widget.isSelected)
                Positioned(
                  left: 0,
                  top: 8,
                  bottom: 8,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ),
              Row(
                children: [
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      widget.model,
                      style: TextStyle(
                        color: widget.isSelected || _isHovered
                            ? Colors.white
                            : const Color(0xFFD1D1D1),
                        fontSize: 13,
                        fontWeight: widget.isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: widget.onPinToggle,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      child: Icon(
                        widget.isPinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        size: 14,
                        color: widget.isPinned
                            ? Colors.white
                            : (_isHovered
                                ? const Color(0xFF878787)
                                : Colors.transparent),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
