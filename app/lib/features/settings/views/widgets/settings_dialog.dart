import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/core/widgets/veraxi_logo.dart';
import 'package:veraxi_app/features/settings/view_models/tts_settings_view_model.dart';
import 'manage_voices_dialog.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SettingsDialog extends ConsumerStatefulWidget {
  final VoidCallback? onDeleteAllChats;
  const SettingsDialog({super.key, this.onDeleteAllChats});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  String _selectedTab = 'General';

  final List<String> _tabs = [
    'General',
    'Chat',
    'Speech',
    'Data & Privacy',
    'Account',
    'About',
  ];

  final Map<String, IconData> _tabIcons = {
    'General': Icons.settings_outlined,
    'Chat': Icons.chat_bubble_outline,
    'Speech': Icons.mic_none,
    'Data & Privacy': Icons.dataset_outlined,
    'Account': Icons.person_outline,
    'About': Icons.info_outline,
  };

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: 800,
        height: 600,
        decoration: BoxDecoration(
          color: const Color(0xFF171717),
          borderRadius: BorderRadius.circular(12),
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
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.only(
                  left: 24, right: 16, top: 16, bottom: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Settings',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Color(0xFF878787), size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                    splashRadius: 20,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A2A)),
            // Body
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Sidebar
                  Container(
                    width: 240,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Search
                        Container(
                          height: 36,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFF3A3A3A)),
                          ),
                          child: Row(
                            children: [
                              const SizedBox(width: 12),
                              const Icon(Icons.search,
                                  color: Color(0xFF878787), size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13),
                                  cursorColor: Colors.white,
                                  decoration: const InputDecoration.collapsed(
                                    hintText: 'Search settings',
                                    hintStyle: TextStyle(
                                        color: Color(0xFF878787), fontSize: 13),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Tabs
                        Expanded(
                          child: ListView.builder(
                            itemCount: _tabs.length,
                            itemBuilder: (context, index) {
                              final tab = _tabs[index];
                              final isSelected = tab == _selectedTab;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: InkWell(
                                  onTap: () {
                                    setState(() {
                                      _selectedTab = tab;
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  hoverColor: const Color(0xFF2F2F2F),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? const Color(0xFF2F2F2F)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          _tabIcons[tab],
                                          color: const Color(0xFFECECEC),
                                          size: 16,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            tab,
                                            style: const TextStyle(
                                              color: Color(0xFFECECEC),
                                              fontSize: 13,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Vertical Divider
                  Container(
                    width: 1,
                    color: const Color(0xFF2A2A2A),
                  ),
                  // Content
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(32),
                      children: _buildTabContent(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildTabContent() {
    switch (_selectedTab) {
      case 'General':
        return _buildGeneralTab();
      case 'Chat':
        return _buildChatTab();
      case 'Speech':
        return _buildSpeechTab();
      case 'Data & Privacy':
        return _buildDataPrivacyTab();
      case 'Account':
        return _buildAccountTab();
      case 'About':
        return _buildAboutTab();
      default:
        return [
          const Center(
              child: Text('Not implemented yet',
                  style: TextStyle(color: Color(0xFF878787))))
        ];
    }
  }

  List<Widget> _buildGeneralTab() {
    return [
      _buildSectionHeader('APPEARANCE'),
      _buildSettingsGroup([
        _buildDropdownRow('Theme', 'System'),
        _buildDropdownRow('Language', 'English'),
        _buildDropdownRow('Message Font Size', 'Medium'),
        _buildTextButtonRow('Chat direction', 'ltr'),
      ]),
      const SizedBox(height: 32),
      _buildSectionHeader('LAYOUT'),
      _buildSettingsGroup([
        _buildToggleRow('Maximize chat space', false),
        _buildToggleRow('Center Chat Input on Welcome Screen', true),
        _buildToggleRow('Scroll to the end button', true),
      ]),
      const SizedBox(height: 32),
      _buildSectionHeader('ACCESSIBILITY'),
      _buildSettingsGroup([
        _buildToggleRow('Keep screen awake during response generation', true),
      ]),
    ];
  }

  List<Widget> _buildChatTab() {
    return [
      _buildSectionHeader('MESSAGING'),
      _buildSettingsGroup([
        _buildToggleRow('Send message on Enter', true),
        _buildToggleRow('Show message history', true),
      ]),
      const SizedBox(height: 32),
      _buildSectionHeader('CODE'),
      _buildSettingsGroup([
        _buildToggleRow('Wrap code blocks', false),
        _buildDropdownRow('Code block theme', 'Default'),
      ]),
    ];
  }

  List<Widget> _buildSpeechTab() {
    final ttsState = ref.watch(ttsSettingsViewModelProvider);
    final isBrowser = ttsState.selectedEngine == 'Browser';

    String voiceDisplay;
    List<String> voiceOptions;

    if (isBrowser) {
      voiceDisplay = 'Default (System)';
      voiceOptions = ['Default (System)'];
    } else {
      if (ttsState.isLoading) {
        voiceDisplay = 'Loading...';
        voiceOptions = ['Loading...'];
      } else if (ttsState.error != null ||
          ttsState.voices.isEmpty ||
          (ttsState.voices.length == 1 &&
              ttsState.voices.first['id'] == 'default_system')) {
        voiceDisplay = 'No voices available';
        voiceOptions = ['No voices available'];
      } else {
        final customVoices =
            ttsState.voices.where((v) => v['id'] != 'default_system').toList();
        if (customVoices.isEmpty) {
          voiceDisplay = 'No voices available';
          voiceOptions = ['No voices available'];
        } else {
          final selected = customVoices.firstWhere(
              (v) => v['id'] == ttsState.selectedVoiceId,
              orElse: () => customVoices.first);
          voiceDisplay = selected['name'] ?? 'Unknown';
          voiceOptions = customVoices.map((v) => v['name'].toString()).toList();
        }
      }
    }

    final urlController = TextEditingController(text: ttsState.gptSovitsUrl);

    return [
      _buildSectionHeader('TEXT TO SPEECH'),
      _buildSettingsGroup([
        _buildRealDropdownRow(
          'Engine',
          ttsState.selectedEngine,
          ['Browser', 'GPT-SoVITS'],
          (value) {
            ref.read(ttsSettingsViewModelProvider.notifier).setEngine(value);
          },
        ),
        if (!isBrowser)
          _buildTextFieldRow(
            'API Base URL',
            urlController,
            onSubmitted: (value) {
              ref
                  .read(ttsSettingsViewModelProvider.notifier)
                  .setGptSovitsUrl(value);
            },
          ),
        _buildRealDropdownRow(
          'Voice',
          voiceDisplay,
          voiceOptions,
          (value) {
            if (isBrowser ||
                value == 'Loading...' ||
                value == 'No voices available') return;
            final voiceId =
                ttsState.voices.firstWhere((v) => v['name'] == value)['id']!;
            ref.read(ttsSettingsViewModelProvider.notifier).setVoice(voiceId);
          },
        ),
        _buildDropdownRow('Playback speed', '1.0x'),
        if (ttsState.selectedEngine == 'GPT-SoVITS')
          _buildActionRow(
            'Manage Voices',
            'Add or configure GPT-SoVITS personas',
            'Manage',
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => const ManageVoicesDialog(),
              );
            },
          ),
      ]),
      const SizedBox(height: 32),
      _buildSectionHeader('SPEECH TO TEXT'),
      _buildSettingsGroup([
        _buildDropdownRow('Language', 'Auto-detect'),
      ]),
    ];
  }

  List<Widget> _buildDataPrivacyTab() {
    return [
      _buildSectionHeader('YOUR DATA'),
      _buildSettingsGroup([
        _buildActionRow(
            'Export data', 'Download a copy of your data as JSON', 'Export',
            onTap: () => _exportUserData(context)),
        _buildActionRow('Delete account & data',
            'Permanently remove your account and all conversations', 'Delete',
            isDestructive: true,
            onTap: () => _showDeleteAccountConfirmation(context)),
      ]),
      const SizedBox(height: 32),
      _buildSectionHeader('TELEMETRY'),
      _buildSettingsGroup([
        _buildToggleRow('Share anonymous usage data', false),
      ]),
    ];
  }

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
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Delete account & data',
            style: TextStyle(color: Colors.white)),
        content: const Text(
            'Are you sure you want to permanently delete your account and all conversations? This action cannot be undone.',
            style: TextStyle(color: Color(0xFF878787))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F)),
            onPressed: () {
              if (widget.onDeleteAllChats != null) {
                widget.onDeleteAllChats!();
              }
              Navigator.of(ctx).pop();
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildAccountTab() {
    final email = Supabase.instance.client.auth.currentUser?.email ?? 'Not signed in';

    return [
      _buildSectionHeader('PROFILE'),
      _buildSettingsGroup([
        _buildActionRow('Profile Picture', 'Update your avatar', 'Change'),
        _buildActionRow('Email Address', email, 'Update'),
      ]),
      const SizedBox(height: 32),
      _buildSectionHeader('DANGER ZONE', isDestructive: true),
      _buildSettingsGroup([
        _buildActionRow('Delete account',
            'Permanently remove your account and data', 'Delete',
            isDestructive: true),
      ]),
    ];
  }

  List<Widget> _buildAboutTab() {
    return [
      _buildSectionHeader('ABOUT VERAXI'),
      Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border.all(color: const Color(0xFF2A2A2A)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const VeraxiLogo(size: 48, color: Colors.white),
            const SizedBox(height: 16),
            const Text(
              'Veraxi Chat',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Version 1.0.0',
              style: TextStyle(color: Color(0xFF878787), fontSize: 13),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLinkButton('GitHub', Icons.code, 'https://github.com/kcoaguila-dev/veraxi'),
                const SizedBox(width: 12),
                _buildLinkButton('Website', Icons.language, '/'),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildLinkButton(String label, IconData icon, String url) {
    return TextButton.icon(
      onPressed: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      icon: Icon(icon, size: 16, color: const Color(0xFFECECEC)),
      label: Text(label, style: const TextStyle(color: Color(0xFFECECEC))),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        backgroundColor: const Color(0xFF2F2F2F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {bool isDestructive = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
          color:
              isDestructive ? const Color(0xFFE53935) : const Color(0xFF878787),
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildSettingsGroup(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: children.asMap().entries.map((entry) {
          final isLast = entry.key == children.length - 1;
          return Column(
            children: [
              entry.value,
              if (!isLast) const Divider(color: Color(0xFF2A2A2A), height: 1),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDropdownRow(String label, String value, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Text(value,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 13)),
                  const SizedBox(width: 8),
                  const Icon(Icons.keyboard_arrow_down,
                      color: Color(0xFF878787), size: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRealDropdownRow(String label, String value, List<String> items,
      Function(String) onSelected) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
          Theme(
            data: Theme.of(context).copyWith(
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
            ),
            child: PopupMenuButton<String>(
              color: const Color(0xFF2A2A2A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              position: PopupMenuPosition.under,
              onSelected: onSelected,
              itemBuilder: (context) => items
                  .map((item) => PopupMenuItem<String>(
                        value: item,
                        height: 40,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(item,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13)),
                            if (item == value)
                              const Icon(Icons.check,
                                  color: Colors.white, size: 16),
                          ],
                        ),
                      ))
                  .toList(),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Text(value,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13)),
                    const SizedBox(width: 8),
                    const Icon(Icons.keyboard_arrow_down,
                        color: Color(0xFF878787), size: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextButtonRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildTextFieldRow(String label, TextEditingController controller,
      {Function(String)? onSubmitted}) {
    return StatefulBuilder(
      builder: (context, setState) {
        bool isSaved = false;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(label,
                    style: const TextStyle(
                        color: Color(0xFFECECEC), fontSize: 13)),
              ),
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: controller,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 0),
                      filled: true,
                      fillColor: const Color(0xFF2A2A2A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (value) {
                      if (onSubmitted != null) {
                        onSubmitted(value);
                        setState(() => isSaved = true);
                        Future.delayed(const Duration(seconds: 2), () {
                          if (mounted) setState(() => isSaved = false);
                        });
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  if (onSubmitted != null) {
                    onSubmitted(controller.text);
                    setState(() => isSaved = true);
                    Future.delayed(const Duration(seconds: 2), () {
                      if (mounted) setState(() => isSaved = false);
                    });
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isSaved
                      ? const Color(0xFF10A37F)
                      : const Color(0xFF2F2F2F),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
                child: Text(isSaved ? 'Saved' : 'Apply'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildToggleRow(String label, bool value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
          ),
          CupertinoSwitch(
            value: value,
            onChanged: (v) {},
            activeTrackColor: const Color(0xFF10A37F),
            inactiveTrackColor: const Color(0xFF3A3A3A),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow(String title, String subtitle, String buttonText,
      {bool isDestructive = false, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Color(0xFFECECEC), fontSize: 14)),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Color(0xFF878787), fontSize: 12)),
                ],
              ],
            ),
          ),
          ElevatedButton(
            onPressed: onTap ?? () {},
            style: ElevatedButton.styleFrom(
              foregroundColor:
                  isDestructive ? Colors.white : const Color(0xFFECECEC),
              backgroundColor:
                  isDestructive ? const Color(0xFFD32F2F) : Colors.transparent,
              elevation: 0,
              side: isDestructive
                  ? null
                  : const BorderSide(color: Color(0xFF3A3A3A)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(buttonText,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}
