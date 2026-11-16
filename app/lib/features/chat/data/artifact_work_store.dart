import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:veraxi_app/features/chat/data/artifact_work_sync_repository.dart';
import 'package:veraxi_app/features/chat/data/local_chat_database.dart';

/// The panel work a user has invested in one artifact: its version
/// history and, when shared, the published link. Persisted so
/// closing the panel — or the app — no longer throws the work
/// away, the way Claude keeps artifact versions with the
/// conversation: locally in the chat database (Drift), and synced
/// through the backend next to the chat history (see
/// [ArtifactWorkSyncRepository]), so it follows the user across
/// devices the way threads do.
class ArtifactWorkState {
  /// Every version of the artifact, oldest first.
  final List<String> versions;

  /// The version on screen when the state was saved.
  final int versionIndex;

  /// The artifact's code as first saved. Identity guard on
  /// restore: a single-version entry whose original no longer
  /// matches what was opened was a stream snapshot, not user work.
  final String originalCode;

  final String? publishedId;
  final String? publishedUrl;

  /// The code as it was when published (staleness check).
  final String? publishedCode;

  /// When this state was last saved (epoch milliseconds), stamped
  /// by the store on every save. Sync conflicts resolve to the
  /// newer stamp, last writer wins.
  final int updatedAtMs;

  const ArtifactWorkState({
    required this.versions,
    required this.versionIndex,
    required this.originalCode,
    this.publishedId,
    this.publishedUrl,
    this.publishedCode,
    this.updatedAtMs = 0,
  });

  ArtifactWorkState copyWith({int? updatedAtMs}) {
    return ArtifactWorkState(
      versions: versions,
      versionIndex: versionIndex,
      originalCode: originalCode,
      publishedId: publishedId,
      publishedUrl: publishedUrl,
      publishedCode: publishedCode,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  /// True when the entry holds work worth restoring even if the
  /// source message has since changed: real edits, navigation, or
  /// a published link.
  bool get hasUserWork =>
      versions.length > 1 || versionIndex > 0 || publishedId != null;

  Map<String, dynamic> toJson() => {
        'versions': versions,
        'versionIndex': versionIndex,
        'originalCode': originalCode,
        'publishedId': publishedId,
        'publishedUrl': publishedUrl,
        'publishedCode': publishedCode,
        'updatedAtMs': updatedAtMs,
      };

  factory ArtifactWorkState.fromJson(Map<String, dynamic> json) {
    return ArtifactWorkState(
      versions: (json['versions'] as List<dynamic>).cast<String>(),
      versionIndex: json['versionIndex'] as int? ?? 0,
      originalCode: json['originalCode'] as String? ?? '',
      publishedId: json['publishedId'] as String?,
      publishedUrl: json['publishedUrl'] as String?,
      publishedCode: json['publishedCode'] as String?,
      updatedAtMs: json['updatedAtMs'] as int? ?? 0,
    );
  }
}

/// Storage key for an artifact's panel work, built from the open
/// coordinates recorded at card tap (thread, message, block).
/// Null when the artifact could not be located in its thread —
/// such panel sessions stay disposable, there is nothing stable
/// to key the work to.
String? artifactWorkKey({
  required String? threadId,
  required int? messageIndex,
  required int artifactIndex,
}) {
  if (messageIndex == null) return null;
  return '${threadId ?? 'local'}:$messageIndex:$artifactIndex';
}

/// The coordinates a work-store key encodes, parsed back out for
/// sync calls.
typedef WorkCoords = ({
  String threadId,
  int messageIndex,
  int artifactIndex,
});

/// Persists [ArtifactWorkState] entries as rows in the local
/// chat database's artifact-work table (one row per artifact, so
/// a save writes one row — not a settings blob rewritten whole),
/// and syncs them through the backend when a sync repository is
/// attached and the key names a real thread: the local copy is
/// the offline cache, the server copy is what follows the user
/// across devices. Failures are reported to Sentry and treated
/// as "nothing stored" — persistence must never break the panel.
class ArtifactWorkStore {
  ArtifactWorkStore({
    ArtifactWorkSyncRepository? sync,
    LocalChatDatabase? database,
  })  : _sync = sync,
        _db = database ?? LocalChatDatabase();

  final ArtifactWorkSyncRepository? _sync;
  final LocalChatDatabase _db;

  /// Oldest entries are evicted past this many artifacts.
  static const int maxEntries = 100;

  Future<void> _writeChain = Future.value();

  /// Loads the newest known state for [key]: the local cache and
  /// the server copy are reconciled by their save stamps, and the
  /// loser is healed to the winner (local refreshed from the
  /// server, or local work pushed up when the server has none or
  /// an older copy). Without sync, or offline, the local state is
  /// the answer.
  Future<ArtifactWorkState?> load(String key) async {
    final local = await _loadLocal(key);
    final coords = parseWorkKey(key);
    final sync = _sync;
    if (sync == null || coords == null) return local;
    try {
      // Bounded: a hung connection must not stall the restore —
      // on timeout the local state is the answer.
      final remote = await sync
          .fetchThreadWork(coords.threadId)
          .timeout(const Duration(seconds: 5));
      final remoteState =
          remote['${coords.messageIndex}:${coords.artifactIndex}'];
      if (remoteState == null) {
        if (local != null) _pushRemote(coords, local);
        return local;
      }
      if (local == null || remoteState.updatedAtMs >= local.updatedAtMs) {
        await _saveLocal(key, remoteState);
        return remoteState;
      }
      _pushRemote(coords, local);
      return local;
    } catch (e) {
      await Sentry.captureException(e);
      return local;
    }
  }

  Future<ArtifactWorkState?> _loadLocal(String key) async {
    try {
      final row = await (_db.select(_db.artifactWorkEntries)
            ..where((t) => t.workKey.equals(key)))
          .getSingleOrNull();
      if (row == null) return null;
      return ArtifactWorkState.fromJson(
        jsonDecode(row.stateJson) as Map<String, dynamic>,
      );
    } catch (e) {
      await Sentry.captureException(e);
      return null;
    }
  }

  /// The last stamp this store handed out. Stamps are kept
  /// strictly increasing so save order is always recoverable from
  /// the stamps alone (eviction drops the least recently saved,
  /// sync takes the newest) even for saves inside one millisecond.
  int _lastStampMs = 0;

  int _nextStamp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastStampMs = now > _lastStampMs ? now : _lastStampMs + 1;
    return _lastStampMs;
  }

  /// Saves [state] locally (stamped with the current time) and
  /// pushes it to the backend in the background when sync applies.
  /// Returns how many older entries this save evicted to stay
  /// under the cap, so the caller can tell the user their oldest
  /// saved work was dropped — never silently.
  Future<int> save(String key, ArtifactWorkState state) async {
    final stamped = state.copyWith(updatedAtMs: _nextStamp());
    final evicted = await _saveLocal(key, stamped);
    final coords = parseWorkKey(key);
    if (_sync != null && coords != null) {
      _pushRemote(coords, stamped);
    }
    return evicted;
  }

  Future<int> _saveLocal(String key, ArtifactWorkState state) async {
    // Serialize read-modify-write cycles so rapid panel actions
    // cannot interleave and drop each other's entries.
    var evicted = 0;
    _writeChain = _writeChain.then((_) async {
      evicted = await _saveNow(key, state);
    });
    await _writeChain;
    return evicted;
  }

  /// Fire-and-forget server save; failures are reported and the
  /// local copy remains the fallback (the next load or save heals
  /// the server copy).
  void _pushRemote(WorkCoords coords, ArtifactWorkState state) {
    final sync = _sync;
    if (sync == null) return;
    () async {
      try {
        await sync.saveWork(
          threadId: coords.threadId,
          messageIndex: coords.messageIndex,
          artifactIndex: coords.artifactIndex,
          state: state,
        );
      } catch (e) {
        await Sentry.captureException(e);
      }
    }();
  }

  /// Writes one entry in a transaction, evicting the
  /// least-recently-saved entries past the cap. Returns the
  /// number evicted (0 when the write failed).
  Future<int> _saveNow(String key, ArtifactWorkState state) async {
    try {
      return await _db.transaction(() async {
        await _db.into(_db.artifactWorkEntries).insertOnConflictUpdate(
              ArtifactWorkEntriesCompanion.insert(
                workKey: key,
                stateJson: jsonEncode(state.toJson()),
                updatedAtMs: Value(state.updatedAtMs),
              ),
            );
        final count = await _entryCount();
        if (count <= maxEntries) return 0;
        final excess = count - maxEntries;
        final oldest = await (_db.select(_db.artifactWorkEntries)
              ..orderBy([
                (t) => OrderingTerm(expression: t.updatedAtMs),
                (t) => OrderingTerm(expression: t.workKey),
              ])
              ..limit(excess))
            .get();
        for (final row in oldest) {
          await (_db.delete(_db.artifactWorkEntries)
                ..where((t) => t.workKey.equals(row.workKey)))
              .go();
        }
        return excess;
      });
    } catch (e) {
      await Sentry.captureException(e);
      return 0;
    }
  }

  Future<int> _entryCount() async {
    final count = _db.artifactWorkEntries.workKey.count();
    final query = _db.selectOnly(_db.artifactWorkEntries)..addColumns([count]);
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }
}

/// Parses a work-store key ("thread:message:artifact") back into
/// its coordinates. Null for malformed keys and for the
/// coordinate-less 'local' thread, which has no server thread to
/// sync to.
WorkCoords? parseWorkKey(String key) {
  final lastColon = key.lastIndexOf(':');
  if (lastColon < 0) return null;
  final secondLastColon = key.lastIndexOf(':', lastColon - 1);
  if (secondLastColon < 0) return null;
  final threadId = key.substring(0, secondLastColon);
  final messageIndex =
      int.tryParse(key.substring(secondLastColon + 1, lastColon));
  final artifactIndex = int.tryParse(key.substring(lastColon + 1));
  if (threadId.isEmpty || threadId == 'local') return null;
  if (messageIndex == null || artifactIndex == null) return null;
  return (
    threadId: threadId,
    messageIndex: messageIndex,
    artifactIndex: artifactIndex,
  );
}
