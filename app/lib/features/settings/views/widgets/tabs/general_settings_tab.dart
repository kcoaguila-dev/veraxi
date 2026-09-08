import 'package:flutter/material.dart';
import 'settings_shared_ui.dart';

class GeneralSettingsTab extends StatelessWidget {
  const GeneralSettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsUI.buildSectionHeader(context, 'APPEARANCE'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildDropdownRow(context, 'Theme', 'System'),
          SettingsUI.buildDropdownRow(context, 'Language', 'English'),
          SettingsUI.buildDropdownRow(context, 'Message Font Size', 'Medium'),
          SettingsUI.buildTextButtonRow(context, 'Chat direction', 'ltr'),
        ]),
        const SizedBox(height: 32),
        SettingsUI.buildSectionHeader(context, 'LAYOUT'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildToggleRow(context, 'Maximize chat space', false),
          SettingsUI.buildToggleRow(context, 'Center Chat Input on Welcome Screen', true),
          SettingsUI.buildToggleRow(context, 'Scroll to the end button', true),
        ]),
        const SizedBox(height: 32),
        SettingsUI.buildSectionHeader(context, 'ACCESSIBILITY'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildToggleRow(context, 'Keep screen awake during response generation', true),
        ]),
      ],
    );
  }
}
