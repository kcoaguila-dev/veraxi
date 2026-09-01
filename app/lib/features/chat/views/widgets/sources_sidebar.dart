import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

class SourcesSidebar extends StatelessWidget {
  final List<Map<String, dynamic>> sources;

  const SourcesSidebar({super.key, required this.sources});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF131313),
      width: 350,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  const Icon(Icons.menu_book_outlined,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 12),
                  const Text(
                    'Sources',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Colors.white70, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF2A2A2A), height: 1),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: sources.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 16),
                itemBuilder: (context, index) {
                  final source = sources[index];
                  String title = source['title'] ?? 'Web Source';
                  String url = source['url'] ?? '';
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
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF2A2A2A)),
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
                                  color: const Color(0xFF2A2A2A),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (hasValidDomain)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.network(
                                    'https://icon.horse/icon/$domain',
                                    width: 16,
                                    height: 16,
                                    errorBuilder:
                                        (context, error, stackTrace) =>
                                            const Icon(Icons.language,
                                                size: 16,
                                                color: Color(0xFF878787)),
                                  ),
                                )
                              else
                                const Icon(Icons.language,
                                    size: 16, color: Color(0xFF878787)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  displayDomain,
                                  style: const TextStyle(
                                    color: Color(0xFF878787),
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                            ),
                          ),
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
