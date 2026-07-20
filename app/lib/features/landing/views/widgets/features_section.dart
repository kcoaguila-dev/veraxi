import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class FeaturesSection extends StatelessWidget {
  const FeaturesSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
              color: theme.colorScheme.primary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 2.0,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Everything your agents need to know.',
            style: GoogleFonts.inter(
              color: theme.colorScheme.onSurface,
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
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              fontSize: 18,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 64),
          
          // Cards Grid
          Wrap(
            spacing: 32,
            runSpacing: 32,
            alignment: WrapAlignment.center,
            children: [
              _FeatureCard(
                title: 'GraphRAG Intelligence',
                description: 'Veraxi navigates codebases like a senior engineer, using Neo4j to trace logical dependencies and data flows.',
                iconData: Icons.hub_outlined,
                iconColor: theme.colorScheme.primary,
              ),
              _FeatureCard(
                title: 'Semantic Search',
                description: 'Instantly find relevant code snippets and documentation across thousands of files using Qdrant vector search.',
                iconData: Icons.search_rounded,
                iconColor: theme.colorScheme.secondary,
              ),
              _FeatureCard(
                title: 'Live Context Fallbacks',
                description: 'When internal knowledge is insufficient, Veraxi seamlessly falls back to real-time web searches to gather external context.',
                iconData: Icons.bolt,
                iconColor: theme.colorScheme.primary,
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
    final theme = Theme.of(context);
    
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 340,
        height: 260,
        transform: Matrix4.translationValues(0, _isHovered ? -8 : 0, 0),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: _isHovered 
              ? widget.iconColor.withValues(alpha: 0.5) 
              : theme.colorScheme.outline.withValues(alpha: 0.2),
            width: 1.5,
          ),
        ),
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
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
                color: theme.colorScheme.onSurface,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.description,
              style: GoogleFonts.inter(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                fontSize: 15,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
