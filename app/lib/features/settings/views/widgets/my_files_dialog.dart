import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class MyFilesDialog extends ConsumerStatefulWidget {
  const MyFilesDialog({super.key});

  @override
  ConsumerState<MyFilesDialog> createState() => _MyFilesDialogState();
}

class _MyFilesDialogState extends ConsumerState<MyFilesDialog> {
  bool _isLoading = true;
  String? _error;
  List<Map<String, dynamic>> _files = [];
  Set<String> _selectedIds = {};
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final repo = ref.read(chatRepositoryProvider);
      final files = await repo.getFiles();
      setState(() {
        _files = files;
        _isLoading = false;
      });
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;

    final repo = ref.read(chatRepositoryProvider);
    for (final id in _selectedIds.toList()) {
      try {
        await repo.deleteFile(id);
      } catch (e, st) {
        Sentry.captureException(e, stackTrace: st);
      }
    }
    setState(() {
      _selectedIds.clear();
    });
    await _loadFiles();
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final filteredFiles = _files.where((f) {
      final name = (f['filename'] ?? '').toString().toLowerCase();
      return name.contains(_searchQuery.toLowerCase());
    }).toList();

    return Dialog(
      backgroundColor: const Color(0xFF171717),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF2A2A2A)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.8,
        height: MediaQuery.of(context).size.height * 0.8,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'My Files',
                  style: TextStyle(
                    color: Color(0xFFECECEC),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Color(0xFF888888)),
                  splashRadius: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                  icon: Icon(
                    Icons.delete_outline,
                    color: _selectedIds.isEmpty
                        ? const Color(0xFF666666)
                        : const Color(0xFFEF4444),
                    size: 16,
                  ),
                  label: Text(
                    'Delete',
                    style: TextStyle(
                      color: _selectedIds.isEmpty
                          ? const Color(0xFF666666)
                          : const Color(0xFFEF4444),
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: const Color(0xFFEF4444),
                    disabledBackgroundColor: Colors.transparent,
                    elevation: 0,
                    side: BorderSide(
                        color: _selectedIds.isEmpty
                            ? const Color(0xFF2A2A2A)
                            : const Color(0xFFEF4444).withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    onChanged: (val) => setState(() => _searchQuery = val),
                    style:
                        const TextStyle(color: Color(0xFFECECEC), fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Filter files...',
                      hintStyle: const TextStyle(color: Color(0xFF888888)),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      filled: true,
                      fillColor: Colors.transparent,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Color(0xFF666666)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF2A2A2A)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.filter_list,
                        color: Color(0xFF888888), size: 18),
                    onPressed: () {},
                    splashRadius: 20,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF2A2A2A)),
                borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(6), topRight: Radius.circular(6)),
                color: const Color(0xFF1E1E1E),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _files.isNotEmpty &&
                          _selectedIds.length == filteredFiles.length,
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedIds.addAll(
                                filteredFiles.map((f) => f['id'].toString()));
                          } else {
                            _selectedIds.clear();
                          }
                        });
                      },
                      side: const BorderSide(color: Color(0xFF666666)),
                      activeColor: const Color(0xFF3B82F6),
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(flex: 3, child: _HeaderTitle('Name')),
                  const Expanded(flex: 2, child: _HeaderTitle('Date')),
                  const Expanded(flex: 1, child: _HeaderTitle('Storage')),
                  const Expanded(flex: 1, child: _HeaderTitle('Context')),
                  const Expanded(flex: 1, child: _HeaderTitle('Size')),
                ],
              ),
            ),
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: Color(0xFF2A2A2A)),
                    right: BorderSide(color: Color(0xFF2A2A2A)),
                    bottom: BorderSide(color: Color(0xFF2A2A2A)),
                  ),
                  borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(6),
                      bottomRight: Radius.circular(6)),
                ),
                child: _isLoading
                    ? const Center(
                        child:
                            CircularProgressIndicator(color: Color(0xFF888888)))
                    : _error != null
                        ? Center(
                            child: Text(_error!,
                                style: const TextStyle(color: Colors.red)))
                        : filteredFiles.isEmpty
                            ? const Center(
                                child: Text('No results.',
                                    style: TextStyle(
                                        color: Color(0xFF888888),
                                        fontSize: 14)),
                              )
                            : ListView.separated(
                                itemCount: filteredFiles.length,
                                separatorBuilder: (context, index) =>
                                    const Divider(
                                        color: Color(0xFF2A2A2A), height: 1),
                                itemBuilder: (context, index) {
                                  final file = filteredFiles[index];
                                  final id = file['id'].toString();
                                  final isSelected = _selectedIds.contains(id);

                                  final date = file['date'] != null
                                      ? DateFormat('MM/dd/yyyy h:mm a').format(
                                          DateTime.fromMillisecondsSinceEpoch(
                                              file['date'] * 1000))
                                      : 'Unknown';

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: Checkbox(
                                            value: isSelected,
                                            onChanged: (val) {
                                              setState(() {
                                                if (val == true) {
                                                  _selectedIds.add(id);
                                                } else {
                                                  _selectedIds.remove(id);
                                                }
                                              });
                                            },
                                            side: const BorderSide(
                                                color: Color(0xFF666666)),
                                            activeColor:
                                                const Color(0xFF3B82F6),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          flex: 3,
                                          child: Text(
                                            file['filename']?.toString() ??
                                                'Unknown',
                                            style: const TextStyle(
                                                color: Color(0xFFECECEC),
                                                fontSize: 13),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Expanded(
                                          flex: 2,
                                          child: Text(
                                            date,
                                            style: const TextStyle(
                                                color: Color(0xFF888888),
                                                fontSize: 13),
                                          ),
                                        ),
                                        const Expanded(
                                          flex: 1,
                                          child: Text(
                                            'local',
                                            style: TextStyle(
                                                color: Color(0xFF888888),
                                                fontSize: 13),
                                          ),
                                        ),
                                        const Expanded(
                                          flex: 1,
                                          child: Text(
                                            'chat',
                                            style: TextStyle(
                                                color: Color(0xFF888888),
                                                fontSize: 13),
                                          ),
                                        ),
                                        Expanded(
                                          flex: 1,
                                          child: Text(
                                            _formatSize(file['size'] ?? 0),
                                            style: const TextStyle(
                                                color: Color(0xFF888888),
                                                fontSize: 13),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_selectedIds.length} of ${filteredFiles.length} item(s) selected',
                  style:
                      const TextStyle(color: Color(0xFF888888), fontSize: 12),
                ),
                Row(
                  children: [
                    const Text('Page 1 / 1',
                        style: TextStyle(
                            color: Color(0xFFECECEC),
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(width: 16),
                    OutlinedButton(
                      onPressed: null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF888888),
                        side: const BorderSide(color: Color(0xFF2A2A2A)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        minimumSize: Size.zero,
                      ),
                      child: const Text('Prev', style: TextStyle(fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF888888),
                        side: const BorderSide(color: Color(0xFF2A2A2A)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        minimumSize: Size.zero,
                      ),
                      child: const Text('Next', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderTitle extends StatelessWidget {
  final String title;
  const _HeaderTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFFECECEC),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 4),
        const Icon(Icons.unfold_more, color: Color(0xFF666666), size: 14),
      ],
    );
  }
}
