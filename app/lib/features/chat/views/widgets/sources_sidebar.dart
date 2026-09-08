import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class SourcesSidebar extends StatelessWidget {
  final List<Map<String, dynamic>> sources;

  const SourcesSidebar({super.key, required this.sources});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.dialogBackground,
      width: 350,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Icon(Icons.menu_book_outlined,
                      color: Colors.white, size: 20),
                  SizedBox(width: 12),
                  Text(
                    'Sources',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close,
                        color: Colors.white70, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor, height: 1),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.all(20),
                itemCount: sources.length,
                separatorBuilder: (context, index) =>
                    SizedBox(height: 16),
                itemBuilder: (context, index) {
                  final source = sources[index];
                  String title = source['title'] ?? 'Web Source';
                  String url = source['url'] ?? '';
                  String snippet = source['snippet'] ?? '';
                  String domain = '';
                  bool hasValidDomain = false;
                  try {
                    if (url.isNotEmpty && url != 'Internal Database') {
                      final uri = Uri.tryParse(
                          url.startsWith('http') ? url : 'http://$url');
                      domain = uri?.host.replaceFirst('www.', '') ?? '';
                      if (domain.contains('.')) {
                        hasValidDomain = true;
                      }
                    }
                  } catch (_) {}

                  String displayDomain =
                      hasValidDomain ? domain : 'Internal Database';

                  return InkWell(
                    onTap: () {
                      if (url.isNotEmpty) launchUrlString(url);
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              SizedBox(width: 12),
                              if (hasValidDomain)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.network(
                                    'https://icon.horse/icon/$domain',
                                    width: 16,
                                    height: 16,
                                    errorBuilder:
                                        (context, error, stackTrace) =>
                                            Icon(Icons.language,
                                                size: 16,
                                                color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                                  ),
                                )
                              else
                                Icon(Icons.language,
                                    size: 16, color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  displayDomain,
                                  style: TextStyle(
                                    color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 12),
                          Text(
                            title,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                            ),
                          ),
                          if (snippet.isNotEmpty) ...[
                            SizedBox(height: 8),
                            Text(
                              snippet,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
