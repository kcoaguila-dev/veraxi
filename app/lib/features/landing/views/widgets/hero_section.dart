import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/theme.dart';

class HeroSection extends StatelessWidget {
  const HeroSection({super.key});

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
                onPressed: () => context.go('/login'),
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
                  backgroundColor: AppTheme.surface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
