import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:veraxi_app/features/control_panel/view_models/control_panel_view_model.dart';

class ControlPanelScreen extends ConsumerWidget {
  const ControlPanelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(controlPanelViewModelProvider);
    final viewModel = ref.read(controlPanelViewModelProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Control Panel', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('System Intelligence', style: theme.textTheme.titleLarge)
                .animate().fade().slideY(begin: 0.2),
            const SizedBox(height: 16),
            _buildStatsGrid(context, state)
                .animate().fade(delay: 100.ms).slideY(begin: 0.2),
            const SizedBox(height: 32),
            Text('Configuration', style: theme.textTheme.titleLarge)
                .animate().fade(delay: 200.ms).slideY(begin: 0.2),
            const SizedBox(height: 16),
            _buildIngestionCard(context, state, viewModel)
                .animate().fade(delay: 300.ms).slideY(begin: 0.2),
            const SizedBox(height: 32),
            Text('Diagnostics', style: theme.textTheme.titleLarge)
                .animate().fade(delay: 400.ms).slideY(begin: 0.2),
            const SizedBox(height: 16),
            _buildDiagnosticsCard(context)
                .animate().fade(delay: 500.ms).slideY(begin: 0.2),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => viewModel.fetchStats(),
        backgroundColor: theme.colorScheme.primary,
        child: Icon(Icons.refresh, color: theme.colorScheme.onPrimary),
      ),
    );
  }

  Widget _buildStatsGrid(BuildContext context, ControlPanelState state) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            title: 'Knowledge Nodes',
            value: state.stats?.nodeCount.toString() ?? '-',
            icon: Icons.share,
            color: theme.colorScheme.primary,
            isLoading: state.stats == null,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _StatCard(
            title: 'Vector Embeddings',
            value: state.stats?.vectorCount.toString() ?? '-',
            icon: Icons.data_array,
            color: theme.colorScheme.secondary,
            isLoading: state.stats == null,
          ),
        ),
      ],
    );
  }

  Widget _buildIngestionCard(BuildContext context, ControlPanelState state, ControlPanelViewModel viewModel) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.upload_file, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Trigger Data Ingestion', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: state.isIngesting ? null : () => viewModel.triggerIngestion("Run"),
              icon: state.isIngesting 
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: Text(state.isIngesting ? 'Ingesting...' : 'Start Pipeline'),
            ),
            if (state.successMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                state.successMessage!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
              ),
            ],
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Text(
                'Error: ${state.error}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildDiagnosticsCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(Icons.bug_report_outlined, color: theme.colorScheme.error),
        title: Text('Trigger Sentry Exception', style: theme.textTheme.bodyLarge),
        subtitle: Text('Simulate a crash to test telemetry.', style: theme.textTheme.bodySmall),
        trailing: Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
        onTap: () {
          try {
            throw Exception("Manual test exception from Control Panel!");
          } catch (e, stackTrace) {
            Sentry.captureException(e, stackTrace: stackTrace);
          }
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final bool isLoading;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 16),
            isLoading
                ? const SizedBox(
                    height: 32,
                    width: 32,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    value,
                    style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                  ),
            const SizedBox(height: 4),
            Text(title, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
