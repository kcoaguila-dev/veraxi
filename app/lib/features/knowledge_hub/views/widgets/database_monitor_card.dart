import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class DatabaseMonitorCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String url;
  final IconData icon;
  final String? telemetry;

  const DatabaseMonitorCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.url,
    required this.icon,
    this.telemetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2D2D32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF232328),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF32323A)),
                ),
                child: Icon(icon, color: const Color(0xFF34D399), size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFFF4F4F5),
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFFA1A1AA),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (telemetry != null) ...[
            const SizedBox(height: 14),
            Text(
              telemetry!,
              style: const TextStyle(
                color: Color(0xFFE4E4E7),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(height: 16),
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
            icon: const Icon(Icons.open_in_new,
                size: 14, color: Color(0xFFA1A1AA)),
            label: const Text('Open Dashboard'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF27272B),
              foregroundColor: const Color(0xFFE4E4E7),
              elevation: 0,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
                side: const BorderSide(color: Color(0xFF3A3A40), width: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
