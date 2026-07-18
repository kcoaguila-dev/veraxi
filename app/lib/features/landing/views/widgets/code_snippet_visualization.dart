import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/theme.dart';

class CodeSnippetVisualization extends StatelessWidget {
  const CodeSnippetVisualization({super.key});

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
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 30,
            offset: const Offset(0, 10),
          )
        ],
      ),
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
                  bottom: 20,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.2),
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
