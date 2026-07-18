import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/theme.dart';

class FeaturesSection extends StatelessWidget {
  const FeaturesSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Section Headers
          Text(
            'CAPABILITIES',
            style: GoogleFonts.inter(
              color: AppTheme.primary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 2.0,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Everything your agents need to know.',
            style: GoogleFonts.inter(
              color: AppTheme.textPrimary,
              fontSize: 42,
              fontWeight: FontWeight.bold,
              letterSpacing: -1.0,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            'A unified intelligence layer designed for autonomous AI systems.',
            style: GoogleFonts.inter(
              color: AppTheme.textSecondary,
              fontSize: 18,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 80),
          
          // Cards Grid
          Wrap(
            spacing: 32,
            runSpacing: 32,
            alignment: WrapAlignment.center,
            children: const [
              _FeatureCard(
                title: 'GraphRAG Synthesis',
                description: 'Extracts complex relationships and hierarchies from messy data using native Neo4j integration.',
                iconData: Icons.hub_outlined,
                iconColor: Color(0xFF6366F1),
              ),
              _FeatureCard(
                title: 'Semantic Search',
                description: 'High-performance vector retrieval via Qdrant, enabling fuzzy matching and conceptual queries instantly.',
                iconData: Icons.search_rounded,
                iconColor: Color(0xFF10B981),
              ),
              _FeatureCard(
                title: 'Universal Access',
                description: 'A standard MCP interface means Veraxi works out-of-the-box with Claude, Cursor, Copilot, and more.',
                iconData: Icons.terminal_rounded,
                iconColor: Color(0xFFEAB308),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatefulWidget {
  final String title;
  final String description;
  final IconData iconData;
  final Color iconColor;

  const _FeatureCard({
    required this.title,
    required this.description,
    required this.iconData,
    required this.iconColor,
  });

  @override
  State<_FeatureCard> createState() => _FeatureCardState();
}

class _FeatureCardState extends State<_FeatureCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 340,
        height: 260,
        transform: Matrix4.translationValues(0, _isHovered ? -8 : 0, 0),
        decoration: BoxDecoration(
          color: const Color(0xFF131313).withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isHovered 
              ? widget.iconColor.withValues(alpha: 0.5) 
              : AppTheme.surfaceHighlight,
            width: 1.5,
          ),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: widget.iconColor.withValues(alpha: 0.15),
                    blurRadius: 30,
                    offset: const Offset(0, 10),
                  )
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: widget.iconColor.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      widget.iconData,
                      color: widget.iconColor,
                      size: 24,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    widget.title,
                    style: GoogleFonts.inter(
                      color: AppTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.description,
                    style: GoogleFonts.inter(
                      color: AppTheme.textSecondary,
                      fontSize: 15,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
