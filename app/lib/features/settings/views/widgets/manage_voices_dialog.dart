import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:veraxi_app/features/settings/view_models/tts_settings_view_model.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/theme_extension.dart';


class ManageVoicesDialog extends ConsumerStatefulWidget {
  const ManageVoicesDialog({super.key});

  @override
  ConsumerState<ManageVoicesDialog> createState() => _ManageVoicesDialogState();
}

class _ManageVoicesDialogState extends ConsumerState<ManageVoicesDialog> {
  late List<Map<String, dynamic>> _voices;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final currentState = ref.read(ttsSettingsViewModelProvider);
    // Deep copy to allow editing without affecting global state until save
    _voices =
        currentState.voices.map((v) => Map<String, dynamic>.from(v)).toList();
  }

  void _addVoice() {
    setState(() {
      _voices.add({
        'id': 'voice_${DateTime.now().millisecondsSinceEpoch}',
        'name': 'New Voice',
        'ref_audio_path': '',
        'prompt_text': '',
        'prompt_lang': 'en',
        'text_lang': 'en',
      });
    });
  }

  Future<void> _uploadVoice() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: true,
    );

    if (result != null && result.files.single.bytes != null) {
      final file = result.files.single;
      final fileName = file.name;
      final bytes = file.bytes!;

      if (!mounted) return;

      // Show dialog to get Name and Prompt
      final nameController = TextEditingController();
      final promptController = TextEditingController();

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
          title: Text('Configure New Voice',
              style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Selected: $fileName',
                  style: TextStyle(color: Colors.grey)),
              SizedBox(height: 16),
              TextField(
                controller: nameController,
                style: TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Voice Name',
                  labelStyle: TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF141414),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: promptController,
                style: TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Prompt Text (what is spoken in the audio)',
                  labelStyle: TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF141414),
                  suffixIcon: IconButton(
                    icon: Icon(Icons.upload_file, color: Colors.grey),
                    tooltip: 'Upload .txt file',
                    onPressed: () async {
                      final txtResult = await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['txt'],
                        withData: true,
                      );
                      if (txtResult != null &&
                          txtResult.files.single.bytes != null) {
                        try {
                          final text =
                              utf8.decode(txtResult.files.single.bytes!);
                          promptController.text = text;
                        } catch (e, st) {
                          Sentry.captureException(e, stackTrace: st);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content:
                                      Text('Failed to read text file: $e')),
                            );
                          }
                        }
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white, foregroundColor: Colors.black),
              child: Text('Upload'),
            ),
          ],
        ),
      );

      if (confirmed == true && mounted) {
        setState(() => _isSaving = true);
        try {
          await ref.read(ttsSettingsViewModelProvider.notifier).uploadVoice(
                nameController.text,
                promptController.text,
                bytes.toList(),
                fileName,
              );
          if (mounted) {
            // Refresh voices
            final currentState = ref.read(ttsSettingsViewModelProvider);
            setState(() {
              _voices = currentState.voices
                  .map((v) => Map<String, dynamic>.from(v))
                  .toList();
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Voice uploaded successfully!')),
            );
          }
        } catch (e, st) {
          Sentry.captureException(e, stackTrace: st);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to upload: $e')),
            );
          }
        } finally {
          if (mounted) setState(() => _isSaving = false);
        }
      }
    }
  }

  void _removeVoice(int index) {
    setState(() {
      _voices.removeAt(index);
    });
  }

  Future<void> _saveVoices() async {
    setState(() {
      _isSaving = true;
    });
    try {
      await ref.read(ttsSettingsViewModelProvider.notifier).saveVoices(_voices);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 600,
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Manage GPT-SoVITS Voices',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: Colors.grey),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            SizedBox(height: 8),
            Text(
              'Add or edit voice personas. Audio files must still exist on the TTS server.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            SizedBox(height: 24),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _voices.length,
                separatorBuilder: (context, index) =>
                    Divider(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                itemBuilder: (context, index) {
                  final voice = _voices[index];
                  final isSystem = voice['id'] == 'default_system';

                  if (isSystem) {
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(voice['name'] ?? 'System Default',
                          style: TextStyle(color: Colors.white)),
                      subtitle: Text('Cannot be edited or removed.',
                          style: TextStyle(color: Colors.grey, fontSize: 12)),
                    );
                  }

                  return _VoiceEditorForm(
                    voice: voice,
                    onChanged: (updatedVoice) {
                      _voices[index] = updatedVoice;
                    },
                    onRemove: () => _removeVoice(index),
                  );
                },
              ),
            ),
            SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _addVoice,
                      icon:
                          Icon(Icons.add, color: Colors.white, size: 18),
                      label: Text('Manual Entry',
                          style: TextStyle(color: Colors.white)),
                      style: TextButton.styleFrom(
                        backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                        padding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                    ),
                    SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _uploadVoice,
                      icon: Icon(Icons.upload_file,
                          color: Colors.white, size: 18),
                      label: Text('Upload Audio',
                          style: TextStyle(color: Colors.white)),
                      style: TextButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                        padding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                    ),
                  ],
                ),
                ElevatedButton(
                  onPressed: _isSaving ? null : _saveVoices,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                  ),
                  child: _isSaving
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text('Save Changes'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceEditorForm extends StatefulWidget {
  final Map<String, dynamic> voice;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final VoidCallback onRemove;

  const _VoiceEditorForm({
    required this.voice,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_VoiceEditorForm> createState() => _VoiceEditorFormState();
}

class _VoiceEditorFormState extends State<_VoiceEditorForm> {
  late TextEditingController _nameController;
  late TextEditingController _pathController;
  late TextEditingController _promptController;
  late String _promptLang;
  late String _textLang;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.voice['name']);
    _pathController =
        TextEditingController(text: widget.voice['ref_audio_path']);
    _promptController =
        TextEditingController(text: widget.voice['prompt_text']);
    _promptLang = widget.voice['prompt_lang'] ?? 'en';
    _textLang = widget.voice['text_lang'] ?? 'en';
  }

  void _update() {
    final updated = Map<String, dynamic>.from(widget.voice);
    updated['name'] = _nameController.text;
    updated['ref_audio_path'] = _pathController.text;
    updated['prompt_text'] = _promptController.text;
    updated['prompt_lang'] = _promptLang;
    updated['text_lang'] = _textLang;
    widget.onChanged(updated);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildTextField('Voice Name', _nameController, _update),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: widget.onRemove,
              ),
            ],
          ),
          SizedBox(height: 8),
          _buildTextField(
              'Audio Path (e.g. voices/geralt.wav)', _pathController, _update),
          SizedBox(height: 8),
          _buildTextField(
            'Reference Transcript',
            _promptController,
            _update,
            hintText: 'Enter exactly what is spoken in the audio file',
            suffixIcon: IconButton(
              icon: Icon(Icons.upload_file, color: Colors.grey),
              tooltip: 'Upload .txt file',
              onPressed: () async {
                final txtResult = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['txt'],
                  withData: true,
                );
                if (txtResult != null && txtResult.files.single.bytes != null) {
                  try {
                    final text = utf8.decode(txtResult.files.single.bytes!);
                    _promptController.text = text;
                    _update();
                  } catch (e, st) {
                    Sentry.captureException(e, stackTrace: st);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to read text file: $e')),
                      );
                    }
                  }
                }
              },
            ),
          ),
          SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child:
                    _buildDropdown('Transcript Language', _promptLang, (val) {
                  setState(() => _promptLang = val!);
                  _update();
                }),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _buildDropdown('Generated Speech Language', _textLang,
                    (val) {
                  setState(() => _textLang = val!);
                  _update();
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(
      String label, TextEditingController controller, VoidCallback onChanged,
      {Widget? suffixIcon, String? hintText}) {
    return TextField(
      controller: controller,
      onChanged: (_) => onChanged(),
      style: TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        hintStyle: TextStyle(color: Color(0xFF666666), fontSize: 13),
        labelStyle: TextStyle(color: Colors.grey, fontSize: 12),
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF141414),
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: Colors.grey),
        ),
      ),
    );
  }

  Widget _buildDropdown(
      String label, String value, ValueChanged<String?> onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      onChanged: onChanged,
      style: TextStyle(color: Colors.white, fontSize: 13),
      dropdownColor: Theme.of(context).extension<AppThemeExtension>()!.cardBackground,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.grey, fontSize: 12),
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF141414),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: Colors.grey),
        ),
      ),
      items: [
        DropdownMenuItem(value: 'en', child: Text('English')),
        DropdownMenuItem(value: 'ja', child: Text('Japanese')),
        DropdownMenuItem(value: 'zh', child: Text('Chinese')),
        DropdownMenuItem(value: 'auto', child: Text('Auto')),
      ],
    );
  }
}
