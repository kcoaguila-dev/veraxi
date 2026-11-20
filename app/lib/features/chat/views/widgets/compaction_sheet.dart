import 'package:material_ui/material_ui.dart';

import '../../view_models/token_usage.dart';

/// Manual compaction flow: preview → edit → apply.
///
/// The preview is generated server-side and applies NOTHING; the
/// summary below is fully editable, and only the Compact button
/// commits it. A truncated or empty summary is rejected by the
/// server before it can ever reach this sheet. "Clear old tool
/// results instead" is Stage 0: deterministic, no LLM call.
Future<void> showCompactionSheet(
  BuildContext context, {
  required Future<Map<String, dynamic>> Function() onPreview,
  required Future<void> Function(String summary) onApply,
  required Future<Map<String, dynamic>> Function() onClearToolResults,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF141414),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => _CompactionSheet(
      onPreview: onPreview,
      onApply: onApply,
      onClearToolResults: onClearToolResults,
    ),
  );
}

class _CompactionSheet extends StatefulWidget {
  final Future<Map<String, dynamic>> Function() onPreview;
  final Future<void> Function(String summary) onApply;
  final Future<Map<String, dynamic>> Function() onClearToolResults;

  const _CompactionSheet({
    required this.onPreview,
    required this.onApply,
    required this.onClearToolResults,
  });

  @override
  State<_CompactionSheet> createState() => _CompactionSheetState();
}

class _CompactionSheetState extends State<_CompactionSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _loading = true;
  bool _applying = false;
  String? _error;
  Map<String, dynamic>? _preview;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _cleanError(Object e) => e.toString().replaceFirst('Exception: ', '');

  Future<void> _loadPreview() async {
    try {
      final preview = await widget.onPreview();
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _controller.text = preview['summary'] as String? ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _cleanError(e);
        _loading = false;
      });
    }
  }

  Future<void> _apply() async {
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      await widget.onApply(_controller.text);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = _cleanError(e);
      });
    }
  }

  Future<void> _clearToolResults() async {
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      await widget.onClearToolResults();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = _cleanError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Compact conversation',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Earlier messages are replaced by this summary. '
            'The last 4 exchanges stay verbatim. Review and edit '
            'before applying — nothing changes until you tap Compact.',
            style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text(
                      'Summarizing earlier messages…',
                      style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else if (preview != null) ...[
            if (preview['tokens_before'] != null)
              Text(
                '${preview['messages_compacted']} messages · '
                '~${formatTokenCountFull(preview['tokens_before'] as int)} '
                '→ ~${preview['tokens_after_estimate'] == null ? '—' : formatTokenCountFull(preview['tokens_after_estimate'] as int)} tokens'
                '${preview['estimated'] == true ? ' (estimated)' : ''}',
                style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12),
              ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: TextField(
                controller: _controller,
                maxLines: null,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Summary',
                  hintStyle: TextStyle(color: Color(0xFF8A8A8A)),
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(color: Color(0xFFE57373), fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _applying ? null : _clearToolResults,
              child: const Text('Clear old tool results instead (no summary)'),
            ),
          ),
          Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: _applying ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: (_applying || preview == null) ? null : _apply,
                child: Text(_applying ? 'Working…' : 'Compact'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
