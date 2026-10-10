import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/api_key_dialog.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/core/widgets/provider_icon.dart';

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

  final TextEditingController _searchController = TextEditingController();

  String _mainSearchQuery = '';
  final TextEditingController _mainSearchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    _mainSearchController.dispose();
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
      _searchController.clear();
      _mainSearchQuery = '';
      _mainSearchController.clear();
    });
  }

  void _closeMenu() {
    if (!_isOpen) return;
    _closeSubMenu();
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
    setState(() {
      _isOpen = false;
      _hoveredProvider = null;
    });
  }

  void _closeSubMenu() {
    _subMenuOverlayEntry?.remove();
    _subMenuOverlayEntry?.dispose();
    _subMenuOverlayEntry = null;
  }

  void _openSubMenu(String provider, List<String> models) {
    _closeMenu(); // close main menu

    showDialog(
      context: context,
      builder: (context) {
        String searchQuery = '';
        final TextEditingController searchController = TextEditingController();

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.all(24),
          child: StatefulBuilder(
            builder: (context, setStateDialog) {
              final allModels = models;
              final filteredModels = allModels
                  .where((m) =>
                      m.toLowerCase().contains(searchQuery.toLowerCase()))
                  .toList();

              return Container(
                width: 320,
                constraints: const BoxConstraints(maxHeight: 500),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .sidebarBackground,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: Theme.of(context)
                          .extension<AppThemeExtension>()!
                          .borderColorStrong),
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
                    // Header
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '$provider Models',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close,
                                color: Colors.white54, size: 20),
                            onPressed: () => Navigator.of(context).pop(),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ),
                    // Search box
                    Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: searchController,
                          autofocus: true,
                          cursorColor: Colors.white,
                          style: TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Search $provider models...',
                            hintStyle: TextStyle(
                                color: Theme.of(context)
                                    .extension<AppThemeExtension>()!
                                    .textTertiary,
                                fontSize: 13),
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .borderColorStrong),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                  color: Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .borderColorStrong),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: Color(0xFF555555)),
                            ),
                          ),
                          onChanged: (val) {
                            setStateDialog(() {
                              searchQuery = val;
                            });
                          },
                        ),
                      ),
                    ),
                    if (filteredModels.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('No models found',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .extension<AppThemeExtension>()!
                                    .textTertiary,
                                fontSize: 13)),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding:
                              EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          itemCount: filteredModels.length,
                          itemBuilder: (context, index) {
                            final model = filteredModels[index];
                            final isSelected = widget.selectedModel == model;
                            final isPinned =
                                widget.pinnedModels.contains(model);
                            return _HoverableModelRow(
                              model: model,
                              isSelected: isSelected,
                              isPinned: isPinned,
                              onTap: () {
                                widget.onModelSelected(model);
                                Navigator.of(context).pop();
                              },
                              onPinToggle: () {
                                if (isPinned) {
                                  widget.onModelUnpinned?.call(model);
                                } else {
                                  widget.onModelPinned?.call(model);
                                }
                                setStateDialog(() {});
                              },
                            );
                          },
                        ),
                      ),
                    SizedBox(height: 8),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  OverlayEntry _createOverlayEntry() {
    return OverlayEntry(
      builder: (context) {
        return Consumer(
          builder: (context, ref, child) {
            final allProviderModels = ref.watch(providerModelsProvider);

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
                      width: 200,
                      constraints: const BoxConstraints(maxHeight: 500),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .sidebarBackground,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .borderColorStrong),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Builder(
                        builder: (context) {
                          final flatModels = allProviderModels.values
                              .expand((m) => m)
                              .toList();
                          final filteredMain = flatModels
                              .where((m) => m
                                  .toLowerCase()
                                  .contains(_mainSearchQuery.toLowerCase()))
                              .toList();
                          final isSearching = _mainSearchQuery.isNotEmpty;

                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: EdgeInsets.all(8.0),
                                child: SizedBox(
                                  height: 36,
                                  child: TextField(
                                    controller: _mainSearchController,
                                    cursorColor: Colors.white,
                                    style: TextStyle(
                                        color: Colors.white, fontSize: 13),
                                    decoration: InputDecoration(
                                      hintText: 'Search models...',
                                      hintStyle: TextStyle(
                                          color: Theme.of(context)
                                              .extension<AppThemeExtension>()!
                                              .textTertiary,
                                          fontSize: 13),
                                      contentPadding:
                                          EdgeInsets.symmetric(horizontal: 12),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(
                                            color: Theme.of(context)
                                                .extension<AppThemeExtension>()!
                                                .borderColorStrong),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(
                                            color: Theme.of(context)
                                                .extension<AppThemeExtension>()!
                                                .borderColorStrong),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(
                                            color: Color(0xFF555555)),
                                      ),
                                    ),
                                    onChanged: (val) {
                                      _overlayEntry?.markNeedsBuild();
                                      _mainSearchQuery = val;
                                      if (val.isNotEmpty) {
                                        _closeSubMenu();
                                      }
                                    },
                                  ),
                                ),
                              ),
                              Flexible(
                                child: ListView(
                                  key: _providerListKey,
                                  shrinkWrap: true,
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 0),
                                  children: [
                                    if (isSearching) ...[
                                      if (filteredMain.isEmpty)
                                        Padding(
                                          padding: EdgeInsets.all(16.0),
                                          child: Text('No models found',
                                              style: TextStyle(
                                                  color: Theme.of(context)
                                                      .extension<
                                                          AppThemeExtension>()!
                                                      .textTertiary,
                                                  fontSize: 13)),
                                        )
                                      else
                                        for (final model in filteredMain)
                                          _HoverableModelRow(
                                            model: model,
                                            isSelected:
                                                widget.selectedModel == model,
                                            isPinned: widget.pinnedModels
                                                .contains(model),
                                            onTap: () {
                                              widget.onModelSelected(model);
                                              _closeMenu();
                                            },
                                            onPinToggle: () {
                                              if (widget.pinnedModels
                                                  .contains(model)) {
                                                widget.onModelUnpinned
                                                    ?.call(model);
                                              } else {
                                                widget.onModelPinned
                                                    ?.call(model);
                                              }
                                              _overlayEntry?.markNeedsBuild();
                                            },
                                          ),
                                    ] else ...[
                                      if (widget.pinnedModels.isNotEmpty) ...[
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 4),
                                          child: Text('Pinned',
                                              style: TextStyle(
                                                  color: Color(0xFF6E6E6E),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600)),
                                        ),
                                        for (final pinned
                                            in widget.pinnedModels)
                                          _HoverableModelRow(
                                            model: pinned,
                                            isSelected:
                                                widget.selectedModel == pinned,
                                            isPinned: true,
                                            onTap: () {
                                              widget.onModelSelected(pinned);
                                              _closeMenu();
                                            },
                                            onPinToggle: () {
                                              widget.onModelUnpinned
                                                  ?.call(pinned);
                                              _overlayEntry?.markNeedsBuild();
                                            },
                                          ),
                                        Padding(
                                          padding:
                                              EdgeInsets.symmetric(vertical: 4),
                                          child: Divider(
                                              color: Theme.of(context)
                                                  .extension<
                                                      AppThemeExtension>()!
                                                  .borderColor,
                                              height: 1),
                                        ),
                                      ],
                                      if (allProviderModels.isNotEmpty) ...[
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 4),
                                          child: Text('Providers',
                                              style: TextStyle(
                                                  color: Color(0xFF6E6E6E),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600)),
                                        ),
                                      ],
                                      for (final providerEntry
                                          in allProviderModels.entries)
                                        HoverableProviderRow(
                                          provider: providerEntry.key,
                                          isHovered: _hoveredProvider ==
                                              providerEntry.key,
                                          onEnter: (layerLink) {
                                            // No longer open submenu on hover, wait for tap on mobile/desktop
                                          },
                                          onTap: (layerLink) {
                                            _openSubMenu(providerEntry.key,
                                                providerEntry.value);
                                          },
                                          onSettingsTap: () {
                                            _closeMenu();
                                            showDialog(
                                              context: context,
                                              builder: (context) =>
                                                  ApiKeyDialog(
                                                      providerName:
                                                          providerEntry.key,
                                                      onModelSaved: widget
                                                          .onModelSelected),
                                            );
                                          },
                                        )
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
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

class HoverableProviderRow extends StatefulWidget {
  final String provider;
  final bool isHovered;
  final ValueChanged<LayerLink> onEnter;
  final ValueChanged<LayerLink> onTap;
  final VoidCallback onSettingsTap;

  const HoverableProviderRow({
    required this.provider,
    required this.isHovered,
    required this.onEnter,
    required this.onTap,
    required this.onSettingsTap,
  });

  @override
  State<HoverableProviderRow> createState() => HoverableProviderRowState();
}

class HoverableProviderRowState extends State<HoverableProviderRow> {
  bool _isLocalHover = false;
  bool _isSettingsHovered = false;
  final LayerLink _layerLink = LayerLink();

  @override
  Widget build(BuildContext context) {
    final active = widget.isHovered || _isLocalHover;

    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _isLocalHover = true);
          widget.onEnter(_layerLink);
        },
        onExit: (_) => setState(() => _isLocalHover = false),
        child: GestureDetector(
          onTap: () => widget.onTap(_layerLink),
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 38,
            margin: EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: active
                  ? Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .surfaceHighlight
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                SizedBox(width: 12),
                buildProviderIcon(widget.provider),
                SizedBox(width: 12),
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
                MouseRegion(
                  onEnter: (_) => setState(() => _isSettingsHovered = true),
                  onExit: (_) => setState(() => _isSettingsHovered = false),
                  child: GestureDetector(
                    onTap: widget.onSettingsTap,
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      decoration: BoxDecoration(
                        color: _isSettingsHovered
                            ? const Color(0xFF444444)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.settings_outlined,
                              size: 15,
                              color: _isSettingsHovered
                                  ? Colors.white
                                  : Theme.of(context)
                                      .extension<AppThemeExtension>()!
                                      .iconColor),
                          if (_isSettingsHovered) ...[
                            SizedBox(width: 4),
                            Text('Set API Key',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 11)),
                          ]
                        ],
                      ),
                    ),
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 16,
                    color: active
                        ? Colors.white
                        : Theme.of(context)
                            .extension<AppThemeExtension>()!
                            .textTertiary),
                SizedBox(width: 8),
              ],
            ),
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
          margin: EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: _isHovered
                ? Theme.of(context)
                    .extension<AppThemeExtension>()!
                    .surfaceHighlight
                : Colors.transparent,
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
                  SizedBox(width: 14),
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
                      padding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Icon(
                        widget.isPinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        size: 14,
                        color: widget.isPinned
                            ? Colors.white
                            : (_isHovered
                                ? Theme.of(context)
                                    .extension<AppThemeExtension>()!
                                    .textTertiary
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
