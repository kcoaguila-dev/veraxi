import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:flutter/foundation.dart';

QueryExecutor openConnectionImpl() {
  return LazyDatabase(() async {
    final result = await WasmDatabase.open(
      databaseName: 'veraxi_local_chat_db',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );

    if (result.missingFeatures.isNotEmpty) {
      debugPrint(
          'Using Drift on web, missing features: ${result.missingFeatures}');
    }

    return result.resolvedExecutor;
  });
}
