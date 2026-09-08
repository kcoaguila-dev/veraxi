import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class AgentSkillsView extends StatefulWidget {
  const AgentSkillsView({super.key});

  @override
  State<AgentSkillsView> createState() => _AgentSkillsViewState();
}

class _AgentSkillsViewState extends State<AgentSkillsView> {
  List<Map<String, dynamic>> _skills = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('tool_settings');
    if (settingsJson != null) {
      try {
        final settings = jsonDecode(settingsJson) as Map<String, dynamic>;
        if (settings['skills'] != null) {
          final skills = settings['skills'] as List<dynamic>;
          _skills = skills
              .map((e) => {
                    'id': (e['id'] as String?) ?? '',
                    'name': (e['name'] as String?) ?? '',
                    'description': (e['description'] as String?) ?? '',
                    'instructions': (e['instructions'] as String?) ?? '',
                    'enabled': (e['enabled'] as bool?) ?? true,
                  })
              .toList();
        }
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final currentJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if (currentJson != null) {
      try {
        settings = jsonDecode(currentJson) as Map<String, dynamic>;
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
      }
    }
    settings['skills'] = _skills;
    await prefs.setString('tool_settings', jsonEncode(settings));
  }

  void _showAddSkillDialog() {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final instructionsController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          title: Text('Add Agent Skill',
              style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  style: TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    labelText: 'Skill Name',
                    labelStyle: TextStyle(color: Colors.grey),
                  ),
                ),
                SizedBox(height: 16),
                TextField(
                  controller: descController,
                  style: TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    labelStyle: TextStyle(color: Colors.grey),
                  ),
                ),
                SizedBox(height: 16),
                TextField(
                  controller: instructionsController,
                  style: TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Instructions / Prompt',
                    labelStyle: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.isNotEmpty &&
                    instructionsController.text.isNotEmpty) {
                  setState(() {
                    _skills.add({
                      'id': DateTime.now().millisecondsSinceEpoch.toString(),
                      'name': nameController.text,
                      'description': descController.text,
                      'instructions': instructionsController.text,
                      'enabled': true,
                    });
                  });
                  _saveSettings();
                  Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary),
              child: Text('Add Skill', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleUploadSkill() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['md', 'txt'],
    );
    if (result != null && result.files.single.path != null) {
      // In a real implementation we would read the file
      setState(() {
        _skills.add({
          'id': DateTime.now().millisecondsSinceEpoch.toString(),
          'name': result.files.single.name.replaceAll(RegExp(r'\.(md|txt)$'), ''),
          'description': 'Uploaded via file',
          'instructions': 'Imported instructions...', // Placeholder
          'enabled': true,
        });
      });
      _saveSettings();
    }
  }

  void _removeSkill(int index) {
    setState(() => _skills.removeAt(index));
    _saveSettings();
  }

  void _toggleSkill(int index, bool val) {
    setState(() => _skills[index]['enabled'] = val);
    _saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Agent Skills',
                    style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text(
                    'Manage custom instructions and workflows for the AI models.',
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary)),
              ],
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'write') {
                  _showAddSkillDialog();
                } else if (value == 'upload') {
                  _handleUploadSkill();
                }
              },
              color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              child: Container(
                padding:
                    EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFE3E3E3),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    Icon(Icons.add, size: 18, color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground),
                    SizedBox(width: 4),
                    Text('Add Skill',
                        style: TextStyle(
                            color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'write',
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, size: 18, color: Colors.white),
                      SizedBox(width: 8),
                      Text('Write skill instructions',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'upload',
                  child: Row(
                    children: [
                      Icon(Icons.upload_file_outlined,
                          size: 18, color: Colors.white),
                      SizedBox(width: 8),
                      Text('Upload a skill',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        SizedBox(height: 32),
        if (_isLoading)
          Center(child: CircularProgressIndicator())
        else if (_skills.isEmpty)
          Center(
            child: Padding(
              padding: EdgeInsets.all(32.0),
              child: Text('No skills configured.',
                  style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary)),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _skills.length,
            itemBuilder: (context, index) {
              final skill = _skills[index];
              return Container(
                margin: EdgeInsets.only(bottom: 12),
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                          borderRadius: BorderRadius.circular(8)),
                      child: Icon(Icons.psychology,
                          color: Color(0xFFE3E3E3)),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(skill['name'] as String,
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16)),
                          SizedBox(height: 4),
                          Text(skill['description'] as String,
                              style: TextStyle(
                                  color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 14)),
                        ],
                      ),
                    ),
                    Switch(
                      value: skill['enabled'] as bool,
                      onChanged: (val) => _toggleSkill(index, val),
                      activeThumbColor: Theme.of(context).colorScheme.secondary,
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline,
                          color: Colors.redAccent),
                      onPressed: () => _removeSkill(index),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}
