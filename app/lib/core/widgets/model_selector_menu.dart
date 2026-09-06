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
  final MenuController _menuController = MenuController();

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
      width: 10,
      height: 10,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  @override
  Widget build(BuildContext context) {
    final asyncModels = ref.watch(providerModelsProvider);

    return MenuAnchor(
      controller: _menuController,
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Color(0xFF171717)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF2A2A2A)),
        )),
        padding:
            const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
      ),
      builder: (context, controller, child) {
        return GestureDetector(
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: widget.child,
        );
      },
      menuChildren: asyncModels.when(
        data: (allProviderModels) {
          final items = <Widget>[];

          // Pinned models section at the top
          if (widget.pinnedModels.isNotEmpty) {
            for (final pinned in widget.pinnedModels) {
              items.add(MenuItemButton(
                onPressed: () => widget.onModelSelected(pinned),
                leadingIcon:
                    const Icon(Icons.push_pin, size: 16, color: Colors.white),
                trailingIcon: widget.selectedModel == pinned
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
                child: Text(pinned,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ));
            }
            items.add(const Divider(color: Color(0xFF2A2A2A), height: 16));
          }

          // Provider groups
          allProviderModels.forEach((provider, models) {
            items.add(SubmenuButton(
              menuStyle: MenuStyle(
                backgroundColor:
                    const WidgetStatePropertyAll(Color(0xFF171717)),
                shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF2A2A2A)),
                )),
                padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(vertical: 8)),
                maximumSize: const WidgetStatePropertyAll(Size.fromHeight(400)),
              ),
              leadingIcon: _providerCircle(provider),
              trailingIcon: GestureDetector(
                onTap: () {
                  _menuController.close();
                  showDialog(
                    context: context,
                    builder: (context) => ApiKeyDialog(providerName: provider),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.only(left: 8.0),
                  child: Icon(Icons.settings_outlined,
                      size: 16, color: Color(0xFF878787)),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(provider,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
              menuChildren: models.map((model) {
                final isSelected = widget.selectedModel == model;
                final isPinned = widget.pinnedModels.contains(model);
                return MenuItemButton(
                  onPressed: () => widget.onModelSelected(model),
                  leadingIcon: SizedBox(
                    width: 24,
                    child: isSelected
                        ? const Icon(Icons.check, size: 16, color: Colors.white)
                        : null,
                  ),
                  trailingIcon: IconButton(
                    icon: Icon(
                      isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                      size: 14,
                      color: isPinned ? Colors.white : const Color(0xFF6E6E6E),
                    ),
                    onPressed: () {
                      if (isPinned) {
                        widget.onModelUnpinned?.call(model);
                      } else {
                        widget.onModelPinned?.call(model);
                      }
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 16,
                  ),
                  child: Text(
                    model,
                    style: TextStyle(
                      color:
                          isSelected ? Colors.white : const Color(0xFFB4B4B4),
                      fontSize: 13,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                );
              }).toList(),
            ));
          });
          return items;
        },
        loading: () => [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child:
                Center(child: CircularProgressIndicator(color: Colors.white54)),
          )
        ],
        error: (e, s) => [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('Error: $e', style: const TextStyle(color: Colors.red)),
          )
        ],
      ),
    );
  }
}
