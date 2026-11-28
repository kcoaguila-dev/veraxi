import 'package:material_ui/material_ui.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'web_search_dialog.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/auto_compact.dart';
import 'package:veraxi_app/features/chat/view_models/token_usage.dart';
import 'package:veraxi_app/features/chat/views/widgets/deep_cost_preflight.dart';
import 'package:veraxi_app/features/chat/views/widgets/integration_chips_bar.dart';
import 'package:veraxi_app/features/chat/views/widgets/sandbox_toggle.dart';
import 'package:veraxi_app/features/chat/views/widgets/token_usage_ring.dart';

class ChatInput extends StatefulWidget {
  final bool isLoading;
  final String? projectName;
  final Function(String, {List<PlatformFile>? attachments}) onSend;
  final String? errorText;
  final VoidCallback? onDismissError;

  /// Currently selected chat model, used only for the Deep-mode
  /// pre-flight cost estimate shown while High-Accuracy is on.
  final String? model;

  /// Aggregated token usage for the current conversation. When null
  /// (no response has reported usage yet) the context ring is hidden.
  final TokenUsageSummary? usageSummary;

  /// Indicator form + change callback, forwarded to the ring and its
  /// breakdown sheet's style switcher.
  final TokenUsageIndicatorStyle? tokenUsageStyle;
  final ValueChanged<TokenUsageIndicatorStyle>? onTokenUsageStyleChanged;

  /// Auto-compact behaviour + change callback, forwarded to the
  /// breakdown sheet's auto-compact switcher.
  final AutoCompactMode? autoCompactMode;
  final ValueChanged<AutoCompactMode>? onAutoCompactModeChanged;

  /// Opens the manual-compaction flow from the breakdown sheet.
  final VoidCallback? onCompactPressed;

  /// Optional externally-owned text controller. The Code composer
  /// owns one so its `@`/`$`/`/` autocomplete overlay can observe
  /// and rewrite the draft; chat mode leaves this null and the
  /// input owns (and disposes) its controller as before.
  final TextEditingController? controller;

  /// Forwarded from the inner [TextField] on every edit.
  final ValueChanged<String>? onChanged;

  /// Overrides the default hint text when non-null.
  final String? hintText;

  /// Extra widget rendered in the bottom action row just after the
  /// attachment/tools buttons (used by Code composer for model,
  /// thinking level, and Plan|Act controls).
  final Widget? leadingFooterSlot;

  /// Extra widget rendered in the bottom action row just before the
  /// token-usage ring (the Code composer's `N sources` pill).
  final Widget? trailingSlot;

  /// When true, omits the outer rounded card decoration so a parent
  /// unified composer card can own the outer container and borders.
  final bool embedded;

  /// Whether to show the `Tools` (`Icons.tune`) menu next to `+`.
  /// Code mode disables this since context/tools live in `+` and the top bar.
  final bool showToolsMenu;

  /// Called when the user taps the Stop button while [isLoading] is true.
  final VoidCallback? onStop;

  const ChatInput({
    super.key,
    required this.isLoading,
    this.projectName,
    required this.onSend,
    this.onStop,
    this.errorText,
    this.onDismissError,
    this.model,
    this.usageSummary,
    this.tokenUsageStyle,
    this.onTokenUsageStyleChanged,
    this.autoCompactMode,
    this.onAutoCompactModeChanged,
    this.onCompactPressed,
    this.controller,
    this.onChanged,
    this.hintText,
    this.leadingFooterSlot,
    this.trailingSlot,
    this.embedded = false,
    this.showToolsMenu = true,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();

  /// The controller the field actually edits: the externally-owned
  /// one when supplied (Code composer), otherwise the internal one.
  TextEditingController get _effectiveController =>
      widget.controller ?? _controller;
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
  final List<({String name, String content})> _pastedSnippets = [];

  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;
  String _lastRecognizedWords = '';
  String _textBeforeListen = '';
  bool _isExpanded = false;
  bool _showExpandIcon = false;

  bool get _shouldShowExpand {
    if (_isExpanded) return true;
    final text = _effectiveController.text;
    final newlineCount = text.split('\n').length;
    final approxWrappedLines = (text.length / 70).ceil();
    return newlineCount >= 3 || approxWrappedLines >= 3;
  }

  void _handleControllerChange() {
    final hasText = _effectiveController.text.trim().isNotEmpty;
    final shouldShowExpand = _shouldShowExpand;
    if (hasText != _hasText || shouldShowExpand != _showExpandIcon) {
      setState(() {
        _hasText = hasText;
        _showExpandIcon = shouldShowExpand;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadToolSettings();
    _effectiveController.addListener(_handleControllerChange);
    _initSpeech();
  }

  @override
  void didUpdateWidget(covariant ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _controller)
          .removeListener(_handleControllerChange);
      _effectiveController.addListener(_handleControllerChange);
      _handleControllerChange();
    }
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
      _textBeforeListen = _effectiveController.text;
      if (_textBeforeListen.isNotEmpty && !_textBeforeListen.endsWith(' ')) {
        _textBeforeListen += ' ';
      }
      _lastRecognizedWords = '';
      await _speechToText.listen(
        onResult: (result) {
          setState(() {
            _lastRecognizedWords = result.recognizedWords;
            _effectiveController.text =
                _textBeforeListen + _lastRecognizedWords;
            _effectiveController.selection = TextSelection.fromPosition(
                TextPosition(offset: _effectiveController.text.length));
          });
        },
      );
      setState(() {
        _isListening = true;
      });
    }
  }

  static const String _transientToolOverridesKey = 'transient_tool_overrides';

  Future<Map<String, dynamic>> _readSettingsMap(SharedPreferences prefs) async {
    final raw = prefs.getString('tool_settings');
    if ((raw ?? '').isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw!) as Map);
    } catch (e) {
      debugPrint('[ChatInput] Failed to decode tool_settings: $e');
      return {};
    }
  }

  Future<Map<String, bool>> _readTransientOverrides(
      SharedPreferences prefs) async {
    final raw = prefs.getString(_transientToolOverridesKey);
    if ((raw ?? '').isEmpty) return {};
    try {
      final decoded = jsonDecode(raw!) as Map;
      return {
        for (final entry in decoded.entries)
          if (entry.value is bool) entry.key.toString(): entry.value as bool,
      };
    } catch (_) {
      return {};
    }
  }

  static void _applyToolFlag(
      Map<String, dynamic> settings, String toolKey, bool enabled) {
    switch (toolKey) {
      case 'file_search':
        settings['file_search_enabled'] = enabled;
      case 'web_search':
        final web = settings['web_search'] is Map
            ? Map<String, dynamic>.from(settings['web_search'] as Map)
            : <String, dynamic>{};
        web['enabled'] = enabled;
        settings['web_search'] = web;
      case 'skills':
        settings['skills_enabled'] = enabled;
      case 'run_code':
        settings['run_code_enabled'] = enabled;
      case 'artifacts':
        settings['artifacts_enabled'] = enabled;
    }
  }

  bool _isToolPinned(String toolKey) {
    switch (toolKey) {
      case 'file_search':
        return _fileSearchPinned;
      case 'web_search':
        return _webSearchPinned;
      case 'skills':
        return _skillsPinned;
      case 'run_code':
        return _runCodePinned;
      case 'artifacts':
        return _artifactsPinned;
      default:
        return false;
    }
  }

  Future<void> _loadToolSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await _readSettingsMap(prefs);
    final overrides = await _readTransientOverrides(prefs);

    final fileStored = settings['file_search_enabled'] as bool? ?? false;
    final webMap = settings['web_search'];
    final webStored = webMap is Map && webMap['enabled'] is bool
        ? webMap['enabled'] as bool
        : false;
    final highAccuracyEnabled = webMap is Map && webMap['high_accuracy'] is bool
        ? webMap['high_accuracy'] as bool
        : false;
    final skillsStored = settings['skills_enabled'] as bool? ?? false;
    final runCodeStored = settings['run_code_enabled'] as bool? ?? false;
    final artifactsStored = settings['artifacts_enabled'] as bool? ?? false;

    final filePinned = overrides['file_search'] ?? fileStored;
    final webPinned = overrides['web_search'] ?? webStored;
    final skillsPinned = overrides['skills'] ?? skillsStored;
    final runCodePinned = overrides['run_code'] ?? runCodeStored;
    final artifactsPinned = overrides['artifacts'] ?? artifactsStored;

    if (mounted) {
      setState(() {
        _fileSearchPinned = filePinned;
        _fileSearchActive = filePinned;
        _webSearchPinned = webPinned;
        _webSearchActive = webPinned;
        _highAccuracyEnabled = highAccuracyEnabled;
        _skillsPinned = skillsPinned;
        _skillsActive = skillsPinned;
        _runCodePinned = runCodePinned;
        _runCodeActive = runCodePinned;
        _artifactsPinned = artifactsPinned;
        _artifactsActive = artifactsPinned;
      });
    }
  }

  void _toggleActive(String toolKey, bool currentActive) {
    final nextActive = !currentActive;
    setState(() {
      if (toolKey == 'file_search')
        _fileSearchActive = nextActive;
      else if (toolKey == 'web_search')
        _webSearchActive = nextActive;
      else if (toolKey == 'skills')
        _skillsActive = nextActive;
      else if (toolKey == 'run_code')
        _runCodeActive = nextActive;
      else if (toolKey == 'artifacts') _artifactsActive = nextActive;
    });
    _persistTransientToolToggle(toolKey, nextActive);
  }

  Future<void> _persistTransientToolToggle(
      String toolKey, bool nextActive) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await _readSettingsMap(prefs);
    final overrides = await _readTransientOverrides(prefs);
    final pinned = _isToolPinned(toolKey);
    if (nextActive != pinned) {
      overrides[toolKey] = pinned;
    } else {
      overrides.remove(toolKey);
    }
    _applyToolFlag(settings, toolKey, nextActive);
    await prefs.setString('tool_settings', jsonEncode(settings));
    if (overrides.isEmpty) {
      await prefs.remove(_transientToolOverridesKey);
    } else {
      await prefs.setString(_transientToolOverridesKey, jsonEncode(overrides));
    }
  }

  Future<void> _togglePin(String toolKey, bool currentPinned) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await _readSettingsMap(prefs);
    final overrides = await _readTransientOverrides(prefs);
    final newPinned = !currentPinned;

    overrides.remove(toolKey);
    _applyToolFlag(settings, toolKey, newPinned);

    if (toolKey == 'file_search') {
      setState(() {
        _fileSearchPinned = newPinned;
        _fileSearchActive = newPinned;
      });
    } else if (toolKey == 'web_search') {
      setState(() {
        _webSearchPinned = newPinned;
        _webSearchActive = newPinned;
      });
    } else if (toolKey == 'skills') {
      setState(() {
        _skillsPinned = newPinned;
        _skillsActive = newPinned;
      });
    } else if (toolKey == 'run_code') {
      setState(() {
        _runCodePinned = newPinned;
        _runCodeActive = newPinned;
      });
    } else if (toolKey == 'artifacts') {
      setState(() {
        _artifactsPinned = newPinned;
        _artifactsActive = newPinned;
      });
    }

    await prefs.setString('tool_settings', jsonEncode(settings));
    if (overrides.isEmpty) {
      await prefs.remove(_transientToolOverridesKey);
    } else {
      await prefs.setString(_transientToolOverridesKey, jsonEncode(overrides));
    }
  }

  Future<void> _toggleHighAccuracy(bool currentValue) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = await _readSettingsMap(prefs);
    final web = settings['web_search'] is Map
        ? Map<String, dynamic>.from(settings['web_search'] as Map)
        : <String, dynamic>{};
    web['high_accuracy'] = !currentValue;
    settings['web_search'] = web;
    setState(() => _highAccuracyEnabled = !currentValue);
    await prefs.setString('tool_settings', jsonEncode(settings));
  }

  Future<void> _restorePinnedToolSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final overrides = await _readTransientOverrides(prefs);
    if (overrides.isEmpty) return;
    final settings = await _readSettingsMap(prefs);
    for (final entry in overrides.entries) {
      _applyToolFlag(settings, entry.key, entry.value);
    }
    await prefs.setString('tool_settings', jsonEncode(settings));
    await prefs.remove(_transientToolOverridesKey);
  }

  void _handleSend() {
    final rawText = _effectiveController.text;
    final hasSnippets = _pastedSnippets.isNotEmpty;
    if ((rawText.trim().isNotEmpty || hasSnippets) && !widget.isLoading) {
      final text = hasSnippets
          ? '${_pastedSnippets.map((s) => '```text\n// ${s.name}\n${s.content}\n```').join('\n\n')}${rawText.trim().isNotEmpty ? '\n\n$rawText' : ''}'
          : rawText;
      final attachments = _attachedFiles.isNotEmpty
          ? List<PlatformFile>.from(_attachedFiles)
          : null;
      final sendFuture = Future<void>.sync(
        () => widget.onSend(text, attachments: attachments),
      );
      sendFuture.whenComplete(_restorePinnedToolSettings);
      _effectiveController.clear();
      setState(() {
        _attachedFiles.clear();
        _pastedSnippets.clear();
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
      final result = await FilePicker.pickFiles(
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
      );

      if (result.isNotEmpty) {
        setState(() {
          _attachedFiles.addAll(result);
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

  /// Inserts an inline trigger sigil (`@`, `$`, `/`) at the end of the
  /// draft and notifies listeners so autocomplete overlays open immediately.
  void _insertTriggerSigil(String sigil) {
    final current = _effectiveController.text;
    final needsSpace = current.isNotEmpty && !current.endsWith(' ');
    final nextText = '$current${needsSpace ? ' ' : ''}$sigil';
    _effectiveController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    widget.onChanged?.call(nextText);
  }

  /// Opens a modal dialog for pasting raw text or logs as an attached
  /// `.txt` snippet without bloating the prompt text field.
  Future<void> _showPasteTextDialog() async {
    final pasted = await showDialog<String>(
      context: context,
      builder: (_) => const _PasteTextDialog(),
    );
    if (pasted == null || pasted.trim().isEmpty || !mounted) return;
    final idx = _pastedSnippets.length + 1;
    setState(() {
      _pastedSnippets.add((name: 'pasted-snippet-$idx.txt', content: pasted));
    });
  }

  void _expandSnippet(int index) {
    final snippet = _pastedSnippets[index];
    final current = _effectiveController.text;
    final nextText =
        current.isEmpty ? snippet.content : '$current\n${snippet.content}';
    _effectiveController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    widget.onChanged?.call(nextText);
    setState(() {
      _pastedSnippets.removeAt(index);
    });
  }

  void _removeSnippet(int index) {
    setState(() {
      _pastedSnippets.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Deep (High-Accuracy / agentic debate) pre-flight estimate:
        // renders only while High-Accuracy is on and an estimate has
        // loaded; see docs/design/deep_cost_preflight.svg.
        if (_highAccuracyEnabled) DeepCostPreflight(model: widget.model),
        if (widget.errorText != null)
          Container(
            margin: EdgeInsets.only(bottom: 8.0, left: 16.0, right: 16.0),
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
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
          decoration: widget.embedded
              ? null
              : BoxDecoration(
                  color: Theme.of(context)
                      .extension<AppThemeExtension>()!
                      .surfaceHighlight,
                  borderRadius: BorderRadius.circular(24),
                ),
          padding: EdgeInsets.symmetric(
            horizontal: widget.embedded ? 14.0 : 12.0,
            vertical: widget.embedded ? 6.0 : 4.0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_attachedFiles.isNotEmpty || _pastedSnippets.isNotEmpty)
                Padding(
                  padding:
                      EdgeInsets.only(bottom: 8.0, left: 12.0, right: 12.0),
                  child: Wrap(
                    spacing: 8.0,
                    runSpacing: 4.0,
                    children: [
                      ..._attachedFiles.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final file = entry.value;
                        return Chip(
                          label: Text(
                            file.name,
                            style: TextStyle(color: Colors.white, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          backgroundColor: Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .borderColorStrong,
                          deleteIconColor: Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .iconColor,
                          onDeleted: () => _removeAttachment(idx),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide.none,
                          ),
                        );
                      }),
                      ..._pastedSnippets.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final snippet = entry.value;
                        final ext =
                            Theme.of(context).extension<AppThemeExtension>()!;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: ext.borderColorStrong,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                snippet.name,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => _expandSnippet(idx),
                                child: const Text(
                                  'Expand',
                                  style: TextStyle(
                                    color: Color(0xFF60A5FA),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: () => _removeSnippet(idx),
                                child: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: ext.iconColor,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              Stack(
                children: [
                  TextField(
                    controller: _effectiveController,
                    minLines: 1,
                    maxLines: _isExpanded ? 20 : 1,
                    style: TextStyle(color: Colors.white, fontSize: 16),
                    cursorColor: Colors.white,
                    decoration: InputDecoration(
                      hintText: widget.hintText ??
                          (widget.projectName != null
                              ? 'New chat in ${widget.projectName}'
                              : 'Message Veraxi...'),
                      hintStyle: TextStyle(
                          color: Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .textTertiary,
                          fontSize: 16),
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.only(
                          left: 4, right: 32, top: 8, bottom: 8),
                    ),
                    onSubmitted: (_) => _handleSend(),
                    onChanged: widget.onChanged,
                    enabled: !widget.isLoading,
                    textInputAction: _isExpanded
                        ? TextInputAction.newline
                        : TextInputAction.send,
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
                            color: Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .textTertiary),
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
                  _buildAddContextMenu(),
                  if (widget.showToolsMenu)
                    MenuAnchor(
                      style: MenuStyle(
                        backgroundColor: WidgetStatePropertyAll(
                            Theme.of(context)
                                .extension<AppThemeExtension>()!
                                .sidebarBackground),
                        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                              color: Theme.of(context)
                                  .extension<AppThemeExtension>()!
                                  .borderColor),
                        )),
                        padding: const WidgetStatePropertyAll(
                            EdgeInsets.symmetric(vertical: 8)),
                      ),
                      builder: (context, controller, child) {
                        return IconButton(
                          icon: Icon(Icons.tune,
                              color: Theme.of(context)
                                  .extension<AppThemeExtension>()!
                                  .iconColor,
                              size: 20),
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
                            subtitle: 'Vector + Graph',
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
                        const ToolsMenuSandbox(),
                        const ToolsMenuIntegrations(),
                      ],
                    ),
                  SizedBox(width: 4),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (widget.leadingFooterSlot != null) ...[
                            widget.leadingFooterSlot!,
                            const SizedBox(width: 8),
                          ],
                          if (_fileSearchActive)
                            _buildActiveToolChip(
                                'File Search',
                                Icons.grid_view_outlined,
                                () => _toggleActive('file_search', true),
                                badge: 'Vector + Graph'),
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
                          const SandboxActiveChip(),
                        ],
                      ),
                    ),
                  ),
                  if (widget.trailingSlot != null) ...[
                    widget.trailingSlot!,
                    SizedBox(width: 4),
                  ],
                  if (widget.usageSummary != null) ...[
                    TokenUsageRing(
                      usage: widget.usageSummary!,
                      indicatorStyle: widget.tokenUsageStyle,
                      onIndicatorStyleChanged: widget.onTokenUsageStyleChanged,
                      autoCompactMode: widget.autoCompactMode,
                      onAutoCompactModeChanged: widget.onAutoCompactModeChanged,
                      onCompactPressed: widget.onCompactPressed,
                    ),
                    SizedBox(width: 4),
                  ],
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    icon: Icon(
                      _isListening ? Icons.mic : Icons.mic_none_outlined,
                      color: _isListening
                          ? const Color(0xFFE53935)
                          : Theme.of(context)
                              .extension<AppThemeExtension>()!
                              .iconColor,
                      size: 20,
                    ),
                    onPressed: widget.isLoading ? null : _toggleListening,
                    tooltip: 'Voice input',
                  ),
                  SizedBox(width: 8),
                  GestureDetector(
                    key: widget.isLoading
                        ? const Key('chat-input-stop-button')
                        : null,
                    onTap: widget.isLoading
                        ? widget.onStop
                        : (_hasText ? _handleSend : null),
                    child: Tooltip(
                      message:
                          widget.isLoading ? 'Stop generating' : 'Send message',
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
                                      : Theme.of(context)
                                          .extension<AppThemeExtension>()!
                                          .iconColor,
                                  size: 20,
                                ),
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

  Widget _buildAddContextMenu() {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return Theme(
      data: Theme.of(context).copyWith(
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: PopupMenuButton<String>(
        tooltip: 'Add context',
        enabled: !widget.isLoading,
        color: ext.sidebarBackground,
        elevation: 10,
        position: PopupMenuPosition.over,
        offset: const Offset(0, -10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: ext.borderColorStrong),
        ),
        icon: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: ext.borderColor.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ext.borderColorStrong),
          ),
          child: Icon(Icons.add, color: ext.iconColor, size: 18),
        ),
        onSelected: _handleAddContextSelection,
        itemBuilder: (context) => <PopupMenuEntry<String>>[
          _buildAddContextHeader('ADD CONTEXT'),
          _buildAddContextItem(
            value: 'files',
            icon: Icons.attach_file,
            label: 'Files',
            trailingHint: 'Auto',
          ),
          _buildAddContextItem(
            value: 'mentions',
            icon: Icons.alternate_email,
            label: 'Mentions',
            keycap: '@',
          ),
          const PopupMenuDivider(height: 8),
          _buildAddContextItem(
            value: 'skills',
            icon: Icons.bolt_outlined,
            label: 'Skills',
            keycap: r'$',
          ),
          _buildAddContextItem(
            value: 'commands',
            icon: Icons.terminal,
            label: 'Commands',
            keycap: '/',
          ),
          _buildAddContextItem(
            value: 'web',
            icon: Icons.language,
            label: 'Web & Browser',
            trailingHint: _webSearchActive ? 'On' : null,
            trailingAccent: _webSearchActive,
          ),
          _buildAddContextItem(
            value: 'paste_text',
            icon: Icons.description_outlined,
            label: 'Paste Text',
            trailingHint: 'Snippet',
          ),
          const PopupMenuDivider(height: 8),
          _buildAddContextItem(
            value: 'connectors',
            icon: Icons.extension_outlined,
            label: 'Connectors',
            trailingHint: 'Set up',
            trailingAccent: true,
          ),
        ],
      ),
    );
  }

  void _handleAddContextSelection(String value) {
    switch (value) {
      case 'files':
        _pickFiles();
      case 'mentions':
        _insertTriggerSigil('@');
      case 'skills':
        _insertTriggerSigil(r'$');
      case 'commands':
        _insertTriggerSigil('/');
      case 'web':
        _toggleActive('web_search', _webSearchActive);
      case 'paste_text':
        _showPasteTextDialog();
      case 'connectors':
        context.go('/admin');
    }
  }

  PopupMenuEntry<String> _buildAddContextHeader(String title) {
    return PopupMenuItem<String>(
      enabled: false,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).extension<AppThemeExtension>()!.textTertiary,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.7,
        ),
      ),
    );
  }

  PopupMenuItem<String> _buildAddContextItem({
    required String value,
    required IconData icon,
    required String label,
    String? keycap,
    String? trailingHint,
    bool trailingAccent = false,
  }) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SizedBox(
        width: 210,
        child: Row(
          children: [
            Icon(icon, color: ext.iconColor, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (keycap != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: ext.cardBackground,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: ext.borderColorStrong),
                ),
                child: Text(
                  keycap,
                  style: TextStyle(
                    color: ext.textTertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else if (trailingHint != null)
              Text(
                trailingHint,
                style: TextStyle(
                  color: trailingAccent
                      ? const Color(0xFF60A5FA)
                      : ext.textTertiary,
                  fontSize: 11.5,
                  fontWeight:
                      trailingAccent ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolItem(String value, String text, IconData icon,
      {bool isActive = false, bool isPinned = false, String? subtitle}) {
    return MenuItemButton(
      style: const ButtonStyle(
          padding:
              WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10))),
      onPressed: () => _toggleActive(value, isActive),
      child: Container(
        width: 185,
        height: subtitle != null ? 44 : 38,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Icon(icon,
                color: isActive
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .iconColor,
                size: 14),
            SizedBox(width: 8),
            Expanded(
              child: subtitle == null
                  ? Text(text,
                      style: TextStyle(
                          color: Color(0xFFE0E0E0),
                          fontSize: 13,
                          fontWeight: FontWeight.w400),
                      overflow: TextOverflow.ellipsis)
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(text,
                            style: TextStyle(
                                color: Color(0xFFE0E0E0),
                                fontSize: 13,
                                fontWeight: FontWeight.w400),
                            overflow: TextOverflow.ellipsis),
                        Text(subtitle,
                            style: const TextStyle(
                                color: Color(0xFF8C8C8C),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w400),
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
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
        backgroundColor: WidgetStatePropertyAll(Theme.of(context)
            .extension<AppThemeExtension>()!
            .sidebarBackground),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
              color: Theme.of(context)
                  .extension<AppThemeExtension>()!
                  .borderColor),
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
            padding: EdgeInsets.only(left: 14, right: 10, top: 4, bottom: 4),
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
                    activeTrackColor: Theme.of(context)
                        .colorScheme
                        .secondary
                        .withValues(alpha: 0.3),
                    inactiveThumbColor: Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .iconColor,
                    inactiveTrackColor: Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .borderColor,
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
                    : Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .iconColor,
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
                    : Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .iconColor,
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
      {bool isActive = true, bool isToggle = false, String? badge}) {
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
                  ? Theme.of(context)
                      .colorScheme
                      .secondary
                      .withValues(alpha: 0.3)
                  : const Color(0xFF3A3A3A)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: (isToggle && isActive)
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context)
                        .extension<AppThemeExtension>()!
                        .iconColor,
                size: 12),
            SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: (isToggle && isActive)
                        ? Theme.of(context).colorScheme.secondary
                        : const Color(0xFFE0E0E0),
                    fontSize: 11,
                    fontWeight: FontWeight.w500)),
            if (badge != null) ...[
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF2B2B2F),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    color: Color(0xFFA1A1AA),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    // The effective controller may be externally owned (Code
    // composer): detach from it, but only dispose our own.
    _effectiveController.removeListener(_handleControllerChange);
    _controller.dispose();
    super.dispose();
  }
}

class _PasteTextDialog extends StatefulWidget {
  const _PasteTextDialog();

  @override
  State<_PasteTextDialog> createState() => _PasteTextDialogState();
}

class _PasteTextDialogState extends State<_PasteTextDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<AppThemeExtension>()!;
    return AlertDialog(
      backgroundColor: ext.cardBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: ext.borderColorStrong),
      ),
      title: const Text(
        'Paste Text Snippet',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _controller,
          autofocus: true,
          minLines: 6,
          maxLines: 14,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Paste logs, code, or raw text here…',
            hintStyle: TextStyle(color: ext.textTertiary, fontSize: 13),
            filled: true,
            fillColor: ext.sidebarBackground,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: ext.borderColor),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Attach Snippet'),
        ),
      ],
    );
  }
}
