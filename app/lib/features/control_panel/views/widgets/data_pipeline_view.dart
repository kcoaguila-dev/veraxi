import 'package:flutter/material.dart';
import 'package:veraxi_app/features/control_panel/views/widgets/schema_card.dart';
import 'package:veraxi_app/features/control_panel/views/widgets/ingestion_card.dart';
import 'package:veraxi_app/features/control_panel/views/widgets/database_monitor_card.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class DataPipelineView extends StatelessWidget {
  const DataPipelineView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Knowledge Base',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(
          'Manage your custom knowledge base.',
          style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 14),
        ),
        SizedBox(height: 32),
        const SchemaCard(),
        SizedBox(height: 32),
        const IngestionCard(),
        SizedBox(height: 48),
        Text('Database Monitors',
            style: theme.textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 20)),
        SizedBox(height: 8),
        Text(
          'Launch web dashboards to inspect the raw databases.',
          style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 14),
        ),
        SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DatabaseMonitorCard(
                title: 'Qdrant',
                subtitle: 'Vector Database',
                url: const String.fromEnvironment('QDRANT_DASHBOARD_URL',
                    defaultValue: 'http://localhost:6333/dashboard'),
                icon: Icons.data_array,
              ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: DatabaseMonitorCard(
                title: 'Neo4j',
                subtitle: 'Knowledge Graph',
                url: const String.fromEnvironment('NEO4J_DASHBOARD_URL',
                    defaultValue: 'http://localhost:7474'),
                icon: Icons.hub,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
