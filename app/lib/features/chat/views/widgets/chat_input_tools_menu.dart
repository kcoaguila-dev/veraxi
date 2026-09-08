import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import 'web_search_dialog.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class ChatInputToolsMenu extends StatelessWidget {
  final bool fileSearchActive;
  final bool fileSearchPinned;
  final bool webSearchActive;
  final bool webSearchPinned;
  final bool highAccuracyEnabled;
  final bool skillsActive;
  final bool skillsPinned;
  final bool runCodeActive;
  final bool runCodePinned;
  final bool artifactsActive;
  final bool artifactsPinned;

  final Function(String, bool) onToggleActive;
  final Function(String, bool) onTogglePin;
  final Function(bool) onToggleHighAccuracy;
  final VoidCallback onReloadSettings;

  const ChatInputToolsMenu({
    super.key,
    required this.fileSearchActive,
    required this.fileSearchPinned,
    required this.webSearchActive,
    required this.webSearchPinned,
    required this.highAccuracyEnabled,
    required this.skillsActive,
    required this.skillsPinned,
    required this.runCodeActive,
    required this.runCodePinned,
    required this.artifactsActive,
    required this.artifactsPinned,
    required this.onToggleActive,
    required this.onTogglePin,
    required this.onToggleHighAccuracy,
    required this.onReloadSettings,
  });

  Widget _buildToolItem(BuildContext context, String value, String text, IconData icon,
      {bool isActive = false, bool isPinned = false}) {
    return MenuItemButton(
      style: const ButtonStyle(
          padding:
              WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10))),
      onPressed: () => onToggleActive(value, isActive),
      child: Container(
        width: 155,
        height: 38,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(icon,
                color: isActive
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 14),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            GestureDetector(
              onTap: () => onTogglePin(value, isPinned),
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Icon(isPinned ? LucideIcons.pinOff : LucideIcons.pin,
                    color: isPinned
                        ? Theme.of(context).colorScheme.secondary
                        : const Color(0xFF6E6E6E),
                    size: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebSearchItem(BuildContext context, {bool isActive = false, bool isPinned = false}) {
    return SubmenuButton(
      style: const ButtonStyle(
          padding:
              WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10))),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
        )),
      ),
      menuChildren: [
        MenuItemButton(
          style: const ButtonStyle(
              padding: WidgetStatePropertyAll(EdgeInsets.zero)),
          onPressed: () {
            onToggleHighAccuracy(highAccuracyEnabled);
          },
          child: Container(
            width: 165,
            padding:
                const EdgeInsets.only(left: 14, right: 10, top: 4, bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('High-Accuracy',
                    style: TextStyle(
                        color: Color(0xFFE0E0E0),
                        fontSize: 13,
                        fontWeight: FontWeight.w400)),
                Transform.scale(
                  scale: 0.6,
                  child: Switch(
                    value: highAccuracyEnabled,
                    activeThumbColor: Theme.of(context).colorScheme.secondary,
                    activeTrackColor:
                        Theme.of(context).colorScheme.secondary.withValues(alpha: 0.3),
                    inactiveThumbColor: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                    inactiveTrackColor: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                    onChanged: (val) {
                      onToggleHighAccuracy(!val);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      child: Container(
        width: 155,
        height: 38,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(Icons.language,
                color: isActive
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 14),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Web Search',
                  style: TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            GestureDetector(
              onTap: () async {
                Navigator.of(context).popUntil((route) => route.isFirst);
                await showDialog(
                  context: context,
                  builder: (context) => const WebSearchDialog(),
                );
                onReloadSettings();
              },
              child: const Padding(
                padding: EdgeInsets.all(4.0),
                child: Icon(Icons.settings_outlined,
                    color: Color(0xFF6E6E6E), size: 14),
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => onTogglePin('web_search', isPinned),
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Icon(isPinned ? LucideIcons.pinOff : LucideIcons.pin,
                    color: isPinned
                        ? Theme.of(context).colorScheme.secondary
                        : const Color(0xFF6E6E6E),
                    size: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkillsItem(BuildContext context, {bool isActive = false, bool isPinned = false}) {
    return MenuItemButton(
      style: const ButtonStyle(
          padding:
              WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10))),
      onPressed: () => onToggleActive('skills', isActive),
      child: Container(
        width: 155,
        height: 38,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(Icons.extension_outlined,
                color: isActive
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 14),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Skills',
                  style: TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            GestureDetector(
              onTap: () {
                Navigator.of(context).popUntil((route) => route.isFirst);
                context.go('/admin');
              },
              child: const Padding(
                padding: EdgeInsets.all(4.0),
                child: Icon(Icons.settings_outlined,
                    color: Color(0xFF6E6E6E), size: 14),
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => onTogglePin('skills', isPinned),
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Icon(isPinned ? LucideIcons.pinOff : LucideIcons.pin,
                    color: isPinned
                        ? Theme.of(context).colorScheme.secondary
                        : const Color(0xFF6E6E6E),
                    size: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
        )),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
      ),
      builder: (context, controller, child) {
        return IconButton(
          icon: Icon(Icons.tune, color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, size: 20),
          tooltip: 'Tools',
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
        );
      },
      menuChildren: [
        _buildToolItem(context, 'file_search', 'File Search', Icons.grid_view_outlined,
            isActive: fileSearchActive, isPinned: fileSearchPinned),
        _buildWebSearchItem(context,
            isActive: webSearchActive, isPinned: webSearchPinned),
        _buildSkillsItem(context,
            isActive: skillsActive, isPinned: skillsPinned),
        _buildToolItem(context, 'run_code', 'Run Code', Icons.terminal,
            isActive: runCodeActive, isPinned: runCodePinned),
        _buildToolItem(context, 'artifacts', 'Artifacts >', Icons.auto_awesome,
            isActive: artifactsActive, isPinned: artifactsPinned),
      ],
    );
  }
}

class ChatInputActiveTools extends StatelessWidget {
  final bool fileSearchActive;
  final bool webSearchActive;
  final bool skillsActive;
  final bool runCodeActive;
  final bool artifactsActive;
  final Function(String, bool) onToggleActive;

  const ChatInputActiveTools({
    super.key,
    required this.fileSearchActive,
    required this.webSearchActive,
    required this.skillsActive,
    required this.runCodeActive,
    required this.artifactsActive,
    required this.onToggleActive,
  });

  Widget _buildActiveToolChip(BuildContext context, String label, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6.0),
      child: ActionChip(
        avatar: Icon(icon, color: Theme.of(context).colorScheme.secondary, size: 14),
        label: Text(label,
            style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontSize: 12)),
        backgroundColor: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Theme.of(context).colorScheme.secondary),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
        onPressed: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!fileSearchActive &&
        !webSearchActive &&
        !skillsActive &&
        !runCodeActive &&
        !artifactsActive) {
      return const SizedBox.shrink();
    }
    return Expanded(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (fileSearchActive)
              _buildActiveToolChip(context, 'File Search', Icons.grid_view_outlined,
                  () => onToggleActive('file_search', true)),
            if (webSearchActive)
              _buildActiveToolChip(context, 'Web Search', Icons.language,
                  () => onToggleActive('web_search', true)),
            if (skillsActive)
              _buildActiveToolChip(context, 'Skills', Icons.extension_outlined,
                  () => onToggleActive('skills', true)),
            if (runCodeActive)
              _buildActiveToolChip(context, 'Run Code', Icons.terminal,
                  () => onToggleActive('run_code', true)),
            if (artifactsActive)
              _buildActiveToolChip(context, 'Artifacts', Icons.auto_awesome,
                  () => onToggleActive('artifacts', true)),
          ],
        ),
      ),
    );
  }
}
