import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:veraxi_app/core/theme_extension.dart';

class SchemaVisualBuilder extends StatefulWidget {
  final Map<String, dynamic>? initialSchema;
  final bool isSaving;
  final Function(Map<String, dynamic>) onSave;

  const SchemaVisualBuilder({
    super.key,
    this.initialSchema,
    required this.isSaving,
    required this.onSave,
  });

  @override
  State<SchemaVisualBuilder> createState() => _SchemaVisualBuilderState();
}

class _SchemaVisualBuilderState extends State<SchemaVisualBuilder> {
  bool _advancedMode = false;
  late TextEditingController _jsonController;

  List<String> _entities = [];
  // list of map for relations: [{'source': 'A', 'type': 'rel', 'target': 'B'}]
  List<Map<String, String>> _relations = [];

  final TextEditingController _newEntityController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _jsonController = TextEditingController();
    _loadFromSchema(widget.initialSchema);
  }

  @override
  void didUpdateWidget(SchemaVisualBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSchema != oldWidget.initialSchema) {
      _loadFromSchema(widget.initialSchema);
    }
  }

  @override
  void dispose() {
    _jsonController.dispose();
    _newEntityController.dispose();
    super.dispose();
  }

  void _loadFromSchema(Map<String, dynamic>? schema) {
    if (schema == null) {
      _entities = [];
      _relations = [];
      _jsonController.text = "{\n  \"entities\": [],\n  \"relations\": {}\n}";
      return;
    }

    try {
      final ents = schema['entities'] as List<dynamic>? ?? [];
      _entities = ents.map((e) => e.toString()).toList();

      final relsMap = schema['relations'] as Map<String, dynamic>? ?? {};
      _relations = [];

      relsMap.forEach((sourceEnt, targetMap) {
        if (targetMap is Map<String, dynamic>) {
          targetMap.forEach((targetEnt, typesList) {
            if (typesList is List<dynamic>) {
              for (var type in typesList) {
                _relations.add({
                  'source': sourceEnt,
                  'target': targetEnt,
                  'type': type.toString(),
                });
              }
            }
          });
        }
      });

      _jsonController.text = const JsonEncoder.withIndent('  ').convert(schema);
    } catch (e) {
      // If parsing fails, just leave current state or clear
    }

    if (mounted) setState(() {});
  }

  Map<String, dynamic> _buildSchemaFromVisual() {
    Map<String, Map<String, List<String>>> relationsMap = {};
    for (var r in _relations) {
      final src = r['source']!;
      final tgt = r['target']!;
      final type = r['type']!;

      if (!relationsMap.containsKey(src)) {
        relationsMap[src] = {};
      }
      if (!relationsMap[src]!.containsKey(tgt)) {
        relationsMap[src]![tgt] = [];
      }
      if (!relationsMap[src]![tgt]!.contains(type)) {
        relationsMap[src]![tgt]!.add(type);
      }
    }

    return {
      'entities': _entities,
      'relations': relationsMap,
    };
  }

  void _syncVisualToJson() {
    final schema = _buildSchemaFromVisual();
    _jsonController.text = const JsonEncoder.withIndent('  ').convert(schema);
  }

  void _syncJsonToVisual() {
    try {
      final schema = jsonDecode(_jsonController.text) as Map<String, dynamic>;
      _loadFromSchema(schema);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid JSON format.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _addEntity() {
    final text = _newEntityController.text.trim();
    if (text.isNotEmpty && !_entities.contains(text)) {
      setState(() {
        _entities.add(text);
        _newEntityController.clear();
        _syncVisualToJson();
      });
    }
  }

  void _removeEntity(String entity) {
    setState(() {
      _entities.remove(entity);
      // Remove all relations involving this entity
      _relations
          .removeWhere((r) => r['source'] == entity || r['target'] == entity);
      _syncVisualToJson();
    });
  }

  void _addRelation() {
    if (_entities.isEmpty) return;
    setState(() {
      _relations.add({
        'source': _entities.first,
        'target': _entities.first,
        'type': 'RELATED_TO',
      });
      _syncVisualToJson();
    });
  }

  void _removeRelation(int index) {
    setState(() {
      _relations.removeAt(index);
      _syncVisualToJson();
    });
  }

  void _updateRelation(int index, String key, String value) {
    setState(() {
      _relations[index][key] = value;
      _syncVisualToJson();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Schema Configuration',
              style: TextStyle(
                color: Color(0xFFE4E4E7),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  if (_advancedMode) {
                    // Switching from JSON to Visual
                    _syncJsonToVisual();
                  } else {
                    // Switching from Visual to JSON
                    _syncVisualToJson();
                  }
                  _advancedMode = !_advancedMode;
                });
              },
              icon: Icon(
                _advancedMode ? Icons.view_quilt : Icons.code,
                size: 14,
                color: const Color(0xFFA1A1AA),
              ),
              label: Text(
                _advancedMode ? 'Visual Mode' : 'Advanced (JSON)',
                style: const TextStyle(
                  color: Color(0xFFD4D4D8),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              style: TextButton.styleFrom(
                backgroundColor: const Color(0xFF27272B),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                  side: const BorderSide(color: Color(0xFF3A3A40), width: 0.8),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF141416),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF2D2D32)),
          ),
          constraints: const BoxConstraints(minHeight: 250, maxHeight: 500),
          child: _advancedMode ? _buildJsonEditor() : _buildVisualEditor(),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: widget.isSaving
              ? null
              : () {
                  if (_advancedMode) {
                    try {
                      final schema = jsonDecode(_jsonController.text);
                      widget.onSave(schema);
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Invalid JSON'),
                          backgroundColor: Colors.red));
                    }
                  } else {
                    widget.onSave(_buildSchemaFromVisual());
                  }
                },
          icon: const Icon(Icons.save_outlined, size: 15),
          label: const Text('Save Schema'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1D4ED8),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF202229),
            disabledForegroundColor: const Color(0xFF71717A),
            elevation: 0,
            shadowColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle:
                const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildJsonEditor() {
    return Padding(
      padding: EdgeInsets.all(8.0),
      child: TextField(
        controller: _jsonController,
        maxLines: 15,
        style: TextStyle(
            color: Colors.greenAccent, fontSize: 13, fontFamily: 'monospace'),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildVisualEditor() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Entities',
              style: TextStyle(
                  color: Colors.white70, fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ..._entities.map((e) => Chip(
                    label: Text(
                      e,
                      style: const TextStyle(
                        color: Color(0xFFE4E4E7),
                        fontSize: 12,
                      ),
                    ),
                    backgroundColor: const Color(0xFF232328),
                    deleteIcon: const Icon(
                      Icons.close,
                      size: 14,
                      color: Color(0xFFA1A1AA),
                    ),
                    onDeleted: () => _removeEntity(e),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    side: const BorderSide(color: Color(0xFF32323A)),
                  )),
              SizedBox(
                width: 150,
                height: 32,
                child: TextField(
                  controller: _newEntityController,
                  style:
                      const TextStyle(color: Color(0xFFF4F4F5), fontSize: 12.5),
                  decoration: InputDecoration(
                    hintText: 'Add entity...',
                    hintStyle: const TextStyle(
                        color: Color(0xFF71717A), fontSize: 12.5),
                    filled: true,
                    fillColor: const Color(0xFF232328),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: Color(0xFF32323A)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: Color(0xFF52525B)),
                    ),
                  ),
                  onSubmitted: (_) => _addEntity(),
                ),
              ),
            ],
          ),
          SizedBox(height: 24),
          Text('Relationships',
              style: TextStyle(
                  color: Colors.white70, fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          if (_relations.isEmpty)
            Text('No relationships defined.',
                style: TextStyle(color: Colors.white38, fontSize: 13)),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _relations.length,
            itemBuilder: (context, index) {
              final rel = _relations[index];
              return Padding(
                padding: EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildEntityDropdown(rel['source']!,
                          (val) => _updateRelation(index, 'source', val!)),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: SizedBox(
                        height: 36,
                        child: TextFormField(
                          initialValue: rel['type'],
                          style: TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .borderColor,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 0),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(4),
                                borderSide: BorderSide.none),
                          ),
                          onChanged: (val) =>
                              _updateRelation(index, 'type', val),
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: _buildEntityDropdown(rel['target']!,
                          (val) => _updateRelation(index, 'target', val!)),
                    ),
                    IconButton(
                      icon: Icon(Icons.remove_circle_outline,
                          color: Colors.redAccent, size: 20),
                      onPressed: () => _removeRelation(index),
                    ),
                  ],
                ),
              );
            },
          ),
          SizedBox(height: 8),
          TextButton.icon(
            onPressed: _entities.isEmpty ? null : _addRelation,
            icon: const Icon(Icons.add, size: 14, color: Color(0xFF34D399)),
            label: const Text(
              'Add Relationship',
              style: TextStyle(
                color: Color(0xFFD4D4D8),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF27272B),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
                side: const BorderSide(color: Color(0xFF3A3A40), width: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntityDropdown(String value, ValueChanged<String?> onChanged) {
    // If somehow the entity was removed but relation still has it, fallback
    final validValue = _entities.contains(value)
        ? value
        : (_entities.isNotEmpty ? _entities.first : null);

    return Container(
      height: 36,
      padding: EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: validValue,
          dropdownColor:
              Theme.of(context).extension<AppThemeExtension>()!.borderColor,
          style: TextStyle(color: Colors.white, fontSize: 13),
          isExpanded: true,
          items: _entities
              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
