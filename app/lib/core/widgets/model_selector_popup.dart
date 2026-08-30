import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:veraxi_app/features/chat/views/widgets/api_key_dialog.dart';

class ModelSelectorPopup extends ConsumerStatefulWidget {
  final String selectedModel;
  final ValueChanged<String> onModelSelected;
  final List<String> pinnedModels;
  final ValueChanged<String>? onModelPinned;
  final ValueChanged<String>? onModelUnpinned;
  final VoidCallback? onClose;

  const ModelSelectorPopup({
    super.key,
    required this.selectedModel,
    required this.onModelSelected,
    this.pinnedModels = const [],
    this.onModelPinned,
    this.onModelUnpinned,
    this.onClose,
  });

  @override
  ConsumerState<ModelSelectorPopup> createState() => _ModelSelectorPopupState();
}

class _ModelSelectorPopupState extends ConsumerState<ModelSelectorPopup> {
  final TextEditingController _globalSearchController = TextEditingController();
  String _globalSearchQuery = '';

  String? _hoveredProvider;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  String? _hoveredModel;
  String? _hoveredGearProvider;

  @override
  void dispose() {
    _globalSearchController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Small colored circle for a provider (used in search results header).
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
      final colorKey = colors.keys.firstWhere(
        (k) => k.toLowerCase() == lower, 
        orElse: () => 'OpenAI'
      );
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
    if (color == null) return const SizedBox(width: 10);
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _buildSubModelRow(String name, {bool isSelected = false}) {
    final isHovered = _hoveredModel == name;
    final actuallyPinned = widget.pinnedModels.contains(name);
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredModel = name),
      onExit: (_) => setState(() {
        if (_hoveredModel == name) _hoveredModel = null;
      }),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            widget.onModelSelected(name);
            widget.onClose?.call();
          },
          hoverColor: const Color(0xFF2F2F2F),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 36,
            margin: const EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: isSelected || isHovered
                  ? const Color(0xFF2F2F2F)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                if (isSelected)
                  Positioned(
                    left: 0,
                    top: 8,
                    child: Container(
                      width: 3,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFFB4B4B4),
                          fontSize: 13,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (isHovered || actuallyPinned) ...[
                      GestureDetector(
                        onTap: () {
                          if (actuallyPinned) {
                            widget.onModelUnpinned?.call(name);
                          } else {
                            widget.onModelPinned?.call(name);
                          }
                        },
                        child: Tooltip(
                          message: actuallyPinned ? 'Unpin model' : 'Pin model',
                          child: Icon(
                            actuallyPinned
                                ? Icons.push_pin
                                : Icons.push_pin_outlined,
                            color: actuallyPinned
                                ? Colors.white
                                : const Color(0xFF6E6E6E),
                            size: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (isSelected) ...[
                      const Icon(Icons.check_circle_outline,
                          color: Colors.white, size: 16),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModelOptionRow(
      BuildContext context, String name, Color circleColor, bool isSelected) {
    final isHovered = _hoveredProvider == name;
    return MouseRegion(
      onEnter: (_) {
        if (_hoveredProvider != name) {
          setState(() => _hoveredProvider = name);
        }
      },
      child: InkWell(
        onTap: () {
          // You can collapse the selector here if you want
        },
        child: Container(
          height: 36,
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: isSelected || isHovered
                ? const Color(0xFF2F2F2F)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              if (isSelected)
                Positioned(
                  left: 0,
                  top: 8,
                  child: Container(
                    width: 3,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ),
              Row(
                children: [
                  const SizedBox(width: 16),
                  _providerCircle(name),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      name,
                      style: TextStyle(
                        color:
                            isSelected ? Colors.white : const Color(0xFFB4B4B4),
                        fontSize: 13,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      widget.onClose?.call();
                      showDialog(
                        context: context,
                        builder: (context) => ApiKeyDialog(providerName: name),
                      );
                    },
                    child: MouseRegion(
                      onEnter: (_) =>
                          setState(() => _hoveredGearProvider = name),
                      onExit: (_) =>
                          setState(() => _hoveredGearProvider = null),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.settings_outlined,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF6E6E6E),
                            size: 16,
                          ),
                          if (_hoveredGearProvider == name) ...[
                            const SizedBox(width: 6),
                            const Text('Set API Key',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 12)),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (isSelected) ...[
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.check_circle_outline,
                      color: Colors.white,
                      size: 16,
                    ),
                  ],
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right,
                    color: isSelected ? Colors.white : const Color(0xFF6E6E6E),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSearching = _globalSearchQuery.isNotEmpty;
    final asyncModels = ref.watch(providerModelsProvider);

    return asyncModels.when(
      loading: () => const Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 360,
          height: 100,
          child: Center(
            child: CircularProgressIndicator(color: Colors.white54),
          ),
        ),
      ),
      error: (err, stack) => Material(
        color: Colors.transparent,
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF171717),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2A2A2A)),
          ),
          child: Text('Failed to load models: $err', style: const TextStyle(color: Colors.red)),
        ),
      ),
      data: (allProviderModels) {
        // Build flat search results grouped by provider
        Widget buildSearchResults() {
          final results = <Widget>[];
          allProviderModels.forEach((provider, models) {
            final matched = models
                .where((m) => m.toLowerCase().contains(_globalSearchQuery))
                .toList();
            if (matched.isEmpty) return;
            // Provider header
            results.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    _providerCircle(provider),
                    const SizedBox(width: 8),
                    Text(provider,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            );
            for (final model in matched) {
              results.add(
                  _buildSubModelRow(model, isSelected: model == widget.selectedModel));
            }
          });
          if (results.isEmpty) {
            results.add(const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No models found',
                  style: TextStyle(color: Color(0xFF878787), fontSize: 13)),
            ));
          }
          return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: results);
        }

        // Determine which provider is currently selected
        String selectedProvider = '';
        allProviderModels.forEach((provider, models) {
          if (models.contains(widget.selectedModel)) {
            selectedProvider = provider;
          }
        });

        return Material(
          color: Colors.transparent,
          elevation: 24,
          shadowColor: Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 360,
                constraints: const BoxConstraints(maxHeight: 650),
                decoration: BoxDecoration(
                  color: const Color(0xFF171717),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF2A2A2A)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Global search field
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      child: TextField(
                        controller: _globalSearchController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        cursorColor: Colors.white,
                        onChanged: (val) => setState(() {
                          _globalSearchQuery = val.toLowerCase();
                          if (val.isNotEmpty) _hoveredProvider = null;
                        }),
                        decoration: InputDecoration(
                          hintText: 'Search models...',
                          hintStyle: const TextStyle(
                              color: Color(0xFF6E6E6E), fontSize: 13),
                          prefixIcon: const Icon(Icons.search,
                              color: Color(0xFF6E6E6E), size: 16),
                          prefixIconConstraints:
                              const BoxConstraints(minWidth: 36, minHeight: 36),
                          filled: true,
                          fillColor: const Color(0xFF1E1E1E),
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide:
                                  const BorderSide(color: Color(0xFF2A2A2A))),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide:
                                  const BorderSide(color: Color(0xFF2A2A2A))),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide:
                                  const BorderSide(color: Color(0xFF3A3A3A))),
                        ),
                      ),
                    ),
                    // Content: flat search results OR provider list
                    Flexible(
                      child: isSearching
                          ? buildSearchResults()
                          : ListView(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 8),
                              children: allProviderModels.keys.map((provider) {
                                return _buildModelOptionRow(
                                    context,
                                    provider,
                                    Colors.white,
                                    selectedProvider == provider);
                              }).toList(),
                            ),
                    ),
                  ],
                ),
              ),
              // Sub-panel: per-provider model list (only when not globally searching)
              if (!isSearching && _hoveredProvider != null) ...[
                const SizedBox(width: 4),
                Container(
                  width: 320,
                  constraints: const BoxConstraints(maxHeight: 650),
                  decoration: BoxDecoration(
                    color: const Color(0xFF171717),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF2A2A2A)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: TextField(
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          cursorColor: Colors.white,
                          controller: _searchController,
                          onChanged: (val) =>
                              setState(() => _searchQuery = val.toLowerCase()),
                          decoration: InputDecoration(
                            hintText: 'Search $_hoveredProvider models...',
                            hintStyle: const TextStyle(
                                color: Color(0xFF6E6E6E), fontSize: 13),
                            prefixIcon: const Icon(Icons.search,
                                color: Color(0xFF6E6E6E), size: 16),
                            prefixIconConstraints:
                                const BoxConstraints(minWidth: 36, minHeight: 36),
                            filled: true,
                            fillColor: const Color(0xFF1E1E1E),
                            contentPadding: const EdgeInsets.symmetric(vertical: 8),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide:
                                    const BorderSide(color: Color(0xFF2A2A2A))),
                            enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide:
                                    const BorderSide(color: Color(0xFF2A2A2A))),
                            focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide:
                                    const BorderSide(color: Color(0xFF3A3A3A))),
                          ),
                        ),
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          children: (allProviderModels[_hoveredProvider!] ?? [])
                              .where((m) =>
                                  _searchQuery.isEmpty ||
                                  m.toLowerCase().contains(_searchQuery))
                              .map((model) {
                            final isSelected = model == widget.selectedModel;
                            return _buildSubModelRow(model, isSelected: isSelected);
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
