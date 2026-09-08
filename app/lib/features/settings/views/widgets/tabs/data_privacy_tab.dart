import 'package:flutter/material.dart';
import 'settings_shared_ui.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class DataPrivacyTab extends StatelessWidget {
  final VoidCallback? onDeleteAllChats;

  const DataPrivacyTab({super.key, this.onDeleteAllChats});

  void _exportUserData(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Exporting user data... This may take a moment.')),
    );
    // In a full implementation, we'd make an HTTP call to /api/user/export and trigger a file download
  }

  void _showDeleteAccountConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
        title: Text('Delete account & data',
            style: TextStyle(color: Colors.white)),
        content: Text(
            'Are you sure you want to permanently delete your account and all conversations? This action cannot be undone.',
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F)),
            onPressed: () {
              if (onDeleteAllChats != null) {
                onDeleteAllChats!();
              }
              Navigator.of(ctx).pop();
            },
            child: Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsUI.buildSectionHeader(context, 'YOUR DATA'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildActionRow(context, 
              'Export data', 'Download a copy of your data as JSON', 'Export',
              onTap: () => _exportUserData(context)),
          SettingsUI.buildActionRow(context, 'Delete account & data',
              'Permanently remove your account and all conversations', 'Delete',
              isDestructive: true,
              onTap: () => _showDeleteAccountConfirmation(context)),
        ]),
        SizedBox(height: 32),
        SettingsUI.buildSectionHeader(context, 'TELEMETRY'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildToggleRow(context, 'Share anonymous usage data', false),
        ]),
      ],
    );
  }
}
