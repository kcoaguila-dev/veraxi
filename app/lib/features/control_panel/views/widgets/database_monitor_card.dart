import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class DatabaseMonitorCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String url;
  final IconData icon;

  const DatabaseMonitorCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.url,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary, size: 24),
              SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16)),
                  Text(subtitle,
                      style: TextStyle(
                          color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 12)),
                ],
              ),
            ],
          ),
          SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () async {
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri);
              } else {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Could not launch dashboard')));
                }
              }
            },
            icon: Icon(Icons.open_in_new, size: 16, color: Colors.white),
            label: Text('Open Dashboard',
                style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }
}
