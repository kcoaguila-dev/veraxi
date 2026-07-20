import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class CodeSnippetVisualization extends StatelessWidget {
  const CodeSnippetVisualization({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
      child: Center(
        child: Container(
          width: 800,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.1),
                blurRadius: 40,
                offset: const Offset(0, 20),
              )
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.3))),
                ),
                child: Row(
                  children: [
                    _buildMacOsButton(Colors.redAccent),
                    const SizedBox(width: 8),
                    _buildMacOsButton(Colors.amber),
                    const SizedBox(width: 8),
                    _buildMacOsButton(Colors.greenAccent),
                    const SizedBox(width: 24),
                    Text(
                      'veraxi_agent.py',
                      style: GoogleFonts.firaCode(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text.rich(
                  TextSpan(
                    style: GoogleFonts.firaCode(
                      fontSize: 14,
                      height: 1.6,
                      color: isDark ? const Color(0xFFD4D4D4) : const Color(0xFF333333),
                    ),
                    children: [
                      _buildToken('from ', theme.colorScheme.primary),
                      _buildToken('veraxi ', theme.colorScheme.onSurface),
                      _buildToken('import ', theme.colorScheme.primary),
                      _buildToken('IntelligenceSubstrate\n\n', theme.colorScheme.secondary),
                      _buildToken('# Initialize the sovereign brain\n', theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                      _buildToken('brain ', theme.colorScheme.onSurface),
                      _buildToken('= ', theme.colorScheme.primary),
                      _buildToken('IntelligenceSubstrate(\n', theme.colorScheme.secondary),
                      _buildToken('    graph_db=', theme.colorScheme.onSurface),
                      _buildToken('"neo4j://localhost:7687"', theme.colorScheme.error),
                      _buildToken(',\n', theme.colorScheme.onSurface),
                      _buildToken('    vector_db=', theme.colorScheme.onSurface),
                      _buildToken('"http://localhost:6333"', theme.colorScheme.error),
                      _buildToken('\n)\n\n', theme.colorScheme.onSurface),
                      _buildToken('# Execute a GraphRAG unified query\n', theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                      _buildToken('result ', theme.colorScheme.onSurface),
                      _buildToken('= ', theme.colorScheme.primary),
                      _buildToken('brain.', theme.colorScheme.onSurface),
                      _buildToken('query(\n', theme.colorScheme.secondary),
                      _buildToken('    ', theme.colorScheme.onSurface),
                      _buildToken('"How does the authentication flow work?"\n', theme.colorScheme.error),
                      _buildToken(')', theme.colorScheme.onSurface),
                    ],
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMacOsButton(Color color) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  TextSpan _buildToken(String text, Color color) {
    return TextSpan(text: text, style: TextStyle(color: color));
  }
}
