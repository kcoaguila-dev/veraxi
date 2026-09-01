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

  String? _hoveredModel;

  @override
  void dispose() {
    _globalSearchController.dispose();
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

  // _buildModelOptionRow is removed as we no longer use the two-column layout.

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
          child: Text('Failed to load models: $err',
              style: const TextStyle(color: Colors.red)),
        ),
      ),
      data: (allProviderModels) {
        // Build the unified list of models, grouped by provider.
        Widget buildUnifiedList() {
          final results = <Widget>[];
          allProviderModels.forEach((provider, models) {
            List<String> matched = models;
            if (isSearching) {
              final providerMatches =
                  provider.toLowerCase().contains(_globalSearchQuery);
              matched = models
                  .where((m) =>
                      providerMatches ||
                      m.toLowerCase().contains(_globalSearchQuery))
                  .toList();
            }
            if (matched.isEmpty) return;

            // Provider header
            results.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Row(
                  children: [
                    _providerCircle(provider),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        provider,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        widget.onClose?.call();
                        showDialog(
                          context: context,
                          builder: (context) =>
                              ApiKeyDialog(providerName: provider),
                        );
                      },
                      child: Tooltip(
                        message: 'Set API Key for $provider',
                        child: const Icon(
                          Icons.settings_outlined,
                          color: Color(0xFF6E6E6E),
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
            for (final model in matched) {
              results.add(_buildSubModelRow(model,
                  isSelected: model == widget.selectedModel));
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
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              children: results);
        }

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: Container(
            width: 600,
            constraints: const BoxConstraints(maxHeight: 700),
            decoration: BoxDecoration(
              color: const Color(0xFF171717),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2A2A2A)),
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
              children: [
                // Modal Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Select AI Model',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Color(0xFF878787), size: 20),
                        onPressed: () {
                          widget.onClose?.call();
                          Navigator.of(context).pop();
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        splashRadius: 20,
                      ),
                    ],
                  ),
                ),
                // Global search field
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: TextField(
                    controller: _globalSearchController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    cursorColor: Colors.white,
                    onChanged: (val) => setState(() {
                      _globalSearchQuery = val.toLowerCase();
                    }),
                    decoration: InputDecoration(
                      hintText: 'Search models...',
                      hintStyle: const TextStyle(
                          color: Color(0xFF6E6E6E), fontSize: 14),
                      prefixIcon: const Icon(Icons.search,
                          color: Color(0xFF6E6E6E), size: 18),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 40, minHeight: 40),
                      filled: true,
                      fillColor: const Color(0xFF1E1E1E),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0xFF2A2A2A))),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0xFF2A2A2A))),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0xFF3A3A3A))),
                    ),
                  ),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: buildUnifiedList(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }
}
