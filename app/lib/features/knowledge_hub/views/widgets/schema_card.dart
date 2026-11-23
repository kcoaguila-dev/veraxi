import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/knowledge_hub/view_models/knowledge_hub_view_model.dart';
import 'package:veraxi_app/features/knowledge_hub/views/widgets/schema_visual_builder.dart';

class SchemaCard extends ConsumerStatefulWidget {
  const SchemaCard({super.key});

  @override
  ConsumerState<SchemaCard> createState() => _SchemaCardState();
}

class _SchemaCardState extends ConsumerState<SchemaCard> {
  final _schemaSampleTextController = TextEditingController();

  @override
  void dispose() {
    _schemaSampleTextController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(knowledgeHubViewModelProvider);
    final viewModel = ref.read(knowledgeHubViewModelProvider.notifier);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2D2D32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Information Extraction Rules',
              style: TextStyle(
                  color: Color(0xFFF4F4F5),
                  fontWeight: FontWeight.w600,
                  fontSize: 16)),
          const SizedBox(height: 4),
          const Text(
              'Define the entities and relationships that the AI should extract during ingestion.',
              style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 13)),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < 600;

              final autoGenerateSection = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Auto-Generate from Sample',
                      style: TextStyle(
                          color: Color(0xFFE4E4E7),
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _schemaSampleTextController,
                    maxLines: 7,
                    style:
                        const TextStyle(color: Color(0xFFF4F4F5), fontSize: 13),
                    decoration: InputDecoration(
                      hintText:
                          'Paste a sample of your text here (e.g., an abstract or executive summary). The AI will auto-generate an appropriate schema.',
                      hintStyle: const TextStyle(
                          color: Color(0xFF71717A), fontSize: 12.5),
                      filled: true,
                      fillColor: const Color(0xFF141416),
                      contentPadding: const EdgeInsets.all(14),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF2D2D32)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF3F3F46)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: state.isIngesting
                        ? null
                        : () {
                            if (_schemaSampleTextController.text
                                .trim()
                                .isNotEmpty) {
                              viewModel.autoGenerateSchema(
                                  _schemaSampleTextController.text.trim());
                            }
                          },
                    icon: state.isIngesting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_awesome,
                            size: 15, color: Color(0xFFA78BFA)),
                    label: const Text('Auto-Generate'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF27272B),
                      foregroundColor: const Color(0xFFE4E4E7),
                      disabledBackgroundColor: const Color(0xFF1F1F23),
                      disabledForegroundColor: const Color(0xFF71717A),
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w500),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                        side: const BorderSide(
                            color: Color(0xFF3A3A40), width: 0.8),
                      ),
                    ),
                  ),
                ],
              );

              final schemaVisualSection = SchemaVisualBuilder(
                initialSchema: state.schema,
                isSaving: state.isIngesting,
                onSave: (schema) {
                  viewModel.saveSchema(schema);
                },
              );

              if (isMobile) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    autoGenerateSection,
                    SizedBox(height: 32),
                    schemaVisualSection,
                  ],
                );
              } else {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 1, child: autoGenerateSection),
                    SizedBox(width: 24),
                    Expanded(flex: 1, child: schemaVisualSection),
                  ],
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
