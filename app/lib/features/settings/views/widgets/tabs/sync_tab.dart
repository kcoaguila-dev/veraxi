import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/sync/sync_service.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'settings_shared_ui.dart';

class SyncTab extends ConsumerStatefulWidget {
  const SyncTab({super.key});

  @override
  ConsumerState<SyncTab> createState() => _SyncTabState();
}

class _SyncTabState extends ConsumerState<SyncTab> {
  final _passphraseController = TextEditingController();
  bool _isLoading = false;
  String? _error;
  String? _success;

  Future<void> _handleSync({required bool isPush}) async {
    final passphrase = _passphraseController.text;
    if (passphrase.isEmpty) {
      setState(() => _error = 'Passphrase is required.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _success = null;
    });

    try {
      final syncService = ref.read(syncServiceProvider);
      if (isPush) {
        await syncService.pushSync(passphrase);
        setState(() => _success = 'Successfully pushed encrypted keys to cloud.');
      } else {
        await syncService.pullSync(passphrase);
        setState(() => _success = 'Successfully downloaded and restored keys.');
      }
    } catch (e) {
      setState(() {
        if (e.toString().contains('403')) {
          _error = 'Sync is a premium feature. Please upgrade to Pro.';
        } else if (e.toString().contains('404')) {
          _error = 'No sync data found on the server.';
        } else {
          _error = 'Error during sync: $e';
        }
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsUI.buildSectionHeader(context, 'Secure API Key Sync (E2EE)'),
        const Text(
          'Sync your local BYOD API keys across devices. Keys are encrypted locally with your passphrase before uploading. The server never sees your plaintext keys.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 24),
        SettingsTextFieldRow(
          label: 'Sync Passphrase',
          controller: _passphraseController,
          obscureText: true,
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        if (_success != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(_success!, style: const TextStyle(color: Colors.green)),
          ),
        Row(
          children: [
            ElevatedButton(
              onPressed: _isLoading ? null : () => _handleSync(isPush: true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
              ),
              child: _isLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('Push Keys to Cloud'),
            ),
            const SizedBox(width: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : () => _handleSync(isPush: false),
              style: ElevatedButton.styleFrom(
                backgroundColor: ext.surfaceHighlight,
                foregroundColor: Colors.white,
              ),
              child: _isLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('Pull Keys from Cloud'),
            ),
          ],
        ),
      ],
    );
  }
}
