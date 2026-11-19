import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/features/landing/views/widgets/answer_demo.dart';
import 'package:veraxi_app/features/landing/views/widgets/connections_section.dart';
import 'package:veraxi_app/features/landing/views/widgets/developers_section.dart';
import 'package:veraxi_app/features/landing/views/widgets/how_it_works_section.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_footer.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_header.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_hero.dart';
import 'package:veraxi_app/features/landing/views/widgets/landing_style.dart';
import 'package:veraxi_app/features/landing/views/widgets/run_section.dart';

class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> {
  final GlobalKey _runKey = GlobalKey();

  void _scrollToRun() {
    final target = _runKey.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LandingColors.paper,
      body: SingleChildScrollView(
        child: Column(
          children: [
            const LandingHeader(),
            LandingHero(onRunItYourself: _scrollToRun),
            LandingColumn(
              top: 24,
              bottom: LandingLayout.sectionGap(context),
              child: const AnswerDemo(),
            ),
            const ConnectionsSection(),
            const HowItWorksSection(),
            RunSection(key: _runKey),
            const DevelopersSection(),
            const LandingFooter(),
          ],
        ),
      ),
    );
  }
}
