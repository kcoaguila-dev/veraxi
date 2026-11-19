import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';

class LandingHero extends StatelessWidget {
  /// Scrolls the page to the "Run it yourself" section.
  final VoidCallback onRunItYourself;

  const LandingHero({super.key, required this.onRunItYourself});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final headlineSize = (width * 0.074).clamp(44.0, 92.0).toDouble();

    return LandingColumn(
      top: LandingLayout.sectionGap(context) * 0.8,
      bottom: 40,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'OPEN-SOURCE DOCUMENT & CODE INTELLIGENCE · LOCAL OR CLOUD',
            style: LandingType.mono(
              size: 12,
              color: LandingColors.cobalt,
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            header: true,
            child: Text(
              'Ask your files.\nCheck the answer.',
              style: LandingType.sans(
                size: headlineSize,
                weight: FontWeight.w800,
                height: 0.98,
                letterSpacing: -headlineSize * 0.045,
              ),
            ),
          ),
          const SizedBox(height: 28),
          LandingBody(
            'Veraxi reads your PDFs, Markdown and text files. Every answer '
            'comes with inline citations and the retrieval trail behind it, '
            'even when the facts sit in different documents.',
            size: width < 600 ? 18 : 20,
            maxWidth: 620,
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              LandingButton(
                label: 'Start Building',
                onPressed: () => context.go('/login'),
              ),
              LandingTextLink(
                label: 'Run it yourself',
                onPressed: onRunItYourself,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
