import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:re_editor/re_editor.dart';
import 'package:veraxi_app/core/theme_extension.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_line_diff.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_quick_actions.dart';
import 'package:veraxi_app/features/chat/view_models/code_artifact_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_incoming_provider.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_runtime_storage_provider.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_publish_provider.dart';
import 'package:veraxi_app/features/chat/view_models/artifact_work_provider.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_download.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_editor_theme.dart';
import 'package:veraxi_app/features/chat/views/widgets/artifact_sandbox.dart';

/// Right-side panel that shows a [CodeArtifact] when its card is tapped
/// in the chat — the split view in Claude's UI.
///
/// Desktop: rendered as a fixed-width column beside the chat.
/// Mobile: the caller renders it as a full-screen overlay instead; this
/// widget simply fills whatever space it is given.
///
/// Like Claude's artifact pane, renderable artifacts (HTML, React, SVG,
/// Mermaid, Markdown) open on a live **Preview** with a **Code** toggle;
/// plain code opens on the highlighted listing. The header also carries
/// a Copy action, a Run action for the languages the existing client
/// sandbox actually executes (Python / JavaScript, code view only), a
/// Download action, a Share action (publishes a public link through
/// the backend), and a close button.
///
/// The code view is a workbench, not just a viewer (the Open Canvas
/// model): the code sits in a real editor (re_editor) whose text can be
/// selected in any mode and edited in Edit mode. Leaving Edit mode with
/// changes appends a **version** — versions are a plain list plus a
/// current index, navigable from the toolbar, with a line **Diff**
/// between the current version and the previous one. Run, Copy, and
/// the Preview always act on the current version. When a rewrite
/// quick action's reply arrives, it is offered as an incoming
/// version: the user can diff it against the current version and
/// accept it (it becomes a new version) or reject it. Versions,
/// the current version, and the published link persist locally
/// (see ArtifactWorkStore), so panel work survives closing the
/// panel, the way Claude keeps artifact versions with the
/// conversation.
class CodeArtifactPanel extends ConsumerStatefulWidget {
  /// The open artifact: tap-time snapshot plus the coordinates used
  /// to resolve its live content while the source message streams.
  final OpenCodeArtifact open;
  final VoidCallback onClose;

  /// Sends a quick-action prompt to the chat (wired by the chat
  /// screen to its sendMessage with the currently selected model).
  /// When null, the quick-action row is not shown — controls only
  /// appear when they can do something.
  final ValueChanged<String>? onQuickAction;

  const CodeArtifactPanel({
    super.key,
    required this.open,
    required this.onClose,
    this.onQuickAction,
  });

  @override
  ConsumerState<CodeArtifactPanel> createState() => _CodeArtifactPanelState();
}

class _CodeArtifactPanelState extends ConsumerState<CodeArtifactPanel> {
  bool _copied = false;
  bool _isRunning = false;
  SandboxResult? _sandboxResult;

  /// Renderable artifacts open on their live preview, like Claude;
  /// everything else has no preview state at all.
  late bool _showPreview = widget.open.artifact.isPreviewable;

  /// The artifact as last resolved live from chat state (identity
  /// fields — title, file name, language). Updated every build.
  late CodeArtifact _resolvedArtifact = widget.open.artifact;

  /// Version history for this panel session: the artifact's original
  /// code plus one entry per committed edit. [_versionIndex] is the
  /// version on screen.
  late final List<String> _versions = [widget.open.artifact.code];
  int _versionIndex = 0;
  bool _editing = false;
  bool _showDiff = false;

  /// A quick action's reply, offered as an incoming version the
  /// user can diff, accept (it becomes a new version), or reject.
  /// Null when no reply is waiting.
  CodeArtifact? _incomingArtifact;
  String? _incomingActionLabel;
  bool _showIncomingDiff = false;

  /// Diagnostics from a quick-action patch reply that did not apply
  /// cleanly, plus the action that produced it (for a full-rewrite
  /// retry). Null when there is no failed patch to report.
  String? _patchFailureNotice;
  ArtifactQuickAction? _failedPatchAction;

  /// Whether the persisted-work restore has finished. Saves are
  /// held until then, so a fresh panel can never overwrite stored
  /// work with its initial state before the restore lands.
  bool _workRestoreDone = false;

  /// Whether the storage-cap notice has been shown this session:
  /// the user is told once when a save drops their oldest saved
  /// work, not on every save after that.
  bool _capNoticeShown = false;

  /// The work-store key for this artifact, or null when it has no
  /// stable coordinates (its panel work then stays disposable).
  String? get _workKey => artifactWorkKey(
        threadId: widget.open.threadId,
        messageIndex: widget.open.messageIndex,
        artifactIndex: widget.open.artifactIndex,
      );

  late final CodeLineEditingController _editorController =
      CodeLineEditingController.fromText(widget.open.artifact.code);

  /// 1-based line range of the editor's current selection, or null
  /// when nothing (or only whitespace) is selected. Drives the
  /// toolbar's selection hint and scopes quick actions.
  int? _selectionStartLine;
  int? _selectionEndLine;

  @override
  void initState() {
    super.initState();
    _editorController.addListener(_syncSelection);
    if (_workKey == null) {
      _workRestoreDone = true;
    } else {
      _restoreWork();
    }
  }

  /// Loads this artifact's persisted panel work (versions, current
  /// version, published link) from the local work store, so work
  /// survives closing the panel. A single-version entry whose
  /// original no longer matches the opened artifact was a stream
  /// snapshot, not user work, and is left behind.
  Future<void> _restoreWork() async {
    final key = _workKey;
    if (key == null) {
      _workRestoreDone = true;
      return;
    }
    final saved = await ref.read(artifactWorkStoreProvider).load(key);
    _workRestoreDone = true;
    if (!mounted || saved == null || saved.versions.isEmpty) return;
    if (!saved.hasUserWork && saved.originalCode != widget.open.artifact.code) {
      return;
    }
    setState(() {
      _versions
        ..clear()
        ..addAll(saved.versions);
      _versionIndex = saved.versionIndex.clamp(0, _versions.length - 1);
      _showDiff = false;
    });
    _editorController.codeLines = CodeLines.fromText(_versions[_versionIndex]);
    final publishedId = saved.publishedId;
    final publishedUrl = saved.publishedUrl;
    if (publishedId != null && publishedUrl != null) {
      ref.read(artifactPublishProvider.notifier).restore(
            id: publishedId,
            url: publishedUrl,
            code: saved.publishedCode,
          );
    }
  }

  /// Persists the panel's current work (versions, current version,
  /// published link) to the local work store. When the store is at
  /// its cap and this save drops the oldest saved work, the user
  /// is told — once per session, in plain terms — instead of the
  /// work vanishing silently.
  void _saveWork() {
    final key = _workKey;
    if (key == null || !_workRestoreDone) return;
    final publish = ref.read(artifactPublishProvider);
    ref
        .read(artifactWorkStoreProvider)
        .save(
          key,
          ArtifactWorkState(
            versions: List.of(_versions),
            versionIndex: _versionIndex,
            originalCode: _versions.first,
            publishedId: publish.publishedId,
            publishedUrl: publish.publishedUrl,
            publishedCode: publish.publishedCode,
          ),
        )
        .then((evicted) {
      if (evicted == 0 || !mounted || _capNoticeShown) return;
      _capNoticeShown = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Saved artifact work is full '
            '(${ArtifactWorkStore.maxEntries} artifacts) — the oldest '
            'saved work was removed to make room.',
          ),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 6),
        ),
      );
    });
  }

  @override
  void dispose() {
    _editorController.removeListener(_syncSelection);
    _editorController.dispose();
    super.dispose();
  }

  void _syncSelection() {
    final selection = _editorController.selection;
    final hasSelection = _editorController.selectedText.trim().isNotEmpty;
    final start = hasSelection
        ? (selection.baseIndex < selection.extentIndex
                ? selection.baseIndex
                : selection.extentIndex) +
            1
        : null;
    final end = hasSelection
        ? (selection.baseIndex < selection.extentIndex
                ? selection.extentIndex
                : selection.baseIndex) +
            1
        : null;
    if (start != _selectionStartLine || end != _selectionEndLine) {
      setState(() {
        _selectionStartLine = start;
        _selectionEndLine = end;
      });
    }
  }

  /// Builds the action's prompt from the current version (and the
  /// editor selection, when there is one) and hands it to the chat.
  /// Rewrite actions also register as pending, so their reply can
  /// be offered back here as an incoming version.
  void _runQuickAction(ArtifactQuickAction action, {bool? preferPatch}) {
    final handler = widget.onQuickAction;
    if (handler == null) return;
    final selected = _editorController.selectedText;
    final hasSelection = selected.trim().isNotEmpty;
    if (action.producesRewrite && widget.open.messageIndex != null) {
      ref.read(pendingQuickActionProvider.notifier).state =
          PendingQuickAction(open: widget.open, action: action);
    }
    handler(action.buildPrompt(
      artifact: _currentArtifact,
      currentCode: _currentCode,
      selectedText: hasSelection ? selected : null,
      selectionStartLine: hasSelection ? _selectionStartLine : null,
      selectionEndLine: hasSelection ? _selectionEndLine : null,
      preferPatch: preferPatch,
    ));
  }

  /// Retries the failed patch's quick action as a full rewrite.
  void _retryPatchAsFullRewrite() {
    final action = _failedPatchAction;
    if (action == null) return;
    setState(() {
      _patchFailureNotice = null;
      _failedPatchAction = null;
    });
    _runQuickAction(action, preferPatch: false);
  }

  /// The code every action acts on: the editor's live text while
  /// editing, the current version otherwise.
  String get _currentCode =>
      _editing ? _editorController.text : _versions[_versionIndex];

  /// The artifact as currently versioned — same identity, current code.
  CodeArtifact get _currentArtifact => CodeArtifact(
        title: _resolvedArtifact.title,
        fileName: _resolvedArtifact.fileName,
        language: _resolvedArtifact.language,
        code: _currentCode,
      );

  bool get _canRun =>
      !_showPreview && isSandboxRunnableLanguage(_resolvedArtifact.language);

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: _currentCode));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// Share: publishes the current version (or refreshes the page
  /// when the code has moved on since the last publish), then shows
  /// the public link. Publishing failures surface as a snackbar —
  /// most commonly the guest case, which the backend rejects.
  Future<void> _share() async {
    final controller = ref.read(artifactPublishProvider.notifier);
    final publishState = ref.read(artifactPublishProvider);
    if (publishState.publishedUrl == null ||
        publishState.isStale(_currentCode)) {
      await controller.publish(_currentArtifact, _currentCode);
    }
    if (!mounted) return;
    final after = ref.read(artifactPublishProvider);
    if (after.publishedUrl != null) {
      await _showShareDialog(after.publishedUrl!);
    } else if (after.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(after.error!),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _showShareDialog(String url) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Share artifact'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Anyone with this link can view the artifact. '
                'It is labeled as user-generated and unverified.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              SelectableText(
                url,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Link copied'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              child: const Text('Copy link'),
            ),
            TextButton(
              onPressed: () {
                launchUrl(
                  Uri.parse(url),
                  mode: LaunchMode.externalApplication,
                );
              },
              child: const Text('Open'),
            ),
            TextButton(
              onPressed: () async {
                await ref.read(artifactPublishProvider.notifier).unpublish();
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Unpublished — the link no longer works'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              child: const Text('Unpublish'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// Downloads the current version under the artifact's real file
  /// name (browser download on web, a saved file on native).
  Future<void> _download() async {
    final artifact = _currentArtifact;
    try {
      final savedPath = await downloadArtifactFile(
        fileName: artifact.downloadFileName,
        content: artifact.code,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedPath != null
                ? 'Saved to $savedPath'
                : 'Downloading ${artifact.downloadFileName}',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      await Sentry.captureException(e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Download failed'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _runCode() async {
    if (_isRunning) return;
    setState(() => _isRunning = true);
    final result = await runCodeInClientSandbox(
      _resolvedArtifact.language,
      _currentCode,
    );
    if (mounted) {
      setState(() {
        _isRunning = false;
        _sandboxResult = result;
      });
    }
  }

  /// Appends [code] as the new current version, discarding any
  /// "future" versions past the current index first (the usual
  /// undo-branch rule), and shows it in the editor.
  void _appendVersion(String code) {
    setState(() {
      _versions
        ..removeRange(_versionIndex + 1, _versions.length)
        ..add(code);
      _versionIndex++;
    });
    _editorController.codeLines = CodeLines.fromText(code);
    _saveWork();
  }

  /// Edit toggle. Leaving Edit mode with unsaved changes commits them
  /// as a new version.
  void _toggleEditing() {
    if (_editing) {
      final edited = _editorController.text;
      if (edited != _versions[_versionIndex]) {
        _appendVersion(edited);
      }
    }
    setState(() => _editing = !_editing);
  }

  /// Accepts the incoming quick-action version: it becomes a new
  /// version of this artifact (so accepting is itself reversible
  /// through version navigation).
  void _acceptIncoming() {
    final incoming = _incomingArtifact;
    if (incoming == null) return;
    setState(() {
      _incomingArtifact = null;
      _showIncomingDiff = false;
      _showDiff = false;
    });
    _appendVersion(incoming.code);
  }

  /// Rejects the incoming quick-action version; the reply stays in
  /// the chat as a message, it just never becomes a version here.
  void _rejectIncoming() {
    setState(() {
      _incomingArtifact = null;
      _showIncomingDiff = false;
    });
  }

  void _stepVersion(int delta) {
    final next = _versionIndex + delta;
    if (next < 0 || next >= _versions.length) return;
    setState(() => _versionIndex = next);
    _editorController.codeLines = CodeLines.fromText(_versions[next]);
    _saveWork();
  }

  @override
  Widget build(BuildContext context) {
    // Follow the artifact's live content while its message streams:
    // the resolved artifact replaces the tap-time snapshot. Once the
    // user commits an edit of their own, their versions win and the
    // stream no longer overwrites them.
    final live = ref.watch(openCodeArtifactLiveProvider);
    if (live != null) _resolvedArtifact = live;
    ref.listen<CodeArtifact?>(openCodeArtifactLiveProvider, (previous, next) {
      if (next == null) return;
      if (_versions.length != 1 || _editing) return;
      if (next.code == _versions[0]) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _versions[0] = next.code);
        _editorController.codeLines = CodeLines.fromText(next.code);
        _saveWork();
      });
    });
    // A completed quick-action reply is offered exactly once as an
    // incoming version: consuming the pending action here keeps
    // later messages in the thread from ever being mistaken for it.
    // (A watch + post-frame, not a listen, so a reply that is
    // already complete when the panel first builds is offered too.)
    final replyContent = ref.watch(quickActionReplyContentProvider);
    if (replyContent != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pending = ref.read(pendingQuickActionProvider);
        if (pending == null) return; // already consumed
        ref.read(pendingQuickActionProvider.notifier).state = null;
        final resolution = resolveQuickActionReply(
          replyContent,
          base: _currentArtifact,
          currentCode: _currentCode,
        );
        if (resolution.isPatchFailure) {
          setState(() {
            _patchFailureNotice = resolution.patchResult!.failedBlocks
                .map((f) => f.toString())
                .join('; ');
            _failedPatchAction = pending.action;
          });
          return;
        }
        final candidate = resolution.artifact;
        if (candidate == null) return;
        if (candidate.code == _currentCode) return;
        setState(() {
          _incomingArtifact = candidate;
          _incomingActionLabel = pending.action.label;
          _showIncomingDiff = false;
          _patchFailureNotice = null;
          _failedPatchAction = null;
        });
      });
    }

    // Persist the published link whenever it changes (publish,
    // republish, unpublish), merged with the current versions.
    ref.listen<ArtifactPublishState>(artifactPublishProvider, (previous, next) {
      if (previous?.publishedId != next.publishedId ||
          previous?.publishedUrl != next.publishedUrl ||
          previous?.publishedCode != next.publishedCode) {
        _saveWork();
      }
    });

    final theme = Theme.of(context);
    final ext = theme.extension<AppThemeExtension>();
    final borderColor = ext?.borderColor ?? const Color(0xFF3F3F3F);
    final artifact = _currentArtifact;
    final isPublishing = ref.watch(artifactPublishProvider).isPublishing;

    return Container(
      decoration: BoxDecoration(
        color: ext?.dialogBackground ?? const Color(0xFF1E1E1E),
        border: Border(left: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(ext, borderColor, isPublishing: isPublishing),
          if (!_showPreview) _buildToolbar(borderColor),
          if (_incomingArtifact != null) _buildIncomingBar(borderColor),
          if (_patchFailureNotice != null) _buildPatchFailureBar(borderColor),
          Expanded(
            child: _showPreview && artifact.isPreviewable
                ? _buildPreviewBody(artifact)
                : _buildCodeBody(artifact),
          ),
          if (_sandboxResult != null) _buildOutputStrip(),
        ],
      ),
    )
        .animate()
        .fade(duration: 200.ms)
        .slideX(begin: 0.04, end: 0, duration: 200.ms);
  }

  Widget _buildHeader(
    AppThemeExtension? ext,
    Color borderColor, {
    required bool isPublishing,
  }) {
    final artifact = _currentArtifact;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          // Claude puts the Preview/Code switch at the far left of the
          // header; plain code keeps the code icon there instead.
          if (artifact.isPreviewable) ...[
            _PreviewToggle(
              showPreview: _showPreview,
              onChanged: (preview) => setState(() => _showPreview = preview),
            ),
            const SizedBox(width: 12),
          ] else ...[
            const Icon(Icons.code, size: 18, color: Color(0xFFECECEC)),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  artifact.fileName ?? artifact.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFECECEC),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _subtitleFor(artifact),
                  style: TextStyle(
                    color: ext?.textTertiary ?? const Color(0xFF878787),
                    fontSize: 11,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
          if (_canRun)
            _HeaderAction(
              icon: _isRunning ? null : Icons.play_arrow_outlined,
              label: _isRunning ? 'Running…' : 'Run',
              onTap: _runCode,
            ),
          const SizedBox(width: 8),
          _HeaderAction(
            icon: _copied ? Icons.check : Icons.copy_outlined,
            label: _copied ? 'Copied' : 'Copy',
            onTap: _copyCode,
          ),
          const SizedBox(width: 6),
          // Icon-only: the header is width-constrained (Preview toggle
          // + Copy + Close already compete for the row, and on mobile
          // the panel is a ~360px overlay). The tooltip names it.
          _HeaderAction(
            icon: Icons.download_outlined,
            label: 'Download',
            onTap: _download,
            iconOnly: true,
          ),
          const SizedBox(width: 6),
          _HeaderAction(
            icon: isPublishing ? null : Icons.share_outlined,
            label: 'Share',
            onTap: _share,
            iconOnly: true,
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Color(0xFFB4B4B4)),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// Workbench toolbar: Edit toggle, version navigation, Diff toggle,
  /// and — when the chat screen wired a handler — the quick-action
  /// row (Canvas-style prompt templates). A selection hint appears
  /// while code is selected, since actions then scope to it.
  Widget _buildToolbar(Color borderColor) {
    final hasVersions = _versions.length > 1;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _HeaderAction(
                icon: _editing ? Icons.check : Icons.edit_outlined,
                label: _editing ? 'Done' : 'Edit',
                onTap: _toggleEditing,
              ),
              const SizedBox(width: 10),
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 16),
                color: const Color(0xFFECECEC),
                disabledColor: const Color(0xFF5A5A5A),
                tooltip: 'Previous version',
                visualDensity: VisualDensity.compact,
                onPressed: (!_editing && _versionIndex > 0)
                    ? () => _stepVersion(-1)
                    : null,
              ),
              Text(
                'v${_versionIndex + 1} / ${_versions.length}',
                style: const TextStyle(color: Color(0xFFECECEC), fontSize: 12),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 16),
                color: const Color(0xFFECECEC),
                disabledColor: const Color(0xFF5A5A5A),
                tooltip: 'Next version',
                visualDensity: VisualDensity.compact,
                onPressed: (!_editing && _versionIndex < _versions.length - 1)
                    ? () => _stepVersion(1)
                    : null,
              ),
              // Diff only exists once there are two versions to compare —
              // same rule as Run: controls appear when they can do
              // something.
              if (hasVersions) ...[
                const SizedBox(width: 6),
                _HeaderAction(
                  icon: Icons.difference_outlined,
                  label: 'Diff',
                  onTap: () => setState(() => _showDiff = !_showDiff),
                  selected: _showDiff,
                ),
              ],
            ],
          ),
          if (widget.onQuickAction != null) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final action in ArtifactQuickAction.values) ...[
                    _HeaderAction(
                      icon: switch (action) {
                        ArtifactQuickAction.fixBugs =>
                          Icons.bug_report_outlined,
                        ArtifactQuickAction.addLogs => Icons.terminal_outlined,
                        ArtifactQuickAction.review =>
                          Icons.rate_review_outlined,
                        ArtifactQuickAction.addComments =>
                          Icons.comment_outlined,
                      },
                      label: action.label,
                      onTap: () => _runQuickAction(action),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ],
          if (_selectionStartLine != null) ...[
            const SizedBox(height: 6),
            Text(
              'Lines $_selectionStartLine–$_selectionEndLine selected — '
              'actions apply to the selection',
              style: const TextStyle(
                color: Color(0xFF878787),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// `PY · Python` style subtitle. When the badge is just the language
  /// name uppercased (`HTML`, `DART`), the display name alone is shown
  /// so the subtitle never reads `HTML · HTML`.
  String _subtitleFor(CodeArtifact artifact) {
    final displayName = codeLanguageDisplayName(artifact.language);
    if (artifact.isPreviewable) {
      return '${artifact.previewKind.label} preview';
    }
    if (artifact.extensionLabel.toLowerCase() == artifact.language) {
      return displayName;
    }
    return '${artifact.extensionLabel} · $displayName';
  }

  Widget _buildPreviewBody(CodeArtifact artifact) {
    if (artifact.previewKind == CodePreviewKind.markdown) {
      // Markdown previews natively — no frame needed.
      final theme = Theme.of(context);
      return Container(
        color: const Color(0xFF141416),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: MarkdownBody(
            data: artifact.code,
            styleSheet: MarkdownStyleSheet(
              p: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFE2E8F0),
                height: 1.6,
              ),
              h1: theme.textTheme.headlineSmall
                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
              h2: theme.textTheme.titleLarge
                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
              h3: theme.textTheme.titleMedium
                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
              code: GoogleFonts.firaCode(
                backgroundColor: Colors.transparent,
                color: const Color(0xFFE2E8F0),
                fontSize: 13,
              ),
              codeblockDecoration: BoxDecoration(
                color: const Color(0xFF0F0F0F),
                borderRadius: BorderRadius.circular(8),
              ),
              listBullet: const TextStyle(color: Color(0xFFE2E8F0)),
            ),
          ),
        ),
      );
    }
    // HTML / SVG / Mermaid / React run in the sandboxed frame.
    // React previews get their sibling files for virtual bundling;
    // every preview gets a storage bridge scoped to this artifact,
    // so window.veraxiStorage works in draft mode.
    final siblingFiles = artifact.previewKind == CodePreviewKind.react
        ? ref.watch(openArtifactSiblingFilesProvider)
        : const <String, String>{};
    final storageScope = artifactStorageScopeId(
      threadId: widget.open.threadId,
      messageIndex: widget.open.messageIndex,
      artifactIndex: widget.open.artifactIndex,
    );
    final storageBridge = storageScope == null
        ? null
        : ref.watch(artifactStorageBridgeProvider(storageScope));
    return Container(
      color: const Color(0xFF141416),
      child: buildArtifactPreviewContent(
        kind: artifact.previewKind.name,
        code: artifact.code,
        siblingFiles: siblingFiles,
        storageHandler: storageBridge?.handle,
      ),
    );
  }

  /// The bar offering a quick action's reply as an incoming
  /// version: diff it against the current version, accept it as a
  /// new version, or reject it.
  Widget _buildIncomingBar(Color borderColor) {
    final label = _incomingActionLabel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF14532D).withValues(alpha: 0.25),
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          const Icon(Icons.update, size: 16, color: Color(0xFFBBF7D0)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label != null ? 'New version from $label' : 'New version',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFECECEC),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () =>
                setState(() => _showIncomingDiff = !_showIncomingDiff),
            child: Text(
              'Diff',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight:
                    _showIncomingDiff ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          TextButton(
            onPressed: _rejectIncoming,
            child: const Text('Reject', style: TextStyle(fontSize: 12.5)),
          ),
          TextButton(
            onPressed: _acceptIncoming,
            child: const Text(
              'Accept',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// Inline notice for a patch reply that did not apply cleanly,
  /// with a one-click retry as a full rewrite.
  Widget _buildPatchFailureBar(Color borderColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF7F1D1D).withValues(alpha: 0.25),
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFFCA5A5)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Patch did not apply: $_patchFailureNotice',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFECECEC),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _patchFailureNotice = null;
              _failedPatchAction = null;
            }),
            child: const Text('Dismiss', style: TextStyle(fontSize: 12.5)),
          ),
          TextButton(
            onPressed: _retryPatchAsFullRewrite,
            child: const Text(
              'Retry as full rewrite',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeBody(CodeArtifact artifact) {
    if (_showIncomingDiff && !_editing && _incomingArtifact != null) {
      return _buildDiffBody(_currentCode, _incomingArtifact!.code);
    }
    if (_showDiff && !_editing && _versionIndex > 0) {
      return _buildDiffBody(
        _versions[_versionIndex - 1],
        _versions[_versionIndex],
      );
    }
    return Container(
      color: const Color(0xFF0F0F0F),
      child: CodeEditor(
        controller: _editorController,
        readOnly: !_editing,
        showCursorWhenReadOnly: false,
        wordWrap: false,
        padding: const EdgeInsets.fromLTRB(4, 16, 24, 16),
        style: CodeEditorStyle(
          fontSize: 13,
          fontHeight: 1.5,
          fontFamily: 'Fira Code',
          backgroundColor: const Color(0xFF0F0F0F),
          textColor: const Color(0xFFABB2BF),
          codeTheme: artifactEditorTheme(artifact.language),
        ),
        indicatorBuilder: (context, controller, chunkController, notifier) {
          return Row(
            children: [
              DefaultCodeLineNumber(
                controller: controller,
                notifier: notifier,
                textStyle: GoogleFonts.firaCode(
                  fontSize: 13,
                  height: 1.5,
                  color: const Color(0xFF5A5A5A),
                ),
                focusedTextStyle: GoogleFonts.firaCode(
                  fontSize: 13,
                  height: 1.5,
                  color: const Color(0xFFB4B4B4),
                ),
              ),
              DefaultCodeChunkIndicator(
                width: 16,
                controller: chunkController,
                notifier: notifier,
              ),
            ],
          );
        },
      ),
    );
  }

  /// Line diff between two versions of the artifact.
  Widget _buildDiffBody(String oldCode, String newCode) {
    final entries = computeLineDiff(oldCode, newCode);
    return Container(
      color: const Color(0xFF0F0F0F),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final entry = entries[i];
          final (bg, fg, marker) = switch (entry.kind) {
            LineDiffKind.added => (
                const Color(0xFF14532D).withValues(alpha: 0.35),
                const Color(0xFFBBF7D0),
                '+',
              ),
            LineDiffKind.removed => (
                const Color(0xFF7F1D1D).withValues(alpha: 0.35),
                const Color(0xFFFCA5A5),
                '−',
              ),
            LineDiffKind.unchanged => (
                Colors.transparent,
                const Color(0xFF878787),
                ' ',
              ),
          };
          return Container(
            color: bg,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
            child: Text(
              '$marker ${entry.text}',
              style: GoogleFonts.firaCode(
                fontSize: 12.5,
                height: 1.5,
                color: fg,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildOutputStrip() {
    final result = _sandboxResult!;
    final failed = result.exitCode != 0;
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFF09090B),
        border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.check_circle_outline,
                size: 14,
                color:
                    failed ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
              ),
              const SizedBox(width: 6),
              Text(
                failed
                    ? 'Sandbox Error (Exit ${result.exitCode})'
                    : 'Sandbox Output',
                style: TextStyle(
                  color: failed
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF22C55E),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () => setState(() => _sandboxResult = null),
                child: const Icon(Icons.close, size: 14, color: Colors.white54),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (result.stdout.isNotEmpty)
                    SelectableText(
                      result.stdout,
                      style: GoogleFonts.firaCode(
                        fontSize: 12,
                        color: const Color(0xFFE2E8F0),
                      ),
                    ),
                  if (result.stderr.isNotEmpty)
                    SelectableText(
                      result.stderr,
                      style: GoogleFonts.firaCode(
                        fontSize: 12,
                        color: const Color(0xFFFCA5A5),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview | Code segmented toggle shown for renderable artifacts,
/// mirroring the tabs in Claude's artifact pane.
class _PreviewToggle extends StatelessWidget {
  final bool showPreview;
  final ValueChanged<bool> onChanged;

  const _PreviewToggle({
    required this.showPreview,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141416),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3F3F3F)),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment('Preview', Icons.visibility_outlined, showPreview, true),
          _segment('Code', Icons.code, !showPreview, false),
        ],
      ),
    );
  }

  Widget _segment(String label, IconData icon, bool selected, bool value) {
    return Material(
      color: selected ? const Color(0xFF3F3F3F) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 13,
                  color: selected ? Colors.white : const Color(0xFF878787)),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? Colors.white : const Color(0xFF878787),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onTap;

  /// Renders the chip in its "active" state (e.g. Diff toggled on).
  final bool selected;

  /// Renders just the icon (the label becomes the tooltip) for
  /// width-constrained spots in the header.
  final bool iconOnly;

  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final chip = Material(
      color: selected ? const Color(0xFF3F3F3F) : const Color(0xFF2F2F2F),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: iconOnly ? 8 : 10,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF3F3F3F)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: const Color(0xFFECECEC)),
                if (!iconOnly) const SizedBox(width: 5),
              ] else ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFECECEC),
                  ),
                ),
                const SizedBox(width: 5),
              ],
              if (!iconOnly)
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFFECECEC),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return iconOnly ? Tooltip(message: label, child: chip) : chip;
  }
}
