import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class SettingsUI {
  static Widget buildLinkButton(BuildContext context, String label, IconData icon, String url) {
    return TextButton.icon(
      onPressed: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      icon: Icon(icon, size: 16, color: const Color(0xFFECECEC)),
      label: Text(label, style: TextStyle(color: Color(0xFFECECEC))),
      style: TextButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  static Widget buildSectionHeader(BuildContext context, String title, {bool isDestructive = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
          color:
              isDestructive ? const Color(0xFFE53935) : Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  static Widget buildSettingsGroup(BuildContext context, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: children.asMap().entries.map((entry) {
          final isLast = entry.key == children.length - 1;
          return Column(
            children: [
              entry.value,
              if (!isLast) Divider(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor, height: 1),
            ],
          );
        }).toList(),
      ),
    );
  }

  static Widget buildDropdownRow(BuildContext context, String label, String value,
      {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Text(value,
                      style:
                          TextStyle(color: Colors.white, fontSize: 13)),
                  SizedBox(width: 8),
                  Icon(Icons.keyboard_arrow_down,
                      color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget buildRealDropdownRow(BuildContext context, String label,
      String value, List<String> items, Function(String) onSelected) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
          Theme(
            data: Theme.of(context).copyWith(
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
            ),
            child: PopupMenuButton<String>(
              color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              position: PopupMenuPosition.under,
              onSelected: onSelected,
              itemBuilder: (context) => items
                  .map((item) => PopupMenuItem<String>(
                        value: item,
                        height: 40,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(item,
                                style: TextStyle(
                                    color: Colors.white, fontSize: 13)),
                            if (item == value)
                              Icon(Icons.check,
                                  color: Colors.white, size: 16),
                          ],
                        ),
                      ))
                  .toList(),
              child: Container(
                padding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Text(value,
                        style:
                            TextStyle(color: Colors.white, fontSize: 13)),
                    SizedBox(width: 8),
                    Icon(Icons.keyboard_arrow_down,
                        color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, size: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget buildTextButtonRow(BuildContext context, String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(value,
                style: TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  static Widget buildTextFieldRow(BuildContext context, String label, TextEditingController controller,
      {Function(String)? onSubmitted}) {
    return StatefulBuilder(
      builder: (context, setState) {
        bool isSaved = false;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(label,
                    style: TextStyle(
                        color: Color(0xFFECECEC), fontSize: 13)),
              ),
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: controller,
                    style: TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 12, vertical: 0),
                      filled: true,
                      fillColor: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (value) {
                      if (onSubmitted != null) {
                        onSubmitted(value);
                        setState(() => isSaved = true);
                        Future.delayed(const Duration(seconds: 2), () {
                          if (context.mounted) setState(() => isSaved = false);
                        });
                      }
                    },
                  ),
                ),
              ),
              SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  if (onSubmitted != null) {
                    onSubmitted(controller.text);
                    setState(() => isSaved = true);
                    Future.delayed(const Duration(seconds: 2), () {
                      if (context.mounted) setState(() => isSaved = false);
                    });
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isSaved
                      ? Theme.of(context).colorScheme.secondary
                      : Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
                child: Text(isSaved ? 'Saved' : 'Apply'),
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget buildToggleRow(BuildContext context, String label, bool value) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(color: Color(0xFFECECEC), fontSize: 13)),
          ),
          CupertinoSwitch(
            value: value,
            onChanged: (v) {},
            activeTrackColor: Theme.of(context).colorScheme.secondary,
            inactiveTrackColor: const Color(0xFF3A3A3A),
          ),
        ],
      ),
    );
  }

  static Widget buildActionRow(BuildContext context, String title, String subtitle, String buttonText,
      {bool isDestructive = false, VoidCallback? onTap}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: Color(0xFFECECEC), fontSize: 14)),
                if (subtitle.isNotEmpty) ...[
                  SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 12)),
                ],
              ],
            ),
          ),
          ElevatedButton(
            onPressed: onTap ?? () {},
            style: ElevatedButton.styleFrom(
              foregroundColor:
                  isDestructive ? Colors.white : const Color(0xFFECECEC),
              backgroundColor:
                  isDestructive ? const Color(0xFFD32F2F) : Colors.transparent,
              elevation: 0,
              side: isDestructive
                  ? null
                  : BorderSide(color: Color(0xFF3A3A3A)),
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }
}
