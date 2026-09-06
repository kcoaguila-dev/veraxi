import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'web_search_dialog.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class ChatInput extends StatefulWidget {
  final bool isLoading;
  final String? projectName;
  final Function(String, {List<PlatformFile>? attachments}) onSend;
  final String? errorText;
  final VoidCallback? onDismissError;

  const ChatInput({
    super.key,
    required this.isLoading,
    this.projectName,
    required this.onSend,
    this.errorText,
    this.onDismissError,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;
  bool _fileSearchEnabled = false;
  bool _webSearchEnabled = false;
  bool _highAccuracyEnabled = false;
  bool _skillsEnabled = false;
  bool _runCodeEnabled = false;
  bool _artifactsEnabled = false;
  final List<PlatformFile> _attachedFiles = [];

  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;
  String _lastRecognizedWords = '';
  String _textBeforeListen = '';
  bool _isExpanded = false;
  bool _showExpandIcon = false;

  bool get _shouldShowExpand {
    if (_isExpanded) return true;
    final text = _controller.text;
    final newlineCount = text.split('\n').length;
    final approxWrappedLines = (text.length / 70).ceil();
    return newlineCount >= 3 || approxWrappedLines >= 3;
  }

  @override
  void initState() {
    super.initState();
    _loadToolSettings();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      final shouldShowExpand = _shouldShowExpand;
      if (hasText != _hasText || shouldShowExpand != _showExpandIcon) {
        setState(() {
          _hasText = hasText;
          _showExpandIcon = shouldShowExpand;
        });
      }
    });
    _initSpeech();
  }

  void _initSpeech() async {
    try {
      _speechEnabled = await _speechToText.initialize(
        onError: (error) => debugPrint('Error initializing STT: $error'),
        onStatus: (status) {
          if (status == 'notListening' || status == 'done') {
            setState(() {
              _isListening = false;
            });
          }
        },
      );
    } catch (e) {
      debugPrint('SpeechToText initialization failed: $e');
      _speechEnabled = false;
    }
    setState(() {});
  }

  void _toggleListening() async {
    if (!_speechEnabled) {
      _speechEnabled = await _speechToText.initialize();
      if (!_speechEnabled) return;
    }

    if (_speechToText.isListening) {
      await _speechToText.stop();
      setState(() {
        _isListening = false;
      });
    } else {
      _textBeforeListen = _controller.text;
      if (_textBeforeListen.isNotEmpty && !_textBeforeListen.endsWith(' ')) {
        _textBeforeListen += ' ';
      }
      _lastRecognizedWords = '';
      await _speechToText.listen(
        onResult: (result) {
          setState(() {
            _lastRecognizedWords = result.recognizedWords;
            _controller.text = _textBeforeListen + _lastRecognizedWords;
            _controller.selection = TextSelection.fromPosition(
                TextPosition(offset: _controller.text.length));
          });
        },
      );
      setState(() {
        _isListening = true;
      });
    }
  }

  Future<void> _loadToolSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settingsJson = prefs.getString('tool_settings');
    if (settingsJson != null) {
      try {
        final settings = jsonDecode(settingsJson) as Map<String, dynamic>;
        bool fileEnabled = settings.containsKey('file_search_enabled')
            ? settings['file_search_enabled'] as bool
            : false;

        bool webEnabled = false;
        bool highAccuracyEnabled = false;
        if (settings['web_search'] != null) {
          if (settings['web_search']['enabled'] != null) {
            webEnabled = settings['web_search']['enabled'] as bool;
          }
          if (settings['web_search']['high_accuracy'] != null) {
            highAccuracyEnabled = settings['web_search']['high_accuracy'] as bool;
          }
        }

        bool skillsEnabled = settings['skills_enabled'] as bool? ?? false;
        bool runCodeEnabled = settings['run_code_enabled'] as bool? ?? false;
        bool artifactsEnabled = settings['artifacts_enabled'] as bool? ?? false;

        if (mounted) {
          setState(() {
            _fileSearchEnabled = fileEnabled;
            _webSearchEnabled = webEnabled;
            _highAccuracyEnabled = highAccuracyEnabled;
            _skillsEnabled = skillsEnabled;
            _runCodeEnabled = runCodeEnabled;
            _artifactsEnabled = artifactsEnabled;
          });
        }
      } catch (_) {}
    }
  }

  Future<void> _toggleTool(String toolKey, bool currentValue) async {
    final prefs = await SharedPreferences.getInstance();
    final currentSettingsJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if (currentSettingsJson != null) {
      try {
        settings = jsonDecode(currentSettingsJson) as Map<String, dynamic>;
      } catch (_) {}
    }

    if (toolKey == 'file_search') {
      settings['file_search_enabled'] = !currentValue;
      setState(() => _fileSearchEnabled = !currentValue);
    } else if (toolKey == 'web_search') {
      settings['web_search'] = settings['web_search'] ?? {};
      settings['web_search']['enabled'] = !currentValue;
      setState(() => _webSearchEnabled = !currentValue);
    } else if (toolKey == 'high_accuracy') {
      settings['web_search'] = settings['web_search'] ?? {};
      settings['web_search']['high_accuracy'] = !currentValue;
      setState(() => _highAccuracyEnabled = !currentValue);
    } else if (toolKey == 'skills') {
      settings['skills_enabled'] = !currentValue;
      setState(() => _skillsEnabled = !currentValue);
    } else if (toolKey == 'run_code') {
      settings['run_code_enabled'] = !currentValue;
      setState(() => _runCodeEnabled = !currentValue);
    } else if (toolKey == 'artifacts') {
      settings['artifacts_enabled'] = !currentValue;
      setState(() => _artifactsEnabled = !currentValue);
    }

    await prefs.setString('tool_settings', jsonEncode(settings));
  }

  void _handleSend() {
    final text = _controller.text;
    if (text.trim().isNotEmpty && !widget.isLoading) {
      widget.onSend(text,
          attachments: _attachedFiles.isNotEmpty ? _attachedFiles : null);
      _controller.clear();
      setState(() {
        _attachedFiles.clear();
      });
    }
  }

  Future<void> _pickFiles() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: [
          'pdf',
          'txt',
          'md',
          'csv',
          'html',
          'doc',
          'docx',
          'ppt',
          'pptx',
          'xls',
          'xlsx'
        ],
        withData: true, // Need bytes to upload
      );

      if (result != null) {
        setState(() {
          _attachedFiles.addAll(result.files);
        });
      }
    } catch (e, st) {
      Sentry.captureException(e, stackTrace: st);
      // Handle error or cancellation
    }
  }

  void _removeAttachment(int index) {
    setState(() {
      _attachedFiles.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.errorText != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8.0, left: 16.0, right: 16.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.errorText!,
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
                if (widget.onDismissError != null)
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.red, size: 20),
                    onPressed: widget.onDismissError,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
          ),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFF2F2F2F),
            borderRadius: BorderRadius.circular(24),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_attachedFiles.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: 8.0, left: 12.0, right: 12.0),
                  child: Wrap(
                    spacing: 8.0,
                    runSpacing: 4.0,
                    children: _attachedFiles.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final file = entry.value;
                      return Chip(
                        label: Text(
                          file.name,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        backgroundColor: const Color(0xFF404040),
                        deleteIconColor: const Color(0xFFB4B4B4),
                        onDeleted: () => _removeAttachment(idx),
                        padding: EdgeInsets.zero,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide.none,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              Stack(
                children: [
                  TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: _isExpanded ? 20 : 5,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    cursorColor: Colors.white,
                    decoration: InputDecoration(
                      hintText: widget.projectName != null
                          ? 'New chat in ${widget.projectName}'
                          : 'Message Veraxi...',
                      hintStyle: const TextStyle(
                          color: Color(0xFF878787), fontSize: 16),
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.only(
                          left: 4, right: 32, top: 12, bottom: 12),
                    ),
                    onSubmitted: (_) => _handleSend(),
                    enabled: !widget.isLoading,
                    textInputAction: TextInputAction.send,
                  ),
                  if (_showExpandIcon)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        icon: Icon(
                            _isExpanded
                                ? Icons.close_fullscreen
                                : Icons.open_in_full,
                            size: 16,
                            color: const Color(0xFF878787)),
                        onPressed: () {
                          setState(() {
                            _isExpanded = !_isExpanded;
                            // Ensure icon stays visible if expanded, or updates appropriately when collapsed
                            _showExpandIcon = _shouldShowExpand;
                          });
                        },
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                      ),
                    ),
                ],
              ),
              // Bottom Row: Actions (Attachment, Tune/Tools | Mic, Send Arrow)
              Row(
                children: [
                  Theme(
                    data: Theme.of(context).copyWith(
                      hoverColor: Colors.transparent,
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                    ),
                    child: PopupMenuButton<String>(
                      icon: const Icon(Icons.attach_file,
                          color: Color(0xFFB4B4B4), size: 20),
                      tooltip: 'Attach file',
                      color: const Color(0xFF2A2A2A),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      position: PopupMenuPosition.over,
                      enabled: !widget.isLoading,
                      onSelected: (value) {
                        _pickFiles();
                      },
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<String>>[
                        const PopupMenuItem<String>(
                          value: 'provider',
                          height: 40,
                          child: Row(
                            children: [
                              Icon(Icons.upload_file,
                                  color: Color(0xFFB4B4B4), size: 16),
                              SizedBox(width: 8),
                              Text('Upload to Provider',
                                  style: TextStyle(
                                      color: Color(0xFFB4B4B4), fontSize: 13)),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'text',
                          height: 40,
                          child: Row(
                            children: [
                              Icon(Icons.text_snippet,
                                  color: Color(0xFFB4B4B4), size: 16),
                              SizedBox(width: 8),
                              Text('Upload as Text',
                                  style: TextStyle(
                                      color: Color(0xFFB4B4B4), fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.tune,
                        color: Color(0xFFB4B4B4), size: 20),
                    tooltip: 'Tools',
                    color: const Color(0xFF171717),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: Color(0xFF2A2A2A)),
                    ),
                    position: PopupMenuPosition.under,
                    onSelected: (value) async {
                      if (value == 'web_search_config') {
                        await showDialog(
                          context: context,
                          builder: (context) => const WebSearchDialog(),
                        );
                        _loadToolSettings();
                      } else if (value == 'skills_config') {
                        context.go('/admin');
                      } else if (value == 'web_search_toggle') {
                        _toggleTool('web_search', _webSearchEnabled);
                      } else if (value == 'file_search_toggle') {
                        _toggleTool('file_search', _fileSearchEnabled);
                      } else if (value == 'skills_toggle') {
                        _toggleTool('skills', _skillsEnabled);
                      } else if (value == 'run_code_toggle') {
                        _toggleTool('run_code', _runCodeEnabled);
                      } else if (value == 'artifacts_toggle') {
                        _toggleTool('artifacts', _artifactsEnabled);
                      }
                    },
                    itemBuilder: (context) => [
                      _buildToolItem('file_search', 'File Search',
                          Icons.grid_view_outlined,
                          isActive: _fileSearchEnabled),
                      _buildWebSearchItem(_webSearchEnabled),
                      _buildSkillsItem(_skillsEnabled),
                      _buildToolItem('run_code', 'Run Code', Icons.terminal,
                          isActive: _runCodeEnabled),
                      _buildToolItem(
                          'artifacts', 'Artifacts >', Icons.auto_awesome,
                          isActive: _artifactsEnabled),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (_fileSearchEnabled)
                            _buildActiveToolChip(
                                'File Search',
                                Icons.grid_view_outlined,
                                () => _toggleTool('file_search', true)),
                          if (_webSearchEnabled) ...[
                            _buildActiveToolChip('Web Search', Icons.language,
                                () => _toggleTool('web_search', true)),
                            _buildActiveToolChip(
                                'High-Accuracy',
                                _highAccuracyEnabled
                                    ? Icons.verified
                                    : Icons.verified_outlined,
                                () => _toggleTool(
                                    'high_accuracy', _highAccuracyEnabled),
                                isActive: _highAccuracyEnabled,
                                isToggle: true),
                          ],
                          if (_skillsEnabled)
                            _buildActiveToolChip(
                                'Skills',
                                Icons.extension_outlined,
                                () => _toggleTool('skills', true)),
                          if (_runCodeEnabled)
                            _buildActiveToolChip('Run Code', Icons.terminal,
                                () => _toggleTool('run_code', true)),
                          if (_artifactsEnabled)
                            _buildActiveToolChip(
                                'Artifacts',
                                Icons.auto_awesome,
                                () => _toggleTool('artifacts', true)),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    icon: Icon(
                      _isListening ? Icons.mic : Icons.mic_none_outlined,
                      color: _isListening
                          ? const Color(0xFFE53935)
                          : const Color(0xFFB4B4B4),
                      size: 20,
                    ),
                    onPressed: widget.isLoading ? null : _toggleListening,
                    tooltip: 'Voice input',
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: (widget.isLoading || !_hasText) ? null : _handleSend,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: (widget.isLoading || _hasText)
                            ? Colors.white
                            : const Color(0xFF424242),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: widget.isLoading
                            ? const Icon(
                                Icons.stop_rounded,
                                color: Colors.black,
                                size: 16,
                              )
                            : Icon(
                                Icons.arrow_upward,
                                color: _hasText
                                    ? Colors.black
                                    : const Color(0xFFB4B4B4),
                                size: 20,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  PopupMenuItem<String> _buildToolItem(String value, String text, IconData icon,
      {bool isActive = false}) {
    return PopupMenuItem<String>(
      value: '${value}_toggle',
      height: 38,
      padding: EdgeInsets.zero,
      child: Container(
        width: 155,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(icon,
                color: isActive
                    ? const Color(0xFF10A37F)
                    : const Color(0xFFB4B4B4),
                size: 14),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            Icon(isActive ? LucideIcons.pinOff : LucideIcons.pin,
                color: isActive
                    ? const Color(0xFF10A37F)
                    : const Color(0xFF6E6E6E),
                size: 14),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _buildWebSearchItem(bool isActive) {
    return PopupMenuItem<String>(
      value: 'web_search_toggle',
      height: 38,
      padding: EdgeInsets.zero,
      child: Container(
        width: 155,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(Icons.language,
                color: isActive
                    ? const Color(0xFF10A37F)
                    : const Color(0xFFB4B4B4),
                size: 14),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Web Search',
                  style: TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            GestureDetector(
              onTap: () => Navigator.pop(context, 'web_search_config'),
              child: const Icon(Icons.settings_outlined,
                  color: Color(0xFF6E6E6E), size: 14),
            ),
            const SizedBox(width: 8),
            Icon(isActive ? LucideIcons.pinOff : LucideIcons.pin,
                color: isActive
                    ? const Color(0xFF10A37F)
                    : const Color(0xFF6E6E6E),
                size: 14),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _buildSkillsItem(bool isActive) {
    return PopupMenuItem<String>(
      value: 'skills_toggle',
      height: 38,
      padding: EdgeInsets.zero,
      child: Container(
        width: 155,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Icon(Icons.extension_outlined,
                color: isActive
                    ? const Color(0xFF10A37F)
                    : const Color(0xFFB4B4B4),
                size: 14),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Skills',
                  style: TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            GestureDetector(
              onTap: () => Navigator.pop(context, 'skills_config'),
              child: const Icon(Icons.settings_outlined,
                  color: Color(0xFF6E6E6E), size: 14),
            ),
            const SizedBox(width: 8),
            Icon(isActive ? LucideIcons.pinOff : LucideIcons.pin,
                color: isActive
                    ? const Color(0xFF10A37F)
                    : const Color(0xFF6E6E6E),
                size: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveToolChip(String label, IconData icon, VoidCallback onTap,
      {bool isActive = true, bool isToggle = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: (isToggle && isActive)
              ? const Color(0xFF10A37F).withValues(alpha: 0.1)
              : const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: (isToggle && isActive)
                  ? const Color(0xFF10A37F).withValues(alpha: 0.3)
                  : const Color(0xFF3A3A3A)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: (isToggle && isActive)
                    ? const Color(0xFF10A37F)
                    : const Color(0xFFB4B4B4),
                size: 12),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: (isToggle && isActive)
                        ? const Color(0xFF10A37F)
                        : const Color(0xFFE0E0E0),
                    fontSize: 11,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
