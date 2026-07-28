import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:veraxi_app/features/settings/views/widgets/settings_dialog.dart';

// Resolved at compile time via --dart-define=IS_SELF_HOSTED=true
const bool _isSelfHosted = bool.fromEnvironment('IS_SELF_HOSTED', defaultValue: false);

/// Returns the display name for the current user.
String resolveDisplayName() {
  if (_isSelfHosted) return 'Local User';
  
  try {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      final meta = user.userMetadata;
      final fullName = meta?['full_name'] as String?;
      if (fullName != null && fullName.isNotEmpty) return fullName;
      final name = meta?['name'] as String?;
      if (name != null && name.isNotEmpty) return name;
      final email = user.email;
      if (email != null && email.isNotEmpty) return email.split('@').first;
    }
  } catch (_) {
    // Supabase not initialised (auth disabled)
  }
  return kDebugMode ? 'Local User' : 'Guest';
}

class ProfileMenuButton extends StatelessWidget {
  const ProfileMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      offset: const Offset(40, -220),
      color: const Color(0xFF171717),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF2A2A2A)),
      ),
      onSelected: (value) {
        if (value == 'settings') {
          showDialog(
            context: context,
            builder: (context) => const SettingsDialog(),
          );
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'email',
          enabled: false,
          child: Text(
            resolveDisplayName(),
            style: const TextStyle(color: Color(0xFFECECEC), fontSize: 13),
          ),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem<String>(
          value: 'help',
          child: Row(
            children: [
              Icon(Icons.help_outline, color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('Help', style: TextStyle(color: Color(0xFFECECEC), fontSize: 14)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'files',
          child: Row(
            children: [
              Icon(Icons.insert_drive_file_outlined, color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('My Files', style: TextStyle(color: Color(0xFFECECEC), fontSize: 14)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'archived',
          child: Row(
            children: [
              Icon(Icons.archive_outlined, color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('Archived chats', style: TextStyle(color: Color(0xFFECECEC), fontSize: 14)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'settings',
          child: Row(
            children: [
              Icon(Icons.settings_outlined, color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('Settings', style: TextStyle(color: Color(0xFFECECEC), fontSize: 14)),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem<String>(
          value: 'logout',
          child: Row(
            children: [
              Icon(Icons.logout_outlined, color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('Log out', style: TextStyle(color: Color(0xFFECECEC), fontSize: 14)),
            ],
          ),
        ),
      ],
      child: Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(
          color: Color(0xFF2F2F2F),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: (resolveDisplayName() == 'Local User' || resolveDisplayName() == 'Guest')
              ? const Icon(Icons.person_outline, color: Color(0xFFECECEC), size: 20)
              : Text(
                  resolveDisplayName().isNotEmpty ? resolveDisplayName()[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: Color(0xFFECECEC),
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
        ),
      ),
    );
  }
}
