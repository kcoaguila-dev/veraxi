import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';

class InfrastructureTab extends ConsumerWidget {
  const InfrastructureTab({super.key});

  Widget _buildDatabaseMonitorCard(ThemeData theme, String title, String status,
      Color statusColor, IconData icon) {
    return Container(
      decoration: BoxDecoration(
        color: theme.extension<AppThemeExtension>()!.sidebarBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.extension<AppThemeExtension>()!.borderColorStrong),
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
                  color: theme.extension<AppThemeExtension>()!.borderColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: Colors.white, size: 24),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: statusColor, shape: BoxShape.circle)),
                        SizedBox(width: 6),
                        Text(status,
                            style: TextStyle(
                                color: statusColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          Spacer(),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {},
              icon: Icon(Icons.open_in_new,
                  size: 16, color: theme.colorScheme.primary),
              label: Text('Open Dashboard',
                  style: TextStyle(color: theme.colorScheme.primary)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpgradeRequiredCard(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.extension<AppThemeExtension>()!.sidebarBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.extension<AppThemeExtension>()!.borderColorStrong),
      ),
      padding: EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline,
              size: 48,
              color: theme.extension<AppThemeExtension>()!.textTertiary),
          SizedBox(height: 24),
          Text('Enterprise Feature',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600)),
          SizedBox(height: 12),
          Text(
              'Advanced infrastructure management and custom database provisioning are available on the Enterprise plan.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: theme.extension<AppThemeExtension>()!.textTertiary,
                  fontSize: 14)),
          SizedBox(height: 24),
          ElevatedButton(
            onPressed: () {},
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor:
                  theme.extension<AppThemeExtension>()!.sidebarBackground,
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: Text('Contact Sales',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Infrastructure & Self-Hosting',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(
            'Manage the underlying Neo4j and Qdrant clusters powering your Sovereign Intelligence.',
            style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.extension<AppThemeExtension>()!.textTertiary)),
        SizedBox(height: 40),
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
                _buildDatabaseMonitorCard(
                    theme,
                    'Neo4j Graph Database',
                    'Healthy (Managed Cloud)',
                    const Color(0xFF10B981),
                    Icons.hub_outlined),
                _buildDatabaseMonitorCard(
                    theme,
                    'Qdrant Vector Database',
                    'Healthy (Managed Cloud)',
                    const Color(0xFF10B981),
                    Icons.blur_on),
              ],
            );
          },
        ),
        SizedBox(height: 40),
        _buildUpgradeRequiredCard(theme),
      ],
    );
  }
}
