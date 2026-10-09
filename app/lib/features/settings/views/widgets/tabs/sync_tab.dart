import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/sync/sync_service.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/core/api_key_storage.dart';
import 'package:zxcvbnm/zxcvbnm.dart';
import 'package:zxcvbnm/languages/en.dart' as en;
import 'settings_shared_ui.dart';

class SyncTab extends ConsumerStatefulWidget {
  const SyncTab({super.key});

  @override
  ConsumerState<SyncTab> createState() => _SyncTabState();
}

class _SyncTabState extends ConsumerState<SyncTab> {
  final _passphraseController = TextEditingController();
  late final Zxcvbnm _zxcvbnm;
  bool _isPushLoading = false;
  bool _isPullLoading = false;
  bool _obscurePassphrase = true;
  String? _error;
  String? _success;
  int _passwordScore = 0;

  @override
  void initState() {
    super.initState();
    _zxcvbnm = Zxcvbnm(dictionaries: en.dictionaries);
    _passphraseController.addListener(_evaluateStrength);
    _loadCachedPassphrase();
  }

  Future<void> _loadCachedPassphrase() async {
    final storage = ref.read(apiKeyStorageProvider);
    final cached = await storage.getValue('sync_passphrase');
    if (cached != null && cached.isNotEmpty) {
      _passphraseController.text = cached;
    }
  }

  void _evaluateStrength() {
    final text = _passphraseController.text;
    if (text.isEmpty) {
      if (_passwordScore != 0) {
        setState(() => _passwordScore = 0);
      }
      return;
    }
    final result = _zxcvbnm(text);
    if (_passwordScore != result.score.toInt()) {
      setState(() {
        _passwordScore = result.score.toInt();
      });
    }
  }

  Future<void> _handleSync({required bool isPush}) async {
    final passphrase = _passphraseController.text;
    if (passphrase.isEmpty) {
      setState(() => _error = 'Passphrase is required.');
      return;
    }

    setState(() {
      if (isPush) {
        _isPushLoading = true;
      } else {
        _isPullLoading = true;
      }
      _error = null;
      _success = null;
    });

    try {
      final syncService = ref.read(syncServiceProvider);
      if (isPush) {
        await syncService.pushSync(passphrase);
        setState(
            () => _success = 'Successfully pushed encrypted keys to cloud.');
      } else {
        await syncService.pullSync(passphrase);
        setState(() => _success = 'Successfully downloaded and restored keys.');
      }

      // Save it securely after successful sync
      final storage = ref.read(apiKeyStorageProvider);
      await storage.saveValue('sync_passphrase', passphrase);
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
      if (mounted) {
        setState(() {
          _isPushLoading = false;
          _isPullLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _passphraseController.removeListener(_evaluateStrength);
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final isMobile = MediaQuery.sizeOf(context).width < 460;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsUI.buildSectionHeader(context, 'Secure API Key Sync (E2EE)'),
        const Text(
          'Sync your local BYOD API keys across devices. Keys are encrypted locally with your passphrase before uploading. The server never sees your plaintext keys.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 24),
        _buildPassphraseField(context, isMobile),
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
        isMobile
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSyncButton(context, ext, isPush: true, fullWidth: true),
                  const SizedBox(height: 10),
                  _buildSyncButton(context, ext,
                      isPush: false, fullWidth: true),
                ],
              )
            : Row(
                children: [
                  _buildSyncButton(context, ext, isPush: true),
                  const SizedBox(width: 16),
                  _buildSyncButton(context, ext, isPush: false),
                ],
              ),
      ],
    );
  }

  Widget _buildPassphraseField(BuildContext context, bool isMobile) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    final field = TextField(
      controller: _passphraseController,
      obscureText: _obscurePassphrase,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        hintText: 'Enter a sync passphrase',
        hintStyle: TextStyle(color: ext.textTertiary, fontSize: 13),
        filled: true,
        fillColor: ext.borderColor,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide.none,
        ),
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePassphrase ? Icons.visibility_off : Icons.visibility,
            size: 18,
            color: ext.textTertiary,
          ),
          splashRadius: 18,
          tooltip: _obscurePassphrase ? 'Show passphrase' : 'Hide passphrase',
          onPressed: () =>
              setState(() => _obscurePassphrase = !_obscurePassphrase),
        ),
      ),
    );

    final fieldWithMeter = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        if (_passphraseController.text.isNotEmpty) ...[
          const SizedBox(height: 8),
          _buildStrengthMeter(),
        ]
      ],
    );

    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Sync Passphrase',
              style: TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
          const SizedBox(height: 8),
          fieldWithMeter,
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: SizedBox(
            width: 120,
            child: Text('Sync Passphrase',
                style: TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
          ),
        ),
        Expanded(child: fieldWithMeter),
      ],
    );
  }

  Widget _buildStrengthMeter() {
    Color color;
    String label;
    switch (_passwordScore) {
      case 0:
      case 1:
        color = Colors.red;
        label = 'Weak';
        break;
      case 2:
        color = Colors.orange;
        label = 'Fair';
        break;
      case 3:
        color = Colors.lightGreen;
        label = 'Good';
        break;
      case 4:
      default:
        color = Colors.green;
        label = 'Strong';
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        LinearProgressIndicator(
          value: (_passwordScore + 1) / 5,
          backgroundColor: Colors.grey[800],
          valueColor: AlwaysStoppedAnimation<Color>(color),
          borderRadius: BorderRadius.circular(2),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildSyncButton(BuildContext context, AppThemeExtension ext,
      {required bool isPush, bool fullWidth = false}) {
    // Disable push if score < 3, unless pulling (allow pulling with weak passwords for backwards compatibility)
    final bool isPushDisabled = isPush && _passwordScore < 3;
    final bool isLoading = isPush ? _isPushLoading : _isPullLoading;
    final bool isDisabled = _isPushLoading || _isPullLoading || isPushDisabled;

    return SizedBox(
      width: fullWidth ? double.infinity : null,
      child: Tooltip(
        message:
            isPushDisabled ? 'Passphrase must be Good or Strong to push.' : '',
        child: ElevatedButton(
          onPressed: isDisabled ? null : () => _handleSync(isPush: isPush),
          style: ElevatedButton.styleFrom(
            backgroundColor: isPush
                ? Theme.of(context).colorScheme.primary
                : ext.surfaceHighlight,
            foregroundColor: Colors.white,
            disabledBackgroundColor: ext.borderColor,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            minimumSize: const Size(140, 44),
          ),
          child: isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : Text(isPush ? 'Push Keys to Cloud' : 'Pull Keys from Cloud'),
        ),
      ),
    );
  }
}
