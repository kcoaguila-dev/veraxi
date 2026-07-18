import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/theme.dart';
import 'package:veraxi_app/features/landing/views/widgets/nav_bar.dart';

class DocsScreen extends StatelessWidget {
  const DocsScreen({super.key});

  final String _docsContent = '''
# Veraxi Documentation

Welcome to the official Veraxi documentation.

## Getting Started
Veraxi is an advanced Model Context Protocol (MCP) server that empowers AI agents to read, write, and query complex Knowledge Graphs and Vector Databases autonomously.

### Core Architecture
- **Knowledge Graph:** Neo4j (Entity Relationship extraction)
- **Vector Database:** Qdrant (Semantic Search)
- **Synthesis:** Hybrid GraphRAG merging

## Using the CLI
To initialize Veraxi in your workspace, run:
```bash
antigravity mcp install veraxi
```

## Creating Entities
Agents can create entities autonomously using the MCP protocol.
```json
{
  "entity": "User",
  "properties": {
    "name": "Jane Doe",
    "role": "Admin"
  }
}
```

*More documentation coming soon...*
''';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Column(
        children: [
          const NavBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
              child: Center(
                child: Container(
                  width: 800,
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.surfaceHighlight),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back, color: AppTheme.textSecondary),
                            onPressed: () => context.go('/'),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            'Documentation',
                            style: GoogleFonts.inter(
                              color: AppTheme.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),
                      MarkdownBody(
                        data: _docsContent,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet(
                          h1: GoogleFonts.inter(color: AppTheme.textPrimary, fontSize: 32, fontWeight: FontWeight.bold),
                          h2: GoogleFonts.inter(color: AppTheme.textPrimary, fontSize: 24, fontWeight: FontWeight.bold),
                          h3: GoogleFonts.inter(color: AppTheme.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
                          p: GoogleFonts.inter(color: AppTheme.textSecondary, fontSize: 16, height: 1.6),
                          code: GoogleFonts.firaCode(color: const Color(0xFF10B981), backgroundColor: const Color(0xFF131313), fontSize: 14),
                          codeblockDecoration: BoxDecoration(
                            color: const Color(0xFF131313),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.surfaceHighlight),
                          ),
                          blockquote: GoogleFonts.inter(color: AppTheme.textSecondary, fontStyle: FontStyle.italic),
                          blockquoteDecoration: const BoxDecoration(
                            border: Border(left: BorderSide(color: AppTheme.primary, width: 4)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
