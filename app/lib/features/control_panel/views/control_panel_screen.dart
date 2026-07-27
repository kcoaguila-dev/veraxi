import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:veraxi_app/features/control_panel/view_models/control_panel_view_model.dart';

class ControlPanelScreen extends ConsumerWidget {
  const ControlPanelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    
    return Scaffold(
      backgroundColor: const Color(0xFF212121),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(40.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Text('MCP Integrations', style: theme.textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                'Manage the external tools, services, and capabilities available to the Sovereign Intelligence.',
                style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFF878787)),
              ),
              const SizedBox(height: 40),

              // Top Action Bar
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF171717),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF333333)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Icon(Icons.search, color: Color(0xFF878787), size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                hintText: 'Search integrations...',
                                hintStyle: TextStyle(color: Color(0xFF878787)),
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF171717),
                      minimumSize: const Size(140, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('Add Server', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 40),

              // Cards Grid
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
                    children: [
                      _buildIntegrationCard(
                        title: 'Neo4j Graph Database',
                        status: 'Live Connection Active',
                        statusColor: const Color(0xFF10B981),
                        description: 'Grants the AI access to query and traverse the enterprise knowledge graph.',
                        icon: Icons.hub,
                        iconColor: const Color(0xFF3B82F6),
                        isOn: true,
                      ),
                      _buildIntegrationCard(
                        title: 'Cloud GPU Processing',
                        status: 'Securely Connected',
                        statusColor: const Color(0xFF10B981),
                        description: 'Grants the AI access to high-performance computing power.',
                        icon: Icons.memory,
                        iconColor: const Color(0xFFE3E3E3),
                        isOn: true,
                      ),
                      _buildIntegrationCard(
                        title: 'Local Filesystem',
                        status: 'Disconnected',
                        statusColor: const Color(0xFF878787),
                        description: 'Permits the AI to read, write, and execute files in the workspace.',
                        icon: Icons.folder_open,
                        iconColor: const Color(0xFF878787),
                        isOn: false,
                      ),
                      _buildIntegrationCard(
                        title: 'GitHub Repositories',
                        status: 'Login Required',
                        statusColor: const Color(0xFFEF4444),
                        description: 'Connects to your codebase to help the AI answer technical questions.',
                        icon: Icons.code,
                        iconColor: const Color(0xFFE3E3E3),
                        isOn: true,
                        borderColor: const Color(0xFFEF4444),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 60),

              // Recent Activity Panel
              Text('Recent Agent Activity', style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                'A transparent log of tools executed by the AI on your behalf.',
                style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF878787)),
              ),
              const SizedBox(height: 24),
              
              // Table
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF171717),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    _buildTableRow('TIMESTAMP', 'AGENT MODEL', 'ACTION PERFORMED', 'STATUS', isHeader: true),
                    _buildTableRow('14:48:32 PM', 'gemini-2.5-flash-lite', 'Read file: docs/architecture.md', 'Success', statusColor: const Color(0xFF10B981)),
                    _buildTableRow('14:45:10 PM', 'gemini-2.5-flash-lite', 'Query Graph: Find architecture patterns', 'Success', statusColor: const Color(0xFF10B981)),
                    _buildTableRow('14:22:05 PM', 'gemini-2.5-flash-lite', 'Fetch GitHub Repository: kcoaguila-dev/veraxi', 'Failed', statusColor: const Color(0xFFEF4444)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIntegrationCard({
    required String title,
    required String status,
    required Color statusColor,
    required String description,
    required IconData icon,
    required Color iconColor,
    required bool isOn,
    Color borderColor = const Color(0xFF333333),
  }) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F2F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF171717),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    Switch(
                      value: isOn,
                      onChanged: (val) {},
                      activeColor: Colors.white,
                      activeTrackColor: const Color(0xFF3B82F6),
                      inactiveThumbColor: const Color(0xFFB4B4B4),
                      inactiveTrackColor: const Color(0xFF424242),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(status, style: TextStyle(color: statusColor, fontSize: 13, fontWeight: FontWeight.w500)),
                  ],
                ),
                const SizedBox(height: 12),
                Text(description, style: const TextStyle(color: Color(0xFFB4B4B4), fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableRow(String col1, String col2, String col3, String col4, {bool isHeader = false, Color? statusColor}) {
    final textColor = isHeader ? const Color(0xFF878787) : const Color(0xFFB4B4B4);
    final textStyle = TextStyle(color: textColor, fontSize: isHeader ? 12 : 13, fontWeight: isHeader ? FontWeight.w600 : FontWeight.w400);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        border: isHeader ? null : const Border(top: BorderSide(color: Color(0xFF333333))),
      ),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(col1, style: textStyle)),
          Expanded(flex: 3, child: Text(col2, style: isHeader ? textStyle : textStyle.copyWith(color: const Color(0xFFE3E3E3), fontWeight: FontWeight.w500))),
          Expanded(flex: 4, child: Text(col3, style: textStyle)),
          Expanded(
            flex: 2,
            child: isHeader
                ? Text(col4, style: textStyle)
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor?.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(col4, style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
