import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class ChatInputAttachments extends StatelessWidget {
  final List<PlatformFile> attachedFiles;
  final Function(int) onRemove;

  const ChatInputAttachments({
    super.key,
    required this.attachedFiles,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (attachedFiles.isEmpty) return SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(bottom: 8.0, left: 12.0, right: 12.0),
      child: Wrap(
        spacing: 8.0,
        runSpacing: 4.0,
        children: attachedFiles.asMap().entries.map((entry) {
          final idx = entry.key;
          final file = entry.value;
          return Chip(
            label: Text(
              file.name,
              style: TextStyle(color: Colors.white, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong,
            deleteIconColor: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
            onDeleted: () => onRemove(idx),
            padding: EdgeInsets.zero,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide.none,
            ),
          );
        }).toList(),
      ),
    );
  }
}
