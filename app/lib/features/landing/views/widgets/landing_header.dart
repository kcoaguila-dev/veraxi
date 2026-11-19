import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';

class LandingHeader extends StatelessWidget {
  const LandingHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;

    return LandingColumn(
      top: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.asset(
                  'assets/veraxi_logo.png',
                  width: 28,
                  height: 28,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Veraxi',
                style: LandingType.sans(
                  size: 24,
                  weight: FontWeight.w800,
                  letterSpacing: -0.7,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (wide) ...[
                LandingTextLink(
                  label: 'Docs',
                  onPressed: () => context.go('/docs'),
                ),
                const SizedBox(width: 8),
              ],
              LandingTextLink(
                label: 'GitHub',
                onPressed: () =>
                    openLandingUrl('https://github.com/kcoaguila-dev/veraxi'),
              ),
              const SizedBox(width: 8),
              LandingTextLink(
                label: 'Sign in',
                onPressed: () => context.go('/login'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
