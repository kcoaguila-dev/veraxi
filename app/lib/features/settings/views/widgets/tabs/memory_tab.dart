import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/settings/view_models/memory_view_model.dart';

/// Memory settings tab.
///
/// Lists the user's visible memories (content, source, validity) from
/// [memoryViewModelProvider] and lets them add, edit, expire or delete
/// entries. Design contract: docs/design/user_memory_settings.svg.
class MemoryTab extends ConsumerStatefulWidget {
  const MemoryTab({super.key});

  @override
  ConsumerState<MemoryTab> createState() => _MemoryTabState();
}

class _MemoryTabState extends ConsumerState<MemoryTab> {
  final _newMemoryController = TextEditingController();

  @override
  void dispose() {
    _newMemoryController.dispose();
    super.dispose();
  }

  Future<void> _showEditDialog(UserMemory memory) async {
    final controller = TextEditingController(text: memory.content);
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Theme.of(dialogContext)
            .extension<AppThemeExtension>()!
            .cardBackground,
        title: const Text('Edit memory', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: const InputDecoration(hintText: 'Memory content'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (edited != null && edited.trim().isNotEmpty) {
      await ref
          .read(memoryViewModelProvider.notifier)
          .editMemory(memory.id, edited);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(memoryViewModelProvider);
    final vm = ref.read(memoryViewModelProvider.notifier);
    final ext = Theme.of(context).extension<AppThemeExtension>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Memory',
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'Facts Veraxi remembers about you. You can add, edit, expire or delete them at any time — nothing is hidden.',
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(color: ext.textTertiary),
        ),
        const SizedBox(height: 32),
        _sectionTitle(context, 'Add a Memory'),
        _card(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newMemoryController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'New memory',
                        hintText: 'e.g. Prefers concise answers with citations',
                        labelStyle:
                            TextStyle(color: ext.textTertiary, fontSize: 13),
                        hintStyle:
                            TextStyle(color: ext.textTertiary, fontSize: 13),
                        filled: true,
                        fillColor: ext.borderColor,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () async {
                      await vm.addMemory(_newMemoryController.text);
                      _newMemoryController.clear();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: ext.sidebarBackground,
                      minimumSize: const Size(130, 44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Add Memory',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'New memories are saved with source “manual” and are valid immediately.',
                style: TextStyle(color: ext.textTertiary, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        _sectionTitle(context, 'Your Memories'),
        if (state.loading && state.memories.isEmpty)
          const Center(child: CircularProgressIndicator())
        else if (state.memories.isEmpty)
          Text(
            'No memories yet. Add one above, or let chat save them as you talk.',
            style: TextStyle(color: ext.textTertiary, fontSize: 13),
          )
        else
          for (final memory in state.memories) ...[
            _memoryCard(context, memory),
            const SizedBox(height: 12),
          ],
        if (state.error != null) ...[
          const SizedBox(height: 8),
          Text(state.error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
        ],
      ],
    );
  }

  Widget _memoryCard(BuildContext context, UserMemory memory) {
    final vm = ref.read(memoryViewModelProvider.notifier);
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return _card(
      context,
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color:
                  memory.isValid ? const Color(0xFF10B981) : ext.textTertiary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  memory.content,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Chip(
                      label: Text(memory.source,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11)),
                      backgroundColor: ext.borderColor,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    Text(
                      memory.isValid
                          ? 'Valid'
                          : 'Expired ${_shortDate(memory.validTo)}',
                      style: TextStyle(
                        color: memory.isValid
                            ? const Color(0xFF10B981)
                            : ext.textTertiary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _showEditDialog(memory),
            child: const Text('Edit'),
          ),
          if (memory.isValid)
            TextButton(
              onPressed: () => vm.expireMemory(memory.id),
              style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFF59E0B)),
              child: const Text('Expire'),
            ),
          TextButton(
            onPressed: () => vm.deleteMemory(memory.id),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  String _shortDate(String? iso) {
    if (iso == null || iso.length < 10) return '';
    return iso.substring(0, 10);
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
    );
  }

  Widget _card(BuildContext context, Widget child) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ext.borderColor),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
