import 'package:flutter/material.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/landing/views/widgets/code_snippet_visualization.dart';
import 'package:veraxi_app/features/landing/views/widgets/development_banner.dart';
import 'package:veraxi_app/features/landing/views/widgets/hero_section.dart';
import 'package:veraxi_app/features/landing/views/widgets/nav_bar.dart';

class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SingleChildScrollView(
        child: Column(
          children: const [
            DevelopmentBanner(),
            NavBar(),
            SizedBox(height: 100),
            HeroSection(),
            SizedBox(height: 60),
            CodeSnippetVisualization(),
            SizedBox(height: 100),
          ],
        ),
      ),
    );
  }
}
