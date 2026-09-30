import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veraxi_app/core/theme_extension.dart';

class AgentSkillsTab extends ConsumerStatefulWidget {
  const AgentSkillsTab({super.key});

  @override
  ConsumerState<AgentSkillsTab> createState() => _AgentSkillsTabState();
}

class _AgentSkillsTabState extends ConsumerState<AgentSkillsTab> {
  List<Map<String, dynamic>> _skills = [];
  bool _isLoadingSkills = true;
  final TextEditingController _skillNameController = TextEditingController();
  final TextEditingController _skillUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSkills();
  }

  @override
  void dispose() {
    _skillNameController.dispose();
    _skillUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadSkills() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('tool_settings');
    if ((settingsJson ?? '').isNotEmpty) {
      try {
        final settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
        if (settings['agent_skills'] != null) {
          final skills = settings['agent_skills'] as List<dynamic>;
          setState(() {
            _skills = skills
                .map((e) => {
                      'name': (e['name'] as String?) ?? '',
                      'url': (e['url'] as String?) ?? '',
                      'enabled': (e['enabled'] as bool?) ?? true,
                    })
                .toList();
          });
        }
      } catch (e) {
        // ignore
      }
    }
    if (mounted) setState(() => _isLoadingSkills = false);
  }

  Future<void> _saveSkills() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if ((settingsJson ?? '').isNotEmpty) {
      try {
        settings = jsonDecode(settingsJson!) as Map<String, dynamic>;
      } catch (_) {}
    }
    settings['agent_skills'] = _skills;
    await prefs.setString('tool_settings', jsonEncode(settings));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agent Skills saved successfully')),
      );
    }
  }

  void _showAddSkillDialog() {
    _skillNameController.clear();
    _skillUrlController.clear();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
        title: Text('Add Custom Skill', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _skillNameController,
              style: TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Skill Name',
                labelStyle: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                ),
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: _skillUrlController,
              style: TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Endpoint / Resource URL',
                labelStyle: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary)),
          ),
          ElevatedButton(
            onPressed: () {
              if (_skillNameController.text.isNotEmpty && _skillUrlController.text.isNotEmpty) {
                setState(() {
                  _skills.add({
                    'name': _skillNameController.text,
                    'url': _skillUrlController.text,
                    'enabled': true,
                  });
                });
                _saveSkills();
                Navigator.pop(context);
              }
            },
            child: Text('Add'),
          ),
        ],
      ),
    );
  }

  void _removeSkill(int index) {
    setState(() {
      _skills.removeAt(index);
    });
    _saveSkills();
  }

  void _toggleSkill(int index, bool value) {
    setState(() {
      _skills[index]['enabled'] = value;
    });
    _saveSkills();
  }

  Widget _buildIntegrationCard({
    required String title,
    required String status,
    required Color statusColor,
    required String description,
    required IconData icon,
    required Color iconColor,
    required bool isOn,
    required ValueChanged<bool> onToggle,
    VoidCallback? onDelete,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
      ),
      padding: EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    SizedBox(height: 4),
                    Row(
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                        SizedBox(width: 6),
                        Text(status, style: TextStyle(color: statusColor, fontSize: 13, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                ),
              ),
              Switch(
                value: isOn,
                onChanged: onToggle,
                activeColor: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
          Spacer(),
          Text(description, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13)),
          if (onDelete != null) ...[
            SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                label: Text('Remove', style: TextStyle(color: Colors.redAccent)),
              ),
            ),
          ]
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Agent Skills', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text('Manage the specialized abilities the agent can dynamically invoke.', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary)),
        SizedBox(height: 40),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            ElevatedButton.icon(
              onPressed: _showAddSkillDialog,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
                minimumSize: const Size(140, 44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: Icon(Icons.add),
              label: Text('Add Custom Skill', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        SizedBox(height: 40),
        if (_isLoadingSkills)
          Center(child: CircularProgressIndicator())
        else if (_skills.isEmpty)
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Text('No Custom Skills configured.', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary)),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 800;
              return GridView.count(
                crossAxisCount: isWide ? 2 : 1,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 24,
                mainAxisSpacing: 24,
                childAspectRatio: isWide ? 2.5 : 2.0,
                children: List.generate(_skills.length, (index) {
                  final skill = _skills[index];
                  final isOn = skill['enabled'] == true;
                  return _buildIntegrationCard(
                    title: skill['name'] ?? 'Custom Skill',
                    status: isOn ? 'Skill Active' : 'Disabled',
                    statusColor: isOn ? const Color(0xFF10B981) : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                    description: skill['url'] ?? '',
                    icon: Icons.psychology_outlined,
                    iconColor: isOn ? const Color(0xFFEab308) : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                    isOn: isOn,
                    onToggle: (val) => _toggleSkill(index, val),
                    onDelete: () => _removeSkill(index),
                  );
                }),
              );
            },
          ),
      ],
    );
  }
}
