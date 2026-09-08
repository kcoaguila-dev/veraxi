import 'package:flutter/material.dart';
import 'settings_shared_ui.dart';

class ChatSettingsTab extends StatelessWidget {
  const ChatSettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsUI.buildSectionHeader(context, 'MESSAGING'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildToggleRow(context, 'Send message on Enter', true),
          SettingsUI.buildToggleRow(context, 'Show message history', true),
        ]),
        const SizedBox(height: 32),
        SettingsUI.buildSectionHeader(context, 'CODE'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildToggleRow(context, 'Wrap code blocks', false),
          SettingsUI.buildDropdownRow(context, 'Code block theme', 'Default'),
        ]),
      ],
    );
  }
}
