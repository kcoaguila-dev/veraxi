import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';

/// The three steps from adding a file to getting an answer with a trail.
/// This is a real sequence, so the steps are numbered.
class HowItWorksSection extends StatelessWidget {
  const HowItWorksSection({super.key});

  @override
  Widget build(BuildContext context) {
    return LandingColumn(
      bottom: LandingLayout.sectionGap(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 640),
            child: LandingHeading('What happens when you add a file'),
          ),
          SizedBox(height: 40),
          LandingColumns(
            gap: 40,
            children: [
              _Step(
                number: '1',
                title: 'It reads the file',
                body:
                    'Veraxi pulls the text out of PDFs, Markdown and plain '
                    'text, then splits it into passages small enough to cite.',
              ),
              _Step(
                number: '2',
                title: 'It links what the file mentions',
                body:
                    'Each passage is indexed by meaning and by keywords. '
                    'Names that appear in more than one file, like “WHO” and '
                    '“World Health Organization,” are tied together.',
              ),
              _Step(
                number: '3',
                title: 'It answers with a trail',
                body:
                    'When you ask a hard question, Veraxi searches both '
                    'indexes and builds the missing connections as it goes. '
                    'In deep research mode, every claim carries a citation, '
                    'and a skeptic sends unsupported claims back for '
                    'revision.',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final String number;
  final String title;
  final String body;

  const _Step({
    required this.number,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          number,
          style: LandingType.sans(
            size: 44,
            weight: FontWeight.w800,
            color: LandingColors.cobalt,
            height: 1,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          style: LandingType.sans(
            size: 22,
            weight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        LandingBody(body),
      ],
    );
  }
}
