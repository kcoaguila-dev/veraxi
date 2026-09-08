import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'web_search_dialog.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/theme_extension.dart';


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
  bool _fileSearchPinned = false;
  bool _fileSearchActive = false;
  bool _webSearchPinned = false;
  bool _webSearchActive = false;
  bool _highAccuracyEnabled = false; // High-accuracy is a global toggle
  bool _skillsPinned = false;
  bool _skillsActive = false;
  bool _runCodePinned = false;
  bool _runCodeActive = false;
  bool _artifactsPinned = false;
  bool _artifactsActive = false;
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
            highAccuracyEnabled =
                settings['web_search']['high_accuracy'] as bool;
          }
        }

        bool skillsEnabled = settings['skills_enabled'] as bool? ?? false;
        bool runCodeEnabled = settings['run_code_enabled'] as bool? ?? false;
        bool artifactsEnabled = settings['artifacts_enabled'] as bool? ?? false;

        if (mounted) {
          setState(() {
            _fileSearchPinned = fileEnabled;
            _fileSearchActive = fileEnabled;
            _webSearchPinned = webEnabled;
            _webSearchActive = webEnabled;
            _highAccuracyEnabled = highAccuracyEnabled;
            _skillsPinned = skillsEnabled;
            _skillsActive = skillsEnabled;
            _runCodePinned = runCodeEnabled;
            _runCodeActive = runCodeEnabled;
            _artifactsPinned = artifactsEnabled;
            _artifactsActive = artifactsEnabled;
          });
        }
      } catch (e) {
        debugPrint('[ChatInput] Failed to decode tool_settings: $e');
      }
    }
  }

  void _toggleActive(String toolKey, bool currentActive) {
    setState(() {
      if (toolKey == 'file_search')
        _fileSearchActive = !currentActive;
      else if (toolKey == 'web_search')
        _webSearchActive = !currentActive;
      else if (toolKey == 'skills')
        _skillsActive = !currentActive;
      else if (toolKey == 'run_code')
        _runCodeActive = !currentActive;
      else if (toolKey == 'artifacts') _artifactsActive = !currentActive;
    });
  }

  Future<void> _togglePin(String toolKey, bool currentPinned) async {
    final prefs = await SharedPreferences.getInstance();
    final currentSettingsJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if (currentSettingsJson != null) {
      try {
        settings = jsonDecode(currentSettingsJson) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('[ChatInput] Failed to decode tool_settings: $e');
      }
    }

    bool newPinned = !currentPinned;

    if (toolKey == 'file_search') {
      settings['file_search_enabled'] = newPinned;
      setState(() {
        _fileSearchPinned = newPinned;
        _fileSearchActive = newPinned;
      });
    } else if (toolKey == 'web_search') {
      settings['web_search'] = settings['web_search'] ?? {};
      settings['web_search']['enabled'] = newPinned;
      setState(() {
        _webSearchPinned = newPinned;
        _webSearchActive = newPinned;
      });
    } else if (toolKey == 'skills') {
      settings['skills_enabled'] = newPinned;
      setState(() {
        _skillsPinned = newPinned;
        _skillsActive = newPinned;
      });
    } else if (toolKey == 'run_code') {
      settings['run_code_enabled'] = newPinned;
      setState(() {
        _runCodePinned = newPinned;
        _runCodeActive = newPinned;
      });
    } else if (toolKey == 'artifacts') {
      settings['artifacts_enabled'] = newPinned;
      setState(() {
        _artifactsPinned = newPinned;
        _artifactsActive = newPinned;
      });
    }

    await prefs.setString('tool_settings', jsonEncode(settings));
  }

  Future<void> _toggleHighAccuracy(bool currentValue) async {
    final prefs = await SharedPreferences.getInstance();
    final currentSettingsJson = prefs.getString('tool_settings');
    Map<String, dynamic> settings = {};
    if (currentSettingsJson != null) {
      try {
        settings = jsonDecode(currentSettingsJson) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('[ChatInput] Failed to decode tool_settings: $e');
      }
    }
    settings['web_search'] = settings['web_search'] ?? {};
    settings['web_search']['high_accuracy'] = !currentValue;
    setState(() => _highAccuracyEnabled = !currentValue);
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
        if (!_fileSearchPinned) _fileSearchActive = false;
        if (!_webSearchPinned) _webSearchActive = false;
        if (!_skillsPinned) _skillsActive = false;
        if (!_runCodePinned) _runCodeActive = false;
        if (!_artifactsPinned) _artifactsActive = false;
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
            margin: EdgeInsets.only(bottom: 8.0, left: 16.0, right: 16.0),
            padding:
                EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.errorText!,
                    style: TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
                if (widget.onDismissError != null)
                  IconButton(
                    icon: Icon(Icons.close, color: Colors.red, size: 20),
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
            color: Theme.of(context).extension<AppThemeExtension>()!.surfaceHighlight,
            borderRadius: BorderRadius.circular(24),
          ),
          padding: EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_attachedFiles.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(
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
                          style: TextStyle(
                              color: Colors.white, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        backgroundColor: Theme.of(context).extension<AppThemeExtension>()!.borderColorStrong,
                        deleteIconColor: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
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
                    style: TextStyle(color: Colors.white, fontSize: 16),
                    cursorColor: Colors.white,
                    decoration: InputDecoration(
                      hintText: widget.projectName != null
                          ? 'New chat in ${widget.projectName}'
                          : 'Message Veraxi...',
                      hintStyle: TextStyle(
                          color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary, fontSize: 16),
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
                            color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary),
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
                      icon: Icon(Icons.attach_file,
                          color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, size: 20),
                      tooltip: 'Attach file',
                      color: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      position: PopupMenuPosition.over,
                      enabled: !widget.isLoading,
                      onSelected: (value) {
                        _pickFiles();
                      },
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'provider',
                          height: 40,
                          child: Row(
                            children: [
                              Icon(Icons.upload_file,
                                  color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, size: 16),
                              SizedBox(width: 8),
                              Text('Upload to Provider',
                                  style: TextStyle(
                                      color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 13)),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'text',
                          height: 40,
                          child: Row(
                            children: [
                              Icon(Icons.text_snippet,
                                  color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, size: 16),
                              SizedBox(width: 8),
                              Text('Upload as Text',
                                  style: TextStyle(
                                      color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  MenuAnchor(
                    style: MenuStyle(
                      backgroundColor:
                          WidgetStatePropertyAll(Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground),
                      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
                      )),
                      padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(vertical: 8)),
                    ),
                    builder: (context, controller, child) {
                      return IconButton(
                        icon: Icon(Icons.tune,
                            color: Theme.of(context).extension<AppThemeExtension>()!.iconColor, size: 20),
                        tooltip: 'Tools',
                        onPressed: () {
                          if (controller.isOpen) {
                            controller.close();
                          } else {
                            controller.open();
                          }
                        },
                      );
                    },
                    menuChildren: [
                      _buildToolItem('file_search', 'File Search',
                          Icons.grid_view_outlined,
                          isActive: _fileSearchActive,
                          isPinned: _fileSearchPinned),
                      _buildWebSearchItem(
                          isActive: _webSearchActive,
                          isPinned: _webSearchPinned),
                      _buildSkillsItem(
                          isActive: _skillsActive, isPinned: _skillsPinned),
                      _buildToolItem('run_code', 'Run Code', Icons.terminal,
                          isActive: _runCodeActive, isPinned: _runCodePinned),
                      _buildToolItem(
                          'artifacts', 'Artifacts >', Icons.auto_awesome,
                          isActive: _artifactsActive,
                          isPinned: _artifactsPinned),
                    ],
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (_fileSearchActive)
                            _buildActiveToolChip(
                                'File Search',
                                Icons.grid_view_outlined,
                                () => _toggleActive('file_search', true)),
                          if (_webSearchActive)
                            _buildActiveToolChip('Web Search', Icons.language,
                                () => _toggleActive('web_search', true)),
                          if (_skillsActive)
                            _buildActiveToolChip(
                                'Skills',
                                Icons.extension_outlined,
                                () => _toggleActive('skills', true)),
                          if (_runCodeActive)
                            _buildActiveToolChip('Run Code', Icons.terminal,
                                () => _toggleActive('run_code', true)),
                          if (_artifactsActive)
                            _buildActiveToolChip(
                                'Artifacts',
                                Icons.auto_awesome,
                                () => _toggleActive('artifacts', true)),
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
                          : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                      size: 20,
                    ),
                    onPressed: widget.isLoading ? null : _toggleListening,
                    tooltip: 'Voice input',
                  ),
                  SizedBox(width: 8),
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
                            ? Icon(
                                Icons.stop_rounded,
                                color: Colors.black,
                                size: 16,
                              )
                            : Icon(
                                Icons.arrow_upward,
                                color: _hasText
                                    ? Colors.black
                                    : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                                size: 20,
                              ),
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildToolItem(String value, String text, IconData icon,
      {bool isActive = false, bool isPinned = false}) {
    return MenuItemButton(
      style: const ButtonStyle(
          padding:
              WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10))),
      onPressed: () => _toggleActive(value, isActive),
      child: Container(
        width: 155,
        height: 38,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(icon,
                color: isActive
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 14),
            SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            GestureDetector(
              onTap: () => _togglePin(value, isPinned),
              child: Padding(
                padding: EdgeInsets.all(4.0),
                child: Icon(isPinned ? LucideIcons.pinOff : LucideIcons.pin,
                    color: isPinned
                        ? Theme.of(context).colorScheme.secondary
                        : const Color(0xFF6E6E6E),
                    size: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebSearchItem({bool isActive = false, bool isPinned = false}) {
    return SubmenuButton(
      style: const ButtonStyle(
          padding:
              WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10))),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Theme.of(context).extension<AppThemeExtension>()!.sidebarBackground),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Theme.of(context).extension<AppThemeExtension>()!.borderColor),
        )),
      ),
      menuChildren: [
        MenuItemButton(
          style: const ButtonStyle(
              padding: WidgetStatePropertyAll(EdgeInsets.zero)),
          onPressed: () {
            _toggleHighAccuracy(_highAccuracyEnabled);
          },
          child: Container(
            width: 165,
            padding:
                EdgeInsets.only(left: 14, right: 10, top: 4, bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('High-Accuracy',
                    style: TextStyle(
                        color: Color(0xFFE0E0E0),
                        fontSize: 13,
                        fontWeight: FontWeight.w400)),
                Transform.scale(
                  scale: 0.6,
                  child: Switch(
                    value: _highAccuracyEnabled,
                    activeThumbColor: Theme.of(context).colorScheme.secondary,
                    activeTrackColor:
                        Theme.of(context).colorScheme.secondary.withValues(alpha: 0.3),
                    inactiveThumbColor: Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                    inactiveTrackColor: Theme.of(context).extension<AppThemeExtension>()!.borderColor,
                    onChanged: (val) {
                      _toggleHighAccuracy(!val);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      child: Container(
        width: 155,
        height: 38,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(Icons.language,
                color: isActive
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 14),
            SizedBox(width: 8),
            const Expanded(
              child: Text('Web Search',
                  style: TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            GestureDetector(
              onTap: () async {
                Navigator.of(context).popUntil((route) => route.isFirst);
                await showDialog(
                  context: context,
                  builder: (context) => const WebSearchDialog(),
                );
                _loadToolSettings();
              },
              child: Padding(
                padding: EdgeInsets.all(4.0),
                child: Icon(Icons.settings_outlined,
                    color: Color(0xFF6E6E6E), size: 14),
              ),
            ),
            SizedBox(width: 4),
            GestureDetector(
              onTap: () => _togglePin('web_search', isPinned),
              child: Padding(
                padding: EdgeInsets.all(4.0),
                child: Icon(isPinned ? LucideIcons.pinOff : LucideIcons.pin,
                    color: isPinned
                        ? Theme.of(context).colorScheme.secondary
                        : const Color(0xFF6E6E6E),
                    size: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkillsItem({bool isActive = false, bool isPinned = false}) {
    return MenuItemButton(
      style: const ButtonStyle(
          padding:
              WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10))),
      onPressed: () => _toggleActive('skills', isActive),
      child: Container(
        width: 155,
        height: 38,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(Icons.extension_outlined,
                color: isActive
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 14),
            SizedBox(width: 8),
            const Expanded(
              child: Text('Skills',
                  style: TextStyle(
                      color: Color(0xFFE0E0E0),
                      fontSize: 13,
                      fontWeight: FontWeight.w400),
                  overflow: TextOverflow.ellipsis),
            ),
            GestureDetector(
              onTap: () {
                Navigator.of(context).popUntil((route) => route.isFirst);
                context.go('/admin');
              },
              child: Padding(
                padding: EdgeInsets.all(4.0),
                child: Icon(Icons.settings_outlined,
                    color: Color(0xFF6E6E6E), size: 14),
              ),
            ),
            SizedBox(width: 4),
            GestureDetector(
              onTap: () => _togglePin('skills', isPinned),
              child: Padding(
                padding: EdgeInsets.all(4.0),
                child: Icon(isPinned ? LucideIcons.pinOff : LucideIcons.pin,
                    color: isPinned
                        ? Theme.of(context).colorScheme.secondary
                        : const Color(0xFF6E6E6E),
                    size: 14),
              ),
            ),
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
        margin: EdgeInsets.only(right: 8),
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: (isToggle && isActive)
              ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1)
              : Theme.of(context).extension<AppThemeExtension>()!.borderColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: (isToggle && isActive)
                  ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.3)
                  : const Color(0xFF3A3A3A)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: (isToggle && isActive)
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).extension<AppThemeExtension>()!.iconColor,
                size: 12),
            SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: (isToggle && isActive)
                        ? Theme.of(context).colorScheme.secondary
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
