import 'dart:convert';
import 'package:flutter/material.dart';

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
      _relations.removeWhere((r) => r['source'] == entity || r['target'] == entity);
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
            const Text('Schema Configuration',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w500)),
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
                size: 16,
                color: Colors.blueAccent,
              ),
              label: Text(
                _advancedMode ? 'Visual Mode' : 'Advanced (JSON)',
                style: const TextStyle(color: Colors.blueAccent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(8),
          ),
          constraints: const BoxConstraints(minHeight: 250),
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
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Invalid JSON'),
                              backgroundColor: Colors.red));
                    }
                  } else {
                    widget.onSave(_buildSchemaFromVisual());
                  }
                },
          icon: const Icon(Icons.save, size: 18),
          label: const Text('Save Schema'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blue.shade600,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildJsonEditor() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: TextField(
        controller: _jsonController,
        maxLines: 15,
        style: const TextStyle(
            color: Colors.greenAccent,
            fontSize: 13,
            fontFamily: 'monospace'),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildVisualEditor() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Entities', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ..._entities.map((e) => Chip(
                label: Text(e, style: const TextStyle(fontSize: 12)),
                backgroundColor: const Color(0xFF333333),
                deleteIcon: const Icon(Icons.close, size: 14),
                onDeleted: () => _removeEntity(e),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                side: BorderSide.none,
              )),
              SizedBox(
                width: 150,
                height: 32,
                child: TextField(
                  controller: _newEntityController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Add entity...',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _addEntity(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Relationships', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (_relations.isEmpty)
            const Text('No relationships defined.', style: TextStyle(color: Colors.white38, fontSize: 13)),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _relations.length,
            itemBuilder: (context, index) {
              final rel = _relations[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildEntityDropdown(rel['source']!, (val) => _updateRelation(index, 'source', val!)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: SizedBox(
                        height: 36,
                        child: TextFormField(
                          initialValue: rel['type'],
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF2A2A2A),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
                          ),
                          onChanged: (val) => _updateRelation(index, 'type', val),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: _buildEntityDropdown(rel['target']!, (val) => _updateRelation(index, 'target', val!)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                      onPressed: () => _removeRelation(index),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _entities.isEmpty ? null : _addRelation,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Relationship'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.blueAccent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntityDropdown(String value, ValueChanged<String?> onChanged) {
    // If somehow the entity was removed but relation still has it, fallback
    final validValue = _entities.contains(value) ? value : (_entities.isNotEmpty ? _entities.first : null);
    
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: validValue,
          dropdownColor: const Color(0xFF2A2A2A),
          style: const TextStyle(color: Colors.white, fontSize: 13),
          isExpanded: true,
          items: _entities.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
