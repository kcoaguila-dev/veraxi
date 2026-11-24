import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/chat/data/acp_repository.dart';

const _envAllowlist = [
  'PATH',
  'HOME',
  'LANG',
  'LC_ALL',
  'TERM',
  'TMPDIR',
  'USER',
  'LOGNAME',
  'XDG_CONFIG_HOME',
  'XDG_DATA_HOME',
  'XDG_CACHE_HOME',
  'ANTIGRAVITY_DATA_DIR',
];

const _quotaMarkers = [
  '429',
  'resource_exhausted',
  'quota',
  'rate limit',
  'ratelimit',
  'too many requests',
  'usage limit',
];

class _DesktopAcpSession {
  final String sessionId;
  final Process process;
  String acpSessionId = '';
  String? model;
  final Map<String, Completer<Map<String, dynamic>>> pendingRpc = {};
  final Map<String, dynamic> pendingPermissionIds = {};
  StreamController<Map<String, dynamic>>? turnEvents;
  bool isRunningTurn = false;

  _DesktopAcpSession({
    required this.sessionId,
    required this.process,
    this.model,
  });
}

/// Direct local `agy acp` client for Veraxi Desktop (Linux/macOS/Windows).
///
/// Spawns the official `agy` binary directly on the user's machine over
/// JSON-RPC 2.0 stdio, keeping all credentials and quotas strictly local.
class DesktopAcpClient {
  DesktopAcpClient._();
  static final DesktopAcpClient instance = DesktopAcpClient._();

  static bool get isSupported =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  final Map<String, _DesktopAcpSession> _sessions = {};
  int _rpcCounter = 0;

  Map<String, String> _scrubbedEnv() {
    final env = <String, String>{};
    for (final key in _envAllowlist) {
      final val = Platform.environment[key];
      if (val != null && val.isNotEmpty) {
        env[key] = val;
      }
    }
    return env;
  }

  Future<String?> _resolveBinary() async {
    final home = Platform.environment['HOME'] ?? '';
    final candidates = <String>[
      if (home.isNotEmpty) '$home/.local/bin/agy',
      'agy',
    ];
    for (final candidate in candidates) {
      if (candidate.contains('/')) {
        if (await File(candidate).exists()) return candidate;
      } else {
        try {
          final whichCmd = Platform.isWindows ? 'where' : 'which';
          final res = await Process.run(whichCmd, [candidate]);
          if (res.exitCode == 0) {
            final line = res.stdout.toString().trim().split('\n').first.trim();
            if (line.isNotEmpty) return line;
          }
        } catch (_) {}
      }
    }
    return null;
  }

  Future<AcpStatus> checkStatus() async {
    if (!isSupported) return const AcpStatus();
    final bin = await _resolveBinary();
    if (bin == null) {
      return const AcpStatus(
        available: false,
        acpEnabled: true,
        transport: 'unavailable',
        binary: 'agy',
      );
    }
    final models = await _listModels(bin);
    return AcpStatus(
      available: true,
      acpEnabled: true,
      transport: 'desktop_stdio',
      binary: bin,
      models: models,
    );
  }

  Future<List<String>> _listModels(String bin) async {
    try {
      final res =
          await Process.run(bin, ['models'], environment: _scrubbedEnv())
              .timeout(const Duration(seconds: 4));
      if (res.exitCode != 0) return defaultAntigravityModels;
      final parsed = <String>[];
      for (final rawLine in res.stdout.toString().split('\n')) {
        final token = rawLine.trim().split(' ').first.trim();
        if (token.isNotEmpty && !RegExp(r'^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]').hasMatch(token)) {
          parsed.add(token);
        }
      }
      return parsed.isNotEmpty ? parsed : defaultAntigravityModels;
    } catch (_) {
      return defaultAntigravityModels;
    }
  }

  Future<_DesktopAcpSession> _getOrSpawn({
    required String threadId,
    String? model,
    String? cwd,
  }) async {
    final effectiveModel =
        (model != null && model.isNotEmpty && model != 'antigravity-acp')
            ? model
            : null;
    final existing = _sessions[threadId];
    if (existing != null) {
      if (effectiveModel != null && effectiveModel != existing.model) {
        await _setModel(existing, effectiveModel);
      }
      return existing;
    }

    final bin = await _resolveBinary();
    if (bin == null) {
      throw StateError(
        'Antigravity CLI (agy) was not found on PATH. Install agy and sign in locally.',
      );
    }

    final args =
        effectiveModel != null ? ['--model', effectiveModel, 'acp'] : ['acp'];
    final process = await Process.start(
      bin,
      args,
      workingDirectory: cwd ?? Directory.current.path,
      environment: _scrubbedEnv(),
    );

    final session = _DesktopAcpSession(
      sessionId: threadId,
      process: process,
      model: effectiveModel,
    );
    _sessions[threadId] = session;
    _attachStdoutListener(session);

    await _rpcCall(session, 'initialize', {
      'protocolVersion': 1,
      'clientInfo': {'name': 'veraxi-desktop', 'version': '1.0.0'},
      'capabilities': {
        'fs': {'readTextFile': false, 'writeTextFile': false},
        'terminal': false,
      },
    });
    final newRes = await _rpcCall(session, 'session/new', {
      'cwd': cwd ?? Directory.current.path,
      'mcpServers': <dynamic>[],
    });
    session.acpSessionId = (newRes['sessionId'] as String?) ?? threadId;
    return session;
  }

  void _attachStdoutListener(_DesktopAcpSession session) {
    session.process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is! Map<String, dynamic>) return;
          final id = decoded['id'];
          final method = decoded['method'];
          if (id != null && method == null) {
            final completer = session.pendingRpc.remove(id.toString());
            if (completer != null && !completer.isCompleted) {
              completer.complete(decoded);
            }
            return;
          }
          session.turnEvents?.add(decoded);
        } catch (_) {}
      },
      onDone: () {
        for (final c in session.pendingRpc.values) {
          if (!c.isCompleted) {
            c.completeError(StateError('Antigravity ACP process exited'));
          }
        }
        session.pendingRpc.clear();
        session.turnEvents?.close();
        _sessions.remove(session.sessionId);
      },
    );
  }

  Future<Map<String, dynamic>> _rpcCall(
    _DesktopAcpSession session,
    String method,
    Map<String, dynamic> params,
  ) async {
    final reqId = 'v_${++_rpcCounter}';
    final completer = Completer<Map<String, dynamic>>();
    session.pendingRpc[reqId] = completer;
    final line = jsonEncode({
      'jsonrpc': '2.0',
      'id': reqId,
      'method': method,
      'params': params,
    });
    session.process.stdin.writeln(line);
    await session.process.stdin.flush();

    final msg = await completer.future.timeout(const Duration(minutes: 5));
    if (msg['error'] != null) {
      throw StateError(jsonEncode(msg['error']));
    }
    final res = msg['result'];
    return res is Map<String, dynamic> ? res : <String, dynamic>{};
  }

  Future<void> _setModel(_DesktopAcpSession session, String modelId) async {
    try {
      await _rpcCall(session, 'session/set_model', {
        'sessionId': session.acpSessionId,
        'modelId': modelId,
      });
      session.model = modelId;
    } catch (_) {}
  }

  Stream<Map<String, dynamic>> streamPrompt({
    required String threadId,
    required String prompt,
    String? model,
    String? cwd,
  }) async* {
    yield {
      'event': 'on_step_start',
      'step': 1,
      'name': 'Antigravity ACP (Local)',
      'description': 'Running directly via local Antigravity CLI...',
    };

    try {
      final session = await _getOrSpawn(
        threadId: threadId,
        model: model,
        cwd: cwd,
      );
      final controller = StreamController<Map<String, dynamic>>();
      session.turnEvents = controller;
      session.isRunningTurn = true;

      unawaited(_rpcCall(session, 'session/prompt', {
        'sessionId': session.acpSessionId,
        'prompt': [
          {'type': 'text', 'text': prompt}
        ],
      }).then((_) {
        if (!controller.isClosed) controller.close();
      }).catchError((Object err) {
        if (!controller.isClosed) {
          controller.addError(err);
          controller.close();
        }
      }));

      try {
        await for (final msg in controller.stream) {
          for (final evt in _translateInbound(session, msg)) {
            yield evt;
          }
        }
      } catch (err) {
        yield _friendlyError(err.toString());
      } finally {
        session.turnEvents = null;
        session.isRunningTurn = false;
      }
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      yield _friendlyError(e.toString());
    }
  }

  List<Map<String, dynamic>> _translateInbound(
    _DesktopAcpSession session,
    Map<String, dynamic> msg,
  ) {
    final method = msg['method'];
    if (method == 'session/request_permission') {
      final reqId = msg['id']?.toString() ?? '';
      session.pendingPermissionIds[reqId] = msg['id'];
      final params = msg['params'] as Map<String, dynamic>? ?? {};
      final toolCall = params['toolCall'] as Map<String, dynamic>? ?? {};
      return [
        {
          'event': 'acp_permission_request',
          'session_id': session.sessionId,
          'request_id': reqId,
          'tool_name': toolCall['title'] ?? toolCall['kind'] ?? 'tool',
          'description': params['description'] ??
              toolCall['title'] ??
              'Permission requested',
          'args': toolCall['rawInput'] is Map
              ? Map<String, dynamic>.from(toolCall['rawInput'] as Map)
              : <String, dynamic>{},
        }
      ];
    }

    if (method == 'session/update') {
      final params = msg['params'] as Map<String, dynamic>? ?? {};
      final update = params['update'] as Map<String, dynamic>? ?? params;
      final kind = update['sessionUpdate'] ?? update['type'] ?? '';
      final content = update['content'];
      final text = content is Map
          ? (content['text']?.toString() ?? '')
          : (content?.toString() ?? update['text']?.toString() ?? '');

      if (kind == 'agent_thought_chunk' && text.isNotEmpty) {
        return [
          {
            'event': 'on_reasoning_stream',
            'data': {'text': text},
          }
        ];
      }
      if (kind == 'agent_message_chunk' && text.isNotEmpty) {
        return [
          {
            'event': 'on_chat_model_stream',
            'data': {
              'chunk': {'content': text}
            },
          }
        ];
      }
      if (kind == 'tool_call') {
        final runId = update['toolCallId']?.toString() ?? '';
        final name = update['title']?.toString() ?? 'tool';
        return [
          {
            'event': 'on_tool_start',
            'name': name,
            'label': name,
            'step': 1,
            'run_id': runId,
            'data': {'input': update['rawInput'] ?? {}},
          }
        ];
      }
      if (kind == 'tool_call_update') {
        final status = (update['status']?.toString() ?? '').toLowerCase();
        if (status == 'completed' ||
            status == 'failed' ||
            status == 'error' ||
            status == 'cancelled') {
          final isErr = status != 'completed';
          return [
            {
              'event': 'on_tool_end',
              'name': update['title']?.toString() ?? 'tool',
              'label': update['title']?.toString() ?? 'tool',
              'step': 1,
              'run_id': update['toolCallId']?.toString() ?? '',
              'status': isErr ? 'error' : 'success',
              'summary': update['rawOutput']?.toString() ??
                  (isErr ? 'Tool failed' : 'Executed successfully'),
              'data': {'output': update['rawOutput'] ?? ''},
            }
          ];
        }
      }
    }
    return const [];
  }

  Map<String, dynamic> _friendlyError(String raw) {
    final lower = raw.toLowerCase();
    if (_quotaMarkers.any(lower.contains)) {
      return {
        'error':
            'Antigravity quota or rate limit reached. Switch to a BYOK model or try again later.',
        'code': 'quota_exhausted',
        'recoverable_action': 'switch_model',
      };
    }
    return {'error': raw, 'code': 'acp_error'};
  }

  Future<bool> resolvePermission({
    required String sessionId,
    required String requestId,
    required String outcome,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return false;
    final rawId = session.pendingPermissionIds.remove(requestId);
    if (rawId == null) return false;
    final result = outcome == 'deny'
        ? {
            'outcome': {'outcome': 'cancelled'}
          }
        : {
            'outcome': {'outcome': 'selected', 'optionId': outcome}
          };
    session.process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': rawId,
      'result': result,
    }));
    await session.process.stdin.flush();
    return true;
  }

  Future<bool> cancelSession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return false;
    session.process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'cancel_${++_rpcCounter}',
      'method': 'session/cancel',
      'params': {'sessionId': session.acpSessionId},
    }));
    await session.process.stdin.flush();
    return true;
  }
}
