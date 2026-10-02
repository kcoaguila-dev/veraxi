import 'dart:convert';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Result returned by every tool implementation.
class ToolResult {
  /// Human-readable summary shown in the chat bubble.
  final String summary;

  /// Raw content passed back to the LLM as the tool result.
  final String content;

  /// Whether execution succeeded.
  final bool isSuccess;

  const ToolResult({
    required this.summary,
    required this.content,
    this.isSuccess = true,
  });

  factory ToolResult.error(String message) => ToolResult(
        summary: '❌ $message',
        content: 'Error: $message',
        isSuccess: false,
      );
}

/// Routes LLM tool-call JSON to native Android implementations.
///
/// Each public method maps to one tool name the LLM can call.
/// All destructive operations require an explicit [confirm] callback so
/// the calling widget can show a confirmation dialog before execution.
class AgentToolRouter {
  /// The navigator key used to show confirmation dialogs.
  final GlobalKey<NavigatorState> navigatorKey;

  const AgentToolRouter({required this.navigatorKey});

  // ---------------------------------------------------------------------------
  // Dispatch
  // ---------------------------------------------------------------------------

  /// Dispatches an incoming tool call from the LLM to the right implementation.
  ///
  /// [toolName] is the name the model declared in its function call.
  /// [args] are the model-supplied arguments.
  Future<ToolResult> dispatch(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    switch (toolName) {
      case 'read_file':
        return _readFile();
      case 'write_file':
        return _writeFile(
          filename: args['filename']?.toString() ?? 'output.txt',
          content: args['content']?.toString() ?? '',
        );
      case 'list_files':
        return _listFiles();
      case 'run_shell':
        return _runShell(command: args['command']?.toString() ?? '');
      case 'open_app':
        return _openApp(
          packageOrUrl: args['package_or_url']?.toString() ?? '',
        );
      case 'web_search':
        // web_search is handled by the backend MCP — we surface a stub result
        // so the LLM knows it should use the backend tool instead.
        return const ToolResult(
          summary: '🌐 Delegating to backend web search…',
          content: 'web_search is handled by the backend MCP tool.',
        );
      default:
        return ToolResult.error('Unknown tool: $toolName');
    }
  }

  // ---------------------------------------------------------------------------
  // Tool: read_file
  // ---------------------------------------------------------------------------

  /// Prompts the user to pick a file and returns its text content.
  Future<ToolResult> _readFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'txt',
          'md',
          'py',
          'js',
          'ts',
          'dart',
          'json',
          'yaml',
          'yml',
          'csv',
          'sh',
          'bash',
          'html',
          'css',
          'xml',
          'log',
        ],
      );

      if (result.isEmpty) {
        return ToolResult.error('No file selected.');
      }

      final file = result.first;
      final path = file.path;
      if (path == null) {
        return ToolResult.error('Could not read file path.');
      }

      final bytes = await File(path).readAsBytes();
      final content = utf8.decode(bytes, allowMalformed: true);
      final truncated = content.length > 8000
          ? '${content.substring(0, 8000)}\n\n[…truncated, ${content.length} chars total]'
          : content;

      return ToolResult(
        summary: '📄 Read "${file.name}" (${_humanSize(bytes.length)})',
        content: '--- File: ${file.name} ---\n$truncated',
      );
    } catch (e) {
      return ToolResult.error('Failed to read file: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Tool: write_file
  // ---------------------------------------------------------------------------

  /// Saves LLM-generated [content] to `Downloads/Veraxi/[filename]`.
  /// Requires confirmation from the user before writing.
  Future<ToolResult> _writeFile({
    required String filename,
    required String content,
  }) async {
    if (content.isEmpty) return ToolResult.error('Nothing to write.');

    final confirmed = await _confirm(
      title: 'Save file?',
      body: 'The agent wants to save "$filename" to Downloads/Veraxi/.',
    );
    if (!confirmed) return ToolResult.error('User cancelled file save.');

    try {
      final dir = await _veraximDir();
      final safeFilename = filename.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
      final file = File('${dir.path}/$safeFilename');
      await file.writeAsString(content);

      return ToolResult(
        summary: '💾 Saved "$safeFilename" to Downloads/Veraxi/',
        content: 'File saved successfully to ${file.path}',
      );
    } catch (e) {
      return ToolResult.error('Failed to write file: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Tool: list_files
  // ---------------------------------------------------------------------------

  /// Lists files inside the app's Veraxi output directory.
  Future<ToolResult> _listFiles() async {
    try {
      final dir = await _veraximDir();
      final entities = dir.listSync();
      if (entities.isEmpty) {
        return const ToolResult(
          summary: '📂 Downloads/Veraxi/ is empty',
          content: 'The Veraxi output directory is empty.',
        );
      }

      final lines = entities.map((e) {
        final name = e.path.split('/').last;
        if (e is File) {
          final size = _humanSize(e.lengthSync());
          return '  📄 $name ($size)';
        }
        return '  📁 $name/';
      }).join('\n');

      return ToolResult(
        summary: '📂 ${entities.length} item(s) in Downloads/Veraxi/',
        content: 'Contents of Downloads/Veraxi/:\n$lines',
      );
    } catch (e) {
      return ToolResult.error('Could not list files: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Tool: run_shell
  // ---------------------------------------------------------------------------

  /// Sends [command] to Termux via the `termux-run-command` Intent.
  /// Requires user confirmation and Termux + Termux:API installed.
  Future<ToolResult> _runShell({required String command}) async {
    if (command.isEmpty) return ToolResult.error('No command provided.');

    final confirmed = await _confirm(
      title: 'Run shell command?',
      body: 'The agent wants to execute:\n\n`$command`\n\n'
          'Termux will run this command. Make sure you trust the agent output.',
    );
    if (!confirmed) return ToolResult.error('User cancelled shell command.');

    // Check if running on Android
    if (!Platform.isAndroid) {
      return ToolResult.error(
          'Shell execution is only supported on Android via Termux.');
    }

    try {
      const channel = MethodChannel('veraxi/termux_bridge');
      final result = await channel.invokeMethod<String>('runCommand', {
        'command': command,
      });

      final output = result ?? '(no output)';
      return ToolResult(
        summary:
            '⚡ Shell: ${command.length > 40 ? '${command.substring(0, 40)}…' : command}',
        content: '\$ $command\n\n$output',
      );
    } on PlatformException catch (e) {
      if (e.code == 'TERMUX_NOT_INSTALLED') {
        return ToolResult.error(
          'Termux is not installed. Install Termux and Termux:API from F-Droid to enable shell commands.',
        );
      }
      return ToolResult.error('Shell error: ${e.message}');
    } catch (e) {
      return ToolResult.error('Shell error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Tool: open_app
  // ---------------------------------------------------------------------------

  /// Opens an Android app by package name or launches a URL.
  Future<ToolResult> _openApp({required String packageOrUrl}) async {
    if (packageOrUrl.isEmpty) {
      return ToolResult.error('No package name or URL provided.');
    }

    // Guard: only on Android
    if (!Platform.isAndroid) {
      return ToolResult.error('open_app is only supported on Android.');
    }

    try {
      if (packageOrUrl.startsWith('http')) {
        final intent = AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: packageOrUrl,
        );
        await intent.launch();
        return ToolResult(
          summary: '🔗 Opened $packageOrUrl',
          content: 'Launched URL: $packageOrUrl',
        );
      } else {
        final intent = AndroidIntent(
          action: 'android.intent.action.MAIN',
          package: packageOrUrl,
          flags: <int>[0x10000000], // FLAG_ACTIVITY_NEW_TASK
        );
        await intent.launch();
        return ToolResult(
          summary: '📱 Opened $packageOrUrl',
          content: 'Launched app: $packageOrUrl',
        );
      }
    } catch (e) {
      return ToolResult.error('Could not open "$packageOrUrl": $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Returns (creating if needed) the `Downloads/Veraxi/` output directory.
  Future<Directory> _veraximDir() async {
    Directory base;
    if (Platform.isAndroid) {
      // Use external storage Downloads on Android
      base = Directory('/storage/emulated/0/Download/Veraxi');
    } else {
      // Fallback for other platforms during development
      final docs = await getApplicationDocumentsDirectory();
      base = Directory('${docs.path}/Veraxi');
    }
    if (!base.existsSync()) {
      await base.create(recursive: true);
    }
    return base;
  }

  /// Shows a confirmation dialog via the navigator key and returns the result.
  Future<bool> _confirm({required String title, required String body}) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;

    final result = await showDialog<bool>(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Converts a byte count into a human-readable size string.
  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

// ---------------------------------------------------------------------------
// Tool schema — the JSON definitions sent to Ollama so it knows what tools
// are available. Matches Ollama's OpenAI-compatible /api/chat tool format.
// ---------------------------------------------------------------------------

/// The tool definitions passed to Ollama's API in every local agent request.
const List<Map<String, dynamic>> kAndroidAgentTools = [
  {
    'type': 'function',
    'function': {
      'name': 'read_file',
      'description':
          'Prompts the user to pick a file from their device and returns its text content. '
              'Use this when the user asks you to read, analyze, or process a file.',
      'parameters': {
        'type': 'object',
        'properties': {},
        'required': [],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'write_file',
      'description':
          'Saves text content to a file in Downloads/Veraxi/ on the device. '
              'Use this when the user asks you to create, save, or export a file.',
      'parameters': {
        'type': 'object',
        'properties': {
          'filename': {
            'type': 'string',
            'description':
                'The filename including extension, e.g. "script.py" or "notes.md".',
          },
          'content': {
            'type': 'string',
            'description': 'The full text content to write to the file.',
          },
        },
        'required': ['filename', 'content'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'list_files',
      'description': 'Lists all files saved in the Downloads/Veraxi/ directory. '
          'Use this to show the user what files the agent has previously created.',
      'parameters': {
        'type': 'object',
        'properties': {},
        'required': [],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'run_shell',
      'description': 'Executes a shell command in Termux on the Android device. '
          'Requires Termux and Termux:API to be installed from F-Droid. '
          'Always prefer safe, non-destructive commands. The user must confirm before execution.',
      'parameters': {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description':
                'The bash shell command to execute, e.g. "ls ~/storage/downloads".',
          },
        },
        'required': ['command'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'open_app',
      'description':
          'Opens an Android app by its package name (e.g. "com.google.android.youtube") '
              'or opens a URL in the browser.',
      'parameters': {
        'type': 'object',
        'properties': {
          'package_or_url': {
            'type': 'string',
            'description':
                'An Android package name like "com.android.settings" or a full URL like "https://example.com".',
          },
        },
        'required': ['package_or_url'],
      },
    },
  },
];

/// Returns the tool list to pass to Ollama when agent mode is active.
/// On non-Android platforms, shell and open_app tools are excluded.
List<Map<String, dynamic>> agentToolsForPlatform() {
  if (!Platform.isAndroid) {
    return kAndroidAgentTools
        .where((t) =>
            t['function']['name'] != 'run_shell' &&
            t['function']['name'] != 'open_app')
        .toList();
  }
  return kAndroidAgentTools;
}
