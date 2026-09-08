import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'settings_shared_ui.dart';

class AccountSettingsTab extends StatelessWidget {
  const AccountSettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final email =
        Supabase.instance.client.auth.currentUser?.email ?? 'Not signed in';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsUI.buildSectionHeader(context, 'PROFILE'),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildActionRow(context, 'Profile Picture', 'Update your avatar', 'Change'),
          SettingsUI.buildActionRow(context, 'Email Address', email, 'Update'),
        ]),
        const SizedBox(height: 32),
        SettingsUI.buildSectionHeader(context, 'DANGER ZONE', isDestructive: true),
        SettingsUI.buildSettingsGroup(context, [
          SettingsUI.buildActionRow(context, 'Delete account',
              'Permanently remove your account and data', 'Delete',
              isDestructive: true),
        ]),
      ],
    );
  }
}
