import re

with open('app/lib/features/knowledge_hub/views/knowledge_hub_screen.dart', 'r') as f:
    content = f.read()

def extract_method(method_name):
    # Extracts the entire method definition by matching braces.
    pattern = r'(Widget ' + method_name + r'\([^)]*\)\s*\{)'
    match = re.search(pattern, content)
    if not match:
        return ""
    start_idx = match.start()
    brace_count = 0
    in_string = False
    escape = False
    
    for i in range(start_idx + len(match.group(1)) - 1, len(content)):
        char = content[i]
        if escape:
            escape = False
            continue
        if char == '\\':
            escape = True
            continue
        if char == '"' or char == "'":
            # very simplistic string handling
            in_string = not in_string
            continue
            
        if not in_string:
            if char == '{':
                brace_count += 1
            elif char == '}':
                brace_count -= 1
                if brace_count == 0:
                    return content[start_idx:i+1]
    return ""

build_schema_card = extract_method('_buildSchemaCard')
build_ingestion_card = extract_method('_buildIngestionCard')
build_db_monitor = extract_method('_buildDatabaseMonitorCard')
build_data_pipeline = extract_method('_buildDataPipeline')

# Rewrite _buildDataPipeline to change 'My Library' to 'Knowledge Hub'
build_data_pipeline = build_data_pipeline.replace("'My Library'", "'Knowledge Hub'")

new_content = f"""import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/knowledge_hub_view_model.dart';
import 'widgets/schema_card.dart';
import 'package:veraxi_app/features/chat/views/widgets/chat_sidebar.dart';
import 'package:veraxi_app/features/chat/view_models/sidebar_view_model.dart';
import 'widgets/schema_visual_builder.dart';

class KnowledgeHubScreen extends ConsumerStatefulWidget {{
  const KnowledgeHubScreen({{super.key}});

  @override
  ConsumerState<KnowledgeHubScreen> createState() => _KnowledgeHubScreenState();
}}

class _KnowledgeHubScreenState extends ConsumerState<KnowledgeHubScreen> {{
  final TextEditingController _textController = TextEditingController();

  @override
  void dispose() {{
    _textController.dispose();
    super.dispose();
  }}

{build_schema_card}

{build_ingestion_card}

{build_db_monitor}

{build_data_pipeline}

  @override
  Widget build(BuildContext context) {{
    final theme = Theme.of(context);
    final isSidebarOpen = ref.watch(sidebarStateProvider);
    final state = ref.watch(knowledgeHubViewModelProvider);

    ref.listen<KnowledgeHubState>(knowledgeHubViewModelProvider, (previous, next) {{
      if (previous?.successMessage != next.successMessage && next.successMessage != null) {{
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!), backgroundColor: Colors.green.shade800));
      }}
      if (previous?.error != next.error && next.error != null) {{
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: ${{next.error}}'), backgroundColor: Colors.red.shade800));
      }}
    }});

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      drawer: const ChatSidebar(isSidebarOpen: true, isMobile: true),
      body: LayoutBuilder(
        builder: (context, constraints) {{
          final isMobile = constraints.maxWidth < 800;
          return Row(
            children: [
              if (!isMobile) ChatSidebar(isSidebarOpen: isSidebarOpen, isMobile: false),
              Expanded(
                child: SafeArea(
                  child: Column(
                    children: [
                      if (isMobile)
                        Container(
                          height: 56,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: const BoxDecoration(
                            border: Border(bottom: BorderSide(color: Color(0xFF2A2A2A))),
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.menu, color: Colors.white),
                                onPressed: () => Scaffold.of(context).openDrawer(),
                              ),
                              const SizedBox(width: 8),
                              const Text('Veraxi', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.all(isMobile ? 16.0 : 48.0),
                          child: _buildDataPipeline(theme),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }},
      ),
    );
  }}
}}
"""

with open('app/lib/features/knowledge_hub/views/knowledge_hub_screen.dart', 'w') as f:
    f.write(new_content)
