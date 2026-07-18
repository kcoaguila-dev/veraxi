import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/theme.dart';

class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SingleChildScrollView(
        child: Column(
          children: [
            const _DevelopmentBanner(),
            const _NavBar(),
            const SizedBox(height: 100),
            const _HeroSection(),
            const SizedBox(height: 60),
            const _CodeSnippetVisualization(),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }
}

class _DevelopmentBanner extends StatelessWidget {
  const _DevelopmentBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.15),
        border: const Border(bottom: BorderSide(color: AppTheme.primary, width: 1)),
      ),
      child: Center(
        child: Text(
          'Veraxi is still in development. Join the waitlist for early access.',
          style: GoogleFonts.inter(
            color: AppTheme.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 80,
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(bottom: BorderSide(color: AppTheme.surfaceHighlight, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.change_history, color: AppTheme.primary, size: 28),
              const SizedBox(width: 8),
              Text(
                'Veraxi',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
          if (MediaQuery.of(context).size.width > 800)
            Row(
              children: [
                _NavLink('Features'),
                const SizedBox(width: 32),
                _NavLink('Docs'),
                const SizedBox(width: 32),
                _NavLink('MCP Protocol'),
                const SizedBox(width: 32),
                _NavLink('GitHub'),
              ],
            ),
          Row(
            children: [
              TextButton(
                onPressed: () {},
                style: TextButton.styleFrom(foregroundColor: AppTheme.textPrimary),
                child: const Text('Sign In'),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => context.go('/chat'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.textPrimary,
                  foregroundColor: AppTheme.background,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Get Started', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NavLink extends StatelessWidget {
  final String title;
  const _NavLink(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: GoogleFonts.inter(
        color: AppTheme.textSecondary,
        fontSize: 15,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [AppTheme.primaryGradientStart, AppTheme.primaryGradientEnd],
            ).createShader(bounds),
            child: Text(
              'Give your AI agents a brain.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 64,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.5,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Turn messy data silos into a searchable, verifiable Knowledge Layer.\nThe standard Model Context Protocol (MCP) server for production-grade architecture at any scale.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: AppTheme.textSecondary,
              fontSize: 20,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 48),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () => context.go('/chat'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                child: const Text('Start Building Free', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.arrow_forward_ios, size: 14),
                label: const Text('View Docs', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.surfaceHighlight),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  backgroundColor: AppTheme.surface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CodeSnippetVisualization extends StatelessWidget {
  const _CodeSnippetVisualization();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 700,
      margin: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF131313),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.surfaceHighlight),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 30,
            offset: const Offset(0, 10),
          )
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Window Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.surfaceHighlight)),
                ),
                child: Row(
                  children: [
                    _buildDot(const Color(0xFFEF4444)),
                    const SizedBox(width: 8),
                    _buildDot(const Color(0xFFEAB308)),
                    const SizedBox(width: 8),
                    _buildDot(const Color(0xFF10B981)),
                    const SizedBox(width: 16),
                    Text(
                      'claude_desktop_config.json',
                      style: GoogleFonts.inter(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              // Code Content
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Stack(
                  children: [
                    Text(
                      '''{
  "mcpServers": {
    "veraxi-knowledge-graph": {
      "command": "veraxi",
      "args": ["mcp", "--tenant-id=enterprise"],
      "env": {
        "NEO4J_URI": "bolt://localhost:7687",
        "QDRANT_URL": "http://localhost:6333",
        "LLM_BASE_URL": "http://localhost:11434/v1"
      }
    }
  }
}''',
                      style: GoogleFonts.firaCode(
                        color: AppTheme.textSecondary,
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                    // Simulated highlight for the LLM
                    Positioned(
                      top: 130,
                      left: 20,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppTheme.primary),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 12),
                            const SizedBox(width: 4),
                            Text(
                              'Local Sovereign LLM',
                              style: GoogleFonts.inter(
                                color: const Color(0xFF10B981),
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDot(Color color) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
