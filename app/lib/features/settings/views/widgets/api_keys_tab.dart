import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/settings/view_models/api_keys_view_model.dart';
import 'package:veraxi_app/core/theme_extension.dart';


/// Renders the "API Keys" tab content inside [SettingsDialog].
class ApiKeysTab extends ConsumerStatefulWidget {
  const ApiKeysTab({super.key});

  @override
  ConsumerState<ApiKeysTab> createState() => _ApiKeysTabState();
}

class _ApiKeysTabState extends ConsumerState<ApiKeysTab> {
  @override
  void initState() {
    super.initState();
    // Show the one-time reveal dialog if a key was just created
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkNewKey());
  }

  @override
  void didUpdateWidget(covariant ApiKeysTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkNewKey());
  }

  void _checkNewKey() {
    final newKey = ref.read(apiKeysViewModelProvider).newlyCreatedKey;
    if (newKey != null && mounted) {
      _showRevealDialog(newKey);
    }
  }

  Future<void> _showRevealDialog(String rawKey) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RevealKeyDialog(rawKey: rawKey),
    );
    ref.read(apiKeysViewModelProvider.notifier).clearNewlyCreatedKey();
  }

  Future<void> _showCreateDialog() async {
    final nameController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          'New API Key',
          style: TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Give this key a descriptive name so you remember where it\'s used.',
              style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13),
            ),
            SizedBox(height: 16),
            TextField(
              controller: nameController,
              autofocus: true,
              style: TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'e.g. Cursor on MacBook',
                hintStyle: TextStyle(color: Color(0xFF555555)),
                filled: true,
                fillColor: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF10B981)),
            child: Text('Generate'),
          ),
        ],
      ),
    );

    if (confirmed == true && nameController.text.trim().isNotEmpty) {
      try {
        await ref
            .read(apiKeysViewModelProvider.notifier)
            .createKey(nameController.text.trim());
        // _checkNewKey will fire on the next frame via listener
        _checkNewKey();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to generate key. Try again.')),
          );
        }
      }
    }
  }

  Future<void> _confirmRevoke(String keyId, String keyName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          'Revoke API Key?',
          style: TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Text(
          'Any MCP client using "$keyName" will immediately lose access. This cannot be undone.',
          style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444)),
            child: Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await ref.read(apiKeysViewModelProvider.notifier).revokeKey(keyId);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to revoke key. Try again.')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vmState = ref.watch(apiKeysViewModelProvider);

    // Listen for newly created key and show reveal dialog
    ref.listen<ApiKeysState>(apiKeysViewModelProvider, (_, next) {
      if (next.newlyCreatedKey != null) {
        _showRevealDialog(next.newlyCreatedKey!);
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header ────────────────────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'API Keys',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Use these keys to connect MCP clients (Cursor, Claude Desktop, etc.) permanently '
                    'to your Veraxi knowledge base without needing to re-login.',
                    style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 12),
                  ),
                ],
              ),
            ),
            SizedBox(width: 16),
            FilledButton.icon(
              onPressed: _showCreateDialog,
              icon: Icon(Icons.add, size: 16),
              label: Text('New Key', style: TextStyle(fontSize: 13)),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                padding:
                    EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ],
        ),
        SizedBox(height: 20),

        // ── MCP Config snippet ─────────────────────────────────────────────
        Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1117),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF21262D)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Usage in MCP client config:',
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 11),
              ),
              SizedBox(height: 8),
              Text(
                '{\n'
                '  "mcpServers": {\n'
                '    "veraxi": {\n'
                '      "url": "${const String.fromEnvironment('MCP_SSE_URL', defaultValue: 'https://your-backend.run.app/sse')}",\n'
                '      "headers": { "Authorization": "Bearer YOUR_KEY" }\n'
                '    }\n'
                '  }\n'
                '}',
                style: TextStyle(
                  color: Color(0xFF79C0FF),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 24),

        // ── Key list ───────────────────────────────────────────────────────
        vmState.keys.when(
          loading: () => Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF10B981),
              ),
            ),
          ),
          error: (e, _) => Center(
            child: Text(
              'Failed to load keys: $e',
              style: TextStyle(color: Color(0xFFEF4444), fontSize: 13),
            ),
          ),
          data: (keys) => keys.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'No API keys yet. Generate one above.',
                      style: TextStyle(color: Color(0xFF555555), fontSize: 13),
                    ),
                  ),
                )
              : Column(
                  children: keys
                      .map((key) => _ApiKeyRow(
                            apiKey: key,
                            onRevoke: () => _confirmRevoke(key.id, key.name),
                          ))
                      .toList(),
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _ApiKeyRow
// ---------------------------------------------------------------------------

class _ApiKeyRow extends StatelessWidget {
  final ApiKeyModel apiKey;
  final VoidCallback onRevoke;

  const _ApiKeyRow({required this.apiKey, required this.onRevoke});

  String _formatDate(String isoDate) {
    try {
      final dt = DateTime.parse(isoDate).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return isoDate;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
      ),
      child: Row(
        children: [
          Icon(Icons.key_outlined, color: Color(0xFF10B981), size: 18),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  apiKey.name,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 3),
                Row(
                  children: [
                    Text(
                      '${apiKey.keyPrefix}…',
                      style: TextStyle(
                        color: Color(0xFF555555),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Created ${_formatDate(apiKey.createdAt)}',
                      style: TextStyle(
                          color: Color(0xFF555555), fontSize: 11),
                    ),
                    if (apiKey.lastUsedAt != null) ...[
                      Text(
                        ' · Last used ',
                        style:
                            TextStyle(color: Color(0xFF555555), fontSize: 11),
                      ),
                      Text(
                        _formatDate(apiKey.lastUsedAt!),
                        style: TextStyle(
                            color: Color(0xFF555555), fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRevoke,
            icon: Icon(Icons.delete_outline, size: 18),
            color: const Color(0xFF555555),
            tooltip: 'Revoke key',
            hoverColor: const Color(0xFFEF4444).withValues(alpha: 0.1),
            style: IconButton.styleFrom(
              padding: EdgeInsets.all(6),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _RevealKeyDialog — shown exactly once after key creation
// ---------------------------------------------------------------------------

class _RevealKeyDialog extends StatelessWidget {
  final String rawKey;

  const _RevealKeyDialog({required this.rawKey});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Row(
        children: [
          Icon(Icons.key, color: Color(0xFF10B981), size: 20),
          SizedBox(width: 8),
          Text(
            'Your New API Key',
            style: TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Copy this key and store it somewhere safe. '
            'It will not be shown again.',
            style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 13),
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: const Color(0xFF10B981).withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    rawKey,
                    style: TextStyle(
                      color: Color(0xFF10B981),
                      fontSize: 12,
                      fontFamily: 'monospace',
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: rawKey));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Copied to clipboard'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: Icon(Icons.copy_outlined, size: 16),
                  color: const Color(0xFF10B981),
                  tooltip: 'Copy to clipboard',
                ),
              ],
            ),
          ),
          SizedBox(height: 12),
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF2D1B00),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_outlined,
                    color: Color(0xFFF59E0B), size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This key will not be shown again.',
                    style: TextStyle(color: Color(0xFFF59E0B), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style:
              FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
          child: Text('Done, I\'ve saved it'),
        ),
      ],
    );
  }
}
