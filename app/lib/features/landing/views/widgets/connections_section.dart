import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';

/// Explains why searching by similarity alone misses answers that sit
/// between two files.
class ConnectionsSection extends StatelessWidget {
  const ConnectionsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return LandingColumn(
      bottom: LandingLayout.sectionGap(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          LandingHeading('The answer lives between two files'),
          SizedBox(height: 16),
          LandingBody(
            'Take the first question above. The lease says how much notice to '
            'give. The email says when you are leaving. Neither one says what '
            'date to put on the letter.',
            size: 19,
            maxWidth: 620,
          ),
          SizedBox(height: 36),
          LandingColumns(
            gap: 28,
            children: [
              _Approach(
                title: 'Searching by similarity',
                body:
                    'Finds passages that read like your question. The lease '
                    'clause is a close match. The email about your move-out '
                    'date is not, so the answer often stops at “60 days.”',
                boxed: false,
              ),
              _Approach(
                title: 'Following connections',
                body:
                    'Veraxi links the clause to the email through your '
                    'move-out date, then counts back 60 days from March 31 to '
                    'reach January 30. Both passages appear next to the '
                    'answer.',
                boxed: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Approach extends StatelessWidget {
  final String title;
  final String body;
  final bool boxed;

  const _Approach({
    required this.title,
    required this.body,
    required this.boxed,
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: LandingType.sans(size: 20, weight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        LandingBody(body, maxWidth: 520),
      ],
    );

    if (!boxed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: content,
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      decoration: BoxDecoration(
        color: LandingColors.panel,
        border: Border.all(color: LandingColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: content,
    );
  }
}
