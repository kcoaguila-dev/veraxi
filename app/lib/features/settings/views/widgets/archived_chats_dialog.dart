import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:veraxi_app/features/chat/view_models/chat_view_model.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class ArchivedChatsDialog extends ConsumerStatefulWidget {
  const ArchivedChatsDialog({super.key});

  @override
  ConsumerState<ArchivedChatsDialog> createState() =>
      _ArchivedChatsDialogState();
}

class _ArchivedChatsDialogState extends ConsumerState<ArchivedChatsDialog> {
  String _formatDate(dynamic timestamp) {
    if (timestamp == null || timestamp == 0 || timestamp == 0.0)
      return 'Unknown';
    try {
      final tsSec = timestamp is num
          ? timestamp.toDouble()
          : double.tryParse(timestamp.toString()) ?? 0.0;
      if (tsSec <= 0) return 'Unknown';
      final date = DateTime.fromMillisecondsSinceEpoch((tsSec * 1000).toInt());
      return DateFormat('MM/dd/yyyy h:mm a').format(date);
    } catch (e) {
      return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatViewModelProvider);
    final viewModel = ref.read(chatViewModelProvider.notifier);

    final archivedChats =
        state.pastThreads.where((t) => t['is_archived'] == true).toList();
    // Sort by timestamp descending
    archivedChats.sort((a, b) {
      final aTs = a['_timestamp'] is num ? a['_timestamp'].toDouble() : 0.0;
      final bTs = b['_timestamp'] is num ? b['_timestamp'].toDouble() : 0.0;
      return bTs.compareTo(aTs);
    });

    return Dialog(
      backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
      ),
      insetPadding: EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.7,
        height: MediaQuery.of(context).size.height * 0.7,
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Archived chats',
                  style: TextStyle(
                    color: Color(0xFFECECEC),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, color: Color(0xFF888888)),
                  splashRadius: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(6), topRight: Radius.circular(6)),
                color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
              ),
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Expanded(flex: 3, child: _HeaderTitle('Name')),
                  const Expanded(flex: 2, child: _HeaderTitle('Date Created')),
                  const Expanded(
                      flex: 1, child: SizedBox.shrink()), // Actions column
                ],
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                    right: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                    bottom: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                  ),
                  borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(6),
                      bottomRight: Radius.circular(6)),
                ),
                child: archivedChats.isEmpty
                    ? Center(
                        child: Text('No archived chats.',
                            style: TextStyle(
                                color: Color(0xFF888888), fontSize: 14)),
                      )
                    : ListView.separated(
                        itemCount: archivedChats.length,
                        separatorBuilder: (context, index) =>
                            Divider(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor, height: 1),
                        itemBuilder: (context, index) {
                          final chat = archivedChats[index];
                          final id = chat['thread_id'].toString();
                          final title = chat['title']?.toString() ?? 'New Chat';
                          final date = _formatDate(chat['_timestamp']);

                          return Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    title,
                                    style: TextStyle(
                                        color: Color(0xFFECECEC), fontSize: 14),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    date,
                                    style: TextStyle(
                                        color: Color(0xFF888888), fontSize: 13),
                                  ),
                                ),
                                Expanded(
                                  flex: 1,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Tooltip(
                                        message: 'Unarchive thread',
                                        child: IconButton(
                                          icon: Icon(
                                              Icons.unarchive_outlined,
                                              color: Color(0xFF888888),
                                              size: 20),
                                          onPressed: () async {
                                            try {
                                              await viewModel
                                                  .toggleArchiveThread(id);
                                            } catch (e, st) {
                                              Sentry.captureException(e,
                                                  stackTrace: st);
                                            }
                                          },
                                          splashRadius: 20,
                                        ),
                                      ),
                                      Tooltip(
                                        message: 'Delete thread',
                                        child: IconButton(
                                          icon: Icon(Icons.delete_outline,
                                              color: Color(0xFFEF4444),
                                              size: 20),
                                          onPressed: () async {
                                            try {
                                              await viewModel.deleteThread(id);
                                            } catch (e, st) {
                                              Sentry.captureException(e,
                                                  stackTrace: st);
                                            }
                                          },
                                          splashRadius: 20,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
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
          style: TextStyle(
            color: Color(0xFFECECEC),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
