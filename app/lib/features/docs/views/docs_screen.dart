import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
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
<your_agent_cli> mcp install veraxi
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
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        children: [
          NavBar(onFeaturesTap: () => context.go('/')),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
              child: Center(
                child: Container(
                  width: 800,
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.arrow_back, color: theme.colorScheme.onSurfaceVariant),
                            onPressed: () => context.go('/'),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            'Documentation',
                            style: GoogleFonts.inter(
                              color: theme.colorScheme.onSurface,
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
                          h1: GoogleFonts.inter(color: theme.colorScheme.onSurface, fontSize: 32, fontWeight: FontWeight.bold),
                          h2: GoogleFonts.inter(color: theme.colorScheme.onSurface, fontSize: 24, fontWeight: FontWeight.bold),
                          h3: GoogleFonts.inter(color: theme.colorScheme.onSurface, fontSize: 20, fontWeight: FontWeight.w600),
                          p: GoogleFonts.inter(color: theme.colorScheme.onSurfaceVariant, fontSize: 16, height: 1.6),
                          code: GoogleFonts.firaCode(color: const Color(0xFF10B981), backgroundColor: theme.colorScheme.surfaceContainerHighest, fontSize: 14),
                          codeblockDecoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: theme.colorScheme.outlineVariant),
                          ),
                          blockquote: GoogleFonts.inter(color: theme.colorScheme.onSurfaceVariant, fontStyle: FontStyle.italic),
                          blockquoteDecoration: BoxDecoration(
                            border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 4)),
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
