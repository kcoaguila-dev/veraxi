import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veraxi_app/features/control_panel/view_models/control_panel_view_model.dart';
import 'package:veraxi_app/features/control_panel/views/widgets/schema_visual_builder.dart';
import 'package:veraxi_app/core/theme_extension.dart';


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
    final state = ref.watch(controlPanelViewModelProvider);
    final viewModel = ref.read(controlPanelViewModelProvider.notifier);

    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Knowledge Graph Schema (Ontology)',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 18)),
          SizedBox(height: 4),
          Text(
              'Define the entities and relationships that the AI should extract during ingestion.',
              style: TextStyle(color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 14)),
          SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Auto-Generate from Sample',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w500)),
                    SizedBox(height: 8),
                    TextField(
                      controller: _schemaSampleTextController,
                      maxLines: 7,
                      style: TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText:
                            'Paste a sample of your text here (e.g., an abstract or executive summary). The AI will auto-generate an appropriate schema.',
                        hintStyle: TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
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
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.auto_awesome, size: 18),
                      label: Text('Auto-Generate'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple.shade600,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 24),
              Expanded(
                flex: 1,
                child: SchemaVisualBuilder(
                  initialSchema: state.schema,
                  isSaving: state.isIngesting,
                  onSave: (schema) {
                    viewModel.saveSchema(schema);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
