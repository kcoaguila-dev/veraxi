import 'dart:convert';

import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The panel work a user has invested in one artifact: its version
/// history and, when shared, the published link. Persisted locally
/// so closing the panel — or the app — no longer throws the work
/// away, the way Claude keeps artifact versions with the
/// conversation. Per-device by design: this is a local store, not a
/// synced one.
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

  const ArtifactWorkState({
    required this.versions,
    required this.versionIndex,
    required this.originalCode,
    this.publishedId,
    this.publishedUrl,
    this.publishedCode,
  });

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
      };

  factory ArtifactWorkState.fromJson(Map<String, dynamic> json) {
    return ArtifactWorkState(
      versions: (json['versions'] as List<dynamic>).cast<String>(),
      versionIndex: json['versionIndex'] as int? ?? 0,
      originalCode: json['originalCode'] as String? ?? '',
      publishedId: json['publishedId'] as String?,
      publishedUrl: json['publishedUrl'] as String?,
      publishedCode: json['publishedCode'] as String?,
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

/// Persists [ArtifactWorkState] entries as one JSON map in
/// SharedPreferences. Failures are reported to Sentry and treated
/// as "nothing stored" — persistence must never break the panel.
class ArtifactWorkStore {
  static const String _prefsKey = 'artifact_work_states_v1';

  /// Oldest entries are evicted past this many artifacts.
  static const int _maxEntries = 100;

  Future<void> _writeChain = Future.value();

  Future<ArtifactWorkState?> load(String key) async {
    try {
      final all = await _readAll();
      final entry = all[key];
      if (entry == null) return null;
      return ArtifactWorkState.fromJson(entry);
    } catch (e) {
      await Sentry.captureException(e);
      return null;
    }
  }

  Future<void> save(String key, ArtifactWorkState state) async {
    // Serialize read-modify-write cycles so rapid panel actions
    // cannot interleave and drop each other's entries.
    _writeChain = _writeChain.then((_) => _saveNow(key, state));
    await _writeChain;
  }

  Future<void> _saveNow(String key, ArtifactWorkState state) async {
    try {
      final all = await _readAll();
      all.remove(key); // re-insert at the end: most recent last
      all[key] = state.toJson();
      while (all.length > _maxEntries) {
        all.remove(all.keys.first);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(all));
    } catch (e) {
      await Sentry.captureException(e);
    }
  }

  Future<Map<String, Map<String, dynamic>>> _readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (key, value) => MapEntry(
        key,
        (value as Map<dynamic, dynamic>).cast<String, dynamic>(),
      ),
    );
  }
}
