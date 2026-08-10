import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:veraxi_app/core/widgets/nav_bar.dart';

class DocsScreen extends StatelessWidget {
  const DocsScreen({super.key});

  final String _docsContent = '''
# Veraxi v1.0 RC Documentation

Welcome to the official Veraxi documentation. The sovereign intelligence platform is now ready for production deployments.

## Core Features

- **Enterprise Authentication:** Secure OAuth SSO (Google & GitHub) powered by Supabase.
- **Knowledge Graph:** Neo4j-backed entity extraction and relationship mapping.
- **Vector Database:** Qdrant-backed semantic search for infinite context windows.
- **Hybrid GraphRAG:** Advanced RRF (Reciprocal Rank Fusion) querying.
- **Content Safety:** Integrated OpenAI Moderation API middleware preventing prompt injection and abuse.

## Data & Privacy (GDPR/CCPA Compliant)
Veraxi is built on the philosophy of sovereign intelligence. We respect user data:
- **Right to Portability:** Users can export all chat history in raw JSON format at any time.
- **Right to be Forgotten:** Users can permanently delete their accounts. This triggers a cascading hard-delete across Neo4j, Qdrant, Redis, and Supabase.

## Production Deployment (Kubernetes)

Veraxi is containerized and managed via Helm, making it trivial to scale horizontally on any Kubernetes cluster.

1. **Install Ingress Controller & Cert-Manager** (for SSL):
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install nginx-ingress ingress-nginx/ingress-nginx

helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager --set crds.enabled=true
```

2. **Configure Domain:** 
Edit `helm/veraxi/values.yaml` and replace `YOUR_DOMAIN_HERE.com` with your domain.

3. **Deploy:**
```bash
helm upgrade --install veraxi ./helm/veraxi
```

## Using the MCP Server CLI
To initialize Veraxi as a tool-agent in your local workspace, run:
```bash
<your_agent_cli> mcp install veraxi
```
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 60),
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 800),
                  padding: const EdgeInsets.all(24),
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
                            icon: Icon(Icons.arrow_back,
                                color: theme.colorScheme.onSurfaceVariant),
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
                          h1: GoogleFonts.inter(
                              color: theme.colorScheme.onSurface,
                              fontSize: 32,
                              fontWeight: FontWeight.bold),
                          h2: GoogleFonts.inter(
                              color: theme.colorScheme.onSurface,
                              fontSize: 24,
                              fontWeight: FontWeight.bold),
                          h3: GoogleFonts.inter(
                              color: theme.colorScheme.onSurface,
                              fontSize: 20,
                              fontWeight: FontWeight.w600),
                          p: GoogleFonts.inter(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 16,
                              height: 1.6),
                          code: GoogleFonts.firaCode(
                              color: const Color(0xFF10B981),
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHighest,
                              fontSize: 14),
                          codeblockDecoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: theme.colorScheme.outlineVariant),
                          ),
                          blockquote: GoogleFonts.inter(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic),
                          blockquoteDecoration: BoxDecoration(
                            border: Border(
                                left: BorderSide(
                                    color: theme.colorScheme.primary,
                                    width: 4)),
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
