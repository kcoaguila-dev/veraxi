import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';

class LandingFooter extends StatelessWidget {
  const LandingFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return LandingColumn(
      bottom: LandingLayout.sectionGap(context) * 0.8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LandingBody(
            'Veraxi is open source under the MIT license and still in '
            'development. One developer builds and maintains it.',
            size: 18,
            maxWidth: 520,
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              LandingButton(
                label: 'Try it with your own files',
                onPressed: () => context.go('/login'),
              ),
              LandingTextLink(
                label: 'Docs & API',
                onPressed: () => context.go('/docs'),
              ),
              LandingTextLink(
                label: 'GitHub',
                onPressed: () =>
                    openLandingUrl('https://github.com/kcoaguila-dev/veraxi'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
