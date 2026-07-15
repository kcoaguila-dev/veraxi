import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/control_panel/view_models/settings_view_model.dart';

class ControlPanelScreen extends ConsumerWidget {
  const ControlPanelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsViewModelProvider);
    final viewModel = ref.read(settingsViewModelProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Control Panel',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('System Intelligence',
                    style: Theme.of(context).textTheme.titleLarge)
                .animate()
                .fade()
                .slideY(begin: 0.2),
            const SizedBox(height: 16),
            _buildStatsGrid(state)
                .animate()
                .fade(delay: 100.ms)
                .slideY(begin: 0.2),
            const SizedBox(height: 32),
            Text('Configuration', style: Theme.of(context).textTheme.titleLarge)
                .animate()
                .fade(delay: 200.ms)
                .slideY(begin: 0.2),
            const SizedBox(height: 16),
            _buildApiKeyCard(state, viewModel)
                .animate()
                .fade(delay: 300.ms)
                .slideY(begin: 0.2),
            const SizedBox(height: 32),
            Text('Diagnostics', style: Theme.of(context).textTheme.titleLarge)
                .animate()
                .fade(delay: 400.ms)
                .slideY(begin: 0.2),
            const SizedBox(height: 16),
            _buildDiagnosticsCard()
                .animate()
                .fade(delay: 500.ms)
                .slideY(begin: 0.2),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => viewModel.refreshStats(),
        backgroundColor: AppTheme.primary,
        child: const Icon(Icons.refresh, color: Colors.white),
      ),
    );
  }

  Widget _buildStatsGrid(SettingsState state) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            title: 'Knowledge Nodes',
            value: state.stats?.nodeCount.toString() ?? '-',
            icon: Icons.share,
            color: Colors.blueAccent,
            isLoading: state.isLoading,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _StatCard(
            title: 'Vector Embeddings',
            value: state.stats?.vectorCount.toString() ?? '-',
            icon: Icons.data_array,
            color: Colors.purpleAccent,
            isLoading: state.isLoading,
          ),
        ),
      ],
    );
  }

  Widget _buildApiKeyCard(SettingsState state, SettingsViewModel viewModel) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.vpn_key_outlined, color: AppTheme.primary),
                SizedBox(width: 8),
                Text('Gemini API Key',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: state.geminiKey,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'AIzaSy...',
              ),
              onChanged: (val) {
                // In a real app, debounce this or use a save button.
                viewModel.saveGeminiKey(val);
              },
            ),
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Text(
                'API Error: \${state.error}',
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildDiagnosticsCard() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.bug_report_outlined, color: Colors.redAccent),
        title: const Text('Trigger Sentry Exception'),
        subtitle: const Text('Simulate a crash to test telemetry.'),
        trailing: const Icon(Icons.chevron_right),
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
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                  ),
            const SizedBox(height: 4),
            Text(title, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
