import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:veraxi_app/features/settings/views/widgets/settings_dialog.dart';
import 'package:veraxi_app/features/settings/views/widgets/my_files_dialog.dart';
import 'package:veraxi_app/features/settings/views/widgets/archived_chats_dialog.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

// Resolved at compile time via --dart-define=IS_SELF_HOSTED=true
const bool _isSelfHosted =
    bool.fromEnvironment('IS_SELF_HOSTED', defaultValue: false);

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
  } catch (e, st) {
    Sentry.captureException(e, stackTrace: st);
    // Supabase not initialised (auth disabled)
  }
  return kDebugMode ? 'Local User' : 'Guest';
}

class ProfileMenuButton extends ConsumerStatefulWidget {
  final VoidCallback? onDeleteAllChats;
  const ProfileMenuButton({super.key, this.onDeleteAllChats});

  @override
  ConsumerState<ProfileMenuButton> createState() => _ProfileMenuButtonState();
}

class _ProfileMenuButtonState extends ConsumerState<ProfileMenuButton> {
  Map<String, dynamic> _uiConfig = {};

  @override
  void initState() {
    super.initState();
    _fetchConfig();
  }

  Future<void> _fetchConfig() async {
    final repo = ref.read(chatRepositoryProvider);
    final config = await repo.getUIConfig();
    if (mounted) {
      setState(() {
        _uiConfig = config;
      });
    }
  }

  Future<void> _launchUrl(String? urlString, String defaultUrl) async {
    final target =
        (urlString != null && urlString.isNotEmpty) ? urlString : defaultUrl;
    final uri = Uri.parse(target);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final menuStyle = MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(Color(0xFF171717)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF2A2A2A)),
      )),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
    );

    final itemStyle = ButtonStyle(
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
      foregroundColor: const WidgetStatePropertyAll(Color(0xFFECECEC)),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14)),
      overlayColor: WidgetStatePropertyAll(Colors.white.withOpacity(0.05)),
    );

    return MenuAnchor(
      alignmentOffset: const Offset(40, -320),
      style: menuStyle,
      builder:
          (BuildContext context, MenuController controller, Widget? child) {
        return GestureDetector(
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: Color(0xFF2F2F2F),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: (resolveDisplayName() == 'Local User' ||
                      resolveDisplayName() == 'Guest')
                  ? const Icon(Icons.person_outline,
                      color: Color(0xFFECECEC), size: 20)
                  : Text(
                      resolveDisplayName().isNotEmpty
                          ? resolveDisplayName()[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: Color(0xFFECECEC),
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                      ),
                    ),
            ),
          ),
        );
      },
      menuChildren: <Widget>[
        MenuItemButton(
          style: itemStyle,
          onPressed: null,
          child: Text(
            resolveDisplayName(),
            style: const TextStyle(color: Color(0xFFECECEC), fontSize: 13),
          ),
        ),
        const Divider(color: Color(0xFF2A2A2A), height: 1),
        SubmenuButton(
          style: itemStyle,
          menuStyle: menuStyle,
          menuChildren: <Widget>[
            MenuItemButton(
              style: itemStyle,
              onPressed: () => _launchUrl(
                  _uiConfig['help_faq_url'], 'https://veraxi.ai/help'),
              child: const Row(
                children: [
                  Icon(Icons.help_outline, color: Color(0xFFECECEC), size: 16),
                  SizedBox(width: 12),
                  Text('Help & FAQ'),
                ],
              ),
            ),
            MenuItemButton(
              style: itemStyle,
              onPressed: () {},
              child: const Row(
                children: [
                  Icon(Icons.keyboard_outlined,
                      color: Color(0xFFECECEC), size: 16),
                  SizedBox(width: 12),
                  Text('Keyboard Shortcuts'),
                ],
              ),
            ),
            MenuItemButton(
              style: itemStyle,
              onPressed: () => _launchUrl(
                  _uiConfig['terms_of_service_url'], 'https://veraxi.ai/terms'),
              child: const Row(
                children: [
                  Icon(Icons.gavel_outlined,
                      color: Color(0xFFECECEC), size: 16),
                  SizedBox(width: 12),
                  Text('Terms of service'),
                ],
              ),
            ),
            MenuItemButton(
              style: itemStyle,
              onPressed: () => _launchUrl(
                  _uiConfig['privacy_policy_url'], 'https://veraxi.ai/privacy'),
              child: const Row(
                children: [
                  Icon(Icons.privacy_tip_outlined,
                      color: Color(0xFFECECEC), size: 16),
                  SizedBox(width: 12),
                  Text('Privacy policy'),
                ],
              ),
            ),
          ],
          child: const Row(
            children: [
              Icon(Icons.help_outline, color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('Help'),
            ],
          ),
        ),
        MenuItemButton(
          style: itemStyle,
          onPressed: () {
            Future.delayed(Duration.zero, () {
              if (context.mounted) {
                showDialog(
                    context: context,
                    builder: (context) => const MyFilesDialog());
              }
            });
          },
          child: const Row(
            children: [
              Icon(Icons.insert_drive_file_outlined,
                  color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('My Files'),
            ],
          ),
        ),
        MenuItemButton(
          style: itemStyle,
          onPressed: () {
            Future.delayed(Duration.zero, () {
              if (context.mounted) {
                showDialog(
                    context: context,
                    builder: (context) => const ArchivedChatsDialog());
              }
            });
          },
          child: const Row(
            children: [
              Icon(Icons.archive_outlined, color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('Archived chats'),
            ],
          ),
        ),
        MenuItemButton(
          style: itemStyle,
          onPressed: () {
            Future.delayed(Duration.zero, () {
              if (context.mounted) {
                showDialog(
                  context: context,
                  builder: (context) =>
                      SettingsDialog(onDeleteAllChats: widget.onDeleteAllChats),
                );
              }
            });
          },
          child: const Row(
            children: [
              Icon(Icons.settings_outlined, color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('Settings'),
            ],
          ),
        ),
        const Divider(color: Color(0xFF2A2A2A), height: 1),
        MenuItemButton(
          style: itemStyle,
          onPressed: () {},
          child: const Row(
            children: [
              Icon(Icons.logout_outlined, color: Color(0xFFECECEC), size: 16),
              SizedBox(width: 12),
              Text('Log out'),
            ],
          ),
        ),
      ],
    );
  }
}
