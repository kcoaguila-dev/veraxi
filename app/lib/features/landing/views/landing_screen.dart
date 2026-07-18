import 'package:flutter/material.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/landing/views/widgets/code_snippet_visualization.dart';
import 'package:veraxi_app/features/landing/views/widgets/development_banner.dart';
import 'package:veraxi_app/features/landing/views/widgets/hero_section.dart';
import 'package:veraxi_app/features/landing/views/widgets/features_section.dart';
import 'package:veraxi_app/features/landing/views/widgets/nav_bar.dart';

class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> {
  final GlobalKey _featuresKey = GlobalKey();

  void _scrollToFeatures() {
    if (_featuresKey.currentContext != null) {
      Scrollable.ensureVisible(
        _featuresKey.currentContext!,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SingleChildScrollView(
        child: Column(
          children: [
            const DevelopmentBanner(),
            NavBar(onFeaturesTap: _scrollToFeatures),
            const SizedBox(height: 100),
            const HeroSection(),
            const SizedBox(height: 60),
            const CodeSnippetVisualization(),
            const SizedBox(height: 100),
            FeaturesSection(key: _featuresKey),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }
}
