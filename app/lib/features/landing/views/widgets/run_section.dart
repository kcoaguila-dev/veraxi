import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';

/// Full-width cobalt band with the commands to run Veraxi locally.
class RunSection extends StatelessWidget {
  const RunSection({super.key});

  static const String _commands =
      'git clone https://github.com/kcoaguila-dev/veraxi.git\n'
      'cd veraxi\n'
      'make setup\n'
      'make up\n'
      'make seed';

  @override
  Widget build(BuildContext context) {
    final gap = LandingLayout.sectionGap(context);

    return Container(
      width: double.infinity,
      color: LandingColors.cobalt,
      child: LandingColumn(
        top: gap,
        bottom: gap,
        child: LandingColumns(
          gap: 48,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LandingHeading(
                  'Run it yourself',
                  color: LandingColors.onCobalt,
                ),
                const SizedBox(height: 24),
                const LandingBody(
                  'The databases run in Docker. You need Docker, Python and '
                  'Flutter installed, then these commands.',
                  size: 18,
                  color: LandingColors.onCobalt,
                  maxWidth: 520,
                ),
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
                  decoration: BoxDecoration(
                    color: LandingColors.code,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      _commands,
                      style: LandingType.mono(
                        color: LandingColors.onCobalt,
                        height: 1.8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '“make seed” loads sample data and needs no API key. To ask '
                  'your own questions, add a model key such as GEMINI_API_KEY '
                  'to backend/.env, or use a local model.',
                  style: LandingType.sans(
                    size: 15,
                    color: LandingColors.onCobaltSoft,
                    height: 1.5,
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Choose where the model runs',
                  style: LandingType.sans(
                    size: 24,
                    weight: FontWeight.w700,
                    color: LandingColors.onCobalt,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 20),
                const LandingBody(
                  'Use a local model through Ollama and your passages stay on '
                  'your computer. Or connect Gemini, Groq, DeepSeek, OpenAI '
                  'or Anthropic. Then the passages used for each answer are '
                  'sent to that provider.',
                  size: 18,
                  color: LandingColors.onCobalt,
                  maxWidth: 520,
                ),
                const SizedBox(height: 24),
                LandingButton(
                  label: 'Read the setup guide',
                  light: true,
                  onPressed: () => openLandingUrl(
                    'https://github.com/kcoaguila-dev/veraxi#readme',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
